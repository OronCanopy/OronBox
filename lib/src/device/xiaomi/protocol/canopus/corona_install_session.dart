import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import 'corona_package.dart';

class CoronaInstallSession {
  CoronaInstallSession({required this.send, required Stream<Uint8List> frames})
    : _frames = StreamIterator(frames) {
    _nextFrame = _frames.moveNext();
  }

  static const moduleId = 'corona';
  static const _hello = 1;
  static const _open = 2;
  static const _data = 3;
  static const _query = 4;
  static const _finish = 5;
  static const _cancel = 6;
  static const _receiving = 1;
  static const _verifying = 2;
  static const _installing = 3;
  static const _installed = 4;
  static const _timeout = Duration(seconds: 8);

  final Future<void> Function(Uint8List bytes) send;
  final StreamIterator<Uint8List> _frames;
  final _random = Random.secure();
  late Future<bool> _nextFrame;
  int _seq = 0;

  Future<void> close() => _frames.cancel();

  Future<void> install(
    Uint8List bytes, {
    void Function(double progress)? onProgress,
  }) async {
    final directory = ZipDirectory()..read(InputMemoryStream(bytes));
    final unpackedBytes = directory.fileHeaders.fold<int>(
      0,
      (total, entry) => total + entry.uncompressedSize,
    );
    final total = bytes.length;
    if (total == 0 || total > coronaPackageMaxBytes) {
      throw const FormatException('Invalid Corona archive size');
    }
    final digest = sha256.convert(bytes).bytes;
    var reported = 0.0;
    void report(_CoronaProgress progress) {
      if (progress.phase == _installed && progress.offset != total) {
        throw const FormatException('Corona confirmed an incomplete archive');
      }
      final value = progress.phase == _installed
          ? 1.0
          : min(progress.offset / total, 0.99);
      if (value > reported) {
        reported = value;
        onProgress?.call(value);
      }
    }

    onProgress?.call(0);
    for (var attempt = 0; ; attempt++) {
      var token = 0;
      try {
        final hello = await _exchange(_hello, payload: const [1, 0]);
        final caps = hello.payload;
        if (hello.token != 0 ||
            hello.arg != 0 ||
            caps.lengthInBytes != 20 ||
            caps.getUint16(0, Endian.little) != 1) {
          throw const FormatException('Invalid Corona HELLO response');
        }
        final chunk = caps.getUint16(2, Endian.little);
        if (chunk == 0 ||
            chunk > 468 ||
            total > caps.getUint32(8, Endian.little) ||
            unpackedBytes > caps.getUint32(12, Endian.little)) {
          throw const FormatException(
            'Corona resource pack exceeds device limits',
          );
        }
        final opened = await _exchange(
          _open,
          arg: total,
          payload: [
            ...digest,
            for (var i = 0; i < 8; i++) _random.nextInt(256),
          ],
        );
        token = opened.token;
        if (token == 0) {
          throw const FormatException('Missing Corona transfer token');
        }
        final defaultWindow = caps.getUint8(5);
        final defaultAckEvery = caps.getUint8(6);
        var progress = _CoronaProgress.read(
          opened,
          total,
          defaultWindow,
          defaultAckEvery,
        );
        report(progress);
        while (progress.phase == _receiving && progress.offset < total) {
          var sent = progress.offset;
          final batchSize = progress.ackEvery;
          for (var i = 0; i < batchSize && sent < total; i++) {
            final end = min(sent + chunk, total);
            await send(
              _encode(
                _data,
                0,
                token,
                sent,
                Uint8List.sublistView(bytes, sent, end),
              ),
            );
            sent = end;
          }
          final wait = Stopwatch()..start();
          do {
            final ack = await _receive(_data, 0, token, wait);
            final next = _CoronaProgress.read(
              ack,
              sent,
              progress.window,
              progress.ackEvery,
            );
            if (next.offset >= progress.offset) progress = next;
            report(progress);
          } while (progress.phase == _receiving && progress.offset < sent);
        }
        if (progress.phase == _receiving) {
          final result = await _exchange(_finish, token: token);
          progress = _CoronaProgress.read(
            result,
            total,
            progress.window,
            progress.ackEvery,
          );
          report(progress);
        }
        final applying = Stopwatch()..start();
        while (progress.phase == _verifying || progress.phase == _installing) {
          if (applying.elapsed >= const Duration(minutes: 3)) {
            throw TimeoutException('Corona installation timed out');
          }
          await Future<void>.delayed(const Duration(seconds: 1));
          progress = _CoronaProgress.read(
            await _exchange(_query, token: token),
            total,
            progress.window,
            progress.ackEvery,
          );
          report(progress);
        }
        if (progress.phase != _installed) {
          throw StateError(
            'Corona installation ended in phase ${progress.phase}',
          );
        }
        return;
      } on TimeoutException {
        if (attempt == 2) rethrow;
      } on _CoronaRejected catch (error) {
        if (error.code == 6 || error.code == 7) {
          final rejectedToken = error.token == 0 ? token : error.token;
          if (rejectedToken != 0) {
            try {
              await _exchange(_cancel, token: rejectedToken);
            } catch (_) {}
          }
          rethrow;
        }
        if (attempt == 2 || !const {2, 3, 4}.contains(error.code)) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 750));
      }
    }
  }

  Future<_CoronaResponse> _exchange(
    int op, {
    int token = 0,
    int arg = 0,
    List<int> payload = const [],
  }) async {
    final seq = _seq = _seq % 0xffff + 1;
    final wait = Stopwatch()..start();
    await send(_encode(op, seq, token, arg, payload));
    return _receive(op, seq, op == _open ? null : token, wait);
  }

  Future<_CoronaResponse> _receive(
    int op,
    int seq,
    int? token,
    Stopwatch wait,
  ) async {
    while (true) {
      final remaining = _timeout - wait.elapsed;
      if (remaining <= Duration.zero) {
        throw TimeoutException('Corona response timed out');
      }
      if (!await _nextFrame.timeout(remaining)) {
        throw StateError('Corona connection closed');
      }
      final bytes = _frames.current;
      _nextFrame = _frames.moveNext();
      if (bytes.length < 12 || bytes[0] != (op | 0x80)) continue;
      final header = ByteData.sublistView(bytes);
      final responseToken = header.getUint32(4, Endian.little);
      if (header.getUint16(2, Endian.little) != seq ||
          (token != null && responseToken != token)) {
        continue;
      }
      if (bytes[1] != 0) throw _CoronaRejected(bytes[1], responseToken);
      return _CoronaResponse(
        responseToken,
        header.getUint32(8, Endian.little),
        ByteData.sublistView(bytes, 12),
      );
    }
  }

  Uint8List _encode(int op, int seq, int token, int arg, List<int> payload) {
    final bytes = Uint8List(12 + payload.length);
    ByteData.sublistView(bytes)
      ..setUint8(0, op)
      ..setUint16(2, seq, Endian.little)
      ..setUint32(4, token, Endian.little)
      ..setUint32(8, arg, Endian.little);
    bytes.setRange(12, bytes.length, payload);
    return bytes;
  }
}

