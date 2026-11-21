import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oronbox/src/app/app_localizations_delegates.dart';
import 'package:oronbox/src/app/generated/app_localizations.dart';
import 'package:oronbox/src/core/models/bt_models.dart';
import 'package:oronbox/src/core/services/shared_prefs_service.dart';
import 'package:oronbox/src/core/storage/app_data_directory_io.dart';
import 'package:oronbox/src/features/devices/controllers/device_manager.dart';
import 'package:oronbox/src/features/devices/health/health_cards.dart';
import 'package:oronbox/src/features/devices/health/health_models.dart';
import 'package:oronbox/src/features/devices/health/health_store.dart';
import 'package:oronbox/src/features/devices/health/pages/xiaomi_health_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _DelayedActivityStorage storage;
  setUp(() async {
    storage = _DelayedActivityStorage();
    HealthStore.activityStorageForTesting = storage;
    HealthStore.clearCache();
    SharedPreferences.setMockInitialValues({});
    await SharedPrefsService.instance.init();
    await SharedPrefsService.instance.reload();
  });
  tearDown(() async {
    if (!storage.resume.isCompleted) storage.resume.complete();
    HealthStore.activityStorageForTesting = null;
    HealthStore.clearCache();
  });

  testWidgets('device switch discards an outstanding health page load', (
    tester,
  ) async {
    const channel = MethodChannel('org.oroncanopy.oronbox/status_surfaces');
    final updates = <int>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'updateHealthStatus') {
        updates.add((call.arguments as Map)['steps'] as int);
      }
      return null;
    });
    addTearDown(() async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );
    });
    final now = DateTime.now();
    final store = HealthStore();
    await store.write(
      'first',
      XiaomiHealthData(daily: [HealthDailySummary(date: now, steps: 111)]),
    );
    await store.write(
      'second',
      XiaomiHealthData(daily: [HealthDailySummary(date: now, steps: 222)]),
    );
    final manager = _HealthDeviceManager();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [deviceManagerProvider.overrideWith(() => manager)],
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const XiaomiHealthPage(),
        ),
      ),
    );
    expect(storage.started.isCompleted, isTrue);
    manager.selectDevice('second');
    await tester.pump();
    storage.resume.complete();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();

    expect(updates, [222]);
    expect(
      tester
          .widget<ActivityOverviewCard>(find.byType(ActivityOverviewCard))
          .summary!
          .steps,
      222,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await store.write(
      'second',
      XiaomiHealthData(daily: [HealthDailySummary(date: now, steps: 333)]),
    );
    await tester.pump();
    expect(updates, [222]);
    expect(tester.takeException(), isNull);
  });
}

class _HealthDeviceManager extends LocalDeviceManager {
  @override
  DeviceManagerState build() =>
      DeviceManagerState(currentDevice: _device('first'));

  void selectDevice(String id) =>
      state = state.copyWith(currentDevice: _device(id));

  MiWearState _device(String id) =>
      MiWearState(name: id, addr: id, connectType: 'ble');
}

class _DelayedActivityStorage extends IoAppDataDirectory {
  _DelayedActivityStorage() : super(Directory.systemTemp);

  final started = Completer<void>();
  final resume = Completer<void>();

  @override
  Future<T> exclusive<T>(Future<T> Function() action) => action();

  @override
  Future<Uint8List?> read(String path) async {
    if (path == 'index.json' && !started.isCompleted) {
      started.complete();
      await resume.future;
    }
    return null;
  }
}
