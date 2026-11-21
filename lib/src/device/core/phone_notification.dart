import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

class PhoneNotification {
  const PhoneNotification({
    required this.key,
    required this.package,
    required this.appName,
    required this.title,
    required this.body,
    required this.timestamp,
  });

  final String key;
  final String package;
  final String appName;
  final String title;
  final String body;
  final DateTime timestamp;

  int get id => ByteData.sublistView(
    Uint8List.fromList(sha256.convert(utf8.encode('phone:$key')).bytes),
  ).getUint32(0, Endian.little);
}
