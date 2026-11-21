import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class PluginHttpServers {
  PluginHttpServers({required this.call});
  final Future<String> Function(String, List<Object?>) call;
  static const _maxBodyBytes = 16 * 1024 * 1024;
  static const _maxRequests = 4;
  static const _bodyTimeout = Duration(seconds: 30);

  final _servers = <int, HttpServer>{};
  int _activeRequests = 0;
  int _nextId = 0;
  bool _closed = false;

  Map<String, Object?> _info(int id, HttpServer server) => {
    'id': id,
    'host': server.address.address,
    'port': server.port,
    'url':
        'http://${server.address.isLoopback ? server.address.address : '0.0.0.0'}:${server.port}',
  };

  Future<Object?> handle(String method, List<Object?> args) async {
    if (_closed) throw StateError('Plugin HTTP servers closed');
    switch (method) {
      case 'http-server.start':
        if (await call('has-export', ['handle']) != 'true') {
          throw StateError('Plugin does not export HTTP handle');
        }
        final options = args.single as Map;
        final server = await HttpServer.bind(
          options['bind-all-interfaces'] == true
              ? InternetAddress.anyIPv4
              : InternetAddress.loopbackIPv4,
          (options['port'] as num).toInt(),
        );
        if (_closed) {
          await server.close(force: true);
          throw StateError('Plugin stopped');
        }
        final id = ++_nextId;
        _servers[id] = server;
        server.listen((request) {
          unawaited(_serve(id, request).catchError((Object _) {}));
        });
        return _info(id, server);
      case 'http-server.stop':
        final server = _servers.remove((args.single as num).toInt());
        if (server == null) throw StateError('Unknown HTTP server');
        await server.close(force: true);
        return null;
      case 'http-server.list-servers':
        return _servers.entries
            .map((entry) => _info(entry.key, entry.value))
            .toList();
      default:
        throw UnsupportedError(method);
    }
  }

  Future<void> _serve(int id, HttpRequest request) async {
    Future<void> reject(int status) {
      request.response
        ..persistentConnection = false
        ..statusCode = status;
      return request.response.close();
    }

    if (_activeRequests >= _maxRequests ||
        request.contentLength > _maxBodyBytes) {
      final subscription = request.listen(null)..pause();
      try {
        await reject(
          _activeRequests >= _maxRequests
              ? HttpStatus.serviceUnavailable
              : HttpStatus.requestEntityTooLarge,
        );
      } finally {
        await subscription.cancel();
      }
      return;
    }
    _activeRequests++;
    try {
      final bytes = BytesBuilder(copy: false);
      final body = StreamIterator(request);
      final elapsed = Stopwatch()..start();
      try {
        while (true) {
          final remaining = _bodyTimeout - elapsed.elapsed;
          if (remaining <= Duration.zero) throw TimeoutException('HTTP body');
          if (!await body.moveNext().timeout(remaining)) break;
          final chunk = body.current;
          if (bytes.length + chunk.length > _maxBodyBytes) {
            await reject(HttpStatus.requestEntityTooLarge);
            return;
          }
          bytes.add(chunk);
        }
      } on TimeoutException {
        await reject(HttpStatus.requestTimeout);
        return;
      } finally {
        await body.cancel();
      }
      final headers = <Map<String, String>>[];
      request.headers.forEach((name, values) {
        for (final value in values) {
          headers.add({'name': name, 'value': value});
        }
      });
      final result = jsonDecode(
        await call('handle', [
          id,
          {
            'method': request.method,
            'path': request.uri.path,
            'query': request.uri.query,
            'headers': headers,
            'body': bytes.takeBytes().toList(),
          },
        ]),
      ) as Map;
      request.response.statusCode = (result['status'] as num).toInt();
      for (final header in (result['headers'] as List).cast<Map>()) {
        request.response.headers.add(
          header['name'].toString(),
          header['value'].toString(),
        );
      }
      request.response.add((result['body'] as List).cast<int>());
    } catch (_) {
      request.response.statusCode = HttpStatus.internalServerError;
    } finally {
      try {
        await request.response.close();
      } finally {
        _activeRequests--;
      }
    }
  }

  Future<void> close() async {
    _closed = true;
    final servers = _servers.values.toList();
    _servers.clear();
    await Future.wait(servers.map((server) => server.close(force: true)));
  }
}
