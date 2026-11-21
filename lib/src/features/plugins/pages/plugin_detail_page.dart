import 'dart:async';

import 'package:oronbox/src/app/widgets/app_scaffold_messenger.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:oronbox/src/app/generated/app_localizations.dart';
import 'package:oronbox/src/app/utils/error_localization.dart';
import 'package:oronbox/src/app/widgets/sys_app_bar.dart';
import 'package:oronbox/src/app/widgets/page_container.dart';
import 'package:oronbox/src/app/widgets/app_state_view.dart';
import 'package:oronbox/src/commands/command_protocol.dart';
import 'package:oronbox/src/core/constants/style_constants.dart';
import 'package:oronbox/src/host/application_host_provider.dart';
import 'package:oronbox/src/app/window/desktop_window.dart';
import 'package:oronbox/src/features/plugins/widgets/plugin_ui_tree.dart';

import '../widgets/plugin_icon.dart';
import 'plugin_management_page.dart';

class PluginDetailPage extends ConsumerStatefulWidget {
  const PluginDetailPage({
    super.key,
    required this.pluginId,
    this.embedded = false,
    this.allowDetach = true,
    this.onClose,
    this.onRemoved,
  });

  final String pluginId;
  final bool embedded;
  final bool allowDetach;
  final VoidCallback? onClose;
  final FutureOr<void> Function()? onRemoved;

  @override
  ConsumerState<PluginDetailPage> createState() => _PluginDetailPageState();
}

class PluginUiRouteArgs {
  const PluginUiRouteArgs({required this.nodes, required this.title});
  final Object? nodes;
  final String title;
}

