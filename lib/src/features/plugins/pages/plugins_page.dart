import 'dart:async';
import 'dart:convert';

import 'package:oronbox/src/app/widgets/app_scaffold_messenger.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:oronbox/src/app/generated/app_localizations.dart';
import 'package:oronbox/src/app/theme/app_theme.dart';
import 'package:oronbox/src/app/utils/error_localization.dart';
import 'package:oronbox/src/app/utils/picked_file.dart';
import 'package:oronbox/src/app/widgets/app_state_view.dart';
import 'package:oronbox/src/app/widgets/page_container.dart';
import 'package:oronbox/src/app/widgets/sys_app_bar.dart';
import 'package:oronbox/src/app/window/desktop_window.dart';
import 'package:oronbox/src/commands/command_protocol.dart';
import 'package:oronbox/src/core/utils/layout.dart';
import 'package:oronbox/src/core/constants/style_constants.dart';
import 'package:oronbox/src/features/plugins/domain/plugin_package.dart';
import 'package:oronbox/src/features/plugins/widgets/plugin_install_confirmation.dart';
import 'package:oronbox/src/host/application_host_provider.dart';

import '../widgets/plugin_icon.dart';
import '../widgets/plugin_summary.dart';
import 'plugin_detail_page.dart';

class PluginsPage extends ConsumerStatefulWidget {
  const PluginsPage({super.key, this.targetPluginId = ''});
  final String targetPluginId;

  @override
  ConsumerState<PluginsPage> createState() => _PluginsPageState();
}

class _PluginsPageState extends ConsumerState<PluginsPage> {
  StreamSubscription<CommandEvent>? _events;
  var _plugins = <Map<String, Object?>>[];
  var _loading = true;
  var _query = '';
  var _section = 0;
  var _sources = <Map<String, Object?>>[];
  String? _marketSource;
  var _marketEntries = <Map<String, Object?>>[];
  var _marketLoading = false;
  var _marketRequest = 0;
  Object? _marketError;
  final _installing = <String>{};
  String? _selectedPluginId;
  var _safeMode = false;

  @override
  void initState() {
    super.initState();
    _events = ref.read(applicationHostProvider).events.listen((event) {
      if (event.event == 'plugin.state') unawaited(_load());
    });
    if (widget.targetPluginId.isNotEmpty) {
      _section = 1;
      _query = widget.targetPluginId;
    }
    _load().then((_) {
      if (mounted && widget.targetPluginId.isNotEmpty) _loadMarket(force: true);
    });
  }

