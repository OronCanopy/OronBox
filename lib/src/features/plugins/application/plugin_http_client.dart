import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:oronbox/src/core/network/app_http_transport.dart';

/// Owns WASI HTTP streams for one component instance.
final class PluginHttpClient {
  final _dio = createAppHttpTransport();
  final _requests = <int, _HttpRequest>{};
  bool _closed = false;

  Future<Object?> handle(String method, List<Object?> args) async {
    if (method == 'network.close') {
      await _requests.remove((args.single as num).toInt())?.close();
      return null;
    }
    if (_closed) throw StateError('Plugin HTTP client closed');
    if (method == 'network.read') {
      final request = _requests[(args.single as num).toInt()];
      if (request == null) throw StateError('HTTP request closed');
      return request.read();
    }
    if (method != 'network.open') throw UnsupportedError(method);
    final options = args.single as Map;
    final id = (options['id'] as num).toInt();
    if (_requests.containsKey(id)) throw StateError('Duplicate HTTP request');
    final request = _HttpRequest();
    _requests[id] = request;
    try {
      final headerValues = <String, List<String>>{};
      for (final header in (options['headers'] as List).cast<Map>()) {
        final name = (header['name'] as String).toLowerCase();
        (headerValues[name] ??= []).add(header['value'] as String);
      }
      final headers = <String, Object>{
        // Dart's IO adapter replaces its default header even with an empty list.
        if (!kIsWeb && !headerValues.containsKey('user-agent'))
          'user-agent': const <String>[],
        for (final entry in headerValues.entries)
          entry.key: entry.key == Headers.contentTypeHeader
              ? entry.value.single
              : entry.value,
      };
      final bytes = Uint8List.fromList((options['body'] as List).cast<int>());
      final requestOptions =
          Options(
            method: options['method'] as String,
            headers: headers,
            responseType: ResponseType.stream,
            validateStatus: (_) => true,
            receiveTimeout: Duration(
              milliseconds: (options['betweenBytesTimeout'] as num).toInt(),
            ),
          ).compose(
            _dio.options,
            options['url'] as String,
            data: bytes.isEmpty ? null : bytes,
            cancelToken: request.cancel,
          );
      requestOptions.connectTimeout = Duration(
        milliseconds: (options['connectTimeout'] as num).toInt(),
      );
      final response = await _dio
          .fetch<ResponseBody>(requestOptions)
          .timeout(
            Duration(
              milliseconds: (options['firstByteTimeout'] as num).toInt(),
            ),
          );
      final body = response.data!;
      if (_closed || request.closed) {
        await body.stream.listen(null).cancel();
        throw StateError('HTTP request cancelled');
      }
      request.iterator = StreamIterator(body.stream);
      final mimeType = _headerToken(
        response.headers,
        Headers.contentTypeHeader,
      );
      final disposition = _headerToken(response.headers, 'content-disposition');
      request.batchBody =
          mimeType != 'text/event-stream' &&
          (disposition == 'attachment' ||
              mimeType == 'application/octet-stream' ||
              mimeType == 'application/zip' ||
              mimeType.startsWith('audio/') ||
              mimeType.startsWith('video/') ||
              mimeType.startsWith('image/'));
      // Dart's HTTP adapter transparently decompresses gzip response bodies.
      final decompressed =
          response.headers.value('content-encoding')?.toLowerCase() == 'gzip';
      return {
        'status': response.statusCode,
        'headers': [
          for (final entry in response.headers.map.entries)
            if (!decompressed ||
                (entry.key.toLowerCase() != 'content-encoding' &&
                    entry.key.toLowerCase() != 'content-length'))
              for (final value in entry.value)
                {'name': entry.key, 'value': value},
        ],
      };
    } catch (_) {
      _requests.remove(id);
      await request.close();
      rethrow;
    }
  }

  Future<void> close() async {
    _closed = true;
    final requests = _requests.values.toList();
    _requests.clear();
    _dio.close(force: true);
    await Future.wait(requests.map((request) => request.close()));
  }
}

String _headerToken(Headers headers, String name) =>
    (headers[name]?.firstOrNull ?? '').split(';').first.trim().toLowerCase();

final class _HttpRequest {
  final cancel = CancelToken();
  StreamIterator<Uint8List>? iterator;
  Uint8List? _remaining;
  Future<bool>? _pendingChunk;
  bool batchBody = false;
  bool _reading = false;
  bool closed = false;

  Future<Uint8List?> read() async {
    if (closed) throw StateError('HTTP request cancelled');
    if (_reading) throw StateError('HTTP body read already pending');
    final stream = iterator;
    if (stream == null) throw StateError('HTTP response unavailable');
    _reading = true;
    try {
      final first = await _nextChunk(stream);
      if (first == null) return null;
      final chunkSize = (batchBody ? 128 : 64) * 1024;
      if (!batchBody || first.length >= chunkSize) {
        return _take(first, chunkSize);
      }

      const batchWindow = Duration(milliseconds: 8);
      final elapsed = Stopwatch()..start();
      final batch = BytesBuilder(copy: false)..add(first);
      while (batch.length < chunkSize) {
        final remainingTime = batchWindow - elapsed.elapsed;
        if (remainingTime <= Duration.zero) break;
        Uint8List? next;
        try {
          next = await _nextChunk(stream, timeout: remainingTime);
        } catch (_) {
          if (closed) rethrow;
          // Deliver buffered bytes before surfacing the pending stream error.
          break;
        }
        if (next == null) break;
        batch.add(_take(next, chunkSize - batch.length));
      }
      return batch.takeBytes();
    } finally {
      _reading = false;
    }
  }

  Future<Uint8List?> _nextChunk(
    StreamIterator<Uint8List> stream, {
    Duration? timeout,
  }) async {
    final remaining = _remaining;
    if (remaining != null) {
      _remaining = null;
      return remaining;
    }
    final elapsed = timeout == null ? null : (Stopwatch()..start());
    while (true) {
      final pending = _pendingChunk ??= stream.moveNext();
      var timedOut = false;
      final hasChunk = timeout == null
          ? await pending
          : await pending.timeout(
              timeout - elapsed!.elapsed,
              onTimeout: () {
                timedOut = true;
                return false;
              },
            );
      if (timedOut) return null;
      _pendingChunk = null;
      if (!hasChunk) return null;
      if (closed) throw StateError('HTTP request cancelled');
      if (stream.current.isNotEmpty) return stream.current;
    }
  }

  Uint8List _take(Uint8List bytes, int size) {
    if (bytes.length <= size) return bytes;
    _remaining = Uint8List.sublistView(bytes, size);
    return Uint8List.sublistView(bytes, 0, size);
  }

  Future<void> close() async {
    if (closed) return;
    closed = true;
    cancel.cancel('Plugin HTTP request closed');
    _remaining = null;
    await iterator?.cancel();
    _pendingChunk = null;
  }
}