class _PluginDetailPageState extends ConsumerState<PluginDetailPage> {
  late final OronBoxCommandBus _host;
  late final String _viewId;
  StreamSubscription<CommandEvent>? _events;
  Map<String, Object?>? _plugin;
  Object? _nodes;
  Object? _error;
  bool _attached = false;
  bool _viewVisible = true;
  GoRouter? _router;
  bool _pageRouteOpen = false;
  bool _loadingFeatures = true;
  int _detailRevision = 0;
  int _uiRevision = 0;
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    _viewId =
        '${DateTime.now().microsecondsSinceEpoch}-${identityHashCode(this)}';
    _host = ref.read(applicationHostProvider);
    _events = _host.events.listen(_handleEvent);
    unawaited(_load());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final router = GoRouter.maybeOf(context);
    if (!identical(_router, router)) {
      _router?.routeInformationProvider.removeListener(_routeChanged);
      _router = router;
      _router?.routeInformationProvider.addListener(_routeChanged);
    }
    _routeChanged();
  }

  void _routeChanged() {
    final uri = _router?.routeInformationProvider.value.uri;
    if (uri == null) return;
    final pluginPath = '/plugins/${Uri.encodeComponent(widget.pluginId)}';
    final visible =
        uri.path == pluginPath ||
        uri.path.startsWith('$pluginPath/') ||
        (widget.embedded && uri.path == '/plugins');
    if (_viewVisible == visible) return;
    _viewVisible = visible;
    if (_attached) {
      unawaited(_setViewVisibility(visible));
    } else if (visible && _plugin != null && _plugin?['enabled'] != false) {
      unawaited(_openFeatures());
    }
  }

  Future<void> _setViewVisibility(bool visible) async {
    final resuming = visible && _plugin?['running'] != true;
    if (mounted && resuming) {
      setState(() => _loadingFeatures = true);
    }
    try {
      await _execute(
        OronBoxCommand(
          method: 'plugin.view.visibility',
          params: {'id': widget.pluginId, 'view': _viewId, 'visible': visible},
        ),
      );
      if (mounted && visible) await _refreshDetail();
    } catch (error) {
      if (mounted && visible) setState(() => _error = error);
    } finally {
      if (mounted && resuming) {
        setState(() => _loadingFeatures = false);
      }
    }
  }

  @override
  void dispose() {
    _router?.routeInformationProvider.removeListener(_routeChanged);
    _events?.cancel();
    if (_attached) {
      unawaited(
        _host.execute(
          OronBoxCommand(
            method: 'plugin.view.detach',
            params: {'id': widget.pluginId, 'view': _viewId},
          ),
        ),
      );
    }
    super.dispose();
  }

  Future<void> _load() async {
    await _refreshDetail();
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted ||
        !_viewVisible ||
        _plugin == null ||
        _plugin!['enabled'] == false) {
      return;
    }
    await _openFeatures();
  }

  Future<void> _refreshDetail() async {
    final revision = ++_detailRevision;
    final uiRevision = _uiRevision;
    try {
      final detail = (await _execute(
        OronBoxCommand(method: 'plugin.get', params: {'id': widget.pluginId}),
      ) as Map).cast<String, Object?>();
      if (!mounted || revision != _detailRevision) return;
      setState(() {
        _plugin = detail;
        if (detail['failure'] case final Map failure) {
          _error = CommandError('plugin_error', failure['message'].toString());
        } else if (detail['running'] == true) {
          _error = null;
        }
        if (uiRevision == _uiRevision && detail.containsKey('ui')) {
          _nodes = detail['ui'];
        }
        if (detail['enabled'] == false || detail['running'] == false) {
          _nodes = null;
        }
      });
      if (!widget.allowDetach) {
        await setSecondaryWindowTitle(detail['name']?.toString() ?? '');
        await setSecondaryWindowIcon(detail['icon']?.toString());
      }
    } catch (error) {
      if (mounted && revision == _detailRevision) {
        setState(() => _error = error);
      }
    }
  }

  Future<void> _openFeatures() async {
    if (!mounted || !_viewVisible || _opening) return;
    _opening = true;
    final uiRevision = _uiRevision;
    setState(() {
      _loadingFeatures = true;
      _error = null;
    });
    _attached = true;
    try {
      final nodes = await _execute(
        OronBoxCommand(
          method: 'plugin.view.attach',
          params: {
            'id': widget.pluginId,
            'view': _viewId,
            'visible': _viewVisible,
          },
        ),
      );
      if (mounted) {
        setState(() {
          if (uiRevision == _uiRevision) _nodes = nodes;
          _loadingFeatures = false;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error;
          _loadingFeatures = false;
        });
      }
    } finally {
      _opening = false;
    }
  }

  void _handleEvent(CommandEvent event) {
    if (event.data['id']?.toString() != widget.pluginId) return;
    if (event.event == 'plugin.state') {
      unawaited(_refreshDetail());
    } else if (event.event == 'plugin.ui') {
      if (event.data['page'] == true) {
        if (!_pageRouteOpen &&
            mounted &&
            ModalRoute.of(context)?.isCurrent != false) {
          unawaited(_openNodePage(event.data['nodes']));
        }
      } else if (mounted) {
        _uiRevision++;
        setState(() {
          _nodes = event.data['nodes'];
          _loadingFeatures = false;
          _error = null;
        });
      }
    }
  }

  Future<void> _openNodePage(Object? nodes) async {
    if (!mounted || _pageRouteOpen) return;
    _pageRouteOpen = true;
    final title =
        _plugin?['name']?.toString() ??
        AppLocalizations.of(context)!.pluginFeatures;
    try {
      if (GoRouter.maybeOf(context) case final router?) {
        await router.push<void>(
          '/plugins/${Uri.encodeComponent(widget.pluginId)}/page',
          extra: PluginUiRouteArgs(nodes: nodes, title: title),
        );
      } else {
        await Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) => PluginUiPage(
              pluginId: widget.pluginId,
              preview: nodes,
              title: title,
            ),
          ),
        );
      }
    } finally {
      _pageRouteOpen = false;
    }
  }

  Future<void> _openManagement() async {
    final bool? removed;
    if (GoRouter.maybeOf(context) case final router?) {
      removed = await router.push<bool>(
        '/plugins/${Uri.encodeComponent(widget.pluginId)}/manage',
      );
    } else {
      removed = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => PluginManagementPage(pluginId: widget.pluginId),
        ),
      );
    }
    if (!mounted) return;
    if (removed == true) {
      await widget.onRemoved?.call();
      if (!mounted) return;
      if (widget.embedded) {
        widget.onClose?.call();
      } else if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      } else {
        await closeSecondaryWindow();
      }
      return;
    }
    await _refreshDetail();
    if (mounted &&
        _plugin?['enabled'] != false &&
        _plugin?['running'] != true) {
      await _openFeatures();
    }
  }

  Future<void> _invoke(String callback, [Object? value]) async {
    try {
      await _execute(
        OronBoxCommand(
          method: 'plugin.invoke',
          params: {
            'id': widget.pluginId,
            'callback': callback,
            if (value != null) 'value': value,
          },
        ),
      );
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
    }
  }

  Widget _features() {
    final l10n = AppLocalizations.of(context)!;
    if (_plugin?['enabled'] == false) {
      return EmptyStateView(
        icon: Icons.extension_off_outlined,
        title: l10n.pluginDisabled,
      );
    }
    if (_error != null) {
      return ErrorStateView(
        message: localizedErrorMessage(l10n, _error),
        onRetry: _plugin == null ? _load : _openFeatures,
      );
    }
    if (_loadingFeatures || _plugin == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_plugin?['running'] == false) {
      return EmptyStateView(
        icon: Icons.stop_circle_outlined,
        title: l10n.pluginStopped,
      );
    }
    return PluginUITree(
      root: _nodes,
      onInvoke: _invoke,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: StyleConstants.pagePadding,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final plugin = _plugin;
    return Scaffold(
      appBar: SysAppBar(
        secondary: !widget.embedded,
        fullWindow: !widget.allowDetach,
        automaticallyImplyLeading: !widget.embedded,
        title: Row(
          children: [
            if (plugin != null) ...[
              PluginIcon(
                base64: plugin['icon']?.toString(),
                path: plugin['iconPath']?.toString(),
                size: 30,
              ),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Text(
                plugin?['name']?.toString() ?? l10n.pluginFeatures,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            onPressed: plugin == null ? null : _openManagement,
            icon: const Icon(Icons.info_outline),
            tooltip: l10n.pluginDetails,
          ),
          if (widget.allowDetach && supportsSecondaryWindows)
            IconButton(
              onPressed: _detach,
              icon: const Icon(Icons.open_in_new),
              tooltip: l10n.pluginOpenWindow,
            ),
          if (widget.embedded && widget.onClose != null)
            IconButton(
              onPressed: widget.onClose,
              icon: const Icon(Icons.close),
              tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
            ),
        ],
      ),
      body: PluginViewport(pluginId: widget.pluginId, child: _features()),
    );
  }

  Future<void> _detach() async {
    final opened = await openPluginWindow(widget.pluginId);
    if (!opened || !mounted) return;
    if (widget.embedded) {
      widget.onClose?.call();
    } else {
      context.pop();
    }
  }

  Future<Object?> _execute(OronBoxCommand command) async {
    final result = await _host.execute(command);
    if (!result.ok) throw result.error!;
    return result.value;
  }
}

/// Displays the page tree currently opened by a plugin.
///
/// The host owns the runtime. This page owns its route-local UI subscription
/// and invocation bridge, including when restored directly by GoRouter.
class PluginUiPage extends ConsumerStatefulWidget {
  const PluginUiPage({
    super.key,
    required this.pluginId,
    this.preview,
    this.title = '',
  });

  final String pluginId;
  final Object? preview;
  final String title;

  @override
  ConsumerState<PluginUiPage> createState() => _PluginUiPageState();
}

class _PluginUiPageState extends ConsumerState<PluginUiPage> {
  late final OronBoxCommandBus _host;
  StreamSubscription<CommandEvent>? _events;
  Object? _nodes;
  Object? _error;
  String? _pluginName;
  int _uiRevision = 0;

  @override
  void initState() {
    super.initState();
    _host = ref.read(applicationHostProvider);
    _nodes = widget.preview;
    _pluginName = widget.title.isEmpty ? null : widget.title;
    _events = _host.events.listen(_handleEvent);
    if (_nodes == null || _pluginName == null) {
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _events?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final detail = (await _execute(
        OronBoxCommand(method: 'plugin.get', params: {'id': widget.pluginId}),
      ) as Map).cast<String, Object?>();
      final page = detail['page'];
      if (!mounted) return;
      setState(() {
        _pluginName ??= detail['name']?.toString();
        _nodes ??= page ?? const <Object?>[];
        _error = null;
      });
    } catch (error) {
      if (mounted && _nodes == null) setState(() => _error = error);
    }
  }

  void _handleEvent(CommandEvent event) {
    if (event.event == 'plugin.state' && event.data['id'] == widget.pluginId) {
      unawaited(_checkSession());
      return;
    }
    if (event.event != 'plugin.ui' ||
        event.data['id']?.toString() != widget.pluginId ||
        event.data['page'] != true ||
        !mounted) {
      return;
    }
    _uiRevision++;
    setState(() {
      _nodes = event.data['nodes'];
      _error = null;
    });
  }

  Future<void> _checkSession() async {
    final revision = _uiRevision;
    final result = await _host.execute(
      OronBoxCommand(method: 'plugin.get', params: {'id': widget.pluginId}),
    );
    if (!mounted || result.value is! Map) return;
    final detail = result.value as Map;
    if (detail['running'] == false ||
        (detail['running'] == true && detail['page'] == null)) {
      if (ModalRoute.of(context)?.isCurrent == true) {
        await Navigator.of(context).maybePop();
      }
    } else if (detail['page'] != null && revision == _uiRevision) {
      setState(() => _nodes = detail['page']);
    }
  }

  Future<void> _invoke(String callback, [Object? value]) async {
    try {
      await _execute(
        OronBoxCommand(
          method: 'plugin.invoke',
          params: {
            'id': widget.pluginId,
            'callback': callback,
            if (value != null) 'value': value,
          },
        ),
      );
    } catch (error) {
      if (!mounted) return;
      appScaffoldMessengerOf(context).showSnackBar(
        SnackBar(
          content: Text(
            localizedErrorMessage(AppLocalizations.of(context)!, error),
          ),
        ),
      );
    }
  }

  Future<Object?> _execute(OronBoxCommand command) async {
    final result = await _host.execute(command);
    if (!result.ok) throw result.error!;
    return result.value;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final title = _pluginName ?? l10n.pluginFeatures;
    final body = _nodes == null && _error == null
        ? const Center(child: CircularProgressIndicator())
        : _error != null && _nodes == null
        ? ErrorStateView(
            message: localizedErrorMessage(l10n, _error),
            onRetry: _load,
          )
        : PluginUITree(
            root: _nodes,
            onInvoke: _invoke,
            contentPadding: EdgeInsets.fromLTRB(
              StyleConstants.pagePadding,
              StyleConstants.pagePadding,
              StyleConstants.pagePadding,
              bottomContentPadding(context, extra: StyleConstants.pagePadding),
            ),
          );
    return Scaffold(
      appBar: SysAppBar(secondary: true, title: Text(title)),
      body: body,
    );
  }
}
