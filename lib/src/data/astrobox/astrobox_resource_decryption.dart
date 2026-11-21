import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

Uint8List decodeAstroBoxResourceKey(String value) {
  final key = value.trim();
  if (RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(key)) {
    return Uint8List.fromList([
      for (var offset = 0; offset < key.length; offset += 2)
        int.parse(key.substring(offset, offset + 2), radix: 16),
    ]);
  }
  try {
    final decoded = base64Decode(key);
    if (decoded.length == 32) return decoded;
  } on FormatException {
    // The upstream format also accepts a 32-byte UTF-8 key.
  }
  final decoded = utf8.encode(key);
  if (decoded.length == 32) return decoded;
  throw const FormatException('Invalid resource key');
}

Future<Uint8List> decryptAstroBoxResourceBytes(
  Uint8List ciphertext,
  Uint8List key,
) async {
  if (ciphertext.isEmpty || ciphertext.length % 16 != 0) {
    throw const FormatException('Invalid encrypted resource length');
  }
  final cipher = ECBBlockCipher(AESEngine())..init(false, KeyParameter(key));
  final plaintext = Uint8List(ciphertext.length);
  for (var offset = 0; offset < ciphertext.length; offset += 16) {
    cipher.processBlock(ciphertext, offset, plaintext, offset);
    if ((offset + 16) % 65536 == 0) {
      // Keep large Web downloads responsive between chunks.
      await Future<void>.delayed(Duration.zero);
    }
  }
  final padding = PKCS7Padding().padCount(
    Uint8List.sublistView(plaintext, plaintext.length - 16),
  );
  return Uint8List.sublistView(plaintext, 0, plaintext.length - padding);
}
