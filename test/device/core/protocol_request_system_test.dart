import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:oronbox/src/device/core/entity.dart';
import 'package:oronbox/src/device/core/event_bus.dart';
import 'package:oronbox/src/device/core/protocol_request_system.dart';
import 'package:oronbox/src/device/core/transport.dart';

void main() {
  late DeviceEntity entity;
  late DeviceEventBus bus;
  late ProtocolRequestSystem requests;
  setUp(() {
    bus = DeviceEventBus();
    entity = DeviceEntity(
      id: 'watch',
      kind: 'zeppos',
      transport: _Transport(),
      eventBus: bus,
    );
    requests = ProtocolRequestSystem();
    entity.registerSystem(requests);
  });
  tearDown(() async {
    await entity.dispose();
    bus.dispose();
  });

  void reply(int channel, {String device = 'watch', int value = 42}) {
    bus.emit(
      ProtocolPacketReceived(
        deviceId: device,
        protocol: 'zeppos',
        channel: channel,
        payload: Uint8List.fromList([value]),
      ),
    );
  }

  Future<Uint8List> request(
    int channel, {
    Stream<void>? cancellation,
    Future<void> Function()? send,
  }) => requests.request(
    channel: channel,
    send: send ?? () async {},
    timeout: const Duration(seconds: 1),
    cancellation: cancellation,
  );

  test('routes complete replies by device and channel and rejects ambiguous concurrency', () async {
    final first = request(1);
    final second = request(2);
    await expectLater(request(1), throwsStateError);
    reply(1, device: 'other', value: 99);
    reply(3, value: 99);
    reply(2, value: 2);
    reply(1);
    expect(await first, [42]);
    expect(await second, [2]);
  });

  test('cancel releases a stalled request and isolates its late reply from a new session', () async {
    final cancellation = StreamController<void>.broadcast(sync: true);
    final sending = Completer<void>();
    final result = request(
      1,
      cancellation: cancellation.stream,
      send: () => sending.future,
    );
    final cancelled = expectLater(
      result.timeout(const Duration(milliseconds: 100)),
      throwsStateError,
    );
    cancellation.add(null);
    await cancelled;
    expect(cancellation.hasListener, false);
    await cancellation.close();
    await expectLater(request(1), throwsStateError);
    reply(1, value: 99);
    await Future<void>.delayed(Duration.zero);
    final next = request(1);
    reply(1);
    expect(await next, [42]);
    sending.completeError(StateError('late transport error'));
  });

  test('disconnect and disposal cancel pending requests', () async {
    final first = request(1);
    final disconnected = expectLater(first, throwsStateError);
    bus.emit(TransportDisconnected(deviceId: 'watch'));
    await disconnected;
    final second = request(2);
    final disposed = expectLater(second, throwsStateError);
    await entity.dispose();
    await disposed;
    await expectLater(request(3), throwsStateError);
  });
}

class _Transport implements Transport {
  @override
  String get deviceId => 'watch';
  @override
  String get deviceName => 'Watch';
  @override
  Stream<Uint8List> get incomingData => const Stream.empty();
  @override
  Stream<bool> get connectionState => const Stream.empty();
  @override
  Future<void> send(Uint8List bytes) async {}
  @override
  Future<void> dispose() async {}
}
