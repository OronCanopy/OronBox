import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oronbox/src/commands/command_protocol.dart';
import 'package:oronbox/src/core/storage/managed_temporary_files.dart';
import 'package:oronbox/src/local_server/local_server.dart';
import 'package:oronbox/src/local_server/local_server_auth.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test('Local API Server full HTTP lifecycle: info, pairing, challenge, SSE and install', () async {
    final serverIdentity = LocalServerEd25519KeyPair.generate();
    final clientIdentity = LocalServerEd25519KeyPair.generate();
    final host = _RecordingHost();

    final stagingDir = await Directory.systemTemp.createTemp(
      'oronbox-staging-',
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    messenger.setMockMethodCallHandler(
      pathProvider,
      (_) async => stagingDir.path,
    );
    final server = LocalServer(
      serverId: 'server-1',
      displayName: 'Test OronBox',
      platform: 'macos',
      identity: serverIdentity,
      host: InternetAddress.loopbackIPv4,
      port: 0,
      commandBus: host,
    );

    await server.start();
    final http = HttpClient();
    addTearDown(() async {
      http.close(force: true);
      await server.stop();
      for (final command in host.commands.where(
        (c) => c.method == 'task.enqueue',
      )) {
        final params = (command.params['command'] as Map)['params'] as Map;
        await ManagedTemporaryFiles.release(params['path'] as String);
      }
      await host.close();
      messenger.setMockMethodCallHandler(pathProvider, null);
      if (await stagingDir.exists()) await stagingDir.delete(recursive: true);
    });

    final port = server.boundPort;

    // 1. GET /v1/info
    final infoRes = await _jsonRequest(http, port, 'GET', '/v1/info');
    expect(infoRes.statusCode, 200);
    expect(infoRes.body['serverId'], 'server-1');
    expect(infoRes.body['protocolVersion'], 1);
    expect(infoRes.body['auth'], 'ed25519-challenge');
    expect(infoRes.body['publicKey'], serverIdentity.publicKeyBase64Url);

    // 2. POST /v1/auth/pairing-requests
    final pairRes = await _jsonRequest(
      http,
      port,
      'POST',
      '/v1/auth/pairing-requests',
      body: {
        'clientName': 'AstroBoxCli',
        'publicKey': clientIdentity.publicKeyBase64Url,
        'requestedScopes': [
          'device.read',
          'events.subscribe',
          'install.upload',
          'task.read',
          'device.control',
          'interconnect.send',
        ],
      },
    );
    expect(pairRes.statusCode, 202);
    final pairingId = pairRes.body['pairingId'].toString();
    expect(pairRes.body['state'], 'pending');

    // 3. GET /v1/auth/pairing-requests/:pairingId
    final statusRes = await _jsonRequest(
      http,
      port,
      'GET',
      '/v1/auth/pairing-requests/$pairingId',
    );
    expect(statusRes.statusCode, 200);
    expect(statusRes.body['state'], 'pending');

    // 4. Server approves pairing
    server.approvePairing(pairingId);

    final approvedStatusRes = await _jsonRequest(
      http,
      port,
      'GET',
      '/v1/auth/pairing-requests/$pairingId',
    );
    expect(approvedStatusRes.body['state'], 'granted');

    // 5. POST /v1/auth/challenges
    final challengeRes = await _jsonRequest(
      http,
      port,
      'POST',
      '/v1/auth/challenges',
      body: {'fingerprint': clientIdentity.fingerprint},
    );
    expect(challengeRes.statusCode, 200);
    final challengeId = challengeRes.body['challengeId'].toString();
    final signingPayload = challengeRes.body['signingPayload'].toString();

    // 6. Sign challenge with Ed25519
    final payloadBytes = decodeBase64Url(signingPayload);
    final sigBytes = clientIdentity.sign(payloadBytes);
    final signatureBase64Url = base64Url.encode(sigBytes).replaceAll('=', '');

    // 7. POST /v1/auth/sessions
    final sessionRes = await _jsonRequest(
      http,
      port,
      'POST',
      '/v1/auth/sessions',
      body: {'challengeId': challengeId, 'signature': signatureBase64Url},
    );
    expect(sessionRes.statusCode, 200);
    final token = sessionRes.body['token'].toString();
    expect(token, isNotEmpty);
    expect(sessionRes.body['tokenType'], 'Bearer');

    // 8. GET /v1/events (SSE)
    final eventClient = HttpClient();
    addTearDown(() => eventClient.close(force: true));
    final sseRequest = await eventClient.getUrl(
      Uri.parse('http://127.0.0.1:$port/v1/events'),
    );
    sseRequest.headers.set('authorization', 'Bearer $token');
    final sseResponse = await sseRequest.close();
    expect(sseResponse.statusCode, 200);
    expect(
      sseResponse.headers.contentType.toString(),
      contains('text/event-stream'),
    );

    final sseEvents = <String>[];
    final readyCompleter = Completer<void>();
    final sseCompleter = Completer<void>();
    final sseSub = sseResponse.transform(utf8.decoder).listen((chunk) {
      sseEvents.add(chunk);
      if (chunk.contains('event: ready') && !readyCompleter.isCompleted) {
        readyCompleter.complete();
      }
      if (!sseCompleter.isCompleted &&
          sseEvents.join().contains('event: device.connected') &&
          sseEvents.join().contains('"moduleId":"demo"')) {
        sseCompleter.complete();
      }
    });

    await readyCompleter.future.timeout(const Duration(seconds: 2));
    expect(sseEvents.any((chunk) => chunk.contains('event: ready')), isTrue);

    // Emit event on command bus and check SSE receipt
    host.emit(
      const CommandEvent('device.connected', data: {'deviceId': 'mac-1'}),
    );
    host.emit(
      const CommandEvent(
        canopusConnectMessageEvent,
        data: {
          'deviceId': 'mac-1',
          'moduleId': 'demo',
          'payload': [0, 255],
          'isText': false,
        },
      ),
    );
    await sseCompleter.future.timeout(const Duration(seconds: 2));
    expect(sseEvents.join(), contains('event: $canopusConnectMessageEvent'));
    final eventClosed = sseSub.cancel();
    eventClient.close(force: true);
    unawaited(eventClosed);

    // 9. POST /v1/install
    final fileBytes = utf8.encode('test-rpk-binary-payload');
    final sha256Hex = sha256.convert(fileBytes).toString();

    final installReq = await http.postUrl(
      Uri.parse('http://127.0.0.1:$port/v1/install'),
    );
    installReq.headers.set('authorization', 'Bearer $token');
    installReq.headers.set('x-oronbox-file-name', 'resources.bin');
    installReq.headers.set('x-oronbox-type', 'res_pack');
    installReq.headers.set('x-oronbox-sha256', sha256Hex);
    installReq.headers.set('x-oronbox-size', fileBytes.length.toString());
    installReq.add(fileBytes);
    final installRes = await installReq.close();
    expect(installRes.statusCode, 202);

    final installBody =
        jsonDecode(await installRes.transform(utf8.decoder).join()) as Map;
    expect(installBody['taskId'], 'task-42');
    expect(installBody['fileName'], 'resources.bin');
    expect(installBody['sha256'], sha256Hex);

    final queuedParams =
        (host.commands.last.params['command'] as Map)['params'] as Map;
    expect(queuedParams['type'], 'res_pack');
    expect(queuedParams['deleteAfter'], true);
    final automatic = await http.postUrl(
      Uri.parse('http://127.0.0.1:$port/v1/install'),
    );
    automatic.headers.set('authorization', 'Bearer $token');
    automatic.headers.set(
      'x-oronbox-file-name',
      Uri.encodeComponent('测试资源.bin'),
    );
    automatic.add(fileBytes);
    final automaticResponse = await automatic.close();
    expect(automaticResponse.statusCode, 202);
    final automaticBody = jsonDecode(
      await automaticResponse.transform(utf8.decoder).join(),
    ) as Map;
    expect(automaticBody['fileName'], '测试资源.bin');
    expect(automaticBody['deviceId'], 'AA:BB:CC:DD:EE:FF');
    final automaticParams =
        (host.commands.last.params['command'] as Map)['params'] as Map;
    expect(automaticParams['type'], 'auto');
    expect(automaticParams['device'], automaticBody['deviceId']);

    for (final invalidHeader in [
      {'x-oronbox-size': '-1'},
      {'x-oronbox-size': '0'},
      {'x-oronbox-sha256': '0' * 64},
      {'x-oronbox-type': 'unknown'},
    ]) {
      final invalidUpload = await http.postUrl(
        Uri.parse('http://127.0.0.1:$port/v1/install'),
      );
      invalidUpload.headers.set('authorization', 'Bearer $token');
      invalidHeader.forEach(invalidUpload.headers.set);
      invalidUpload.add(fileBytes);
      final rejected = await invalidUpload.close();
      expect(rejected.statusCode, 400);
      await rejected.drain<void>();
    }

    final sent = await _jsonRequest(
      http,
      port,
      'POST',
      '/v1/interconnect/send',
      token: token,
      body: {
        'packageName': 'com.example.app',
        'payload': [0, 255],
        'deviceId': 'AA:BB:CC:DD:EE:FF',
      },
    );
    expect(sent.statusCode, 200);
    expect(host.commands.last.method, 'device.interconnect.send');
    expect(host.commands.last.params['device'], 'AA:BB:CC:DD:EE:FF');
    expect(host.commands.last.params['payload'], [0, 255]);
    final beforeInvalid = host.commands.length;
    for (final payload in [
      [256],
      [-1],
      [1.5],
      ['1'],
    ]) {
      final invalid = await _jsonRequest(
        http,
        port,
        'POST',
        '/v1/interconnect/send',
        token: token,
        body: {'packageName': 'com.example.app', 'payload': payload},
      );
      expect(invalid.statusCode, 400);
    }
    expect(host.commands.length, beforeInvalid);

    String authorize(Set<String> scopes, {List<String> devices = const []}) {
      final key = LocalServerEd25519KeyPair.generate();
      final pairing = server.authenticator.createPairingRequest(
        clientName: 'Restricted',
        publicKey: key.publicKeyBase64Url,
        requestedScopes: scopes,
        deviceAllowlist: devices,
      );
      server.approvePairing(pairing.pairingId);
      final challenge = server.authenticator.issueChallenge(
        fingerprint: key.fingerprint,
      );
      return server.authenticator
          .createSession(
            challengeId: challenge.challengeId,
            signatureBase64Url: base64Url.encode(
              key.sign(decodeBase64Url(challenge.signingPayload)),
            ),
          )
          .token;
    }

    final moduleToken = authorize({
      'module.read',
      'module.control',
      'canopusconnect.send',
    });
    for (final (method, path, payload, command) in [
      ('GET', '/v1/modules', null, 'device.module.list'),
      (
        'PUT',
        '/v1/modules/demo/enabled',
        {'enabled': false},
        'device.module.enable',
      ),
      ('DELETE', '/v1/modules/demo', null, 'device.module.remove'),
      (
        'POST',
        '/v1/canopus-connect/send',
        {
          'moduleId': 'demo',
          'payload': [0, 255],
        },
        'device.canopus.send',
      ),
    ]) {
      final response = await _jsonRequest(
        http,
        port,
        method,
        path,
        token: moduleToken,
        body: payload,
      );
      expect(response.statusCode, 200);
      expect(host.commands.last.method, command);
    }

    final canopusToken = authorize({'events.subscribe'});
    final canopusAddress = Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: port,
      path: '/v1/events',
      queryParameters: {
        'event': [canopusConnectMessageEvent, 'device.connected'],
        'filter.deviceId': 'AA:BB:CC:DD:EE:FF',
        'filter.moduleId': ['demo', 'diag'],
      },
    );
    final canopusClient = HttpClient();
    addTearDown(() => canopusClient.close(force: true));
    final canopusRequest = await canopusClient.getUrl(canopusAddress);
    canopusRequest.headers.set('authorization', 'Bearer $canopusToken');
    final response = await canopusRequest.close().timeout(
      const Duration(seconds: 3),
    );
    expect(response.statusCode, 200);
    final commandsBeforeEvents = host.commands.length;
    final frames = <String>[];
    final received = Completer<void>();
    final canopusSub = response.transform(utf8.decoder).listen((chunk) {
      frames.add(chunk);
      if (frames.join().contains('"moduleId":"diag"') &&
          !received.isCompleted) {
        received.complete();
      }
    });
    host.emit(
      const CommandEvent(
        canopusConnectMessageEvent,
        data: {'deviceId': 'AA:BB:CC:DD:EE:FF', 'moduleId': 'other'},
      ),
    );
    host.emit(
      const CommandEvent(
        'device.connected',
        data: {'deviceId': 'AA:BB:CC:DD:EE:FF'},
      ),
    );
    host.emit(
      const CommandEvent(
        canopusConnectMessageEvent,
        data: {'deviceId': 'AA:BB:CC:DD:EE:FF', 'moduleId': 'demo'},
      ),
    );
    host.emit(
      const CommandEvent(
        canopusConnectMessageEvent,
        data: {'deviceId': 'AA:BB:CC:DD:EE:FF', 'moduleId': 'diag'},
      ),
    );
    await received.future.timeout(const Duration(seconds: 2));
    expect(frames.join(), contains('"moduleId":"demo"'));
    expect(frames.join(), isNot(contains('"moduleId":"other"')));
    expect(frames.join(), isNot(contains('event: device.connected')));
    final canopusClosed = canopusSub.cancel();
    canopusClient.close(force: true);
    unawaited(canopusClosed);

    expect(host.commands.length, commandsBeforeEvents);

    final readOnlyToken = authorize({'device.read'});
    final unauthorizedSend = await _jsonRequest(
      http,
      port,
      'POST',
      '/v1/interconnect/send',
      token: readOnlyToken,
      body: {
        'packageName': 'com.example.app',
        'payload': [1],
      },
    );
    expect(unauthorizedSend.statusCode, 403);
    final scopedToken = authorize(
      {'interconnect.send', 'device.control'},
      devices: ['AA'],
    );
    final wrongDevice = await _jsonRequest(
      http,
      port,
      'POST',
      '/v1/interconnect/send',
      token: scopedToken,
      body: {
        'packageName': 'com.example.app',
        'payload': [1],
        'deviceId': 'BB',
      },
    );
    expect(wrongDevice.statusCode, 403);
    final sendOnlyToken = authorize({'interconnect.send'});
    final cannotSwitch = await _jsonRequest(
      http,
      port,
      'POST',
      '/v1/interconnect/send',
      token: sendOnlyToken,
      body: {
        'packageName': 'com.example.app',
        'payload': [1],
        'deviceId': 'BB',
      },
    );
    expect(cannotSwitch.statusCode, 403);

    // 10. GET /v1/tasks/:taskId
    final taskRes = await _jsonRequest(
      http,
      port,
      'GET',
      '/v1/tasks/task-42',
      token: token,
    );
    expect(taskRes.statusCode, 200);
    expect(taskRes.body['id'], 'task-42');
    expect(taskRes.body['status'], 'completed');

    // 11. GET /v1/devices/info
    final deviceInfoRes = await _jsonRequest(
      http,
      port,
      'GET',
      '/v1/devices/info',
      token: token,
    );
    expect(deviceInfoRes.statusCode, 200);
    final result = deviceInfoRes.body['result'] as Map<String, dynamic>;
    expect(result['connected'], true);
    final storageMap = result['storage'] as Map<String, dynamic>;
    expect(storageMap['totalBytes'], 104857600);
  });
}

