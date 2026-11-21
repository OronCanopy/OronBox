import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

abstract final class SystemNotificationBridge {
  static const _channel = MethodChannel('org.oroncanopy.oronbox/notifications');

  static bool get isSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  static Future<bool> hasPermission() async =>
      await _channel.invokeMethod<bool>('hasSendPermission') ?? false;

  static Future<void> openSettings() =>
      _channel.invokeMethod<void>('openSendSettings');

  static Future<bool> show({
    required String id,
    required String category,
    required String title,
    required String body,
    required String location,
  }) async =>
      isSupported &&
      (await _channel.invokeMethod<bool>('show', {
            'id': id,
            'category': category,
            'title': title,
            'body': body,
            'location': location,
          }) ??
          false);

  static Future<String?> initialLocation() =>
      _channel.invokeMethod<String>('getInitialLocation');

  static void setLocationHandler(void Function(String location)? handler) {
    _channel.setMethodCallHandler(
      handler == null
          ? null
          : (call) async {
              if (call.method == 'notificationOpened' &&
                  call.arguments is String) {
                handler(call.arguments as String);
              }
            },
    );
  }
}
