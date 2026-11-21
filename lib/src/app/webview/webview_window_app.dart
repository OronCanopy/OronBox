import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:oronbox/src/app/widgets/auxiliary_app.dart';
import 'package:oronbox/src/app/window/desktop_window.dart';
import 'package:oronbox/src/core/errors/coded_error.dart';

import 'app_webview_page.dart';
import 'app_webview_session.dart';
import 'webview_window_connection.dart';

class WebViewWindowApp extends StatelessWidget {
  const WebViewWindowApp({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context) =>
      AuxiliaryApp(child: _WindowPage(id: id));
}

class _WindowPage extends StatefulWidget {
  const _WindowPage({required this.id});
  final String id;

  @override
  State<_WindowPage> createState() => _WindowPageState();
}

class _WindowPageState extends State<_WindowPage> {
  WebViewWindowConnection? _connection;
  AppWebViewSession? _session;
  StreamSubscription<Map<String, Object?>>? _events;
  Future<void>? _closing;
  Future<void>? _releasing;
  Future<void> _forwarding = Future.value();

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    try {
      final connection = await attachWebViewWindowConnection(widget.id, (
        method,
        arguments,
      ) async {
        try {
          if (method == 'focus') {
            await focusSecondaryWindow();
            return null;
          }
          if (method == 'dispose') {
            await _session?.close();
            return null;
          }
          return await _session!.invoke(method, arguments);
        } catch (error) {
          return {
            'webview-error': {
              'code': error is CodedError ? error.code : 'webview_failed',
              'message': error is CodedError ? error.message : error.toString(),
            },
          };
        }
      });
      _connection = connection;
      unawaited(connection.disconnected.then((_) => _finish()));
      final options = ((await connection.invoke('options')) as Map)
          .cast<String, Object?>();
      options.remove('_owner-window');
      final session = AppWebViewSession(options)..windowContent = true;
      _session = session;
      _events = session.events.listen((event) {
        _forwarding = _forwarding
            .then((_) async {
              await connection.invoke('event', event);
            })
            .catchError((Object _) {});
      });
      if (!mounted) {
        await _finish();
        return;
      }
      await setSecondaryWindowTitle(options['title']?.toString() ?? 'OronBox');
      if (!mounted) return;
      setState(() {});
      try {
        await session.initialize();
        await connection.invoke('ready');
      } catch (error) {
        await connection.invoke('ready', {
          'error': error.toString(),
          if (error is CodedError) 'code': error.code,
        });
        await _finish();
        return;
      }
      unawaited(session.done.then((_) => _finish()));
    } catch (_) {
      await _finish();
    }
  }

  Future<void> _finish() => _closing ??= _close();

  Future<void> _close() async {
    await _release();
    await closeSecondaryWindow();
  }

  Future<void> _release() => _releasing ??= _releaseOwned();

  Future<void> _releaseOwned() async {
    await _session?.close();
    await _events?.cancel();
    await _forwarding;
    final connection = _connection;
    if (connection != null) {
      try {
        await connection.invoke('event', {'type': 'closed'});
      } catch (_) {}
      await connection.close();
    }
  }

  @override
  void dispose() {
    unawaited(_finish());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SecondaryWindowHost(
    role: 'webview',
    onClose: _release,
    child: _session == null
        ? const Scaffold(body: Center(child: CircularProgressIndicator()))
        : AppWebViewPage(session: _session!, window: true),
  );
}