class _CoronaResponse {
  const _CoronaResponse(this.token, this.arg, this.payload);

  final int token;
  final int arg;
  final ByteData payload;
}

class _CoronaProgress {
  const _CoronaProgress(this.offset, this.window, this.ackEvery, this.phase);

  final int offset;
  final int window;
  final int ackEvery;
  final int phase;

  factory _CoronaProgress.read(
    _CoronaResponse response,
    int sent,
    int defaultWindow,
    int defaultAckEvery,
  ) {
    final payload = response.payload;
    if (payload.lengthInBytes != 8 ||
        response.arg > sent ||
        payload.getUint32(0, Endian.little) > response.arg) {
      throw const FormatException('Invalid Corona transfer progress');
    }
    final phase = payload.getUint8(6);
    final detail = payload.getUint8(7);
    if (phase == 5 || phase == 6) {
      throw _CoronaRejected(detail, response.token);
    }
    final window = payload.getUint8(4) == 0
        ? defaultWindow
        : payload.getUint8(4);
    final ackEvery = payload.getUint8(5) == 0
        ? defaultAckEvery
        : payload.getUint8(5);
    if (phase == CoronaInstallSession._receiving &&
        (window > 64 || ackEvery < 1 || ackEvery > window)) {
      throw const FormatException('Invalid Corona transfer window');
    }
    return _CoronaProgress(response.arg, window, ackEvery, phase);
  }
}

class _CoronaRejected implements Exception {
  const _CoronaRejected(this.code, this.token);

  final int code;
  final int token;

  @override
  String toString() => 'Corona rejected the resource pack (code $code)';
}
