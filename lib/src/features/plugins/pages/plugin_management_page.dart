import '../widgets/plugin_type_badge.dart';

import 'dart:async';

import 'package:oronbox/src/app/widgets/app_scaffold_messenger.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:segmented_list/segmented_list.dart';
import 'package:oronbox/src/core/constants/style_constants.dart';

import '../domain/plugin_host_settings.dart';

import 'package:oronbox/src/app/generated/app_localizations.dart';
import 'package:oronbox/src/app/utils/error_localization.dart';
import 'package:oronbox/src/app/widgets/app_state_view.dart';
import 'package:oronbox/src/app/widgets/page_container.dart';
import 'package:oronbox/src/app/widgets/sys_app_bar.dart';
import 'package:oronbox/src/commands/command_protocol.dart';
import 'package:oronbox/src/host/application_host_provider.dart';

import '../widgets/plugin_icon.dart';
import '../widgets/plugin_permission_labels.dart';

class PluginManagementPage extends ConsumerStatefulWidget {
  const PluginManagementPage({super.key, required this.pluginId});
  final String pluginId;

  @override
  ConsumerState<PluginManagementPage> createState() =>
      _PluginManagementPageState();
}

class _PluginManagementPageState extends ConsumerState<PluginManagementPage> {
  late final OronBoxCommandBus _host;
  StreamSubscription<CommandEvent>? _events;
  Map<String, Object?>? _plugin;
  Object? _error;
  bool _busy = false;
  bool _removed = false;
  int _revision = 0;

  @override
  void initState() {
    super.initState();
    _host = ref.read(applicationHostProvider);
    _events = _host.events.listen((event) {
      if (!_removed &&
          event.event == 'plugin.state' &&
          event.data['id'] == widget.pluginId) {
        unawaited(_load());
      }
    });
    unawaited(_load());
  }

  @override
  void dispose() {
    _events?.cancel();
    super.dispose();
  }

  Future<Object?> _execute(
    String method, [
    Map<String, Object?> params = const {},
  ]) async {
    final result = await _host.execute(
      OronBoxCommand(
        method: method,
        params: {'id': widget.pluginId, ...params},
      ),
    );
    if (!result.ok) throw result.error!;
    return result.value;
  }

  Future<void> _load() async {
    final revision = ++_revision;
    try {
      final detail = (await _execute('plugin.get') as Map)
          .cast<String, Object?>();
      if (mounted && revision == _revision) {
        setState(() {
          _plugin = detail;
          _error = null;
        });
      }
    } catch (error) {
      if (mounted && revision == _revision && !_removed) {
        setState(() => _error = error);
      }
    }
  }

