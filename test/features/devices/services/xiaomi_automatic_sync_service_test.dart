import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oronbox/src/core/models/bt_models.dart';
import 'package:oronbox/src/core/services/shared_prefs_service.dart';
import 'package:oronbox/src/device/core/device_state.dart' as proto;
import 'package:oronbox/src/features/devices/controllers/device_manager.dart';
import 'package:oronbox/src/features/devices/health/health_models.dart';
import 'package:oronbox/src/features/devices/models/xiaomi_device_features.dart';
import 'package:oronbox/src/features/devices/services/xiaomi_automatic_sync_service.dart';
import 'package:oronbox/src/features/devices/services/xiaomi_sync_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _ZeppManager extends LocalDeviceManager {
  int syncDeviceCalls = 0;
  int healthCalls = 0;
  int weatherCalls = 0;

  @override
  DeviceManagerState build() => DeviceManagerState(
    protocolState: proto.ProtocolState.ready,
    currentDevice: const MiWearState(
      name: 'test Zepp device',
      addr: 'zepp-1',
      connectType: 'ble',
      codename: 'zepp:test',
    ),
  );

  @override
  Future<void> syncDevice() async {
    syncDeviceCalls++;
  }

  @override
  Future<XiaomiHealthSyncResult> syncXiaomiHealth() async {
    healthCalls++;
    throw StateError('health must not be called for ZeppOS');
  }

  @override
  Future<void> syncXiaomiWeather(XiaomiWeatherData weather) async {
    weatherCalls++;
    throw StateError('weather must not be called for ZeppOS');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      XiaomiSyncPreferences.healthAutoSyncKey: true,
      XiaomiSyncPreferences.weatherAutoSyncKey: true,
      XiaomiSyncPreferences.weatherLastCityKey: 'Test City',
    });
    await SharedPrefsService.instance.init();
    await SharedPrefsService.instance.reload();
  });

  test('ZeppOS full sync remains available without Xiaomi follow-ups', () async {
    final container = ProviderContainer(
      overrides: [deviceManagerProvider.overrideWith(_ZeppManager.new)],
    );
    addTearDown(container.dispose);
    final manager =
        container.read(deviceManagerProvider.notifier) as _ZeppManager;

    await XiaomiAutomaticSyncService(manager).run(automatic: false);

    expect(manager.syncDeviceCalls, 1);
    expect(manager.healthCalls, 0);
    expect(manager.weatherCalls, 0);
  });

  test('manual Xiaomi health sync explicitly rejects ZeppOS', () async {
    final container = ProviderContainer(
      overrides: [deviceManagerProvider.overrideWith(_ZeppManager.new)],
    );
    addTearDown(container.dispose);
    final manager =
        container.read(deviceManagerProvider.notifier) as _ZeppManager;

    await expectLater(
      XiaomiAutomaticSyncService(manager).runHealthSync(),
      throwsA(isA<UnsupportedError>()),
    );
    expect(manager.healthCalls, 0);
  });
}
