import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:oronbox/src/core/network/app_http_transport.dart';

const _messageLimit = 16 * 1024 * 1024;

/// Connections belong to one plugin session, including pending handshakes.
class PluginWebSockets {
  PluginWebSockets({required this.emit});

  final Future<void> Function(String, String) emit;
  final _connections = <int, _Connection>{};
  final _handshakes = <_UpgradeAdapter>{};
  int _sequence = 0;
  bool _closed = false;

  Future<Object?> handle(String method, List<Object?> args) async {
    if (_closed) throw StateError('WebSocket session closed');
    if (method == 'websocket.connect') {
      return _connect((args.single as Map).cast<String, Object?>());
    }
    final id = (args.first as num).toInt();
    final connection = _connections[id];
    if (connection == null) throw StateError('No such WebSocket');
    switch (method) {
      case 'websocket.send':
        final message = args[1] as Map;
        final Object data = message['case'] == 'text'
            ? message['value'] as String
            : Uint8List.fromList((message['value'] as List).cast<int>());
        final size = data is String
            ? utf8.encode(data).length
            : (data as List).length;
        if (size > _messageLimit) {
          throw StateError('WebSocket message exceeds 16 MiB');
        }
        await connection.send(data);
        return null;
      case 'websocket.receive':
        if (connection.eventName != null) {
          throw StateError('WebSocket uses push delivery');
        }
        final message = await connection.receive((args[1] as num?)?.toInt());
        if (message?['case'] == 'closed' &&
            identical(_connections[id], connection)) {
          _connections.remove(id);
          connection.dispose();
        }
        return message;
      case 'websocket.close':
        final code = (args[1] as num?)?.toInt() ?? 1000;
        final reason = args[2]?.toString() ?? '';
        if (!((code >= 1000 && code <= 1003) ||
            (code >= 1007 && code <= 1013) ||
            (code >= 3000 && code <= 4999))) {
          throw const FormatException('Invalid WebSocket close code');
        }
        if (utf8.encode(reason).length > 123) {
          throw const FormatException(
            'WebSocket close reason exceeds 123 bytes',
          );
        }
        _connections.remove(id);
        connection.dispose(code, reason);
        return null;
      default:
        throw UnsupportedError(method);
    }
  }

