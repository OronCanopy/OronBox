import 'dart:async';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oronbox/src/device/xiaomi/protocol/canopus/corona_install_session.dart';

void main() {
  test('resumes the original ZIP and waits for Corona to install it', () async {
    final archive = Archive()
      ..addFile(ArchiveFile.string('corona.json', '{"themeId":"demo"}'));
    final bytes = Uint8List.fromList(ZipEncoder().encode(archive));
    final frames = StreamController<Uint8List>();
    final reported = <double>[];
    final sent = <int>[...bytes.take(8)];
    var chunksSinceAck = 0;
    var queried = false;
    const token = 42;
    final session = CoronaInstallSession(
      frames: frames.stream,
      send: (request) async {
        final header = ByteData.sublistView(request);
        final op = header.getUint8(0);
        final seq = header.getUint16(2, Endian.little);
        final requestToken = header.getUint32(4, Endian.little);
        final arg = header.getUint32(8, Endian.little);
        switch (op) {
          case 1:
            expect(request.sublist(12), [1, 0]);
            final caps = ByteData(20)
              ..setUint16(0, 1, Endian.little)
              ..setUint16(2, 16, Endian.little)
              ..setUint8(4, 1)
              ..setUint8(5, 4)
              ..setUint8(6, 2)
              ..setUint32(8, 1024, Endian.little)
              ..setUint32(12, 1024, Endian.little);
            frames.add(_response(op, seq, 0, 0, caps.buffer.asUint8List()));
          case 2:
            expect(arg, bytes.length);
            expect(request.sublist(12, 44), sha256.convert(bytes).bytes);
            expect(request.length, 52);
            frames.add(_progress(op, seq, token, sent.length, 1));
          case 3:
            expect(seq, 0);
            expect(requestToken, token);
            expect(arg, sent.length);
            sent.addAll(request.skip(12));
            if (++chunksSinceAck == 2 || sent.length == bytes.length) {
              frames.add(_progress(op, seq, token, sent.length, 1));
              chunksSinceAck = 0;
            }
          case 5:
            expect(requestToken, token);
            expect(sent, bytes);
            expect(reported.last, lessThan(1));
            frames.add(_progress(op, seq, token, sent.length, 2));
          case 4:
            expect(requestToken, token);
            queried = true;
            frames.add(_progress(op, seq, token, sent.length, 4));
          default:
            fail('Unexpected Corona operation $op');
        }
      },
    );
    try {
      await session.install(bytes, onProgress: reported.add);
      expect(queried, isTrue);
      expect(reported.last, 1);
    } finally {
      await session.close();
      await frames.close();
    }
  });
}

Uint8List _progress(int op, int seq, int token, int offset, int phase) {
  final payload = ByteData(8)
    ..setUint32(0, offset, Endian.little)
    ..setUint8(6, phase);
  return _response(op, seq, token, offset, payload.buffer.asUint8List());
}

Uint8List _response(int op, int seq, int token, int arg, List<int> payload) {
  final bytes = Uint8List(12 + payload.length);
  ByteData.sublistView(bytes)
    ..setUint8(0, op | 0x80)
    ..setUint16(2, seq, Endian.little)
    ..setUint32(4, token, Endian.little)
    ..setUint32(8, arg, Endian.little);
  bytes.setRange(12, bytes.length, payload);
  return bytes;
}
