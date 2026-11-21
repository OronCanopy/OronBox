import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:oronbox/src/device/core/transport.dart';
import 'package:oronbox/src/device/core/event_bus.dart';
import 'package:oronbox/src/device/zeppos/crypto/zeppos_auth_crypto.dart';
import 'package:oronbox/src/device/zeppos/zeppos_device_factory.dart';
import 'package:oronbox/src/device/zeppos/zeppos_device_component.dart';

void main() {
  test('outbound authentication payload uses extended 2021 chunks', () async {
    final transport = _FakeTransport();
    final component = ZeppOsDeviceComponent(transport: transport);

    await component.sendToEndpoint(
      ZeppOsDeviceComponent.endpointAuthentication,
      Uint8List.fromList(List<int>.generate(12, (index) => index)),
    );

    expect(transport.writes, hasLength(2));
    expect(transport.writes.first.sublist(0, 11), [
      0x03,
      0x01,
      0x00,
      0x01,
      0x00,
      0x0c,
      0x00,
      0x00,
      0x00,
      0x82,
      0x00,
    ]);
    expect(transport.writes.last.sublist(0, 5), [0x03, 0x06, 0x00, 0x01, 0x01]);
  });

  test(
    'protocol events contain complete decrypted endpoint payloads',
    () async {
      final transport = _FakeTransport();
      final senderTransport = _FakeTransport();
      final bus = DeviceEventBus();
      final entity = ZeppOsDeviceFactory().create(
        id: 'watch',
        kind: 'zeppos',
        transport: transport,
        eventBus: bus,
      );
      final keys = ZeppOsAuthKeys(
        privateKey: Uint8List(0),
        publicKey: Uint8List(0),
        sharedSecret: Uint8List(0),
        sessionKey: Uint8List.fromList(List.generate(16, (i) => i)),
        encryptedSequenceNumber: 1,
      );
      entity.getRequired<ZeppOsDeviceComponent>().authKeys = keys;
      entity.startListening();
      final sender = ZeppOsDeviceComponent(transport: senderTransport)
        ..authKeys = keys;
      final bytes = Uint8List.fromList(List.generate(35, (i) => i));
      final received = entity.on<ProtocolPacketReceived>().first;
      try {
        await sender.sendToEndpoint(
          0x1234,
          bytes,
          encrypted: true,
          maxWriteLength: 20,
        );
        expect(senderTransport.writes.length, greaterThan(1));
        for (final chunk in senderTransport.writes) {
          transport._incoming.add(chunk);
        }
        final event = await received.timeout(const Duration(seconds: 1));
        expect(event.channel, 0x1234);
        expect(event.protocol, 'zeppos');
        expect(event.payload, bytes);
      } finally {
        await entity.dispose();
        await senderTransport.dispose();
        bus.dispose();
      }
    },
  );

  test('rejects continuation chunks without a first chunk', () {
    final component = ZeppOsDeviceComponent(transport: _FakeTransport());
    expect(
      () => component.handleIncoming(
        Uint8List.fromList([0x03, 0x02, 0x00, 0x01, 0x01]),
      ),
      throwsStateError,
    );
  });
}

class _FakeTransport implements Transport {
  final writes = <Uint8List>[];
  final _incoming = StreamController<Uint8List>.broadcast();
  final _connection = StreamController<bool>.broadcast();

  @override
  String get deviceId => 'test-device';

  @override
  String get deviceName => 'Test ZeppOS';

  @override
  Stream<Uint8List> get incomingData => _incoming.stream;

  @override
  Stream<bool> get connectionState => _connection.stream;

  @override
  Future<void> send(Uint8List data) async {
    writes.add(Uint8List.fromList(data));
  }

  @override
  Future<void> dispose() async {
    await _incoming.close();
    await _connection.close();
  }
}