  @override
  void dispose() {
    _events?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    try {
      final values = await Future.wait([
        _execute(
          OronBoxCommand(
            method: 'plugin.list',
            params: {'includeIcons': kIsWeb},
          ),
        ),
        _execute(const OronBoxCommand(method: 'plugin.safeMode.get')),
        _execute(const OronBoxCommand(method: 'plugin.repositories')),
      ]);
      if (!mounted) return;
      setState(() {
        _plugins = (values[0] as List)
            .whereType<Map>()
            .map((row) => row.cast<String, Object?>())
            .toList(growable: false);
        _safeMode = (values[1] as Map?)?['enabled'] == true;
        _sources = (values[2] as List)
            .whereType<Map>()
            .map((row) => row.cast<String, Object?>())
            .toList(growable: false);
        if (!_sources.any((source) => source['id'] == _marketSource)) {
          _marketSource = _sources.firstOrNull?['id']?.toString();
        }
        final ids = _plugins.map((plugin) => plugin['id']?.toString()).toSet();
        if (!ids.contains(_selectedPluginId)) {
          _selectedPluginId = null;
        }
      });
    } catch (error) {
      if (mounted) _showError(error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadMarket({bool force = false}) async {
    final source = _marketSource;
    if (source == null) return;
    if (!force && _marketEntries.isNotEmpty) return;
    final request = ++_marketRequest;
    setState(() {
      _marketLoading = true;
      _marketError = null;
    });
    try {
      final value = await _execute(
        OronBoxCommand(
          method: 'plugin.repository.catalog',
          params: {'source': source, 'force': force},
        ),
      );
      if (mounted && request == _marketRequest) {
        setState(
          () => _marketEntries = (value as List)
              .whereType<Map>()
              .map((row) => row.cast<String, Object?>())
              .toList(growable: false),
        );
      }
    } catch (error) {
      if (mounted && request == _marketRequest) {
        setState(() => _marketError = error);
      }
    } finally {
      if (mounted && request == _marketRequest) {
        setState(() => _marketLoading = false);
      }
    }
  }

  Future<void> _openInstalledPlugin(String id, {required bool wide}) async {
    await takePluginWindow(id);
    if (!mounted) return;
    if (wide) {
      setState(() => _selectedPluginId = id);
    } else {
      context.push('/plugins/$id');
    }
  }

  Future<Uint8List?> _pickPackage(List<String> extensions) async {
    final picked = await pickFileData(
      type: FileType.custom,
      allowedExtensions: extensions,
      loadBytes: true,
    );
    if (picked == null) return null;
    final bytes = await picked.readAsBytes();
    if (bytes == null) {
      _showError(StateError('Unable to read ${picked.name}'));
    }
    return bytes;
  }

  Future<void> _importPlugin() async {
    final bytes = await _pickPackage(const ['obp', 'abp', 'zip']);
    if (bytes == null) return;
    if (!mounted) return;
    try {
      final package = const PluginPackageReader().read(bytes);
      final manifest = package.manifest;
      final updating = _plugins.any(
        (plugin) => plugin['id']?.toString() == manifest.id,
      );
      if (!await confirmPluginInstall(
        context: context,
        name: manifest.name,
        author: manifest.author,
        version: manifest.version,
        description: manifest.description,
        runtime: manifest.runtime.manifestValue,
        icon: PluginIcon(
          base64: manifest.iconPath == null
              ? null
              : base64Encode(package.files[manifest.iconPath] ?? const []),
          size: 56,
        ),
        permissions: manifest.permissions,
        updating: updating,
      )) {
        return;
      }
      await _execute(
        OronBoxCommand(
          method: 'plugin.install',
          params: {'bytes': base64Encode(bytes), 'includeIcon': false},
        ),
      );
      await _load();
    } catch (error) {
      if (mounted) _showError(error);
    }
  }

  Future<void> _installMarketPlugin(Map<String, Object?> entry) async {
    final id = entry['id']?.toString() ?? '';
    if (_installing.contains(id)) return;
    setState(() => _installing.add(id));
    try {
      await _execute(
        OronBoxCommand(
          method: 'plugin.repository.install',
          params: {'source': entry['source']?.toString() ?? '', 'id': id},
        ),
      );
      await _load();
      await _loadMarket(force: true);
    } catch (error) {
      if (mounted) _showError(error);
    } finally {
      if (mounted) setState(() => _installing.remove(id));
    }
  }

  Future<void> _showMarketEntry(Map<String, Object?> entry) async {
    final confirmed = await confirmPluginInstall(
      context: context,
      name: entry['name']?.toString() ?? '',
      author: entry['author']?.toString() ?? '',
      version: entry['version']?.toString() ?? '',
      description: entry['description']?.toString() ?? '',
      runtime: entry['runtime']?.toString(),
      icon: _MarketIcon(iconUrl: entry['iconUrl']?.toString(), size: 56),
      permissions: (entry['permissions'] as List? ?? const [])
          .map((value) => value.toString())
          .toList(growable: false),
      installed: entry['installed'] == true,
      updating: entry['updateAvailable'] == true,
    );
    if (confirmed && mounted) await _installMarketPlugin(entry);
  }

  Future<void> _exitSafeMode() async {
    await _execute(
      const OronBoxCommand(
        method: 'plugin.safeMode.set',
        params: {'enabled': false},
      ),
    );
    if (mounted) setState(() => _safeMode = false);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final query = _query.trim().toLowerCase();
    bool matches(Iterable<Object?> values) => values.any(
      (value) => value?.toString().toLowerCase().contains(query) ?? false,
    );
    final visiblePlugins = query.isEmpty
        ? _plugins
        : _plugins
              .where(
                (plugin) => matches([
                  plugin['name'],
                  plugin['description'],
                  plugin['author'],
                ]),
              )
              .toList(growable: false);
    final visibleEntries = query.isEmpty
        ? _marketEntries
        : _marketEntries
              .where(
                (entry) => matches([
                  entry['id'],
                  entry['name'],
                  entry['description'],
                  entry['author'],
                ]),
              )
              .toList(growable: false);
    return Scaffold(
      appBar: SysAppBar(
        title: Text(l10n.pluginsTab),
        actions: [
          if (_section == 1) ...[
            _PluginSourceMenu(
              sources: _sources,
              selected: _marketSource,
              onSelected: (source) {
                setState(() {
                  _marketSource = source;
                  _marketEntries = const [];
                });
                _loadMarket();
              },
            ),
          ],
          IconButton(
            onPressed: _importPlugin,
            icon: const Icon(Icons.add),
            tooltip: l10n.pluginImport,
          ),
          IconButton(
            onPressed: _section == 0 ? _load : () => _loadMarket(force: true),
            icon: const Icon(Icons.refresh),
            tooltip: l10n.refresh,
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final wide = useWideLayout(constraints.maxWidth);
          final catalog = _PluginCatalog(
            section: _section,
            loading: _loading,
            plugins: visiblePlugins,
            entries: visibleEntries,
            marketLoading: _marketLoading,
            marketError: _marketError,
            installing: _installing,
            selectedPluginId: wide ? _selectedPluginId : null,
            emptyText: query.isEmpty
                ? l10n.pluginEmpty
                : l10n.pluginSearchEmpty,
            marketEmptyText: query.isEmpty
                ? l10n.pluginMarketEmpty
                : l10n.pluginSearchEmpty,
            installedLabel: l10n.pluginInstalled,
            marketLabel: l10n.pluginMarket,
            onQueryChanged: (value) => setState(() => _query = value),
            onSectionChanged: (value) {
              setState(() => _section = value);
              if (value == 1) _loadMarket();
            },
            onRefreshMarket: () => _loadMarket(force: true),
            onOpenEntry: _showMarketEntry,
            onOpen: (id) => _openInstalledPlugin(id, wide: wide),
          );
          return PageContainer(
            maxWidth: wide ? 1280 : 1000,
            padding: const EdgeInsets.fromLTRB(
              StyleConstants.pagePadding,
              0,
              StyleConstants.pagePadding,
              0,
            ),
            child: Column(
              children: [
                if (_safeMode) ...[
                  _PluginSafeModeBanner(onExit: _exitSafeMode),
                  const SizedBox(height: 12),
                ],
                Expanded(
                  child: Row(
                    children: [
                      if (wide)
                        SizedBox(width: 360, child: catalog)
                      else
                        Expanded(child: catalog),
                      if (wide) ...[
                        const SizedBox(width: 24),
                        Expanded(
                          child: _selectedPluginId == null
                              ? _PluginSelectionPlaceholder(
                                  text: l10n.pluginSelectHint,
                                )
                              : PluginDetailPage(
                                  key: ValueKey(_selectedPluginId),
                                  pluginId: _selectedPluginId!,
                                  embedded: true,
                                  onClose: () =>
                                      setState(() => _selectedPluginId = null),
                                  onRemoved: _load,
                                ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<Object?> _execute(OronBoxCommand command) async {
    final result = await ref.read(applicationHostProvider).execute(command);
    if (!result.ok) {
      throw result.error!;
    }
    return result.value;
  }

  void _showError(Object error) {
    if (_isPluginPackageError(error)) {
      unawaited(_showPluginPackageCorruptedDialog());
      return;
    }
    final l10n = AppLocalizations.of(context)!;
    appScaffoldMessengerOf(
      context,
    ).showSnackBar(SnackBar(content: Text(localizedErrorMessage(l10n, error))));
  }

  Future<void> _showPluginPackageCorruptedDialog() async {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.pluginErrorTitle),
        content: Text(l10n.pluginPackageCorruptedMessage),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.close),
          ),
        ],
      ),
    );
  }

  bool _isPluginPackageError(Object error) {
    final message = switch (error) {
      CommandError(:final message) => message,
      FormatException(:final message) => message,
      _ => error.toString(),
    };
    return message.contains('ABP manifest.json is missing') ||
        message.contains('ABP package') ||
        message.contains('ABP entry is missing');
  }
}

class _PluginSourceMenu extends StatelessWidget {
  const _PluginSourceMenu({
    required this.sources,
    required this.selected,
    required this.onSelected,
  });

  final List<Map<String, Object?>> sources;
  final String? selected;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final current = sources
        .where((source) => source['id'] == selected)
        .firstOrNull;
    return MenuAnchor(
      menuChildren: sources
          .map(
            (source) => MenuItemButton(
              trailingIcon: source['id'] == selected
                  ? Icon(
                      Icons.check,
                      color: Theme.of(context).colorScheme.primary,
                    )
                  : null,
              onPressed: source['id'] == selected
                  ? null
                  : () => onSelected(source['id'].toString()),
              child: Text(source['name']?.toString() ?? ''),
            ),
          )
          .toList(growable: false),
      builder: (context, controller, child) => TextButton(
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(current?['name']?.toString() ?? ''),
            const Icon(Icons.arrow_drop_down),
          ],
        ),
      ),
    );
  }
}

class _PluginSafeModeBanner extends StatelessWidget {
  const _PluginSafeModeBanner({required this.onExit});

  final VoidCallback onExit;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = Theme.of(context).colorScheme;
    return ColoredBox(
      color: Theme.of(context).useMaterial3
          ? colors.secondaryContainer
          : context.appSelectionContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Icon(
              Icons.shield_outlined,
              color: Theme.of(context).useMaterial3
                  ? colors.onSecondaryContainer
                  : context.appSelectionForeground,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.pluginSafeModeTitle,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  Text(l10n.pluginSafeModeDescription),
                ],
              ),
            ),
            TextButton(onPressed: onExit, child: Text(l10n.pluginSafeModeExit)),
          ],
        ),
      ),
    );
  }
}

class _PluginCatalog extends StatelessWidget {
  const _PluginCatalog({
    required this.section,
    required this.loading,
    required this.plugins,
    required this.entries,
    required this.marketLoading,
    required this.marketError,
    required this.installing,
    required this.selectedPluginId,
    required this.emptyText,
    required this.marketEmptyText,
    required this.installedLabel,
    required this.marketLabel,
    required this.onQueryChanged,
    required this.onSectionChanged,
    required this.onRefreshMarket,
    required this.onOpenEntry,
    required this.onOpen,
  });

  final int section;
  final bool loading;
  final List<Map<String, Object?>> plugins;
  final List<Map<String, Object?>> entries;
  final bool marketLoading;
  final Object? marketError;
  final Set<String> installing;
  final String? selectedPluginId;
  final String emptyText;
  final String marketEmptyText;
  final String installedLabel;
  final String marketLabel;
  final ValueChanged<String> onQueryChanged;
  final ValueChanged<int> onSectionChanged;
  final VoidCallback onRefreshMarket;
  final ValueChanged<Map<String, Object?>> onOpenEntry;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 600;
    return Column(
      children: [
        SegmentedButton<int>(
          showSelectedIcon: false,
          style: ButtonStyle(
            visualDensity: VisualDensity.compact,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            side: const WidgetStatePropertyAll(BorderSide.none),
            backgroundColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.selected)) {
                return Theme.of(context).colorScheme.secondaryContainer;
              }
              return Theme.of(context).colorScheme.surfaceContainerHighest
                  .withValues(alpha: 0.5);
            }),
          ),
          segments: [
            ButtonSegment(
              value: 0,
              label: Text(
                installedLabel,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
              ),
              icon: const Icon(Icons.extension_outlined),
            ),
            ButtonSegment(
              value: 1,
              label: Text(
                marketLabel,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
              ),
              icon: const Icon(Icons.storefront_outlined),
            ),
          ],
          selected: {section},
          onSelectionChanged: (value) => onSectionChanged(value.first),
        ),
        SizedBox(height: compact ? 10 : StyleConstants.pagePadding),
        SearchBar(
          constraints: BoxConstraints.tightFor(height: compact ? 48 : 56),
          elevation: const WidgetStatePropertyAll(0),
          leading: const Icon(Icons.search),
          hintText: AppLocalizations.of(context)!.search,
          onChanged: onQueryChanged,
        ),
        const SizedBox(height: 12),
        Expanded(
          child: section == 0
              ? _InstalledPlugins(
                  loading: loading,
                  plugins: plugins,
                  selectedPluginId: selectedPluginId,
                  onOpen: onOpen,
                  emptyText: emptyText,
                )
              : _PluginMarket(
                  loading: marketLoading,
                  error: marketError,
                  entries: entries,
                  installing: installing,
                  emptyText: marketEmptyText,
                  onRefresh: onRefreshMarket,
                  onOpen: onOpenEntry,
                ),
        ),
      ],
    );
  }
}

