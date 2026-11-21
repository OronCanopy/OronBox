import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oronbox/src/core/models/bt_models.dart';
import 'package:oronbox/src/core/services/shared_prefs_service.dart';
import 'package:oronbox/src/device/core/device_state.dart';
import 'package:oronbox/src/features/accounts/application/host_accounts.dart';
import 'package:oronbox/src/features/devices/controllers/device_manager.dart';
import 'package:oronbox/src/features/devices/services/xiaomi_automatic_sync_service.dart';
import 'package:oronbox/src/features/oobe/oobe_state.dart';
import 'package:oronbox/src/features/resources/services/install_queue_notifier.dart';
import 'package:oronbox/src/features/settings/services/update_reminder_service.dart';
import 'package:oronbox/src/features/settings/widgets/update_reminder_scheduler.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('resource checks use the periodic tick independently of sync', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await tester.runAsync(() async {
      SharedPreferences.setMockInitialValues({});
      await SharedPrefsService.instance.init();
      await SharedPrefsService.instance.reload();
      await markLegalAccepted();
      await markOobeCompleted();
    });

    final devices = _Devices();
    final container = ProviderContainer(
      overrides: [
        hostAccountsProvider.overrideWith(_Accounts.new),
        deviceManagerProvider.overrideWith(() => devices),
        installQueueProvider.overrideWith(_IdleQueue.new),
        updateReminderServiceProvider.overrideWith(_ReminderService.new),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const XiaomiAutomaticSyncScheduler(
          child: UpdateReminderScheduler(child: SizedBox()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(devices.syncCalls, 1);
    expect(devices.inventoryReads, isEmpty);

    await tester.pump(const Duration(minutes: 14, seconds: 58));
    await tester.pump(const Duration(seconds: 2));
    expect(devices.inventoryReads, ['watchfaces', 'apps']);

    devices.finishSync.complete();
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('a periodic resource check waits for the install queue', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await tester.runAsync(() async {
      SharedPreferences.setMockInitialValues({});
      await SharedPrefsService.instance.init();
      await SharedPrefsService.instance.reload();
      await markLegalAccepted();
      await markOobeCompleted();
    });

    final devices = _Devices();
    final queue = _IdleQueue();
    final container = ProviderContainer(
      overrides: [
        hostAccountsProvider.overrideWith(_Accounts.new),
        deviceManagerProvider.overrideWith(() => devices),
        installQueueProvider.overrideWith(() => queue),
        updateReminderServiceProvider.overrideWith(_ReminderService.new),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const UpdateReminderScheduler(child: SizedBox()),
      ),
    );
    queue.setBusy(true);
    await tester.pump(const Duration(minutes: 15));
    await tester.pump(const Duration(seconds: 2));
    expect(devices.inventoryReads, isEmpty);

    queue.setBusy(false);
    await tester.pump(const Duration(seconds: 2));
    expect(devices.inventoryReads, ['watchfaces', 'apps']);
    await tester.pumpWidget(const SizedBox());
  });
}

class _ReminderService extends UpdateReminderService {
  const _ReminderService(super.ref);

  @override
  Future<List<UpdateReminderItem>> plugins() async => const [];
}

class _Devices extends LocalDeviceManager {
  final finishSync = Completer<void>();
  final inventoryReads = <String>[];
  int syncCalls = 0;

  @override
  DeviceManagerState build() => const DeviceManagerState(
    currentDevice: MiWearState(
      name: 'Test device',
      addr: 'AA:BB:CC:DD:EE:FF',
      connectType: 'ble',
    ),
    protocolState: ProtocolState.ready,
  );

  @override
  Future<void> syncDevice() {
    syncCalls++;
    return finishSync.future;
  }

  @override
  Future<void> fetchWatchfaces() async => inventoryReads.add('watchfaces');

  @override
  Future<void> fetchApps() async => inventoryReads.add('apps');
}

class _IdleQueue extends InstallQueueNotifier {
  @override
  InstallQueueState build() => const InstallQueueState(loaded: true);

  void setBusy(bool busy) {
    state = InstallQueueState(
      loaded: true,
      tasks: [
        if (busy)
          const InstallTask(
            id: 'installing',
            name: 'Test resource',
            description: '',
            type: LocalDeviceInstallType.app,
            filePath: '',
            status: ResourceTaskStatus.installing,
          ),
      ],
    );
  }
}

class _Accounts extends HostAccountsNotifier {
  @override
  HostAccountsState build() => const HostAccountsState();
}
