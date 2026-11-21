import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:oronbox/src/device/xiaomi/protocol/generated/wear.pb.dart' as pb;
import 'package:oronbox/src/device/xiaomi/protocol/xiaomi_plugin_notification.dart';
import 'package:oronbox/src/device/xiaomi/protocol/xiaomi_plugin_protocol.dart';

void main() {
  test('transport JSON preserves notification content and zero fields', () {
    final packet = XiaomiPluginProtocol.fromJson(jsonEncode({
      'type': 'NOTIFICATION',
      'id': 0,
      'notification': {
        'data': {'title': 'Weather', 'text': '0°C', 'uid': 0},
      },
    }));
    final decoded = pb.WearPacket.fromBuffer(packet);
    expect(decoded.type, pb.WearPacket_Type.NOTIFICATION);
    expect(decoded.notification.data.text, '0°C');
    final roundTrip = XiaomiPluginProtocol.fromJson(XiaomiPluginProtocol.toJson(packet));
    expect(pb.WearPacket.fromBuffer(roundTrip), decoded);
  });

  test('invalid binary matches official empty JSON result', () {
    expect(XiaomiPluginProtocol.toJson(Uint8List.fromList([255])), '');
    expect(() => XiaomiPluginProtocol.fromJson('{'), throwsFormatException);
  });

  test('notification removal targets the same plugin-scoped identity', () {
    final message = <String, Object?>{
      'id': 0,
      'app-name': 'Weather',
      'title': 'Forecast',
      'sub-title': '',
      'body': '0°C',
      'timestamp-ms': DateTime(2026, 11, 12, 12, 34, 56).millisecondsSinceEpoch,
    };
    final sent = pb.WearPacket.fromBuffer(XiaomiPluginNotification.encode('weather', message));
    final removed = pb.WearPacket.fromBuffer(XiaomiPluginNotification.remove('weather', 0));
    final other = pb.WearPacket.fromBuffer(XiaomiPluginNotification.remove('other', 0));
    expect(sent.type, pb.WearPacket_Type.NOTIFICATION);
    expect(sent.id, 0);
    expect(removed.id, 1);
    expect(sent.notification.data.date, '20261112T123456');
    expect(sent.notification.data.uid, removed.notification.id.uid);
    expect(sent.notification.data.key, removed.notification.id.key);
    expect(removed.notification.id.key, isNot(other.notification.id.key));
    expect(sent.notification.data.supportReply, isFalse);
    expect(sent.notification.data.supportOpen, isFalse);
  });
}