class _RecordingHost implements OronBoxCommandBus {
  final _eventsController = StreamController<CommandEvent>.broadcast();
  final commands = <OronBoxCommand>[];

  @override
  Stream<CommandEvent> get events => _eventsController.stream;

  void emit(CommandEvent event) {
    _eventsController.add(event);
  }

  @override
  Future<CommandResult> execute(OronBoxCommand command) async {
    commands.add(command);
    if (command.method == 'task.enqueue') {
      return const CommandResult.success({'taskId': 'task-42'});
    }
    if (command.method == 'queue.get') {
      return const CommandResult.success({
        'id': 'task-42',
        'status': 'completed',
        'progress': 1.0,
      });
    }
    if (command.method == 'device.paired') {
      return const CommandResult.success([
        {
          'name': 'Xiaomi Band 9 Pro',
          'address': 'AA:BB:CC:DD:EE:FF',
          'connectType': 'BLE',
          'codename': 'm75',
        },
      ]);
    }
    if (command.method == 'device.status') {
      return const CommandResult.success({
        'connected': true,
        'protocolState': 'ready',
        'device': {
          'name': 'Xiaomi Band 9 Pro',
          'address': 'AA:BB:CC:DD:EE:FF',
          'connectType': 'BLE',
        },
      });
    }
    if (command.method == 'device.info') {
      return const CommandResult.success({
        'connected': true,
        'protocolState': 'ready',
        'device': {
          'name': 'Xiaomi Band 9 Pro',
          'address': 'AA:BB:CC:DD:EE:FF',
          'connectType': 'BLE',
        },
        'battery': 85,
        'storage': {
          'totalBytes': 104857600,
          'freeBytes': 52428800,
          'usedBytes': 52428800,
        },
      });
    }
    return const CommandResult.success(null);
  }

  @override
  Future<void> close() async {
    await _eventsController.close();
  }
}

class _Response {
  const _Response(this.statusCode, this.body);

  final int statusCode;
  final Map<String, Object?> body;
}

Future<_Response> _jsonRequest(
  HttpClient http,
  int port,
  String method,
  String path, {
  Map<String, Object?>? body,
  String? token,
}) async {
  final request = await http.openUrl(
    method,
    Uri.parse('http://127.0.0.1:$port$path'),
  );
  if (token != null) {
    request.headers.set('authorization', 'Bearer $token');
  }
  if (body != null) {
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(body));
  }
  final response = await request.close();
  final responseText = await response.transform(utf8.decoder).join();
  final decoded = responseText.isNotEmpty
      ? jsonDecode(responseText) as Map<String, Object?>
      : <String, Object?>{};
  return _Response(response.statusCode, decoded);
}
