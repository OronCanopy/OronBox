import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:oronbox/src/core/services/shared_prefs_service.dart';

abstract final class PhoneNotifications {
  static const _channel = MethodChannel('org.oroncanopy.oronbox/notifications');
  static const _events = EventChannel(
    'org.oroncanopy.oronbox/notifications/phone',
  );
  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<bool> hasAccess() async =>
      isSupported &&
      (await _channel.invokeMethod<bool>('hasPhoneAccess') ?? false);
  static Future<void> openAccessSettings() =>
      _channel.invokeMethod('openPhoneAccess');
  static Stream<Map<String, Object?>> get events => _events
      .receiveBroadcastStream()
      .where((value) => value is Map)
      .map((value) => (value as Map).cast<String, Object?>());
}

final notificationAppsProvider =
    FutureProvider.autoDispose<List<({String id, String name})>>((ref) async {
      final apps =
          await PhoneNotifications._channel.invokeListMethod<Map>('listApps') ??
          const [];
      return [
        for (final app in apps)
          (id: app['package'] as String, name: app['name'] as String),
      ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    });

final deviceNotificationPreferencesProvider =
    NotifierProvider.family<
      DeviceNotificationPreferences,
      ({bool enabled, Set<String> apps}),
      String
    >(DeviceNotificationPreferences.new);

class DeviceNotificationPreferences
    extends Notifier<({bool enabled, Set<String> apps})> {
  DeviceNotificationPreferences(this.deviceId);

  final String deviceId;
  String get _key => 'device_notifications:$deviceId';

  @override
  ({bool enabled, Set<String> apps}) build() => (
    enabled: SharedPrefsService.instance.getBool(_key) ?? false,
    apps: (SharedPrefsService.instance.getStringList('$_key:apps') ?? const [])
        .toSet(),
  );

  Future<void> setEnabled(bool enabled) async {
    state = (enabled: enabled, apps: state.apps);
    await SharedPrefsService.instance.setBool(_key, enabled);
  }

  Future<void> setApp(String id, bool enabled) async {
    final apps = {...state.apps};
    if (enabled) {
      apps.add(id);
    } else {
      apps.remove(id);
    }
    state = (enabled: state.enabled, apps: apps);
    await SharedPrefsService.instance.setStringList(
      '$_key:apps',
      apps.toList(),
    );
  }
}