class _InstalledPlugins extends StatelessWidget {
  const _InstalledPlugins({
    required this.loading,
    required this.plugins,
    required this.selectedPluginId,
    required this.onOpen,
    required this.emptyText,
  });

  final bool loading;
  final List<Map<String, Object?>> plugins;
  final String? selectedPluginId;
  final ValueChanged<String> onOpen;
  final String emptyText;

  @override
  Widget build(BuildContext context) {
    if (loading) return const Center(child: CircularProgressIndicator());
    if (plugins.isEmpty) {
      return EmptyStateView(icon: Icons.extension_outlined, title: emptyText);
    }

    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 16),
      itemCount: plugins.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final plugin = plugins[index];
        return _PluginCard(
          plugin: plugin,
          onTap: () => onOpen(plugin['id']!.toString()),
        );
      },
    );
  }
}

class _PluginCard extends StatelessWidget {
  const _PluginCard({required this.plugin, required this.onTap});

  final Map<String, Object?> plugin;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme;
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: color.surfaceContainerHighest.withValues(alpha: .5),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: PluginSummary(
            name: plugin['name']?.toString() ?? '',
            author: plugin['author']?.toString() ?? '',
            version: plugin['version']?.toString() ?? '',
            runtime: plugin['runtime']?.toString(),
            compact: true,
            icon: PluginIcon(
              base64: plugin['icon']?.toString(),
              path: plugin['iconPath']?.toString(),
              size: 56,
            ),
          ),
        ),
      ),
    );
  }
}

