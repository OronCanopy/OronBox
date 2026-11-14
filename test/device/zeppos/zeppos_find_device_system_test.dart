import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oronbox/src/device/core/entity.dart';
import 'package:oronbox/src/device/core/event_bus.dart';
import 'package:oronbox/src/device/core/transport.dart';
import 'package:oronbox/src/device/zeppos/systems/zeppos_find_device_system.dart';
import 'package:oronbox/src/device/zeppos/zeppos_device_component.dart';

void main() {
  test('capabilities have exact length and encryption follows configuration', () {
    fakeAsync((clock) {
      final h = Harness();
      unawaited(h.system.initialize());
      clock.flushMicrotasks();
      expect(h.component.sent, [[1]]);
      expect(h.component.encryption, [false]);
      for (final frame in [<int>[], [2], [2, 1], [2, 1, 2, 0], [255]]) {
        h.receive(frame);
        expect(h.system.version, 0);
      }
      h.receive([2, 1, 2]);
      expect(h.system.supportsContinuousFindDevice, isTrue);
      h.system.encrypted = true;
      unawaited(h.system.setFinding(true));
      clock.flushMicrotasks();
      expect(h.component.encryption.last, isTrue);
      h.close(clock);
    });
  });

  test('legacy repeats are ACK driven, coalesced and cancellable', () {
    fakeAsync((clock) {
      final h = Harness();
      h.receive([2, 1, 1]);
      unawaited(h.system.setFinding(true));
      clock.elapse(const Duration(seconds: 30));
      expect(h.component.sent, [[3]]);
      h.receive([4]);
      h.receive([4]);
      expect(clock.nonPeriodicTimerCount, 1);
      clock.elapse(const Duration(milliseconds: 9999));
      expect(h.component.sent.length, 1);
      clock.elapse(const Duration(milliseconds: 1));
      expect(h.component.sent, [[3], [3]]);
      clock.elapse(const Duration(seconds: 30));
      expect(h.component.sent.length, 2);
      h.receive([4]);
      unawaited(h.system.setFinding(false));
      clock.elapse(const Duration(seconds: 30));
      expect(h.component.sent, [[3], [3], [6]]);
      h.close(clock);
    });
  });

  test('v2 cancels legacy repeat; watch stop updates UI', () {
    fakeAsync((clock) {
      final h = Harness();
      unawaited(h.system.setFinding(true));
      h.receive([4]);
      h.receive([2, 1, 2]);
      h.receive([4]);
      clock.elapse(const Duration(seconds: 30));
      expect(h.component.sent, [[3]]);
      h.receive([7]);
      clock.flushMicrotasks();
      final event = h.events.whereType<ZeppOsFindWearableRequested>().last;
      expect(event.deviceId, 'device');
      expect(event.finding, isFalse);
      h.close(clock);
    });
  });

  test('ACK then fallback ring at exactly 1500 milliseconds', () {
    fakeAsync((clock) {
      final h = Harness();
      h.receive([0x11]);
      expect(h.component.sent, [[0x12, 1]]);
      clock.flushMicrotasks();
      clock.elapse(const Duration(milliseconds: 1499));
      expect(h.phone, isEmpty);
      clock.elapse(const Duration(milliseconds: 1));
      expect(h.phone.single.deviceId, 'device');
      expect(h.phone.single.finding, isTrue);
      expect(h.phone.single.ring, isTrue);
      h.close(clock);
    });
  });

  test('mode requires request; vibrate then ring; stop has no echo', () {
    fakeAsync((clock) {
      final h = Harness();
      h.receive([0x15, 0]);
      clock.flushMicrotasks();
      expect(h.phone, isEmpty);
      h.receive([0x11]);
      h.receive([0x15, 0]); // Mode can precede ACK future completion.
      clock.flushMicrotasks();
      expect(h.phone.single.ring, isFalse);
      expect(h.phone.single.finding, isTrue);
      expect(clock.nonPeriodicTimerCount, 0);
      clock.elapse(const Duration(seconds: 2));
      expect(h.phone.length, 1);
      h.receive([0x15, 1]);
      clock.flushMicrotasks();
      expect(h.phone.last.ring, isTrue);
      h.receive([0x13]);
      h.receive([0x15, 1]);
      clock.flushMicrotasks();
      expect(h.phone.length, 3);
      expect(h.phone.last.finding, isFalse);
      expect(h.component.sent, [[0x12, 1]]);
      h.close(clock);
    });
  });

  test('malformed frames preserve fallback; stop cancels pending start', () {
    fakeAsync((clock) {
      final h = Harness();
      h.receive([0x11, 0]);
      expect(h.component.sent, isEmpty);
      h.receive([0x11]);
      clock.flushMicrotasks();
      for (final frame in [[0x15], [0x15, 2], [0x15, 1, 0], [0x13, 0]]) {
        h.receive(frame);
      }
      expect(clock.nonPeriodicTimerCount, 1);
      h.receive([0x13]);
      clock.elapse(const Duration(seconds: 2));
      expect(h.phone.single.finding, isFalse);
      h.close(clock);
    });
  });

  test('local stop sends 14 and invalidates pending ACK and late mode', () {
    fakeAsync((clock) {
      final h = Harness();
      final ack = Completer<void>();
      h.component.block = ack.future;
      h.receive([0x11]);
      h.component.block = null;
      unawaited(h.system.stopFindingPhone());
      ack.complete();
      h.receive([0x15, 1]);
      clock.elapse(const Duration(seconds: 2));
      expect(h.component.sent, [[0x12, 1], [0x14]]);
      expect(h.phone.single.finding, isFalse);
      h.close(clock);
    });
  });

  for (final disconnect in [true, false]) {
    test('teardown disconnect=$disconnect stops both finders and timers', () {
      fakeAsync((clock) {
        final h = Harness();
        unawaited(h.system.setFinding(true));
        h.receive([4]);
        h.receive([0x11]);
        clock.flushMicrotasks();
        expect(clock.nonPeriodicTimerCount, 2);
        if (disconnect) {
          h.bus.emit(const TransportDisconnected(deviceId: 'other'));
          clock.flushMicrotasks();
          expect(clock.nonPeriodicTimerCount, 2);
          h.bus.emit(const TransportDisconnected(deviceId: 'device'));
        } else {
          unawaited(h.system.dispose());
        }
        clock.flushMicrotasks();
        expect(h.phone.single.finding, isFalse);
        expect(h.events.whereType<ZeppOsFindWearableRequested>().last.finding,
            isFalse);
        expect(clock.nonPeriodicTimerCount, 0);
        h.receive([0x15, 1]);
        clock.elapse(const Duration(seconds: 30));
        expect(h.phone.length, 1);
        expect(h.component.sent, [[3], [0x12, 1]]);
        h.close(clock);
      });
    });
  }

  test('initialize is idempotent and duplicate start preserves active mode', () {
    fakeAsync((clock) {
      final h = Harness();
      unawaited(h.system.initialize());
      unawaited(h.system.initialize());
      h.receive([0x11]);
      h.receive([0x15, 0]);
      clock.flushMicrotasks();
      unawaited(h.system.initialize());
      h.receive([0x11]);
      clock.elapse(const Duration(seconds: 2));
      expect(h.component.sent, [[1], [0x12, 1], [0x12, 1]]);
      expect(h.phone.single.ring, isFalse);
      expect(h.phone.single.finding, isTrue);
      h.close(clock);
    });
  });

  test('watch send completions cannot resurrect state after stop', () {
    fakeAsync((clock) {
      final h = Harness();
      final start = Completer<void>();
      h.component.block = start.future;
      unawaited(h.system.setFinding(true));
      h.component.block = null;
      unawaited(h.system.setFinding(false));
      clock.flushMicrotasks();
      start.complete();
      clock.flushMicrotasks();
      final states = h.events.whereType<ZeppOsFindWearableRequested>();
      expect(states.length, 1);
      expect(states.single.finding, isFalse);
      unawaited(h.system.setFinding(true));
      clock.flushMicrotasks();
      expect(h.events.whereType<ZeppOsFindWearableRequested>().last.finding,
          isTrue);
      h.close(clock);
    });
  });

  test('failed ACK and repeat leave no start or timer', () {
    fakeAsync((clock) {
      final h = Harness();
      h.component.fail = true;
      h.receive([0x11]);
      clock.flushMicrotasks();
      expect(h.phone.single.finding, isFalse);
      expect(clock.nonPeriodicTimerCount, 0);
      h.component.fail = false;
      unawaited(h.system.setFinding(true));
      h.receive([4]);
      h.component.fail = true;
      clock.elapse(const Duration(seconds: 10));
      expect(h.events.whereType<DeviceError>().length, 2);
      h.close(clock);
    });
  });
}

