import 'dart:typed_data';

import 'package:oronbox/src/device/core/event_bus.dart';
import 'package:oronbox/src/device/xiaomi/protocol/packet/l2_packet.dart';
import 'package:oronbox/src/device/xiaomi/systems/xiaomi_system.dart';

class XiaomiProtocolObserverSystem extends XiaomiSystem {
  @override
  void onLayer2Packet(L2Channel channel, L2OpCode opcode, Uint8List payload) {
    entity.emit(
      XiaomiProtocolPacketReceived(
        deviceId: entity.id,
        channel: channel.value,
        payload: Uint8List.fromList(payload),
      ),
    );
  }
}