  Future<Map<String, Object?>> _connect(Map<String, Object?> options) async {
    if (_connections.length + _handshakes.length >= 16) {
      throw StateError('At most 16 WebSockets per plugin');
    }
    final url = (options['url'] as String).trim();
    if (utf8.encode(url).length > 8192) {
      throw const FormatException('WebSocket URL is too long');
    }
    final uri = Uri.parse(url);
    if (!{'ws', 'wss'}.contains(uri.scheme) ||
        !uri.hasAuthority ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      throw const FormatException(
        'A ws or wss URL without credentials or fragment is required',
      );
    }
    final headers = <String, Object>{};
    final requestedHeaders = (options['headers'] as List).cast<Map>();
    if (requestedHeaders.length > 64) {
      throw const FormatException('At most 64 WebSocket headers');
    }
    var headerBytes = 0;
    for (final header in requestedHeaders) {
      final name = (header['name'] as String).trim().toLowerCase();
      final value = header['value'] as String;
      headerBytes += utf8.encode(name).length + utf8.encode(value).length;
      if (headerBytes > 16384) {
        throw const FormatException('WebSocket headers exceed 16 KiB');
      }
      if ({
            'host',
            'upgrade',
            'connection',
            'content-length',
            'transfer-encoding',
          }.contains(name) ||
          name.startsWith('sec-websocket-')) {
        throw FormatException('WebSocket manages header $name');
      }
      (headers.putIfAbsent(name, () => <String>[]) as List<String>).add(value);
    }
    final protocols = (options['protocols'] as List).cast<String>();
    if (protocols.length > 16 ||
        protocols.toSet().length != protocols.length ||
        protocols.any(
          (value) =>
              value.isEmpty ||
              !RegExp(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$").hasMatch(value),
        )) {
      throw const FormatException('Invalid WebSocket subprotocol');
    }
    final event = (options['event-name'] as String?)?.trim();
    if (event != null && utf8.encode(event).length > 256) {
      throw const FormatException('WebSocket event name exceeds 256 bytes');
    }
    final timeout = Duration(
      milliseconds: ((options['timeout-ms'] as num?)?.toInt() ?? 15000).clamp(
        1000,
        120000,
      ),
    );
    final adapter = _UpgradeAdapter(protocols);
    _handshakes.add(adapter);
    final dio = createAppHttpTransport()..httpClientAdapter = adapter;
    try {
      await dio
          .get<ResponseBody>(
            uri
                .replace(scheme: uri.scheme == 'wss' ? 'https' : 'http')
                .toString(),
            options: Options(
              headers: headers,
              responseType: ResponseType.stream,
              followRedirects: false,
              validateStatus: (status) => status == 101,
            ),
          )
          .timeout(timeout);
      final socket = adapter.webSocket!;
      if (_closed) {
        unawaited(socket.close(1001));
        throw StateError('WebSocket session closed');
      }
      final ping = (options['ping-interval-ms'] as num?)?.toInt();
      if (ping != null && ping > 0) {
        socket.pingInterval = Duration(milliseconds: max(5000, ping));
      }
      final id = ++_sequence;
      final connection = _Connection(
        socket,
        event?.isEmpty == true ? null : event,
      );
      _connections[id] = connection;
      unawaited(_read(id, connection));
      return {
        'id': id,
        'protocol': socket.protocol,
        'headers': adapter.responseHeaders,
      };
    } finally {
      _handshakes.remove(adapter);
      dio.close(force: true);
    }
  }

  Future<void> _read(int id, _Connection connection) async {
    Object? failure;
    try {
      await for (final data in connection.socket) {
        if (connection.disposed) return;
        // Do not time out a peer while the guest applies backpressure to reads.
        final ping = connection.socket.pingInterval;
        connection.socket.pingInterval = null;
        final message = <String, Object?>{
          'case': data is String ? 'text' : 'binary',
          'value': data,
        };
        if (connection.eventName != null) {
          await _push(id, connection, message);
        } else {
          await connection.enqueue(
            message,
            data is String ? utf8.encode(data).length : (data as List).length,
          );
        }
        connection.socket.pingInterval = ping;
      }
    } catch (error) {
      failure = error;
    }
    if (connection.disposed) return;
    final code = failure != null ? 1006 : connection.socket.closeCode ?? 1006;
    final closed = <String, Object?>{
      'case': 'closed',
      'value': {
        'code': code,
        'reason': connection.socket.closeReason ?? '',
        'error':
            failure?.toString() ??
            (code == 1006 ? 'WebSocket connection interrupted' : null),
      },
    };
    if (connection.eventName != null) {
      try {
        await _push(id, connection, closed);
      } catch (_) {
        // A stopped or failed guest must not retain its connection.
      } finally {
        if (identical(_connections[id], connection)) _connections.remove(id);
        connection.dispose();
      }
    } else {
      await connection.enqueue(closed, 0);
    }
  }

  Future<void> _push(
    int id,
    _Connection connection,
    Map<String, Object?> message,
  ) {
    if (_closed ||
        connection.disposed ||
        !identical(_connections[id], connection)) {
      return Future.value();
    }
    final kind = message['case'];
    return emit(
      connection.eventName!,
      jsonEncode({
        'id': id,
        'type': kind,
        if (kind == 'text') 'data': message['value'],
        if (kind == 'binary')
          'data': base64Encode((message['value'] as List).cast<int>()),
        if (kind == 'closed')
          ...(message['value'] as Map).cast<String, Object?>(),
      }),
    );
  }

  Future<void> close() async {
    _closed = true;
    for (final handshake in _handshakes.toList()) {
      handshake.close(force: true);
    }
    for (final connection in _connections.values) {
      connection.dispose(1001);
    }
    _connections.clear();
  }
}

class _Connection {
  _Connection(this.socket, this.eventName);
  final WebSocket socket;
  final String? eventName;
  final messages = Queue<({Map<String, Object?> value, int bytes})>();
  Completer<void> _changed = Completer<void>();
  Future<void> _sending = Future.value();
  int _buffered = 0;
  Future<void> _receiving = Future.value();
  bool disposed = false;

  void _notify() {
    final previous = _changed;
    _changed = Completer<void>();
    previous.complete();
  }

  Future<void> enqueue(Map<String, Object?> value, int bytes) async {
    while (!disposed &&
        (_buffered + bytes > _messageLimit || messages.length >= 1024)) {
      await _changed.future;
    }
    if (disposed) return;
    messages.add((value: value, bytes: bytes));
    _buffered += bytes;
    _notify();
  }

