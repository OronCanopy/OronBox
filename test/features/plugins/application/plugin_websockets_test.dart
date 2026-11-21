import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:oronbox/src/features/plugins/application/plugin_websockets_io.dart';

void main() {
  late HttpServer server;
  late PluginWebSockets sockets;
  late StreamController<WebSocket> peers;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    peers = StreamController<WebSocket>.broadcast();
    server.listen((request) async {
      request.response.headers.set('x-handshake', 'ok');
      peers.add(
        await WebSocketTransformer.upgrade(
          request,
          protocolSelector: (protocols) =>
              protocols.contains('test') ? 'test' : null,
        ),
      );
    });
    sockets = PluginWebSockets(emit: (_, _) async {});
  });
  tearDown(() async {
    await sockets.close();
    await server.close(force: true);
    await peers.close();
  });

  Future<Map> connect({String? event}) async =>
      await sockets.handle('websocket.connect', [
        {
          'url': 'ws://127.0.0.1:${server.port}/',
          'headers': <Object>[],
          'protocols': ['test'],
          'event-name': event,
          'ping-interval-ms': 0,
        },
      ]) as Map;

  test(
    'upgrade preserves headers, text and binary, then delivers closure once',
    () async {
      final peerFuture = peers.stream.first;
      final info = await connect();
      final peer = await peerFuture;
      expect(info['protocol'], 'test');
      expect(
        (info['headers'] as List)
            .where((h) => h['name'] == 'x-handshake')
            .single['value'],
        'ok',
      );
      final incoming = StreamIterator<Object?>(peer);
      addTearDown(incoming.cancel);
      await sockets.handle('websocket.send', [
        info['id'],
        {'case': 'text', 'value': '你好'},
      ]);
      expect(await incoming.moveNext(), isTrue);
      expect(incoming.current, '你好');
      peer.add([0, 128, 255]);
      expect(await sockets.handle('websocket.receive', [info['id'], 1000]), {
        'case': 'binary',
        'value': [0, 128, 255],
      });
      unawaited(peer.close(4000, 'done'));
      final closed =
          await sockets.handle('websocket.receive', [info['id'], 1000]) as Map;
      expect(closed['case'], 'closed');
      expect((closed['value'] as Map)['code'], 4000);
      await expectLater(
        sockets.handle('websocket.receive', [info['id'], 0]),
        throwsStateError,
      );
    },
  );

  test('concurrent receives take successive messages and close wakes a pending receive', () async {
    final peerFuture = peers.stream.first;
    final info = await connect();
    final peer = await peerFuture;
    peer.listen((_) {});
    final first = sockets.handle('websocket.receive', [info['id'], 1000]);
    final second = sockets.handle('websocket.receive', [info['id'], 1000]);
    peer.add('first');
    peer.add('second');
    expect(await first, {'case': 'text', 'value': 'first'});
    expect(await second, {'case': 'text', 'value': 'second'});
    final pending = expectLater(
      sockets.handle('websocket.receive', [info['id'], null]),
      throwsStateError,
    );
    await sockets.handle('websocket.close', [info['id'], 4001, 'stop']);
    await pending.timeout(const Duration(seconds: 1));
  });

  test('push delivery is ordered and waits for the guest callback', () async {
    final received = <Map>[];
    final gate = Completer<void>();
    final reached = Completer<void>();
    sockets = PluginWebSockets(
      emit: (event, payload) async {
        expect(event, 'messages');
        received.add(jsonDecode(payload) as Map);
        if (received.length == 1) {
          reached.complete();
          await gate.future;
        }
      },
    );
    final peerFuture = peers.stream.first;
    final info = await connect(event: 'messages');
    final peer = await peerFuture;
    peer.listen((_) {});
    peer.add('first');
    peer.add([9, 8, 7]);
    await reached.future;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(received, hasLength(1));
    gate.complete();
    while (received.length < 2) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(received[1], {'id': info['id'], 'type': 'binary', 'data': 'CQgH'});
    await expectLater(
      sockets.handle('websocket.receive', [info['id'], 0]),
      throwsStateError,
    );
  });

  test('session close aborts a pending handshake', () async {
    final stalled = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requested = Completer<void>();
    stalled.listen((_) => requested.complete());
    addTearDown(() => stalled.close(force: true));
    final starting = sockets.handle('websocket.connect', [
      {
        'url': 'ws://127.0.0.1:${stalled.port}/',
        'headers': [],
        'protocols': [],
      },
    ]);
    final failed = expectLater(starting, throwsA(anything));
    await requested.future;
    await sockets.close();
    await failed.timeout(const Duration(seconds: 1));
  });
}
