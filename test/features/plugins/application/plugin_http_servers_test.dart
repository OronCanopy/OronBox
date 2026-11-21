import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:oronbox/src/features/plugins/application/plugin_http_servers_io.dart';

void main() {
  test(
    'HTTP server forwards request fields and preserves plugin response bytes',
    () async {
      final servers = PluginHttpServers(
        call: (name, args) async {
          if (name == 'has-export') return 'true';
          expect(name, 'handle');
          expect(args.first, 1);
          final request = args[1] as Map;
          expect(request['method'], 'POST');
          expect(request['path'], '/callback');
          expect(request['query'], 'state=abc');
          expect(request['body'], [0, 128, 255]);
          return jsonEncode({
            'status': 201,
            'headers': [
              {'name': 'x-plugin', 'value': 'yes'},
            ],
            'body': [255, 128, 0],
          });
        },
      );
      final client = HttpClient();
      addTearDown(() async {
        client.close(force: true);
        await servers.close();
      });
      final info = await servers.handle('http-server.start', [
        {'port': 0, 'bind-all-interfaces': false},
      ]) as Map;
      expect(info['host'], '127.0.0.1');
      final request = await client.postUrl(
        Uri.parse('${info['url']}/callback?state=abc'),
      );
      request.add([0, 128, 255]);
      final response = await request.close();
      expect(response.statusCode, 201);
      expect(response.headers.value('x-plugin'), 'yes');
      expect(
        await response.fold<List<int>>(
          [],
          (bytes, part) => bytes..addAll(part),
        ),
        [255, 128, 0],
      );
      expect(
        await servers.handle('http-server.list-servers', []),
        hasLength(1),
      );
      await servers.handle('http-server.stop', [info['id']]);
      expect(await servers.handle('http-server.list-servers', []), isEmpty);
    },
  );

  test('rejects an oversized upload before the body arrives', () async {
    final servers = PluginHttpServers(
      call: (name, _) async {
        expect(name, 'has-export');
        return 'true';
      },
    );
    addTearDown(servers.close);
    final info = await servers.handle('http-server.start', [
      {'port': 0, 'bind-all-interfaces': false},
    ]) as Map;
    final socket = await Socket.connect('127.0.0.1', info['port'] as int);
    addTearDown(socket.destroy);
    socket.write(
      'POST / HTTP/1.1\r\nHost: 127.0.0.1\r\n'
      'Content-Length: 16777217\r\n\r\n',
    );
    await socket.flush();
    final status = await socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first
        .timeout(const Duration(seconds: 3));
    expect(status, startsWith('HTTP/1.1 413 '));
  });

  test(
    'server shutdown during asynchronous startup releases the socket',
    () async {
      final servers = PluginHttpServers(
        call: (_, args) async {
          await Future<void>.delayed(Duration.zero);
          return 'true';
        },
      );
      final starting = servers.handle('http-server.start', [
        {'port': 0, 'bind-all-interfaces': false},
      ]);
      final failed = expectLater(starting, throwsStateError);
      await servers.close();
      await failed;
    },
  );
}
