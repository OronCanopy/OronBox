import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:oronbox/src/device/core/phone_notification.dart';
import 'package:oronbox/src/device/xiaomi/protocol/generated/wear.pb.dart'
    as pb;
import 'package:oronbox/src/device/xiaomi/protocol/generated/wear_notification.pb.dart'
    as notification;

abstract final class XiaomiPluginNotification {
  static notification.NotifyId _identity(String source, int id) {
    final namespace = sha256.convert(utf8.encode(source)).toString();
    final key = '$namespace:$id';
    final hash = Uint8List.fromList(sha256.convert(utf8.encode(key)).bytes);
    return notification.NotifyId(
      uid: ByteData.sublistView(hash).getUint32(0, Endian.little),
      appId: 'org.zxor.oronbox.plugin.$namespace',
      appGroup: namespace,
      key: key,
    );
  }

  static Uint8List encode(String source, Map<String, Object?> message) {
    final identity = _identity(source, (message['id'] as num).toInt());
    final date = DateTime.fromMillisecondsSinceEpoch(
      (message['timestamp-ms'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch,
    );
    final data = _data(
      identity,
      date,
      appName: message['app-name'] as String,
      title: message['title'] as String,
      subtitle: message['sub-title'] as String,
      body: message['body'] as String,
    );
    if (message['live-activity'] case final Map activity) {
      final value = (activity['value'] as Map).cast<String, Object?>();
      if (activity['case'] == 'focus') {
        data.focus = notification.NotifyData_Focus(
          style: (value['style'] as num).toInt(),
          title: _text(value['title']),
          content: _text(value['content']),
          desc: _text(value['desc']),
          progress: _progress(value['progress']),
          updatable: value['updatable'] as bool,
          sequence: (value['sequence'] as num).toInt(),
        );
      } else if (activity['case'] == 'focus-v2') {
        data.focusV2 = notification.NotifyData_FocusV2(
          scene: (value['scene'] as num).toInt(),
          ticker: value['ticker'] as String,
          basicInfo: _info(value['basic-info']),
          hintInfo: _info(value['hint-info']),
          progress: _progress(value['progress']),
          updatable: value['updatable'] as bool,
          sequence: (value['sequence'] as num).toInt(),
        );
      } else {
        throw const FormatException('Unknown live activity');
      }
    }
    return _encodeData(data);
  }

  static Uint8List phone(PhoneNotification value, {required bool removed}) {
    final identity = notification.NotifyId(
      uid: value.id,
      appId: value.package,
      key: value.key,
    );
    if (removed) return _remove(identity);
    return _encodeData(
      _data(
        identity,
        value.timestamp,
        appName: value.appName,
        title: value.title,
        body: value.body,
      ),
    );
  }

  static notification.NotifyData _data(
    notification.NotifyId identity,
    DateTime date, {
    required String appName,
    required String title,
    required String body,
    String subtitle = '',
  }) {
    String digits(int value, [int width = 2]) =>
        value.toString().padLeft(width, '0');
    return notification.NotifyData(
      uid: identity.uid,
      appId: identity.appId,
      appGroup: identity.hasAppGroup() ? identity.appGroup : null,
      key: identity.key,
      appName: appName,
      title: title,
      subTitle: subtitle,
      text: body,
      date:
          '${digits(date.year, 4)}${digits(date.month)}${digits(date.day)}T${digits(date.hour)}${digits(date.minute)}${digits(date.second)}',
      supportReply: false,
      supportOpen: false,
    );
  }

  static Uint8List _encodeData(notification.NotifyData data) {
    final bytes = pb.WearPacket(
      type: pb.WearPacket_Type.NOTIFICATION,
      id: notification.Notification_NotificationID.ADD_NOTIFY.value,
      notification: notification.Notification(data: data),
    ).writeToBuffer();
    if (bytes.length > 16 * 1024) {
      throw const FormatException('Notification exceeds 16 KiB');
    }
    return bytes;
  }

  static notification.NotifyData_Text? _text(Object? raw) {
    if (raw == null) return null;
    final value = raw as Map;
    return notification.NotifyData_Text(
      chars: value['chars'] as String,
      color: (value['color'] as List?)?.cast<int>(),
    );
  }

  static notification.NotifyData_Progress? _progress(Object? raw) {
    if (raw == null) return null;
    final value = raw as Map;
    return notification.NotifyData_Progress(
      sectionCount: (value['section-count'] as num).toInt(),
      progress: (value['progress'] as num).toInt(),
      color: (value['color'] as List?)?.cast<int>(),
    );
  }

  static notification.NotifyData_Info? _info(Object? raw) {
    if (raw == null) return null;
    final value = raw as Map;
    return notification.NotifyData_Info(
      title: _text(value['title']),
      subTitle: _text(value['sub-title']),
      content: _text(value['content']),
      subContent: _text(value['sub-content']),
      specialTitle: _text(value['special-title']),
      specialTitleBg: (value['special-title-bg'] as List?)?.cast<int>(),
    );
  }

  static Uint8List remove(String source, int id) =>
      _remove(_identity(source, id));

  static Uint8List _remove(notification.NotifyId identity) => pb.WearPacket(
    type: pb.WearPacket_Type.NOTIFICATION,
    id: notification.Notification_NotificationID.REMOVE_NOTIFY.value,
    notification: notification.Notification(id: identity),
  ).writeToBuffer();
}
