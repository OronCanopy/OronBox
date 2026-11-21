import 'dart:async';

import 'package:go_router/go_router.dart';
import 'package:oronbox/src/app/router/app_router.dart';
import 'package:oronbox/src/app/webview/app_webview_session.dart';
import 'package:oronbox/src/app/webview/app_webview_page.dart';

GoRoute pluginBrowserRoute({String fallbackLocation = '/plugins'}) => GoRoute(
  path: '/plugins/:pluginId/browser/:id',
  redirect: (context, state) =>
      state.extra is AppWebViewSession ? null : fallbackLocation,
  builder: (context, state) =>
      AppWebViewPage(session: state.extra as AppWebViewSession),
);

class PluginBrowserSessions {
  PluginBrowserSessions({required this.pluginId, this.router});

  final String pluginId;
  final GoRouter? router;
  final _sessions = <int, AppWebViewSession>{};
  final _opening = <Future<void>>{};
  int _nextId = 0;
  bool _closed = false;

  Future<Object?> handle(String method, List<Object?> args) async {
    if (_closed) throw StateError('Plugin browser sessions closed');
    if (method == 'browser.open') {
      final raw = args.single;
      final options = raw is String
          ? <String, Object?>{'url': raw}
          : (raw as Map).cast<String, Object?>();
      final router =
          this.router ??
          (rootNavigatorKey.currentContext == null
              ? null
              : GoRouter.of(rootNavigatorKey.currentContext!));
      if (router == null) throw StateError('Application window unavailable');
      final session = AppWebViewSession(options);
      final opening = () async {
        try {
          await session.initialize(detached: usesDesktopWebViewWindows);
          if (_closed) await session.close();
        } catch (_) {
          await session.close();
          rethrow;
        }
      }();
      _opening.add(opening);
      try {
        await opening;
      } finally {
        _opening.remove(opening);
      }
      if (_closed ||
          (!usesDesktopWebViewWindows &&
              router.routerDelegate.navigatorKey.currentState == null)) {
        await session.close();
        throw StateError('Plugin stopped');
      }
      final id = ++_nextId;
      _sessions[id] = session;
      unawaited(session.done.then((_) => session.close()));
      if (session.closed || usesDesktopWebViewWindows) return id;
      session.router = router;
      session.presentation = router.push<void>(
        '/plugins/${Uri.encodeComponent(pluginId)}/browser/$id',
        extra: session,
      );
      unawaited(session.presentation!.whenComplete(session.close));
      return id;
    }
    final session = _sessions[(args.first as num).toInt()];
    if (session == null) throw StateError('Unknown browser session');
    if (method == 'browser.wait-for-intercept') {
      final timeout = args.elementAtOrNull(1) as num?;
      return timeout == null
          ? session.intercept.future
          : session.intercept.future.timeout(
              Duration(milliseconds: timeout.toInt()),
            );
    }
    if (method == 'browser.close') {
      await session.close();
      _sessions.remove((args.first as num).toInt());
      return null;
    }
    if (session.closed) throw StateError('Browser closed');
    final operation = switch (method) {
      'browser.navigate' => 'navigate',
      'browser.current-url' => 'current-url',
      'browser.eval' => 'eval',
      'browser.get-cookies' => 'cookies',
      _ => throw UnsupportedError(method),
    };
    return session.invoke(operation, args.elementAtOrNull(1));
  }

  Future<void> close() async {
    _closed = true;
    await Future.wait([
      for (final opening in _opening)
        opening.then<void>((_) {}, onError: (Object _) {}),
    ]);
    for (final session in _sessions.values.toList()) {
      await session.close();
    }
    _sessions.clear();
  }
}
