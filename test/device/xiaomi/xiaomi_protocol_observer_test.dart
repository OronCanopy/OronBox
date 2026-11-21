import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:oronbox/src/device/core/entity.dart';
import 'package:oronbox/src/device/core/event_bus.dart';
import 'package:oronbox/src/device/core/transport.dart';
import 'package:oronbox/src/device/xiaomi/protocol/packet/l2_packet.dart';
import 'package:oronbox/src/device/xiaomi/protocol/packet/l1_packet.dart';
import 'package:oronbox/src/device/xiaomi/protocol/packet/spp_v1_packet.dart';
import 'package:oronbox/src/device/xiaomi/systems/protocol_observer_system.dart';
import 'package:oronbox/src/device/xiaomi/systems/xiaomi_device_component.dart';
import 'package:oronbox/src/device/xiaomi/systems/xiaomi_dispatcher.dart';
import 'package:oronbox/src/device/xiaomi/utils/auth_utils.dart';
import 'package:oronbox/src/device/xiaomi/protocol/crypto/miwear_crypto.dart';

void main() {
  for (final v1 in [false, true]) {
    test(
      'SPP ${v1 ? 1 : 2} observation publishes decrypted channel payloads',
      () async {
        final transport = _Transport();
        final bus = DeviceEventBus();
        final entity = DeviceEntity(
          id: 'watch',
          kind: 'xiaomi',
          transport: transport,
          eventBus: bus,
        );
        final key = Uint8List.fromList(List.generate(16, (i) => i));
        final keys = XiaomiAuthKeys(
          encKey: key,
          decKey: key,
          encNonce: Uint8List.fromList([1, 2, 3, 4]),
          decNonce: Uint8List.fromList([1, 2, 3, 4]),
        );
        final component = XiaomiDeviceComponent(transport: transport, sppV1: v1)
          ..authKeys = keys;
        final dispatcher = XiaomiDispatcher(component);
        component.onL2Payload = dispatcher.onL2Payload;
        entity.set(component);
        entity.setDispatcher(dispatcher);
        entity.registerSystem(XiaomiProtocolObserverSystem());
        entity.startListening();
        final received = entity.on<ProtocolPacketReceived>().first;
        final plain = Uint8List.fromList([8, 6, 16, 1]);
        try {
          if (v1) {
            // Watch-to-phone SPP v1 uses the receive nonce without the
            // phone-to-watch counter prefix.
            final cipher = aes128CcmEncrypt(
              key,
              Uint8List(12)..setRange(0, 4, keys.decNonce),
              Uint8List(0),
              plain,
            );
            final encrypted = XiaomiSppV1Codec().encodeProtobuf(
              cipher,
              authenticate: true,
            );
            encrypted[9] = XiaomiSppV1Packet.encrypted;
            transport.incoming.add(Uint8List.sublistView(encrypted, 0, 9));
            await Future<void>.delayed(Duration.zero);
            transport.incoming.add(Uint8List.sublistView(encrypted, 9));
          } else {
            final encrypted = L2Packet.pbWriteEncBytes(
              plain,
              keys.cipher,
            ).toBytes();
            expect(encrypted.sublist(2), isNot(plain));
            dispatcher.onL2Payload(encrypted);
          }
          final event = await received.timeout(const Duration(seconds: 1));
          expect(event.payload, plain);
          expect(event.channel, 1);
          expect(event.protocol, 'xiaomi');
          await component.sendProtobufBytes(plain);
          await Future<void>.delayed(Duration.zero);
          final outgoing = transport.writes.single;
          if (v1) {
            expect(outgoing[9], XiaomiSppV1Packet.encrypted);
            final counter = outgoing[10] | outgoing[11] << 8;
            final nonce = Uint8List(12)..setRange(0, 4, keys.encNonce);
            nonce.buffer.asByteData().setUint32(8, counter, Endian.little);
            expect(
              aes128CcmDecrypt(
                key,
                nonce,
                Uint8List(0),
                Uint8List.sublistView(outgoing, 12, outgoing.length - 1),
              ),
              plain,
            );
          } else {
            final l1 = L1Packet.fromBytes(outgoing);
            expect(l1.payload[1], L2OpCode.writeEnc.value);
            expect(
              L2Packet.fromBytes(l1.payload, cipher: keys.cipher).payload,
              plain,
            );
          }
        } finally {
          await entity.dispose();
          bus.dispose();
        }
      },
    );
  }

  for (final v1 in [false, true]) {
    test(
      'encrypted SPP ${v1 ? 1 : 2} never reaches observers before authentication',
      () async {
        final transport = _Transport();
        final bus = DeviceEventBus();
        final entity = DeviceEntity(
          id: 'watch',
          kind: 'xiaomi',
          transport: transport,
          eventBus: bus,
        );
        final component = XiaomiDeviceComponent(
          transport: transport,
          sppV1: v1,
        );
        final dispatcher = XiaomiDispatcher(component);
        entity.set(component);
        entity.setDispatcher(dispatcher);
        entity.registerSystem(XiaomiProtocolObserverSystem());
        final packets = <ProtocolPacketReceived>[];
        final subscription = entity.on<ProtocolPacketReceived>().listen(
          packets.add,
        );
        try {
          if (v1) {
            final bytes = XiaomiSppV1Codec().encodeProtobuf(
              Uint8List.fromList([8, 6, 16, 1]),
              authenticate: true,
            );
            bytes[9] = XiaomiSppV1Packet.encrypted;
            dispatcher.dispatch(bytes);
          } else {
            dispatcher.onL2Payload(Uint8List.fromList([1, 2, 8, 6, 16, 1]));
          }
          await Future<void>.delayed(Duration.zero);
          expect(packets, isEmpty);
        } finally {
          await subscription.cancel();
          await entity.dispose();
          bus.dispose();
        }
      },
    );
  }
}

class _Transport implements Transport {
  final incoming = StreamController<Uint8List>.broadcast();
  final writes = <Uint8List>[];
  @override
  String get deviceId => 'watch';
  @override
  String get deviceName => 'Watch';
  @override
  Stream<Uint8List> get incomingData => incoming.stream;
  @override
  Stream<bool> get connectionState => const Stream.empty();
  @override
  Future<void> send(Uint8List bytes) async {
    writes.add(Uint8List.fromList(bytes));
  }

  @override
  Future<void> dispose() => incoming.close();
}
