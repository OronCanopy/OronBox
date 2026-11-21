import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:cross_file/cross_file.dart';
import 'package:oronbox/src/features/resources/services/install_queue_notifier.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:oronbox/src/app/generated/app_localizations.dart';
import 'package:oronbox/src/app/utils/picked_file.dart';
import 'package:oronbox/src/app/utils/error_localization.dart';
import 'package:oronbox/src/app/widgets/app_scaffold_messenger.dart';
import 'package:oronbox/src/app/router/app_router.dart';
import 'package:oronbox/src/commands/command_protocol.dart';
import 'package:oronbox/src/host/application_host_provider.dart';

import 'plugin_ui_tree.dart';
import 'plugin_permission_labels.dart';

class PluginHostRequestHandler extends ConsumerStatefulWidget {
  const PluginHostRequestHandler({
    super.key,
    required this.child,
    this.reportLifecycle = true,
    this.pluginId,
  });

  final Widget child;
  final bool reportLifecycle;
  final String? pluginId;

  @override
  ConsumerState<PluginHostRequestHandler> createState() =>
      _PluginHostRequestHandlerState();
}

class _PluginHostRequestHandlerState
    extends ConsumerState<PluginHostRequestHandler>
    with WidgetsBindingObserver {
  late final OronBoxCommandBus _host;
  late final String _owner;
  StreamSubscription<CommandEvent>? _subscription;
  final _renderSizes = <String, Size>{};
  final _requests = <CommandEvent>[];
  bool _draining = false;
  bool _foreground = true;
  String? _activeRequest;
  DialogRoute<String>? _dialogRoute;
  final _shownFailures = <String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _owner =
        '${DateTime.now().microsecondsSinceEpoch}-${identityHashCode(this)}';
    _host = ref.read(applicationHostProvider);
    _subscription = _host.events.listen(_onEvent);
    if (!_foreground) _reportLifecycle(false);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _reportLifecycle(_foreground, state: state);
    if (_foreground) unawaited(_drain());
  }

  void _reportLifecycle(bool foreground, {AppLifecycleState? state}) {
    final mobile =
        !kIsWeb &&
        {
          TargetPlatform.android,
          TargetPlatform.iOS,
        }.contains(defaultTargetPlatform);
    if (mobile &&
        widget.reportLifecycle &&
        state != AppLifecycleState.inactive) {
      unawaited(
        _host.execute(
          OronBoxCommand(
            method: 'plugin.lifecycle',
            params: {'foreground': foreground},
          ),
        ),
      );
    }
  }

  void _onEvent(CommandEvent event) {
    if (event.event == 'plugin.notice') {
      if (widget.pluginId != null &&
          event.data['pluginId'] != widget.pluginId) {
        return;
      }
      if (!_foreground || !mounted) return;
      final navigator = rootNavigatorKey.currentContext ?? context;
      appScaffoldMessengerOf(navigator).showSnackBar(
        SnackBar(
          content: Text(
            localizedErrorMessage(
              AppLocalizations.of(navigator)!,
              event.data['code'],
            ),
          ),
        ),
      );
      return;
    }
    if (widget.pluginId != null &&
        (event.event == 'plugin.hostRequest' ||
            event.event == 'plugin.error') &&
        event.data['pluginId'] != widget.pluginId) {
      return;
    }
    if (event.event == 'plugin.hostCancelled') {
      final id = event.data['requestId'];
      _requests.removeWhere((item) => item.data['requestId'] == id);
      if (_activeRequest == id) {
        final route = _dialogRoute;
        if (route != null && route.isActive) {
          route.navigator?.removeRoute(route);
        }
      }
      return;
    }
    if (event.event != 'plugin.hostRequest' && event.event != 'plugin.error') {
      return;
    }
    if (event.event == 'plugin.hostRequest' &&
        {'renderSize', 'enqueueFile'}.contains(event.data['type'])) {
      unawaited(_handle(event.data));
      return;
    }
    _requests.add(event);
    unawaited(_drain());
  }

  Future<void> _drain() async {
    if (_draining || !_foreground || !mounted) return;
    _draining = true;
    try {
      while (mounted && _foreground && _requests.isNotEmpty) {
        final event = _requests.removeAt(0);
        _activeRequest = event.data['requestId']?.toString();
        if (event.event == 'plugin.hostRequest') {
          final pending = await _host.execute(
            OronBoxCommand(
              method: 'plugin.host.pending',
              params: {'requestId': _activeRequest},
            ),
          );
          if (pending.value != true) continue;
          if (!_foreground) {
            _requests.insert(0, event);
            break;
          }
          await _handle(event.data);
        } else {
          await _handlePluginFailure(event.data);
        }
      }
    } finally {
      _activeRequest = null;
      _draining = false;
    }
  }

  Future<String?> _showDialog({
    required BuildContext context,
    required WidgetBuilder builder,
    bool barrierDismissible = true,
  }) async {
    if (_activeRequest case final requestId?) {
      final pending = await _host.execute(
        OronBoxCommand(
          method: 'plugin.host.pending',
          params: {'requestId': requestId},
        ),
      );
      if (!mounted || !context.mounted || pending.value != true) return null;
    }
    if (!context.mounted) return null;
    final route = DialogRoute<String>(
      context: context,
      builder: builder,
      barrierDismissible: barrierDismissible,
    );
    _dialogRoute = route;
    try {
      return await Navigator.of(context, rootNavigator: true).push(route);
    } finally {
      if (identical(_dialogRoute, route)) _dialogRoute = null;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _subscription?.cancel();
    final route = _dialogRoute;
    if (route != null) {
      scheduleMicrotask(() {
        if (route.isActive && route.navigator?.mounted == true) {
          route.navigator!.removeRoute(route);
        }
      });
    }
    unawaited(
      _host.execute(
        OronBoxCommand(
          method: 'plugin.host.release',
          params: {'owner': _owner},
        ),
      ),
    );
    super.dispose();
  }

  Future<void> _handle(Map<String, Object?> request) async {
    final requestId = request['requestId']?.toString() ?? '';
    if (requestId.isEmpty) return;
    final claimed = await _host.execute(
      OronBoxCommand(
        method: 'plugin.host.claim',
        params: {'requestId': requestId, 'owner': _owner},
      ),
    );
    if (claimed.value != true) return;
    if (!mounted ||
        (!_foreground &&
            !{'renderSize', 'enqueueFile'}.contains(request['type']))) {
      await _host.execute(
        OronBoxCommand(
          method: 'plugin.host.release',
          params: {'owner': _owner, 'requestId': requestId},
        ),
      );
      return;
    }
    Map<String, Object?> response;
    try {
      response = switch (request['type']?.toString()) {
        'permission' => await _permission(request),
        'pickFile' => await _pickFile(request),
        'saveFile' => await _saveFile(request),
        'enqueueFile' => await _enqueueFile(request),
        'openUrl' => await _openUrl(request),
        'dialog' => await _dialog(request),
        'renderSize' => await _renderSize(request),
        _ => const {'cancelled': true, 'error': 'Unsupported host request'},
      };
    } catch (error) {
      response = {'cancelled': true, 'error': error.toString()};
    }
    if (!mounted) return;
    await _host.execute(
      OronBoxCommand(
        method: 'plugin.host.respond',
        params: {'requestId': requestId, 'response': response, 'owner': _owner},
      ),
    );
  }

  Future<Map<String, Object?>> _dialog(Map<String, Object?> request) async {
    final navigator = await _waitForNavigator();
    if (!mounted || navigator == null) return const {'cancelled': true};
    final dialogContext = navigator.context;
    if (!dialogContext.mounted) return const {'cancelled': true};
    final l10n = AppLocalizations.of(dialogContext)!;
    final buttons =
        (request['buttons'] as List?)
            ?.whereType<Map>()
            .map((button) => button.cast<String, Object?>())
            .take(4)
            .toList(growable: false) ??
        const <Map<String, Object?>>[];
    final input = TextEditingController();
    final clicked = await _showDialog(
      context: dialogContext,
      builder: (context) => AlertDialog(
        title: Text(request['title']?.toString() ?? ''),
        content: request['input'] == true
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(request['message']?.toString() ?? ''),
                  TextField(controller: input, autofocus: true),
                ],
              )
            : Text(request['message']?.toString() ?? ''),
        actions: buttons.isEmpty
            ? [
                TextButton(
                  onPressed: () => Navigator.pop(context, 'ok'),
                  child: Text(l10n.understood),
                ),
              ]
            : buttons
                  .map((button) {
                    final id = button['id']?.toString() ?? '';
                    final label = button['text']?.toString() ?? id;
                    return button['primary'] == true
                        ? FilledButton(
                            onPressed: id.isEmpty
                                ? null
                                : () => Navigator.pop(context, id),
                            child: Text(label),
                          )
                        : TextButton(
                            onPressed: id.isEmpty
                                ? null
                                : () => Navigator.pop(context, id),
                            child: Text(label),
                          );
                  })
                  .toList(growable: false),
      ),
    );
    final value = input.text;
    input.dispose();
    return clicked == null
        ? const {'cancelled': true}
        : {'clickedBtnId': clicked, 'inputResult': value};
  }

  Future<Map<String, Object?>> _renderSize(Map<String, Object?> request) async {
    if (_foreground) await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return const {'width': 0.0, 'height': 0.0};
    final id = request['pluginId'] as String;
    final viewport = ref
        .read(pluginViewportKeyProvider(id))
        .currentContext
        ?.findRenderObject();
    if (viewport is RenderBox && viewport.hasSize) {
      _renderSizes[id] = viewport.size;
    }
    final view = View.of(context);
    final size = _renderSizes[id] ?? view.physicalSize / view.devicePixelRatio;
    return {'width': size.width, 'height': size.height};
  }

  Future<Map<String, Object?>> _permission(Map<String, Object?> request) async {
    final navigator = await _waitForNavigator();
    if (!mounted || navigator == null) return const {'decision': 'deny'};
    final dialogContext = navigator.context;
    if (!dialogContext.mounted) return const {'decision': 'deny'};
    final l10n = AppLocalizations.of(dialogContext)!;
    final plugin =
        request['pluginName']?.toString() ??
        request['pluginId']?.toString() ??
        l10n.pluginsTab;
    final operation = _permissionOperation(request, l10n);
    final decision = await _showDialog(
      context: dialogContext,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text(l10n.pluginPermissionRequestTitle),
        content: Text(l10n.pluginPermissionRequestMessage(plugin, operation)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'deny'),
            child: Text(l10n.pluginPermissionDeny),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'once'),
            child: Text(l10n.pluginPermissionOnce),
          ),
          if (request['capability'] != 'mass.firmware')
            TextButton(
              onPressed: () => Navigator.pop(context, 'session'),
              child: Text(l10n.pluginPermissionSession),
            ),
          if (request['capability'] != 'mass.firmware')
            FilledButton(
              onPressed: () => Navigator.pop(context, 'always'),
              child: Text(l10n.pluginPermissionAlways),
            ),
        ],
      ),
    );
    return {'decision': decision ?? 'deny'};
  }

  String _permissionOperation(
    Map<String, Object?> request,
    AppLocalizations l10n,
  ) {
    final operation = pluginPermissionOperationLabel(l10n, request);
    final resource = request['resource']?.toString().trim() ?? '';
    return resource.isEmpty ? operation : '$operation ($resource)';
  }

  Future<Map<String, Object?>> _pickFile(Map<String, Object?> request) async {
    final extensions = (request['extensions'] as List? ?? const [])
        .cast<String>()
        .map((extension) => extension.replaceFirst(RegExp(r'^\*?\.'), ''))
        .where((extension) => extension.isNotEmpty && extension != '*')
        .toList();
    final files = await pickFilesData(
      type: extensions.isEmpty ? FileType.any : FileType.custom,
      allowedExtensions: extensions.isEmpty ? null : extensions,
      allowMultiple: request['multiple'] == true,
      initialDirectory: request['default-directory']?.toString(),
      loadBytes: true,
    );
    final selected = files.firstOrNull;
    final bytes = await selected?.readAsBytes();
    if (selected == null || bytes == null) return const {'cancelled': true};
    return {
      'cancelled': false,
      'name': selected.name,
      'bytes': bytes.toList(growable: false),
    };
  }

  Future<Map<String, Object?>> _enqueueFile(
    Map<String, Object?> request,
  ) async {
    final type = LocalDeviceInstallType.values.byName(
      request['resourceType'] as String,
    );
    await ref
        .read(installQueueProvider.notifier)
        .enqueueLocalFile(
          XFile.fromData(
            Uint8List.fromList((request['bytes'] as List).cast<int>()),
            name: request['name'] as String,
          ),
          type: type,
        );
    return {'queued': true};
  }

  Future<Map<String, Object?>> _saveFile(Map<String, Object?> request) async {
    final bytes = Uint8List.fromList(
      (request['bytes'] as List? ?? const [])
          .whereType<num>()
          .map((value) => value.toInt() & 0xff)
          .toList(growable: false),
    );
    final path = await FilePicker.saveFile(
      fileName: request['name']?.toString() ?? 'oronbox-export.bin',
      bytes: bytes,
    );
    return {
      'exported': path != null,
      if (path == null) 'cancelled': true,
      if (path != null) 'name': request['name']?.toString() ?? '',
    };
  }

  Future<Map<String, Object?>> _openUrl(Map<String, Object?> request) async {
    final uri = Uri.tryParse(request['url']?.toString() ?? '');
    if (uri == null) throw const FormatException('Invalid URL');
    return {'opened': await launchUrl(uri)};
  }

  Future<void> _handlePluginFailure(Map<String, Object?> failure) async {
    final pluginId = failure['pluginId']?.toString() ?? '';
    final occurredAt = failure['occurredAt']?.toString() ?? '';
    final key = '$pluginId:$occurredAt';
    if (pluginId.isEmpty || _shownFailures.contains(key)) return;
    final navigator = await _waitForNavigator();
    if (!mounted || navigator == null || !_shownFailures.add(key)) return;
    final dialogContext = navigator.context;
    if (!dialogContext.mounted) return;
    final l10n = AppLocalizations.of(dialogContext)!;
    final pluginName = failure['pluginName']?.toString() ?? pluginId;
    final rawError = failure['message']?.toString() ?? 'Unknown error';
    final error = rawError.length > 800
        ? '${rawError.substring(0, 800)}...'
        : rawError;
    final action = await _showDialog(
      context: dialogContext,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text(l10n.pluginErrorTitle),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: SingleChildScrollView(
            child: Text(l10n.pluginErrorMessage(pluginName, error)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'cancel'),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'uninstall'),
            child: Text(l10n.pluginErrorUninstall),
          ),
        ],
      ),
    );
    final command = switch (action) {
      'uninstall' => OronBoxCommand(
        method: 'plugin.remove',
        params: {'id': pluginId},
      ),
      _ => null,
    };
    if (command != null) {
      await _host.execute(command);
    }
  }

  Future<NavigatorState?> _waitForNavigator() async {
    while (true) {
      if (!mounted) return null;
      final navigator =
          Navigator.maybeOf(context, rootNavigator: true) ??
          rootNavigatorKey.currentState;
      if (navigator != null) return navigator;
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
