import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:webview_all/webview_all.dart';
import 'package:oronbox/src/app/router/close_root_page.dart';
import 'package:oronbox/src/core/errors/platform_capability_error.dart';

import 'webview_window_connection.dart';

import 'package:oronbox/src/app/window/desktop_window.dart';

bool get usesDesktopWebViewWindows =>
    supportsSecondaryWindows &&
    {
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.linux,
    }.contains(defaultTargetPlatform);

class AppWebViewSession extends ChangeNotifier {
  AppWebViewSession(this.options) {
    unawaited(intercept.future.then<void>((_) {}, onError: (Object _) {}));
  }

  final Map<String, Object?> options;
  final intercept = Completer<String>();
  final _closed = Completer<void>();
  final _events = StreamController<Map<String, Object?>>.broadcast(sync: true);
  final attached = Completer<void>();
  WebViewSession? _view;
  WebViewWindowConnection? _window;
  Future<void>? _opening;
  Future<void>? _closing;
  Future<void>? presentation;
  GoRouter? router;
  TransitionRoute<dynamic>? route;
  bool windowContent = false;
  bool closed = false;
  bool ready = false;
  int progress = 0;
  Object? error;

  WebViewController get controller => _view!.controller;
  Stream<Map<String, Object?>> get events => _events.stream;
  Future<void> get done => _closed.future;

  Future<void> initialize({bool detached = false}) =>
      _opening ??= _initialize(detached);

  Future<void> _initialize(bool detached) async {
    try {
      if (detached) {
        final window = await openWebViewWindowConnection(options, (
          method,
          arguments,
        ) async {
          if (method == 'event') {
            receiveEvent((arguments as Map).cast<String, Object?>());
          }
          return null;
        });
        _window = window;
        unawaited(window.disconnected.then((_) => markClosed()));
        if (closed) await window.close();
        return;
      }
      final mode = options['ephemeral'] == true
          ? WebViewSessionMode.incognito
          : WebViewSessionMode.shared;
      final capabilities = await WebViewSession.getCapabilities();
      if (!capabilities.canClose || !capabilities.supports(mode)) {
        throw const PlatformCapabilityError(
          'Requested browser session mode is unavailable',
        );
      }
      _view = await WebViewSession.create(
        mode: mode,
        customSchemes: (options['intercept-prefixes'] as List? ?? const [])
            .cast<String>()
            .map((value) => Uri.parse(value).scheme)
            .where(
              (value) =>
                  value.isNotEmpty && value != 'http' && value != 'https',
            )
            .toSet()
            .toList(),
      );
      if (_view == null) throw StateError('Browser session unavailable');
      if (closed) return;
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      if (options['user-agent'] case final String agent) {
        await controller.setUserAgent(agent);
      }
      for (final name
          in (options['channels'] as List? ?? const []).cast<String>()) {
        await controller.addJavaScriptChannel(
          name,
          onMessageReceived: (message) => receiveEvent({
            'type': 'message',
            'channel': name,
            'message': message.message,
          }),
        );
      }
      await controller.setNavigationDelegate(
        NavigationDelegate(
          onProgress: (value) =>
              receiveEvent({'type': 'progress', 'value': value}),
          onPageFinished: (url) => receiveEvent({'type': 'loaded', 'url': url}),
          onWebResourceError: (value) {
            if (value.isForMainFrame != false) {
              receiveEvent({'type': 'error', 'message': value.description});
            }
          },
          onNavigationRequest: (request) {
            final prefixes =
                (options['intercept-prefixes'] as List? ?? const [])
                    .cast<String>();
            if (prefixes.any(request.url.startsWith)) {
              receiveEvent({'type': 'intercept', 'url': request.url});
              if (options['close-on-intercept'] == true) unawaited(close());
              return NavigationDecision.prevent;
            }
            if (options['controlled-html'] == true &&
                request.url != 'about:blank' &&
                !request.url.startsWith('data:text/html')) {
              receiveEvent({'type': 'external', 'url': request.url});
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      );
      if (closed) return;
      if (options['html'] case final String html) {
        await controller.loadHtmlString(html);
      } else {
        await controller.loadRequest(Uri.parse(options['url'] as String));
      }
      if (!closed) {
        ready = true;
        notifyListeners();
      }
    } on UnsupportedError catch (value) {
      error = PlatformCapabilityError(
        value.message ?? 'WebView operation unavailable',
      );
      await _releaseFailedView();
      throw error!;
    } catch (value) {
      error = value;
      await _releaseFailedView();
      rethrow;
    }
  }

  Future<void> _releaseFailedView() async {
    final view = _view;
    _view = null;
    await view?.close();
    if (!closed) notifyListeners();
  }

  Future<void> retry() async {
    if (closed) return;
    error = null;
    progress = 0;
    notifyListeners();
    if (ready) {
      await invoke('reload');
    } else {
      _opening = null;
      await initialize();
    }
  }

  void receiveEvent(Map<String, Object?> event) {
    if (closed) return;
    switch (event['type']) {
      case 'closed':
        markClosed();
        return;
      case 'progress':
        progress = (event['value'] as num).toInt();
      case 'error':
        error = event['message'];
      case 'loaded':
        error = null;
        progress = 100;
      case 'intercept':
        if (!intercept.isCompleted) intercept.complete(event['url'] as String);
    }
    _events.add(event);
    notifyListeners();
  }

  Future<Object?> invoke(String method, [Object? arguments]) async {
    if (closed) throw StateError('Browser closed');
    if (_window case final window?) return window.invoke(method, arguments);
    try {
      switch (method) {
        case 'navigate':
          error = null;
          await controller.loadRequest(Uri.parse(arguments as String));
          return null;
        case 'current-url':
          return await controller.currentUrl() ?? '';
        case 'eval':
          return jsonEncode(
            await controller.runJavaScriptReturningResult(arguments as String),
          );
        case 'script':
          await controller.runJavaScript(arguments as String);
          return null;
        case 'cookies':
          if (kIsWeb) {
            final target = Uri.parse(arguments as String);
            if (target.origin != Uri.base.origin ||
                target.path != Uri.base.path) {
              throw const PlatformCapabilityError(
                'Cross-origin browser cookies are unavailable',
              );
            }
          }
          return (await _view!.cookieManager.getCookies(
                domain: Uri.parse(arguments as String),
              ))
              .map(
                (cookie) => <String, Object?>{
                  'name': cookie.name,
                  'value': cookie.value,
                  'domain': cookie.domain,
                  'path': cookie.path,
                },
              )
              .toList();
        case 'reload':
          error = null;
          notifyListeners();
          await controller.reload();
          return null;
        default:
          throw UnsupportedError(method);
      }
    } on UnsupportedError catch (value) {
      throw PlatformCapabilityError(value.message ?? method);
    }
  }

  void markClosed() {
    if (closed) return;
    closed = true;
    if (!intercept.isCompleted) {
      intercept.completeError(StateError('Browser closed'));
    }
    _closed.complete();
    notifyListeners();
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    markClosed();
    try {
      await _opening;
    } catch (_) {}
    if (presentation case final pending?) {
      await Future.any([attached.future, pending]);
    }
    if (route case final current?) {
      route = null;
      await closeRootPage(router!, current);
    } else if (windowContent && attached.isCompleted) {
      await WidgetsBinding.instance.endOfFrame;
    }
    final window = _window;
    _window = null;
    if (window != null) {
      try {
        await window.invoke('dispose');
      } catch (_) {}
      await window.close();
    }
    final view = _view;
    _view = null;
    await view?.close();
    await _events.close();
  }
}
