import 'package:archive/archive.dart' show getCrc32;
import 'package:oronbox/src/core/errors/coded_error.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:oronbox/src/device/core/system.dart';

class MiWearEngineeringSystem extends System {
  MiWearEngineeringSystem({
    required this.ble,
    required this.writeLength,
    this.onLog,
  });

  final bool ble;
  final int writeLength;
  final void Function(String)? onLog;
  final _buffer = <int>[];
  Completer<String>? _reply;
  String? _expected;
  bool _cancelled = false;
  bool _disposed = false;
  bool _busy = false;

  @override
  void onData(Uint8List data) {
    if (_disposed || _reply == null) return;
    _buffer.addAll(data);
    if (_buffer.length > 4096) {
      _fail('engineering_response');
      return;
    }
    if (_expected == 'upload') {
      final text = ascii
          .decode(_buffer, allowInvalid: true)
          .replaceAll('\x00', '');
      final match = RegExp(r'(?:^|[^0-9])(3[0-4][01])(?=$|[^0-9])')
          .firstMatch(text);
      if (match != null) _complete(match.group(1)!);
      return;
    }
    while (_reply != null) {
      final end = _buffer.indexOf(10);
      if (end < 0) return;
      final line = ascii
          .decode(_buffer.sublist(0, end), allowInvalid: true)
          .replaceAll('\x00', '')
          .trimRight();
      _buffer.removeRange(0, end + 1);
      if (_expected != null && line.startsWith(_expected!)) {
        _complete(line);
      } else if (line.contains('ERROR') || line.contains('unknown cmd')) {
        _fail('engineering_response');
      }
    }
  }

  void _complete(String text) {
    if (text != '310' && text != '311') onLog?.call(text);
    final reply = _reply;
    _reply = null;
    _buffer.clear();
    reply?.complete(text);
  }

  void _fail(String code) {
    final reply = _reply;
    _reply = null;
    _buffer.clear();
    reply?.completeError(MiWearEngineeringException(code, code));
  }

  void cancel() {
    _cancelled = true;
    _fail('cancelled');
  }

  void _check() {
    if (_disposed || _cancelled || entity.isDisposed) {
      throw const MiWearEngineeringException('cancelled', 'cancelled');
    }
  }

  Future<T> _exclusive<T>(Future<T> Function() action) async {
    if (_busy) {
      throw const MiWearEngineeringException(
        'engineering_busy',
        'engineering_busy',
      );
    }
    _check();
    _busy = true;
    try {
      return await action();
    } finally {
      _busy = false;
    }
  }

  Future<String> _exchange(Uint8List data, String expected) async {
    _check();
    _buffer.clear();
    _expected = expected;
    final reply = _reply = Completer<String>();
    // Attach timeout handling before the write, which can disconnect inline.
    final response = reply.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        throw const MiWearEngineeringException(
          'engineering_timeout',
          'engineering_timeout',
        );
      },
    );
    unawaited(response.then<void>((_) {}, onError: (Object _) {}));
    try {
      if (expected != 'upload' && data.length > writeLength && ble) {
        throw const MiWearEngineeringException(
          'engineering_mtu',
          'engineering_mtu',
        );
      }
      for (var offset = 0; offset < data.length; offset += writeLength) {
        _check();
        final end = (offset + writeLength).clamp(0, data.length);
        await entity.transport
            .send(Uint8List.sublistView(data, offset, end))
            .timeout(
              const Duration(seconds: 10),
              onTimeout: () {
                throw const MiWearEngineeringException(
                  'engineering_timeout',
                  'engineering_timeout',
                );
              },
            );
      }
      return await response;
    } finally {
      if (identical(_reply, reply)) _reply = null;
      if (!reply.isCompleted) reply.complete('');
      _buffer.clear();
    }
  }

  Future<String> at(String command, String expected) => _exclusive(() {
    onLog?.call(command);
    return _exchange(Uint8List.fromList(ascii.encode('00$command')), expected);
  });

  Future<void> uploadFirmware(
    Uint8List bytes,
    void Function(double) progress,
  ) => _exclusive(() async {
    Future<void> control(String message, String expected) async {
      onLog?.call(message);
      final reply = await _exchange(
        Uint8List.fromList(ascii.encode(message)),
        'upload',
      );
      if (reply != expected) {
        throw const MiWearEngineeringException(
          'engineering_response',
          'engineering_response',
        );
      }
    }

    // Metadata must reach the firmware's read-based parser in one write.
    final metadata = '33OTA,/data/ota/b283_ota.bin,${bytes.length}';
    if (ble && ascii.encode(metadata).length > writeLength) {
      throw const MiWearEngineeringException(
        'engineering_mtu',
        'engineering_mtu',
      );
    }
    await control('300', '300');
    await control(metadata, '330');
    final blockSize = ble ? 4480 : 9900;
    for (var offset = 0; offset < bytes.length; offset += blockSize) {
      final end = (offset + blockSize).clamp(0, bytes.length);
      final data = Uint8List.sublistView(bytes, offset, end);
      final block = Uint8List(data.length + 4)..setAll(0, data);
      ByteData.sublistView(block)
          .setUint32(data.length, getCrc32(data), Endian.little);
      for (var retry = 0; ; retry++) {
        final reply = await _exchange(block, 'upload');
        if (reply == '310') break;
        if (reply != '311' || retry >= 29) {
          throw const MiWearEngineeringException(
            'engineering_response',
            'engineering_response',
          );
        }
      }
      progress(end / bytes.length);
    }
    await control('32', '320');
  });

  @override
  Future<void> dispose() async {
    _disposed = true;
    cancel();
  }
}

class MiWearEngineeringException implements CodedError {
  const MiWearEngineeringException(this.code, this.message);
  @override
  final String code;
  @override
  final String message;
  @override
  Object? get details => null;
  @override
  String toString() => message;
}
