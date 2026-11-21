import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oronbox/src/command_bus/local_command_bus.dart';
import 'package:oronbox/src/commands/command_protocol.dart';
import 'package:oronbox/src/core/services/shared_prefs_service.dart';
import 'package:oronbox/src/device/core/event_bus.dart';
import 'package:oronbox/src/core/models/bt_models.dart';
import 'package:oronbox/src/device/core/device_state.dart';
import 'package:oronbox/src/features/accounts/models/mi_account_models.dart';
import 'package:oronbox/src/features/accounts/services/bandbbs_auth_service.dart';
import 'package:oronbox/src/features/accounts/services/mi_account_service.dart';
import 'package:oronbox/src/features/devices/controllers/device_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  test('target selection and sending share one exclusive turn and enforce device grants', () async {
    SharedPreferences.setMockInitialValues({});
    await SharedPrefsService.instance.init();
    final root = await Directory.systemTemp.createTemp(
      'oronbox-device-command-',
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
    final manager = container.read(deviceManagerProvider.notifier) as _Devices;
    try {
      final sending = bus.execute(
        const OronBoxCommand(
          method: 'device.interconnect.send',
          params: {
            'device': 'BB',
            '_localApiDeviceAllowlist': ['bb'],
            'package': 'com.example',
            'payload': [0, 255],
          },
        ),
      );
      await manager.connectStarted.future;
      final switching = bus.execute(
        const OronBoxCommand(
          method: 'device.connect',
          params: {'device': 'AA'},
        ),
      );
      manager.connectionGate.complete();
      expect((await sending).ok, isTrue);
      expect((await switching).ok, isTrue);
      expect(manager.sentTo, ['BB']);
      expect(container.read(deviceManagerProvider).currentDevice?.addr, 'AA');
      final denied = await bus.execute(
        const OronBoxCommand(
          method: 'device.interconnect.send',
          params: {
            '_localApiDeviceAllowlist': ['BB'],
            'package': 'com.example',
            'payload': [0],
          },
        ),
      );
      expect(denied.error?.code, 'forbidden');
      final invalid = await bus.execute(
        const OronBoxCommand(
          method: 'device.interconnect.send',
          params: {
            'package': 'com.example',
            'payload': [256],
          },
        ),
      );
      expect(invalid.error?.code, 'usage');
      expect(manager.sentTo, ['BB']);
      manager.markDisconnected();
      final status = await bus.execute(
        const OronBoxCommand(
          method: 'device.status',
          params: {
            '_localApiDeviceAllowlist': ['AA'],
          },
        ),
      );
      expect(status.ok, isTrue);
      expect((status.value as Map)['connected'], isFalse);
    } finally {
      if (!manager.connectionGate.isCompleted) {
        manager.connectionGate.complete();
      }
      await bus.close();
      container.dispose();
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      await root.delete(recursive: true);
    }
  });
}

class _Devices extends LocalDeviceManager {
  static const devices = [
    MiWearState(name: 'First', addr: 'AA', connectType: 'ble', authkey: 'key'),
    MiWearState(name: 'Second', addr: 'BB', connectType: 'ble', authkey: 'key'),
  ];
  final connectStarted = Completer<void>();
  final connectionGate = Completer<void>();
  final sentTo = <String>[];
  void markDisconnected() {
    state = state.copyWith(protocolState: ProtocolState.disconnected);
  }

  @override
  DeviceManagerState build() => DeviceManagerState(
    currentDevice: devices[0],
    pairedDevices: devices,
    protocolState: ProtocolState.ready,
  );
  @override
  Stream<DeviceEvent> get deviceEvents => const Stream.empty();
  @override
  Future<void> connect(
    String addr,
    String name,
    String authKey, {
    Object? kind,
    String connectType = 'ble',
  }) async {
    if (!connectStarted.isCompleted) connectStarted.complete();
    await connectionGate.future;
    state = state.copyWith(
      currentDevice: devices.firstWhere((device) => device.addr == addr),
      protocolState: ProtocolState.ready,
    );
  }

  @override
  Future<void> sendInterconnectMessage(
    String packageName,
    Uint8List payload,
  ) async {
    sentTo.add(state.currentDevice!.addr);
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
