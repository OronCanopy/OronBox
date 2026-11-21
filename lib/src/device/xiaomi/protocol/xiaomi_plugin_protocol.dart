import 'dart:convert';
import 'dart:typed_data';

import 'package:protobuf/protobuf.dart' show InvalidProtocolBufferException;

import 'package:oronbox/src/device/xiaomi/protocol/generated/wear.pb.dart'
    as pb;

abstract final class XiaomiPluginProtocol {
  static String toJson(Uint8List bytes) {
    try {
      return jsonEncode(pb.WearPacket.fromBuffer(bytes).toProto3Json());
    } on InvalidProtocolBufferException {
      return '';
    }
  }

  static Uint8List fromJson(String json) =>
      (pb.WearPacket()..mergeFromProto3Json(jsonDecode(json))).writeToBuffer();
}
