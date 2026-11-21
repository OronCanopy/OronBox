import 'package:oronbox/src/device/xiaomi/systems/xiaomi_system.dart';
import 'package:oronbox/src/device/xiaomi/protocol/generated/wear.pb.dart'
    as pb;
import 'package:oronbox/src/device/xiaomi/protocol/generated/wear_factory.pb.dart'
    as pb_factory;

class XiaomiFactorySystem extends XiaomiPbSystem {
  pb.WearPacket _packet(int id, [int? mode]) => pb.WearPacket(
    type: pb.WearPacket_Type.FACTORY,
    id: id,
    factory: pb_factory.Factory(
      mode: mode == null ? null : pb_factory.FactoryMode.valueOf(mode),
    ),
  );

  Future<int> getMode() => component.requestPool.request<int>(
    packet: _packet(6),
    typeMatcher: (packet) =>
        packet.type == pb.WearPacket_Type.FACTORY &&
        packet.id == 6 &&
        packet.factory.hasMode(),
    responseMapper: (packet) => packet.factory.mode.value,
  );

  Future<void> setMode(int mode) {
    if (![0, 1, 2].contains(mode)) throw ArgumentError.value(mode);
    return component.sendPbPacket(_packet(0, mode));
  }

  @override
  void onWearPacket(pb.WearPacket packet) {}
}
