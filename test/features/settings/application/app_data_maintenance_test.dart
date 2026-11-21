import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:oronbox/src/commands/command_protocol.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:oronbox/src/features/devices/health/health_store.dart';
import 'package:oronbox/src/features/devices/health/health_models.dart';
import 'package:oronbox/src/device/zeppos/app_side/zeppos_app_side_storage.dart';
import 'package:oronbox/src/device/zeppos/systems/zeppos_app_side_system.dart';
import 'package:oronbox/src/features/devices/controllers/device_manager.dart';
import 'package:oronbox/src/features/settings/application/app_data_maintenance.dart';

class _Device extends Fake implements DeviceManager {
  _Device({this.healthDrain});
  final Future<void> Function()? healthDrain;
  @override
  Future<void> reloadSavedDevices() async {}
  @override
  Future<void> waitForHealthSync() async => healthDrain?.call();
  @override
  Future<List<ZeppOsAppSideSessionInfo>> zeppOsAppSideSessions() async => [];
}

class _TransientReleaseBus extends Fake implements OronBoxCommandBus {
  int releaseAttempts = 0;

  @override
  Future<CommandResult> execute(OronBoxCommand command) async {
    switch (command.method) {
      case 'appdata.maintenance.begin':
        return const CommandResult.success('owner');
      case 'appdata.maintenance.validate':
        return const CommandResult.success(true);
      case 'appdata.maintenance.end':
        releaseAttempts++;
        return releaseAttempts == 1
            ? const CommandResult.failure(
                CommandError('temporary', 'Temporary release failure'),
              )
            : const CommandResult.success();
      default:
        throw StateError(command.method);
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'maintenance release is retried after a transient host failure',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'maintenance-release-test-',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) async => root.path,
      );
      final host = _TransientReleaseBus();
      var executed = false;
      try {
        await expectLater(
          runWithAppDataMaintenance(host, () async {
            executed = true;
          }),
          throwsStateError,
        );
        expect(executed, isTrue);
        expect(host.releaseAttempts, 2);
      } finally {
        messenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
        await root.delete(recursive: true);
      }
    },
  );
  tearDown(() => ZeppOsLocalDataGuard.active = false);
  test('maintenance drains existing writers and rejects new ones until its owner releases it', () async {
    var reloads = 0;
    final stopped = Completer<void>();
    final maintenance = AppDataMaintenance(
      deviceManager: _Device(),
      initialize: () async {},
      stopRuntimes: () async {
        stopped.complete();
      },
      reload: () async {
        reloads++;
      },
    );
    final gate = Completer<void>();
    final writer = maintenance.hostCall(() => gate.future);
    final acquiring = maintenance.begin();
    await stopped.future;
    expect(maintenance.active, isTrue);
    expect(ZeppOsLocalDataGuard.active, isTrue);
    await expectLater(maintenance.hostCall(() async {}), throwsStateError);
    await expectLater(maintenance.end('other-owner'), throwsStateError);
    expect(maintenance.active, isTrue);
    gate.complete();
    await writer;
    final token = await acquiring;
    await maintenance.end(token);
    expect(reloads, 1);
    expect(maintenance.active, isFalse);
    expect(ZeppOsLocalDataGuard.active, isFalse);
    await maintenance.hostCall(() async {});
  });
  test(
    'maintenance waits for health sync and pauses writes until release',
    () async {
      final entered = Completer<void>();
      final drained = Completer<void>();
      final maintenance = AppDataMaintenance(
        deviceManager: _Device(
          healthDrain: () {
            entered.complete();
            return drained.future;
          },
        ),
        initialize: () async {},
        stopRuntimes: () async {},
        reload: () async {},
      );
      var granted = false;
      final acquiring = maintenance.begin().then((token) {
        granted = true;
        return token;
      });
      await entered.future;
      expect(HealthStore.maintenanceRequested, isTrue);
      expect(granted, isFalse);
      drained.complete();
      final token = await acquiring;
      try {
        await expectLater(
          HealthStore().write('device', const XiaomiHealthData()),
          throwsStateError,
        );
      } finally {
        await maintenance.end(token);
      }
      expect(HealthStore.maintenanceRequested, isFalse);
    },
  );
  test(
    'a failed stop releases maintenance and never starts the snapshot',
    () async {
      final maintenance = AppDataMaintenance(
        deviceManager: _Device(),
        initialize: () async {},
        stopRuntimes: () async => throw StateError('stop failed'),
        reload: () async {},
      );
      await expectLater(maintenance.begin(), throwsStateError);
      expect(maintenance.active, isFalse);
      expect(ZeppOsLocalDataGuard.active, isFalse);
    },
  );
}
