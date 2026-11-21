import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';
// ignore: depend_on_referenced_packages
import 'package:webview_platform_interface/webview_platform_interface.dart';

class TestWebViewPlatform extends WebViewPlatform {
  final controllers = <TestWebViewController>[];
  final cookies = TestWebViewCookies(
    const PlatformWebViewCookieManagerCreationParams(),
  );
  final created = Completer<void>();
  Completer<void>? preparation;
  bool failPreparation = false;
  bool failConfiguration = false;
  String? interceptOnLoad;

  @override
  Future<WebViewSessionCapabilities> getSessionCapabilities() async =>
      WebViewSessionCapabilities(
        supportedModes: WebViewSessionMode.values.toSet(),
        canClose: true,
        incognitoSupport: WebViewIncognitoSupport.nativeStore,
      );

  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) {
    final controller = TestWebViewController(params, this);
    controllers.add(controller);
    if (!created.isCompleted) created.complete();
    return controller;
  }

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) => TestWebViewNavigation(params);

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) => _TestWebViewWidget(params);
}

class TestWebViewController extends PlatformWebViewController {
  TestWebViewController(super.params, this.owner) : super.implementation();

  final TestWebViewPlatform owner;
  final loads = <Uri>[];
  final loaded = Completer<void>();
  final executions = StreamController<String>.broadcast();
  final scripts = <String>[];
  TestWebViewNavigation? navigation;
  JavaScriptChannelParams? channel;
  VoidCallback? onClose;
  int closes = 0;
  String? agent;
  String? html;
  Uri? url;

  void send(Map<String, Object?> value) =>
      channel!.onMessageReceived(JavaScriptMessage(message: jsonEncode(value)));

  @override
  Future<void> prepareSession() async {
    await owner.preparation?.future;
    if (owner.failPreparation) throw StateError('creation failed');
  }

  @override
  PlatformWebViewCookieManager createSessionCookieManager() => owner.cookies;

  @override
  Future<void> closeWebViewSession() async {
    closes++;
    onClose?.call();
    await executions.close();
  }

  @override
  Future<void> setJavaScriptMode(JavaScriptMode mode) async {}

  @override
  Future<void> setUserAgent(String? userAgent) async => agent = userAgent;

  @override
  Future<String?> currentUrl() async => url?.toString();

  @override
  Future<Object> runJavaScriptReturningResult(String javaScript) async => 2;

  @override
  Future<void> addJavaScriptChannel(JavaScriptChannelParams params) async {
    if (owner.failConfiguration) throw StateError('configuration failed');
    channel = params;
  }

  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate delegate,
  ) async => navigation = delegate as TestWebViewNavigation;

  @override
  Future<void> loadRequest(LoadRequestParams params) async {
    url = params.uri;
    loads.add(params.uri);
    if (owner.interceptOnLoad case final intercepted?) {
      await navigation!.request!(
        NavigationRequest(url: intercepted, isMainFrame: true),
      );
    }
  }

  @override
  Future<void> loadHtmlString(String value, {String? baseUrl}) async {
    html = value;
    loaded.complete();
  }

  @override
  Future<void> runJavaScript(String script) async {
    scripts.add(script);
    executions.add(script);
  }

  @override
  Future<void> reload() async {}
}

class TestWebViewNavigation extends PlatformNavigationDelegate {
  TestWebViewNavigation(super.params) : super.implementation();

  PageEventCallback? finished;
  NavigationRequestCallback? request;

  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback callback,
  ) async => request = callback;

  @override
  Future<void> setOnPageFinished(PageEventCallback callback) async =>
      finished = callback;

  @override
  Future<void> setOnProgress(ProgressCallback callback) async {}

  @override
  Future<void> setOnWebResourceError(WebResourceErrorCallback callback) async {}
}

class TestWebViewCookies extends PlatformWebViewCookieManager {
  TestWebViewCookies(super.params) : super.implementation();

  List<WebViewCookie> values = [];
  Completer<List<WebViewCookie>>? pending;
  int reads = 0;

  @override
  Future<List<WebViewCookie>> getCookies(Uri url) async {
    reads++;
    return pending == null ? values : pending!.future;
  }
}

class _TestWebViewWidget extends PlatformWebViewWidget {
  _TestWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}
