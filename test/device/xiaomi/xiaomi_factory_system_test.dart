import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:oronbox/src/device/core/entity.dart';
import 'package:oronbox/src/device/core/event_bus.dart';
import 'package:oronbox/src/device/core/transport.dart';
import 'package:oronbox/src/device/xiaomi/systems/factory_system.dart';
import 'package:oronbox/src/device/xiaomi/systems/xiaomi_device_component.dart';
import 'package:oronbox/src/device/xiaomi/protocol/generated/wear.pb.dart'
    as pb;
import 'package:oronbox/src/device/xiaomi/protocol/generated/wear_factory.pb.dart'
    as pb_factory;

class _Link implements Transport {
  @override
  String get deviceId => 'factory-test';
  @override
  String get deviceName => 'factory-test';
  @override
  Stream<Uint8List> get incomingData => const Stream.empty();
  @override
  Stream<bool> get connectionState => const Stream.empty();
  @override
  Future<void> send(Uint8List data) async {}
  @override
  Future<void> dispose() async {}
}

class _Component extends XiaomiDeviceComponent {
  _Component({required super.transport}) : super(sppV1: false);
  final sent = <pb.WearPacket>[];
  @override
  Future<void> sendPbPacket(
    pb.WearPacket packet, {
    bool waitForAck = false,
  }) async {
    sent.add(packet);
    if (packet.id == 6) {
      requestPool.onPacket(
        pb.WearPacket(
          type: pb.WearPacket_Type.FACTORY,
          id: 6,
          factory: pb_factory.Factory(mode: pb_factory.FactoryMode.USERDEBUG),
        ),
      );
    }
  }
}

void main() {
  test(
    'factory commands use type 13 and field 15 and preserve USER zero',
    () async {
      final link = _Link();
      final events = DeviceEventBus();
      final entity = DeviceEntity(
        id: link.deviceId,
        kind: 'xiaomi',
        transport: link,
        eventBus: events,
      );
      final component = _Component(transport: link);
      entity.set<XiaomiDeviceComponent>(component);
      final system = XiaomiFactorySystem();
      entity.registerSystem(system);
      expect(await system.getMode(), 1);
      for (final mode in [0, 1, 2]) {
        await system.setMode(mode);
        final packet = component.sent.last;
        expect(packet.type.value, 13);
        expect(packet.id, 0);
        expect(packet.factory.hasMode(), isTrue);
        expect(packet.factory.mode.value, mode);
        expect(packet.writeToBuffer(), contains(0x7a));
      }
      expect(() => system.setMode(3), throwsArgumentError);
      await entity.dispose();
      events.dispose();
    },
  );
}
