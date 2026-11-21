import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:uuid/uuid.dart';
import 'package:oronbox/src/app/window/desktop_window.dart';
import 'package:oronbox/src/core/errors/platform_capability_error.dart';

import 'webview_window_connection.dart';

Future<WebViewWindowConnection> openWebViewWindowConnection(
  Map<String, Object?> options,
  Future<Object?> Function(String, Object?) handler,
) async {
  final id = const Uuid().v4();
  final ready = Completer<void>();
  final connection = _Connection(id, owner: true);
  try {
    final ownerId = (await WindowController.fromCurrentEngine()).windowId;
    await connection.initialize((method, arguments) async {
      if (method == 'options') return {...options, '_owner-window': ownerId};
      if (method == 'ready') {
        if (!ready.isCompleted) {
          if (arguments is Map && arguments['error'] != null) {
            final message = arguments['error'].toString();
            ready.completeError(
              arguments['code'] == 'platform_capability_unavailable'
                  ? PlatformCapabilityError(message)
                  : StateError(message),
            );
          } else {
            ready.complete();
          }
        }
        return null;
      }
      return handler(method, arguments);
    });
    connection.peerId = await createWebViewWindow(id);
    await Future.any([
      ready.future,
      connection.disconnected.then<void>(
        (_) => throw StateError('WebView window closed during startup'),
      ),
    ]).timeout(const Duration(seconds: 30));
    return connection;
  } catch (_) {
    await connection.close();
    rethrow;
  }
}

Future<WebViewWindowConnection> attachWebViewWindowConnection(
  String id,
  Future<Object?> Function(String, Object?) handler,
) async {
  final connection = _Connection(id, owner: false);
  await connection.initialize(handler);
  return connection;
}

class _Connection implements WebViewWindowConnection {
  _Connection(this.id, {required this.owner})
    : channel = WindowMethodChannel('org.oroncanopy.oronbox.webview.$id');

  final String id;
  final bool owner;
  final WindowMethodChannel channel;
  final _disconnected = Completer<void>();
  StreamSubscription<void>? _windows;
  String? peerId;
  bool _closed = false;
  Future<void>? _closing;

  Future<void> initialize(
    Future<Object?> Function(String, Object?) handler,
  ) async {
    await channel.setMethodCallHandler((call) async {
      if (_closed) throw StateError('WebView window disconnected');
      return handler(call.method, call.arguments);
    });
    _windows = onWindowsChanged.listen((_) => unawaited(_checkPeer()));
  }

  Future<void> _checkPeer() async {
    if (_closed) return;
    List<WindowController> windows;
    try {
      windows = await WindowController.getAll();
    } catch (_) {
      return;
    }
    if (_closed) return;
    final peer = peerId;
    if (peer != null && windows.every((window) => window.windowId != peer)) {
      await close();
    }
  }

  @override
  Future<void> get disconnected => _disconnected.future;

  @override
  Future<Object?> invoke(String method, [Object? arguments]) async {
    if (_closed) return Future.error(StateError('WebView window disconnected'));
    final result = await Future.any([
      channel.invokeMethod<Object?>(method, arguments),
      disconnected.then<Object?>(
        (_) => throw StateError('WebView window disconnected'),
      ),
    ]);
    if (!owner && method == 'options' && result is Map) {
      peerId = result['_owner-window'] as String?;
    }
    if (result is Map && result['webview-error'] is Map) {
      final error = result['webview-error'] as Map;
      if (error['code'] == 'platform_capability_unavailable') {
        throw PlatformCapabilityError(error['message'].toString());
      }
      throw StateError(error['message'].toString());
    }
    return result;
  }

  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    if (!_disconnected.isCompleted) _disconnected.complete();
    await _windows?.cancel();
    if (owner) await closeWebViewWindow(id);
    await channel.setMethodCallHandler(null);
  }
}