class _PluginSelectionPlaceholder extends StatelessWidget {
  const _PluginSelectionPlaceholder({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return EmptyStateView(icon: Icons.extension_outlined, title: text);
  }
}

class _PluginMarket extends StatelessWidget {
  const _PluginMarket({
    required this.loading,
    required this.error,
    required this.entries,
    required this.installing,
    required this.emptyText,
    required this.onRefresh,
    required this.onOpen,
  });

  final bool loading;
  final Object? error;
  final List<Map<String, Object?>> entries;
  final Set<String> installing;
  final String emptyText;
  final VoidCallback onRefresh;
  final ValueChanged<Map<String, Object?>> onOpen;

  @override
  Widget build(BuildContext context) {
    if (loading && entries.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (error != null && entries.isEmpty) {
      return ErrorStateView(
        message: localizedErrorMessage(AppLocalizations.of(context)!, error),
        onRetry: onRefresh,
      );
    }
    if (entries.isEmpty) {
      return EmptyStateView(icon: Icons.extension_outlined, title: emptyText);
    }
    return RefreshIndicator(
      onRefresh: () async => onRefresh(),
      child: ListView.separated(
        padding: EdgeInsets.only(
          bottom: bottomContentPadding(context, extra: 16),
        ),
        itemCount: entries.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final entry = entries[index];
          final id = entry['id']?.toString() ?? '';
          final isInstalling = installing.contains(id);
          final installed = entry['installed'] == true;
          final updateAvailable = entry['updateAvailable'] == true;
          return Card(
            elevation: 0,
            margin: EdgeInsets.zero,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => onOpen(entry),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Expanded(
                      child: PluginSummary(
                        name: entry['name']?.toString() ?? '',
                        author: entry['author']?.toString() ?? '',
                        version: entry['version']?.toString() ?? '',
                        runtime: entry['runtime']?.toString(),
                        compact: true,
                        icon: _MarketIcon(
                          iconUrl: entry['iconUrl']?.toString(),
                          size: 56,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    isInstalling
                        ? IconButton.filledTonal(
                            onPressed: null,
                            icon: const SizedBox.square(
                              dimension: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : IconButton.filledTonal(
                            onPressed: () => onOpen(entry),
                            icon: Icon(
                              installed && !updateAvailable
                                  ? Icons.check_rounded
                                  : updateAvailable
                                  ? Icons.upgrade_rounded
                                  : Icons.add_rounded,
                            ),
                            tooltip: installed && !updateAvailable
                                ? AppLocalizations.of(context)!.pluginUpToDate
                                : updateAvailable
                                ? AppLocalizations.of(context)!.update
                                : AppLocalizations.of(context)!.install,
                          ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _MarketIcon extends StatelessWidget {
  const _MarketIcon({required this.iconUrl, required this.size});

  final String? iconUrl;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    Widget fallback(BuildContext context) => ColoredBox(
      color: Theme.of(context).useMaterial3
          ? colors.secondaryContainer
          : context.appSelectionContainer,
      child: Icon(
        Icons.extension,
        color: Theme.of(context).useMaterial3
            ? colors.onSecondaryContainer
            : context.appSelectionForeground,
      ),
    );
    final url = iconUrl;
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.22),
      child: SizedBox.square(
        dimension: size,
        child: url == null
            ? fallback(context)
            : Image.network(
                url,
                fit: BoxFit.cover,
                errorBuilder: (context, _, _) => fallback(context),
                loadingBuilder: (context, child, progress) =>
                    progress == null ? child : fallback(context),
              ),
      ),
    );
  }
}