  Future<void> _change(String method, Map<String, Object?> params) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _execute(method, params);
      await _load();
    } catch (error) {
      if (mounted) {
        appScaffoldMessengerOf(context).showSnackBar(
          SnackBar(
            content: Text(
              localizedErrorMessage(AppLocalizations.of(context)!, error),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _uninstall() async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.pluginUninstallTitle),
        content: Text(l10n.pluginUninstallMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.uninstall),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    _removed = true;
    try {
      await _execute('plugin.remove');
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      _removed = false;
      if (mounted) {
        setState(() => _busy = false);
        appScaffoldMessengerOf(context).showSnackBar(
          SnackBar(content: Text(localizedErrorMessage(l10n, error))),
        );
      }
    }
  }

  String _backgroundLabel(PluginBackgroundMode mode) {
    final l10n = AppLocalizations.of(context)!;
    return switch (mode) {
      PluginBackgroundMode.forbidden => l10n.pluginBackgroundForbidden,
      PluginBackgroundMode.active => l10n.pluginBackgroundActive,
      PluginBackgroundMode.continuous => l10n.pluginBackgroundContinuous,
    };
  }

  String _backgroundDescription(PluginBackgroundMode mode) {
    final l10n = AppLocalizations.of(context)!;
    return switch (mode) {
      PluginBackgroundMode.forbidden =>
        l10n.pluginBackgroundForbiddenDescription,
      PluginBackgroundMode.active => l10n.pluginBackgroundDescription,
      PluginBackgroundMode.continuous =>
        l10n.pluginBackgroundContinuousDescription,
    };
  }

  Future<void> _chooseBackground(PluginBackgroundMode current) async {
    final selected = await showDialog<PluginBackgroundMode>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(AppLocalizations.of(context)!.pluginBackground),
        children: [
          RadioGroup<PluginBackgroundMode>(
            groupValue: current,
            onChanged: (value) => Navigator.of(context).pop(value),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final mode in PluginBackgroundMode.values)
                  RadioListTile<PluginBackgroundMode>(
                    value: mode,
                    title: Text(_backgroundLabel(mode)),
                    subtitle: Text(_backgroundDescription(mode)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (selected != null && mounted && selected != current) {
      await _change('plugin.settings.set', {'background': selected.name});
    }
  }

  String _permissionLabel(String decision) {
    final l10n = AppLocalizations.of(context)!;
    return switch (decision) {
      'allow' => l10n.pluginPermissionAllow,
      'deny' => l10n.pluginPermissionDeny,
      _ => l10n.pluginPermissionAsk,
    };
  }

  Future<void> _choosePermission(
    String key,
    String title,
    String current,
  ) async {
    final selected = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(title),
        children: [
          RadioGroup<String>(
            groupValue: current,
            onChanged: (value) => Navigator.of(context).pop(value),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final decision in ['ask', 'allow', 'deny'])
                  RadioListTile<String>(
                    value: decision,
                    title: Text(_permissionLabel(decision)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (selected != null && mounted && selected != current) {
      await _change('plugin.permission.set', {
        'key': key,
        'policy': {'decision': selected},
      });
    }
  }

  AbstractSegmentedTile _permission(
    String key,
    Map<String, Object?> policy, {
    String? capability,
  }) {
    final l10n = AppLocalizations.of(context)!;
    final name = capability ?? policy['capability']?.toString();
    final resource = policy['resource']?.toString();
    final title = capability == null
        ? pluginPermissionOperationLabel(l10n, policy)
        : pluginPermissionLabel(l10n, name ?? '');
    final decision = policy['decision']?.toString() ?? 'ask';
    return SegmentedTile.navigation(
      title: Text(title),
      description: resource == null || resource.isEmpty ? null : Text(resource),
      value: Text(_permissionLabel(decision)),
      enabled: !_busy,
      onPressed: (_) => _choosePermission(key, title, decision),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final plugin = _plugin;
    final policies = (plugin?['permissionPolicies'] as Map? ?? {})
        .cast<String, Object?>();
    final permissions = (plugin?['permissions'] as List? ?? []).map(
      (value) => value.toString().trim().toLowerCase(),
    );
    final scoped = policies.entries.where(
      (entry) => entry.value is Map && (entry.value as Map)['operation'] != '*',
    );
    return Scaffold(
      appBar: SysAppBar(secondary: true, title: Text(l10n.pluginDetails)),
      body: _error != null && plugin == null
          ? ErrorStateView(
              message: localizedErrorMessage(l10n, _error),
              onRetry: _load,
            )
          : plugin == null
          ? const Center(child: CircularProgressIndicator())
          : SegmentedList(
              maxWidth: StyleConstants.pageMaxWidth,
              contentPadding: EdgeInsets.only(
                top: 16,
                bottom: bottomContentPadding(context, extra: 16),
              ),
              sections: [
                CustomSegmentedSection(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            PluginIcon(
                              base64: plugin['icon']?.toString(),
                              path: plugin['iconPath']?.toString(),
                              size: 52,
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Text(
                                plugin['name']?.toString() ?? '',
                                style: Theme.of(context)
                                    .textTheme
                                    .headlineSmall,
                              ),
                            ),
                          ],
                        ),
                        if (plugin['description']?.toString().isNotEmpty ==
                            true) ...[
                          const SizedBox(height: 16),
                          Text(
                            plugin['description'].toString(),
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ],
                        const SizedBox(height: 20),
                        Row(
                          children: [
                            Expanded(
                              child: FilledButton.icon(
                                onPressed: _busy
                                    ? null
                                    : () => _change('plugin.settings.set', {
                                        'enabled': plugin['enabled'] == false,
                                      }),
                                icon: const Icon(Icons.power_settings_new),
                                label: Text(
                                  plugin['enabled'] == false
                                      ? l10n.pluginEnable
                                      : l10n.pluginDisable,
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: FilledButton.icon(
                                onPressed: _busy ? null : _uninstall,
                                icon: const Icon(Icons.delete_outline),
                                label: Text(l10n.uninstall),
                                style: FilledButton.styleFrom(
                                  backgroundColor: Theme.of(context)
                                      .colorScheme
                                      .errorContainer,
                                  foregroundColor: Theme.of(context)
                                      .colorScheme
                                      .onErrorContainer,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                SegmentedSection(
                  title: Text(l10n.pluginRunSettings),
                  tiles: [
                    SegmentedTile.switchTile(
                      leading: const Icon(Icons.rocket_launch_outlined),
                      title: Text(l10n.pluginAutoStart),
                      description: Text(l10n.pluginAutoStartDescription),
                      initialValue: plugin['autoStart'] == true,
                      enabled: !_busy,
                      onToggle: (value) => _change('plugin.settings.set', {
                        'autoStart': value ?? (plugin['autoStart'] != true),
                      }),
                    ),
                    SegmentedTile.navigation(
                      leading: const Icon(Icons.timelapse_outlined),
                      title: Text(l10n.pluginBackground),
                      value: Text(
                        _backgroundLabel(
                          PluginHostSettings.fromJson(plugin).background,
                        ),
                      ),
                      enabled: !_busy,
                      onPressed: (_) => _chooseBackground(
                        PluginHostSettings.fromJson(plugin).background,
                      ),
                    ),
                    SegmentedTile(
                      leading: const Icon(Icons.info_outline),
                      title: Text(l10n.pluginRunStatus),
                      trailing: Text(
                        plugin['running'] == true
                            ? l10n.running
                            : l10n.pluginStopped,
                      ),
                    ),
                  ],
                ),
                SegmentedSection(
                  title: Text(l10n.pluginPermissions),
                  tiles: [
                    if (permissions.isEmpty)
                      SegmentedTile(title: Text(l10n.pluginNoPermissions)),
                    for (final capability in permissions)
                      _permission(
                        capability,
                        (policies[capability] as Map? ?? {})
                            .cast<String, Object?>(),
                        capability: capability,
                      ),
                  ],
                ),
                SegmentedSection(
                  title: Text(l10n.pluginTargetPermissions),
                  tiles: [
                    if (scoped.isEmpty)
                      SegmentedTile(
                        title: Text(l10n.pluginNoTargetPermissions),
                      ),
                    for (final entry in scoped)
                      _permission(
                        entry.key,
                        (entry.value as Map).cast<String, Object?>(),
                      ),
                  ],
                ),
                SegmentedSection(
                  title: Text(l10n.pluginDetails),
                  tiles: [
                    SegmentedTile(
                      title: Text(l10n.pluginAuthor),
                      trailing: Text(plugin['author']?.toString() ?? ''),
                    ),
                    SegmentedTile(
                      title: Text(l10n.pluginVersion),
                      trailing: Text(plugin['version']?.toString() ?? ''),
                    ),
                    SegmentedTile(
                      title: Text(l10n.pluginType),
                      trailing: PluginTypeBadge(
                        runtime: plugin['runtime']?.toString(),
                      ),
                    ),
                    SegmentedTile(
                      title: Text(l10n.pluginApiLevel),
                      trailing: Text(plugin['apiLevel']?.toString() ?? ''),
                    ),
                    if (plugin['website']?.toString().isNotEmpty == true)
                      SegmentedTile.navigation(
                        title: Text(l10n.pluginWebsite),
                        description: Text(plugin['website'].toString()),
                        onPressed: (_) async {
                          final uri = Uri.tryParse(
                            plugin['website'].toString(),
                          );
                          if (uri != null) await launchUrl(uri);
                        },
                      ),
                  ],
                ),
              ],
            ),
    );
  }
}
