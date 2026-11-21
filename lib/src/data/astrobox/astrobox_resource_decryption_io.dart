import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart';

Future<void> decryptAstroBoxResourceFile(String path, Uint8List key) =>
    compute(_decryptFile, (path, key));

void _decryptFile((String, Uint8List) request) {
  final (path, key) = request;
  final temporary = File('$path.decrypted');
  try {
    final input = File(path).openSync();
    try {
      final length = input.lengthSync();
      if (length == 0 || length % 16 != 0) {
        throw const FormatException('Invalid encrypted resource length');
      }
      final cipher = ECBBlockCipher(AESEngine())
        ..init(false, KeyParameter(key));
      final output = temporary.openSync(mode: FileMode.write);
      try {
        final buffer = Uint8List(65536);
        var remaining = length;
        while (remaining > 0) {
          final size = remaining < buffer.length ? remaining : buffer.length;
          var read = 0;
          while (read < size) {
            final count = input.readIntoSync(buffer, read, size);
            if (count == 0) {
              throw const FormatException('Truncated encrypted resource');
            }
            read += count;
          }
          for (var offset = 0; offset < size; offset += 16) {
            cipher.processBlock(buffer, offset, buffer, offset);
          }
          remaining -= size;
          final padding = remaining == 0
              ? PKCS7Padding().padCount(
                  Uint8List.sublistView(buffer, size - 16, size),
                )
              : 0;
          output.writeFromSync(buffer, 0, size - padding);
        }
        output.flushSync();
      } finally {
        output.closeSync();
      }
    } finally {
      input.closeSync();
    }
    temporary.renameSync(path);
  } finally {
    if (temporary.existsSync()) temporary.deleteSync();
  }
}
