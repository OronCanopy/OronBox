import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:oronbox/src/features/plugins/application/plugin_http_client.dart';

void main() {
  late HttpServer server;
  late PluginHttpClient client;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    client = PluginHttpClient();
  });

  tearDown(() async {
    await client.close();
    await server.close(force: true);
  });

  Future<Map> open({
    String method = 'GET',
    List<int> body = const [],
    List<Map<String, String>> headers = const [],
  }) async => await client.handle('network.open', [
    {
      'id': 1,
      'url': 'http://127.0.0.1:${server.port}/events',
      'method': method,
      'headers': headers,
      'body': body,
      'connectTimeout': 2000,
      'firstByteTimeout': 2000,
      'betweenBytesTimeout': 2000,
    },
  ]) as Map;

  test(
    'preserves content type, cookies and repeated request headers',
    () async {
      final serving = server.first.then((request) async {
        expect(request.headers.contentType?.mimeType, 'application/json');
        expect(request.headers.value('cookie'), 'session=fixture');
        expect(request.headers.value('x-plugin-value'), 'first, second');
        expect(await utf8.decoder.bind(request).join(), '{"key":"value"}');
        request.response.write('ok');
        await request.response.close();
      });
      final response = await open(
        method: 'POST',
        body: utf8.encode('{"key":"value"}'),
        headers: [
          {'name': 'Content-Type', 'value': 'application/json'},
          {'name': 'Cookie', 'value': 'session=fixture'},
          {'name': 'X-Plugin-Value', 'value': 'first'},
          {'name': 'x-plugin-value', 'value': 'second'},
        ],
      );
      expect(response['status'], 200);
      await serving;
    },
  );

  test(
    'omits the Dart user agent and forwards the plugin user agent',
    () async {
      final agents = <String?>[];
      server.listen((request) async {
        agents.add(request.headers.value(HttpHeaders.userAgentHeader));
        await request.response.close();
      });
      await open();
      await client.handle('network.close', [1]);
      await open(
        headers: [
          {'name': 'User-Agent', 'value': 'plugin-test/1.0'},
        ],
      );
      expect(agents, [null, 'plugin-test/1.0']);
    },
  );

  test('batches split file data and resumes after a slow burst', () async {
    final nextBurst = Completer<void>();
    final payload = Uint8List.fromList(
      List.generate(280 * 1024, (i) => i % 251),
    );
    final serving = server.first.then((request) async {
      final response = request.response;
      response.bufferOutput = false;
      response.headers.contentType = ContentType('audio', 'mpeg');
      for (var start = 0; start < payload.length; start += 4096) {
        if (start == 8192) {
          await response.flush();
          await nextBurst.future;
        }
        response.add(Uint8List.sublistView(payload, start, start + 4096));
      }
      await response.close();
    });
    await open();
    final output = BytesBuilder(copy: false);
    final first = await client.handle('network.read', [1]) as Uint8List;
    expect(first, isNotEmpty);
    expect(first.length, lessThanOrEqualTo(8192));
    output.add(first);
    nextBurst.complete();
    var largest = first.length;
    while (true) {
      final chunk = await client.handle('network.read', [1]) as Uint8List?;
      if (chunk == null) break;
      if (chunk.length > largest) largest = chunk.length;
      output.add(chunk);
    }
    expect(largest, inInclusiveRange(64 * 1024 + 1, 128 * 1024));
    expect(output.takeBytes(), payload);
    await serving;
  });

  test('publishes headers and SSE chunks before the response ends', () async {
    final finish = Completer<void>();
    final serving = server.first.then((request) async {
      request.response.bufferOutput = false;
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
      );
      request.response.write('data: first\n\n');
      await request.response.flush();
      await finish.future;
      request.response.write('data: second\n\n');
      await request.response.close();
    });
    final response = await open();
    expect(response['status'], 200);
    expect(
      utf8.decode(await client.handle('network.read', [1]) as Uint8List),
      'data: first\n\n',
    );
    finish.complete();
    expect(
      utf8.decode(await client.handle('network.read', [1]) as Uint8List),
      'data: second\n\n',
    );
    expect(await client.handle('network.read', [1]), isNull);
    await serving;
  });

  test('preserves binary uploads and non-success HTTP statuses', () async {
    final received = Completer<List<int>>();
    final serving = server.first.then((request) async {
      received.complete(
        await request.fold<List<int>>([], (all, chunk) => all..addAll(chunk)),
      );
      request.response.statusCode = 409;
      request.response.add([0, 128, 255]);
      await request.response.close();
    });
    expect((await open(method: 'POST', body: [0, 128, 255]))['status'], 409);
    expect(await received.future, [0, 128, 255]);
    expect(await client.handle('network.read', [1]), [0, 128, 255]);
    await serving;
  });

  test('gzip response metadata matches the decompressed body', () async {
    final serving = server.first.then((request) async {
      final encoded = gzip.encode(utf8.encode('compressed response'));
      request.response.headers.set(HttpHeaders.contentEncodingHeader, 'gzip');
      request.response.contentLength = encoded.length;
      request.response.add(encoded);
      await request.response.close();
    });
    final response = await open();
    final headers = (response['headers'] as List).cast<Map>();
    expect(
      headers.where((header) => header['name'] == 'content-encoding'),
      isEmpty,
    );
    expect(
      headers.where((header) => header['name'] == 'content-length'),
      isEmpty,
    );
    expect(
      utf8.decode(await client.handle('network.read', [1]) as Uint8List),
      'compressed response',
    );
    await serving;
  });

  test('closing a component cancels a pending body read', () async {
    final serving = server.first.then((request) async {
      request.response.bufferOutput = false;
      request.response.write('first');
      await request.response.flush();
    });
    await open();
    await client.handle('network.read', [1]);
    final reading = client.handle('network.read', [1]);
    final completed = expectLater(reading, anyOf(completes, throwsA(anything)));
    await client.close();
    await completed;
    await serving;
  });
}