  Future<Map<String, Object?>?> receive(int? timeout) {
    final receiving = _receiving.then((_) => _receive(timeout));
    _receiving = receiving.then<void>((_) {}, onError: (Object error) {});
    return receiving;
  }

  Future<Map<String, Object?>?> _receive(int? timeout) async {
    if (disposed) throw StateError('WebSocket closed');
    final watch = Stopwatch()..start();
    while (messages.isEmpty) {
      if (disposed) throw StateError('WebSocket closed');
      final remaining = timeout == null
          ? null
          : timeout - watch.elapsedMilliseconds;
      if (remaining != null && remaining <= 0) return null;
      if (remaining == null) {
        await _changed.future;
      } else {
        await _changed.future.timeout(
          Duration(milliseconds: remaining),
          onTimeout: () {},
        );
      }
    }
    final message = messages.removeFirst();
    _buffered -= message.bytes;
    _notify();
    return message.value;
  }

  Future<void> send(Object message) {
    final sending = _sending.then((_) async {
      if (disposed || socket.readyState != WebSocket.open) {
        throw StateError('WebSocket closed');
      }
      await socket
          .addStream(Stream.value(message))
          .timeout(const Duration(seconds: 30));
    });
    _sending = sending.catchError((Object error) {
      dispose();
    });
    return sending;
  }

  void dispose([int code = 1001, String reason = '']) {
    if (disposed) return;
    disposed = true;
    messages.clear();
    _buffered = 0;
    _notify();
    unawaited(socket.close(code, reason).catchError((_) {}));
  }
}

/// Dio runs the application's interceptors before the native HTTP upgrade.
class _UpgradeAdapter implements HttpClientAdapter {
  _UpgradeAdapter(this.protocols);
  final List<String> protocols;
  final _client = HttpClient();
  final responseHeaders = <Map<String, String>>[];
  WebSocket? webSocket;
  bool _closed = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? body,
    Future<void>? cancelFuture,
  ) async {
    final request = await _client.openUrl('GET', options.uri);
    request.followRedirects = false;
    options.headers.forEach((name, value) {
      request.headers.set(name, value);
    });
    final random = Random.secure();
    final key = base64Encode(List.generate(16, (_) => random.nextInt(256)));
    request.headers.set('Connection', 'Upgrade');
    request.headers.set('Upgrade', 'websocket');
    request.headers.set('Sec-WebSocket-Version', '13');
    request.headers.set('Sec-WebSocket-Key', key);
    if (protocols.isNotEmpty) {
      request.headers.set('Sec-WebSocket-Protocol', protocols.join(', '));
    }
    final response = await request.close();
    if (response.statusCode != 101) {
      await response.listen(null).cancel();
      throw StateError(
        'WebSocket handshake rejected with HTTP ${response.statusCode}',
      );
    }
    final accept = base64Encode(
      sha1
          .convert(utf8.encode('${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11'))
          .bytes,
    );
    final protocol = response.headers.value('sec-websocket-protocol');
    if (response.headers.value('sec-websocket-accept') != accept ||
        response.headers.value('upgrade')?.toLowerCase() != 'websocket' ||
        !(response.headers['connection'] ?? [])
            .join(',')
            .toLowerCase()
            .split(',')
            .any((value) => value.trim() == 'upgrade') ||
        (protocol != null && !protocols.contains(protocol)) ||
        response.headers.value('sec-websocket-extensions') != null) {
      await response.listen(null).cancel();
      throw StateError('Invalid WebSocket handshake response');
    }
    response.headers.forEach((name, values) {
      for (final value in values) {
        responseHeaders.add({'name': name, 'value': value});
      }
    });
    final socket = await response.detachSocket();
    if (_closed) {
      socket.destroy();
      throw StateError('WebSocket handshake cancelled');
    }
    webSocket = WebSocket.fromUpgradedSocket(
      socket,
      serverSide: false,
      protocol: protocol,
      compression: CompressionOptions.compressionOff,
      maxPayloadLength: _messageLimit,
    );
    return ResponseBody(const Stream.empty(), 101);
  }

  @override
  void close({bool force = false}) {
    _closed = true;
    _client.close(force: force);
  }
}
