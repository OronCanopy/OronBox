import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oronbox/src/app/app_localizations_delegates.dart';
import 'package:oronbox/src/app/generated/app_localizations.dart';
import 'package:oronbox/src/app/widgets/app_state_view.dart';
import 'package:oronbox/src/core/models/bt_models.dart';
import 'package:oronbox/src/device/core/device_state.dart' as proto;
import 'package:oronbox/src/device/zeppos/systems/zeppos_alarms_system.dart';
import 'package:oronbox/src/features/devices/controllers/device_manager.dart';
import 'package:oronbox/src/features/devices/pages/tools/zeppos_alarms_page.dart';

const _alarm = ZeppOsAlarm(
  position: 0,
  hour: 7,
  minute: 30,
  repetition: 0,
);

class _AlarmManager extends LocalDeviceManager {
  List<ZeppOsAlarm> alarms = const [];
  int? capacity = 2;
  bool failLoad = false;
  int loads = 0;
  int writes = 0;
  final updates = StreamController<List<ZeppOsAlarm>>.broadcast();

  @override
  DeviceManagerState build() => const DeviceManagerState(
    currentDevice: MiWearState(
      name: 'Test ZeppOS',
      addr: 'z',
      connectType: 'ble',
      codename: 'zepp:test',
    ),
    protocolState: proto.ProtocolState.ready,
  );

  @override
  int? get zeppOsMaxAlarms => capacity;

  @override
  Stream<List<ZeppOsAlarm>> get zeppOsAlarmUpdates => updates.stream;

  @override
  Future<List<ZeppOsAlarm>> loadZeppOsAlarms() async {
    loads++;
    if (failLoad) throw StateError('load failed');
    return alarms;
  }

  @override
  Future<void> addZeppOsAlarm(ZeppOsAlarm alarm) async {
    writes++;
  }

  @override
  Future<void> updateZeppOsAlarm(ZeppOsAlarm alarm) async {
    writes++;
  }

  @override
  Future<void> deleteZeppOsAlarm(int position) async {
    writes++;
  }

  void markDisconnected() {
    state = state.copyWith(protocolState: proto.ProtocolState.disconnected);
  }
}

Future<void> _pump(WidgetTester tester, _AlarmManager manager) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [deviceManagerProvider.overrideWith(() => manager)],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const ZeppOsAlarmsPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  late _AlarmManager manager;

  setUp(() {
    manager = _AlarmManager();
  });
  tearDown(() async {
    await manager.updates.close();
  });

  testWidgets('failed load exposes retry and reloads alarms', (tester) async {
    manager.failLoad = true;
    await _pump(tester, manager);
    expect(find.byType(ErrorStateView), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsNothing);
    expect(manager.loads, 1);

    manager.failLoad = false;
    manager.alarms = const [_alarm];
    await tester.tap(find.descendant(
      of: find.byType(ErrorStateView),
      matching: find.byType(FilledButton),
    ));
    await tester.pumpAndSettle();
    expect(manager.loads, 2);
    expect(find.text('07:30'), findsOneWidget);
    expect(find.byType(ErrorStateView), findsNothing);
  });

  testWidgets('full capacity never exposes add', (tester) async {
    manager.capacity = 1;
    manager.alarms = const [_alarm];
    await _pump(tester, manager);
    expect(find.text('07:30'), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsNothing);
  });

  testWidgets('unknown capacity never exposes add', (tester) async {
    manager.capacity = null;
    await _pump(tester, manager);
    expect(find.byType(FloatingActionButton), findsNothing);
  });

  testWidgets('disconnect while editing prevents save from writing', (tester) async {
    manager.alarms = const [_alarm];
    await _pump(tester, manager);
    await tester.tap(find.byTooltip('编辑闹钟'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);

    manager.markDisconnected();
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(manager.writes, 0);
    final l10n = AppLocalizations.of(tester.element(find.byType(ZeppOsAlarmsPage)))!;
    expect(find.text(l10n.deviceNotConnected), findsOneWidget);
  });

  testWidgets('device notifications replace visible alarm values', (tester) async {
    manager.alarms = const [_alarm];
    await _pump(tester, manager);
    expect(find.text('07:30'), findsOneWidget);

    manager.updates.add([_alarm.copyWith(hour: 9, minute: 45)]);
    await tester.pumpAndSettle();
    expect(find.text('09:45'), findsOneWidget);
    expect(find.text('07:30'), findsNothing);
    expect(manager.loads, 1);
  });
}
