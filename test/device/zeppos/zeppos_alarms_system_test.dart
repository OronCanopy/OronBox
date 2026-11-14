import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:oronbox/src/device/core/entity.dart';
import 'package:oronbox/src/device/core/event_bus.dart';
import 'package:oronbox/src/device/core/transport.dart';
import 'package:oronbox/src/device/zeppos/systems/zeppos_alarms_system.dart';
import 'package:oronbox/src/device/zeppos/zeppos_device_component.dart';

void main() {
  late _Transport transport;
  late ZeppOsAlarmsSystem system;
  late DeviceEntity entity;

  setUp(() {
    transport = _Transport();
    final component = ZeppOsDeviceComponent(transport: transport);
    entity = DeviceEntity(
      id: 'z',
      kind: 'z',
      transport: transport,
      eventBus: DeviceEventBus(),
    )..set<ZeppOsDeviceComponent>(component);
    system = ZeppOsAlarmsSystem();
    entity.registerSystem(system);
  });

  tearDown(() async => entity.dispose());

  test('create uses upsert frame and confirms with list readback', () async {
    const alarm = ZeppOsAlarm(
      position: 1,
      hour: 7,
      minute: 5,
      repetition: 127,
      smartWakeup: true,
    );
    final future = system.create(alarm);
    await Future<void>.delayed(Duration.zero);
    expect([
      ...transport.sent[0].sublist(11),
      ...transport.sent[1].sublist(5),
    ], [
      3, 1, 5, 1, 7, 5, 127, 0, 0, 0, 0, 0,
    ]);
    system.handlePayload(Uint8List.fromList([4, 0]));
    await Future<void>.delayed(Duration.zero);
    expect(transport.sent.last.sublist(11), [9]);
    system.handlePayload(Uint8List.fromList([
      10, 1, 5, 1, 7, 5, 127, 0, 0, 0, 0, 0,
    ]));
    await future;
  });

  test('unconfirmed upsert and invalid time are rejected', () async {
    final future = system.update(const ZeppOsAlarm(
      position: 0,
      hour: 1,
      minute: 2,
      repetition: 0,
    ));
    await Future<void>.delayed(Duration.zero);
    system.handlePayload(Uint8List.fromList([4, 0]));
    await Future<void>.delayed(Duration.zero);
    expect(transport.sent, hasLength(3));
    final rejected = expectLater(future, throwsStateError);
    system.handlePayload(Uint8List.fromList([10, 0]));
    await rejected;
    await expectLater(
      system.create(const ZeppOsAlarm(
        position: 0,
        hour: 24,
        minute: 0,
        repetition: 0,
      )),
      throwsRangeError,
    );
  });

  test('default capacity rejects positions beyond ten', () async {
    await expectLater(
      system.create(const ZeppOsAlarm(
        position: 10,
        hour: 1,
        minute: 1,
        repetition: 0,
      )),
      throwsRangeError,
    );
    expect(transport.sent, isEmpty);
  });

  test('list decode and malformed response', () async {
    final load = system.load();
    await Future<void>.delayed(Duration.zero);
    system.handlePayload(Uint8List.fromList([
      10, 1, 5, 1, 23, 59, 127, 0, 0, 0, 0, 0,
    ]));
    expect((await load).single.position, 1);

    final invalid = system.load();
    await Future<void>.delayed(Duration.zero);
    system.handlePayload(Uint8List.fromList([10, 1, 5, 1]));
    await expectLater(invalid, throwsA(isA<FormatException>()));
  });

  test('incoming repetition uses only defined weekday bits', () async {
    for (final (wire, weekdays) in [(0x80, 0), (0xff, 127), (0x85, 5)]) {
      final load = system.load();
      await Future<void>.delayed(Duration.zero);
      system.handlePayload(Uint8List.fromList([
        10, 1, 4, 0, 7, 30, wire, 0, 0, 0, 0, 0,
      ]));
      expect((await load).single.repetition, weekdays);
    }
  });

  test('outgoing repetition rejects bits outside the weekday mask', () async {
    await expectLater(
      system.create(const ZeppOsAlarm(
        position: 0, hour: 7, minute: 30, repetition: 0x80,
      )),
      throwsRangeError,
    );
    expect(transport.sent, isEmpty);
  });

  test('delete confirms that the alarm disappeared', () async {
    final future = system.delete(3);
    await Future<void>.delayed(Duration.zero);
    expect(transport.sent.single.sublist(11), [5, 1, 3]);
    system.handlePayload(Uint8List.fromList([6, 1]));
    await Future<void>.delayed(Duration.zero);
    expect(transport.sent.last.sublist(11), [9]);
    system.handlePayload(Uint8List.fromList([10, 0]));
    await future;
  });

  test('byte range is rejected', () async {
    await expectLater(system.delete(256), throwsRangeError);
    expect(transport.sent, isEmpty);
  });

  test('disconnect rejects queued work without sending it', () async {
    final first = system.load();
    final second = system.load();
    await Future<void>.delayed(Duration.zero);
    expect(transport.sent, hasLength(1));
    entity.emit(const TransportDisconnected(deviceId: 'z'));
    await expectLater(first, throwsStateError);
    await expectLater(second, throwsStateError);
    expect(transport.sent, hasLength(1));
  });

  test('dispose releases pending operation', () async {
    final future = system.load();
    await Future<void>.delayed(Duration.zero);
    final rejected = expectLater(future, throwsStateError);
    await system.dispose();
    await rejected;
  });

  test('load times out when no response arrives', () async {
    await expectLater(system.load(), throwsA(isA<TimeoutException>()));
  }, timeout: const Timeout(Duration(seconds: 10)));
}

class _Transport implements Transport {
  final sent = <Uint8List>[];

  @override
  String get deviceId => 'z';

  @override
  String get deviceName => 'z';

  @override
  Stream<Uint8List> get incomingData => const Stream.empty();

  @override
  Stream<bool> get connectionState => const Stream.empty();

  @override
  Future<void> send(Uint8List data) async {
    sent.add(Uint8List.fromList(data));
  }

  @override
  Future<void> dispose() async {}
}