class Harness {
  Harness() {
    final entity = DeviceEntity(
      id: 'device',
      kind: 'zepp',
      transport: UnusedTransport(),
      eventBus: bus,
    );
    entity.set<ZeppOsDeviceComponent>(component);
    entity.registerSystem(system);
    subscription = bus.stream.listen(events.add);
  }

  final bus = DeviceEventBus();
  final component = RecordingComponent();
  final system = ZeppOsFindDeviceSystem()..encrypted = false;
  final events = <DeviceEvent>[];
  late final StreamSubscription<DeviceEvent> subscription;

  List<ZeppOsFindPhoneRequested> get phone =>
      events.whereType<ZeppOsFindPhoneRequested>().toList();

  void receive(List<int> bytes) =>
      system.handlePayload(Uint8List.fromList(bytes));

  void close(FakeAsync clock) {
    unawaited(system.dispose());
    clock.flushMicrotasks();
    expect(clock.nonPeriodicTimerCount, 0);
    expect(clock.periodicTimerCount, 0);
    unawaited(subscription.cancel());
    bus.dispose();
    clock.flushMicrotasks();
  }
}

class RecordingComponent extends ZeppOsDeviceComponent {
  RecordingComponent() : super(transport: UnusedTransport());
  final sent = <List<int>>[];
  final encryption = <bool>[];
  bool fail = false;
  Future<void>? block;

  @override
  Future<void> sendToEndpoint(
    int endpoint,
    Uint8List payload, {
    bool encrypted = false,
    int? maxWriteLength,
  }) async {
    expect(endpoint, ZeppOsFindDeviceSystem.endpoint);
    sent.add(payload.toList());
    encryption.add(encrypted);
    if (fail) throw StateError('send failed');
    await block;
  }
}

class UnusedTransport implements Transport {
  @override
  String get deviceId => 'device';
  @override
  String get deviceName => 'Zepp Device';
  @override
  Stream<Uint8List> get incomingData => const Stream.empty();
  @override
  Stream<bool> get connectionState => const Stream.empty();
  @override
  Future<void> send(Uint8List data) async {}
  @override
  Future<void> dispose() async {}
}
