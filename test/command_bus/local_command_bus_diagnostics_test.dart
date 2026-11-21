import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oronbox/src/command_bus/local_command_bus.dart';
import 'package:oronbox/src/commands/command_protocol.dart';
import 'package:oronbox/src/core/services/shared_prefs_service.dart';
import 'package:oronbox/src/device/core/event_bus.dart';
import 'package:oronbox/src/features/accounts/models/mi_account_models.dart';
import 'package:oronbox/src/features/accounts/services/bandbbs_auth_service.dart';
import 'package:oronbox/src/features/accounts/services/mi_account_service.dart';
import 'package:oronbox/src/features/devices/controllers/device_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'diagnostic listeners share battery pause and preserve manual intent',
    () async {
      SharedPreferences.setMockInitialValues({});
      await SharedPrefsService.instance.init();
      final root = await Directory.systemTemp.createTemp(
        'oronbox-diagnostics-',
      );
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (_) async => root.path,
      );
      final container = ProviderContainer(
        overrides: [
          deviceManagerProvider.overrideWith(_Devices.new),
          bandBbsAuthProvider.overrideWith(_Auth.new),
          miAccountServiceProvider.overrideWithValue(_MiAccount()),
        ],
      );
      final bus = LocalCommandBus(container);
      final manager =
          container.read(deviceManagerProvider.notifier) as _Devices;
      Future<void> set(String method, String key, bool value) async {
        final result = await bus.execute(
          OronBoxCommand(method: method, params: {key: value}),
        );
        expect(result.ok, isTrue, reason: result.error?.toString());
      }

      try {
        for (final first in [
          'debug.rawBluetooth.set',
          'debug.protocolTrace.set',
        ]) {
          final second = first == 'debug.rawBluetooth.set'
              ? 'debug.protocolTrace.set'
              : 'debug.rawBluetooth.set';
          await set(first, 'enabled', true);
          expect(manager.batteryRefreshPaused, isTrue);
          await set(second, 'enabled', true);
          await set(first, 'enabled', false);
          expect(manager.batteryRefreshPaused, isTrue);
          await set(second, 'enabled', false);
          expect(manager.batteryRefreshPaused, isFalse);
        }
        for (final failRequest in [false, true]) {
          manager.requestStarted = Completer<void>();
          manager.response = Completer<Uint8List>();
          final request = bus.execute(
            const OronBoxCommand(
              method: 'device.raw.request',
              params: {
                'payload': [1],
              },
            ),
          );
          await manager.requestStarted.future;
          expect(manager.batteryRefreshPaused, isTrue);
          if (failRequest) {
            await set('debug.rawBluetooth.set', 'enabled', true);
            manager.response.completeError(TimeoutException('No response'));
          } else {
            manager.response.complete(Uint8List.fromList([2]));
          }
          expect((await request).ok, !failRequest);
          expect(manager.batteryRefreshPaused, failRequest);
          await set('debug.rawBluetooth.set', 'enabled', false);
          expect(manager.batteryRefreshPaused, isFalse);
        }
        await set('debug.batterySync.set', 'paused', true);
        await set('debug.rawBluetooth.set', 'enabled', true);
        await set('debug.rawBluetooth.set', 'enabled', false);
        expect(manager.batteryRefreshPaused, isTrue);
        await set('debug.rawBluetooth.set', 'enabled', true);
        await set('debug.batterySync.set', 'paused', false);
        expect(manager.batteryRefreshPaused, isTrue);
        await bus.close();
        expect(manager.batteryRefreshPaused, isFalse);
      } finally {
        container.dispose();
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
        await root.delete(recursive: true);
      }
    },
  );
}

class _Devices extends LocalDeviceManager {
  @override
  DeviceManagerState build() => const DeviceManagerState();
  @override
  Stream<DeviceEvent> get deviceEvents => const Stream.empty();
  Completer<void> requestStarted = Completer<void>();
  Completer<Uint8List> response = Completer<Uint8List>();
  @override
  Future<Uint8List> requestRaw(
    Uint8List payload, {
    Duration timeout = const Duration(seconds: 5),
  }) {
    requestStarted.complete();
    return response.future;
  }

  bool paused = false;
  @override
  bool get batteryRefreshPaused => paused;
  @override
  Future<void> setBatteryRefreshPaused(bool value) async {
    paused = value;
  }

  @override
  Future<void> disconnect([String? addr]) async {}
}

class _Auth extends BandBbsAuthNotifier {
  @override
  BandBbsAuthState build() => BandBbsAuthState.empty;
}

class _MiAccount extends Fake implements MiAccountService {
  @override
  Future<MiAccountToken?> loadStoredToken() async => null;
}
