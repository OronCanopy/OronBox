part of 'plugin_manager.dart';

extension _PluginNetwork on PluginManager {
  Future<Object?> _jsNetwork(
    InstalledPlugin plugin,
    _PluginSession session,
    String method,
    List<Object?> args,
  ) async {
    final id = plugin.manifest.id;
    final url = args.firstOrNull?.toString() ?? '';
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !uri.hasAuthority ||
        !{'http', 'https'}.contains(uri.scheme)) {
      throw const FormatException('Only HTTP and HTTPS URLs are supported');
    }
    final download = method == 'network.download';
    final options = _jsonMap(args.elementAtOrNull(download ? 2 : 1));
    final client = _httpClients.putIfAbsent(id, PluginHttpClient.new);
    final requestId = ++session.nextRequest;
    final headers =
        (options['headers'] as Map?)?.cast<String, Object?>() ?? const {};
    final body = options['body']?.toString() ?? '';
    Uint8List requestBody;
    try {
      requestBody = base64Decode(body);
    } on FormatException {
      requestBody = Uint8List.fromList(utf8.encode(body));
    }
    try {
      final response = (await client.handle('network.open', [
        {
          'id': requestId,
          'url': url,
          'method': options['method']?.toString() ?? 'GET',
          'headers': [
            for (final entry in headers.entries)
              {'name': entry.key, 'value': entry.value.toString()},
          ],
          'body': requestBody.toList(),
          'connectTimeout': 30000,
          'firstByteTimeout': 30000,
          'betweenBytesTimeout': 30000,
        },
      ]) as Map).cast<String, Object?>();
      Stream<List<int>> chunks() async* {
        while (true) {
          final bytes = await client.handle('network.read', [requestId]);
          if (!identical(_sessions[id], session)) {
            throw StateError('Plugin session ended');
          }
          if (bytes == null) break;
          yield bytes as Uint8List;
        }
      }

      if (download) {
        final path = PluginStoragePath.parse(args[1].toString());
        final status = (response['status'] as num).toInt();
        if (status < 200 || status >= 300) throw StateError('HTTP $status');
        final written = await _withSessionFiles(id, session, () async {
          return (await _storage).writeFileStream(
            id,
            path,
            chunks(),
            append: options['append'] == true,
          );
        });
        return {
          'path': path.virtualPath,
          'bytesWritten': written,
          'status': status,
        };
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in chunks()) {
        if (bytes.length + chunk.length > 16 * 1024 * 1024) {
          throw StateError(
            'Network response exceeds 16 MiB; use network.download',
          );
        }
        bytes.add(chunk);
      }
      final responseHeaders = <String, String>{};
      for (final header in (response['headers'] as List).cast<Map>()) {
        final key = header['name'].toString();
        final value = header['value'].toString();
        responseHeaders.update(
          key,
          (previous) => '$previous,$value',
          ifAbsent: () => value,
        );
      }
      return {
        'status': response['status'],
        'headers': responseHeaders,
        'contentType': responseHeaders['content-type'] ?? '',
        'body': base64Encode(bytes.takeBytes()),
      };
    } catch (error) {
      if (download) rethrow;
      return {'error': error.toString()};
    } finally {
      await client.handle('network.close', [requestId]);
    }
  }
}
