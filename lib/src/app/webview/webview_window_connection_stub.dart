import 'webview_window_connection.dart';

Future<WebViewWindowConnection> openWebViewWindowConnection(
  Map<String, Object?> options,
  Future<Object?> Function(String, Object?) handler,
) async => throw UnsupportedError('Desktop windows are unavailable');

Future<WebViewWindowConnection> attachWebViewWindowConnection(
  String id,
  Future<Object?> Function(String, Object?) handler,
) async => throw UnsupportedError('Desktop windows are unavailable');
