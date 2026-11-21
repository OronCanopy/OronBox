import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oronbox/src/commands/command_protocol.dart';
import 'package:oronbox/src/core/models/bt_models.dart';
import 'package:oronbox/src/core/services/shared_prefs_service.dart';
import 'package:oronbox/src/data/community/community_source.dart';
import 'package:oronbox/src/device/core/event_bus.dart';
import 'package:oronbox/src/device/zeppos/systems/zeppos_app_side_system.dart';
import 'package:oronbox/src/features/devices/controllers/device_manager.dart';
import 'package:oronbox/src/features/plugins/application/plugin_community_catalog.dart';
import 'package:oronbox/src/features/plugins/application/plugin_manager.dart';
import 'package:oronbox/src/features/resources/domain/resource_catalog.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wasm_abp/wasm_abp.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory root;
  late PluginManager manager;
  late _Devices devices;
  late List<CommandEvent> events;
  HttpOverrides? httpOverrides;
  Future<Map<String, Object?>> Function(CommandEvent)? respond;

  setUp(() async {
    httpOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    await SharedPrefsService.instance.init();
    root = await Directory.systemTemp.createTemp('js-host-');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) async => root.path,
    );
    devices = _Devices();
    events = [];
    respond = null;
    manager = PluginManager(
      deviceManager: devices,
      readDeviceState: () => devices.current,
      emitEvent: (event) {
        events.add(event);
        if (event.event == 'plugin.hostRequest') {
          unawaited(
            (respond?.call(event) ??
                    Future.value(<String, Object?>{'decision': 'session'}))
                .then(
                  (value) => manager.respondToHostRequest(
                    event.data['requestId'].toString(),
                    value,
                  ),
                ),
          );
        }
      },
    );
  });
  tearDown(() async {
    await manager.close();
    HttpOverrides.global = httpOverrides;
    await devices.events.close();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    await root.delete(recursive: true);
  });

  Future<Object?> install(
    String script, {
    String runtime = 'js',
    List<String> permissions = const ['ui'],
    Map<String, List<int>> files = const {},
  }) async {
    final entries = <String, List<int>>{
      'manifest.json': utf8.encode(
        jsonEncode({
          'id': 'org.example.js-host',
          'name': 'Host',
          'api_level': 1,
          'runtime': runtime,
          'entry': 'main.js',
          'permissions': permissions,
        }),
      ),
      'main.js': utf8.encode(script),
      ...files,
    };
    final archive = Archive();
    for (final entry in entries.entries) {
      archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
    }
    await manager.install(Uint8List.fromList(ZipEncoder().encode(archive)));
    return manager.open('org.example.js-host');
  }

  Map<String, Object?> storage() =>
      (manager.diagnosticSnapshot('org.example.js-host')['storage'] as Map)
          .cast<String, Object?>();
  Future<void> waitFor(bool Function() ready) async {
    for (var i = 0; i < 100 && !ready(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(ready(), true);
  }

  test('protocol observes complete plaintext with routing metadata and unsubscribes', () async {
    final tree = await install(
      r'''
      globalThis.activate = async () => {
        const stop = await OronBox.protocol.observe(value => OronBox.storage.set('packet', value));
        await OronBox.ui.render(OronBox.ui.Button('stop', {onClick: stop}));
      };
    ''',
      permissions: ['ui', 'protocol'],
    ) as Map;
    devices.events.add(
      XiaomiProtocolPacketReceived(
        deviceId: 'watch',
        channel: 1,
        payload: Uint8List.fromList([8, 6, 16, 1]),
      ),
    );
    await waitFor(() => storage()['packet'] != null);
    expect(storage()['packet'], {
      'deviceId': 'watch',
      'protocol': 'xiaomi',
      'channel': 1,
      'data': base64Encode([8, 6, 16, 1]),
    });
    devices.events.add(
      ProtocolPacketReceived(
        deviceId: 'watch',
        protocol: 'zeppos',
        channel: 0x10,
        payload: Uint8List.fromList([1, 0, 255]),
      ),
    );
    await waitFor(() => (storage()['packet'] as Map)['protocol'] == 'zeppos');
    final last = storage()['packet'];
    await manager.invoke(
      'org.example.js-host',
      (tree['props'] as Map)['onClick'].toString(),
      null,
    );
    devices.events.add(
      XiaomiProtocolPacketReceived(
        deviceId: 'watch',
        channel: 2,
        payload: Uint8List(0),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(storage()['packet'], last);
    expect(devices.rawReads, 0);
  });

  test('switching the active device while approval is open cannot retarget the authorized operation', () async {
    respond = (event) async {
      devices.current = const DeviceManagerState(
        currentDevice: MiWearState(
          name: 'Other',
          addr: 'other',
          connectType: 'spp',
        ),
      );
      return {'decision': 'once'};
    };
    await expectLater(
      install(
        r'''globalThis.activate = () => OronBox.protocol.send(btoa('data'), {channel: 1});''',
        permissions: ['protocol'],
      ),
      throwsA(isA<PluginExecutionException>()),
    );
    expect(devices.sent, isEmpty);
    expect(manager.failures(), isEmpty);
  });

  test('a denied callback reports an operation error and retains the running UI session', () async {
    final tree = await install(
      r'''
      globalThis.activate = () => OronBox.ui.render(OronBox.ui.Button('Send', {
        onClick: () => OronBox.protocol.send(btoa('data'), {channel: 1}),
      }));
    ''',
      permissions: ['ui', 'protocol'],
    ) as Map;
    await manager.setPermission('org.example.js-host', 'protocol', {
      'decision': 'deny',
    });
    await expectLater(
      manager.invoke(
        'org.example.js-host',
        (tree['props'] as Map)['onClick'].toString(),
        null,
      ),
      throwsA(isA<PluginExecutionException>()),
    );
    expect(devices.sent, isEmpty);
    expect(
      (await manager.get('org.example.js-host'))['running'],
      true,
      reason: jsonEncode(manager.failures()),
    );
    expect(manager.failures(), isEmpty);
  });

  test('protocol sends plaintext through the device API and returns a complete response', () async {
    await install(
      r'''
      globalThis.activate = async () => {
        await OronBox.protocol.send(btoa('\x08\x06'), {channel: 1});
        const result = await OronBox.protocol.request(btoa('\x08\x06'), {channel: 1, timeout: 1234});
        await OronBox.storage.set('response', result.data);
      };
    ''',
      permissions: ['protocol'],
    );
    expect(devices.sent, [
      [8, 6],
    ]);
    expect(devices.requestChannel, 1);
    expect(devices.requestTimeout, const Duration(milliseconds: 1234));
    expect(base64Decode(storage()['response'] as String), [8, 6, 16, 1]);
    expect(devices.rawWrites, 0);
  });

  test(
    'file operations serialize append, copy, move and binary reads',
    () async {
      await install(
        r'''
      globalThis.activate = async () => {
        await OronBox.file.write('/data/input.txt', 'a', {encoding:'utf8'});
        await Promise.all(['b', 'c'].map(text => OronBox.file.write('/data/input.txt', text, {encoding:'utf8', append:true})));
        await OronBox.file.mkdir('/data/source');
        await OronBox.file.copy('/data/input.txt', '/data/source/output.txt');
        await OronBox.file.copy('/data/source', '/data/copied');
        await OronBox.file.move('/data/copied', '/data/moved');
        await OronBox.storage.set('text', await OronBox.file.read('/data/moved/output.txt', {encoding:'utf8'}));
        await OronBox.storage.set('slice', await OronBox.file.read('/data/input.txt', {offset:1, length:1}));
        await OronBox.storage.set('stat', await OronBox.file.stat('/data/moved/output.txt'));
        await OronBox.file.remove('/data/source');
        await OronBox.storage.set('removed', await OronBox.file.stat('/data/source'));
      };
    ''',
        permissions: ['file'],
      );
      expect(storage()['text'], 'abc');
      expect(base64Decode(storage()['slice'] as String), [98]);
      expect((storage()['stat'] as Map)['size'], 3);
      expect(storage()['removed'], isNull);
    },
  );

  test(
    'network fetch and download work without a permission declaration',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requests = <HttpRequest>[];
      final listener = server.listen((request) async {
        requests.add(request);
        if (request.uri.path == '/missing') request.response.statusCode = 404;
        request.response.headers.set('X-Fixture', 'binary');
        request.response.add([0, 128, 255]);
        await request.response.close();
      });
      try {
        await install(
          '''
        globalThis.activate = async () => {
          const origin = 'http://127.0.0.1:${server.port}';
          const result = await OronBox.network.fetch(origin + '/fetch');
          await OronBox.storage.set('fetch', result);
          await OronBox.network.download(origin + '/download', '/data/result.bin');
          await OronBox.storage.set('file', await OronBox.file.read('/data/result.bin'));
          try { await OronBox.network.download(origin + '/missing', '/data/result.bin'); }
          catch (error) { await OronBox.storage.set('failed', true); }
          await OronBox.storage.set('kept', await OronBox.file.read('/data/result.bin'));
        };
      ''',
          permissions: ['file'],
        );
        final response = storage()['fetch'] as Map;
        expect(response['status'], 200);
        expect((response['headers'] as Map)['x-fixture'], 'binary');
        expect(base64Decode(response['body'] as String), [0, 128, 255]);
        expect(base64Decode(storage()['file'] as String), [0, 128, 255]);
        expect(storage()['kept'], storage()['file']);
        expect(storage()['failed'], true);
        expect(requests, hasLength(3));
      } finally {
        await server.close(force: true);
        await listener.cancel();
      }
    },
  );

  test('closing a download cancels its stream and an immediate reopen starts cleanly', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final reached = Completer<void>();
    final listener = server.listen((request) async {
      request.response.add([1, 2, 3]);
      await request.response.flush();
      if (!reached.isCompleted) reached.complete();
    });
    try {
      final tree = await install(
        '''
        globalThis.activate = () => OronBox.ui.render(OronBox.ui.Button('download', {
          onClick: () => OronBox.network.download('http://127.0.0.1:${server.port}/slow', '/data/result.bin')
        }));
      ''',
        permissions: ['ui', 'file'],
      ) as Map;
      final invoking = manager.invoke(
        'org.example.js-host',
        (tree['props'] as Map)['onClick'].toString(),
        null,
      );
      final ended = expectLater(
        invoking,
        throwsA(isA<PluginExecutionException>()),
      );
      await reached.future.timeout(const Duration(seconds: 2));
      final closing = manager.closePlugin('org.example.js-host');
      final reopened = manager.open('org.example.js-host');
      await closing.timeout(const Duration(seconds: 2));
      await ended;
      await reopened;
      final summary = await manager.get('org.example.js-host');
      expect(summary['failure'], isNull);
      expect(summary['running'], true);
    } finally {
      await server.close(force: true);
      await listener.cancel();
    }
  });

  test('hybrid loads package Wasm, preserves floats, accesses memory and releases instances', () async {
    final before = WasmAbpEngine.shared.diagnostics;
    await install(
      r'''
      globalThis.activate = async () => {
        const module = await OronBox.wasm.load('/plugin/hybrid.wasm');
        await OronBox.storage.set('sum', await module.call('add', 1.5, 2.25));
        await module.writeMemory(16384, btoa('\x00\x80\xff'));
        await OronBox.storage.set('memory', await module.readMemory(16384, 3));
        await module.dispose();
        await OronBox.wasm.load('/plugin/hybrid.wasm');
      };
    ''',
      runtime: 'hybrid',
      permissions: [],
      files: {
        'hybrid.wasm': await File('test/core/wasm/fixtures/hybrid.wasm')
            .readAsBytes(),
      },
    );
    expect(storage()['sum'], [3.75]);
    expect(base64Decode(storage()['memory'] as String), [0, 128, 255]);
    await manager.closePlugin('org.example.js-host');
    expect(WasmAbpEngine.shared.diagnostics['instances'], before['instances']);
    expect(WasmAbpEngine.shared.diagnostics['modules'], before['modules']);
  });

  test('provider catalog query detail categories and download follow the JS contract', () async {
    await install(
      r'''
      globalThis.activate = async () => {
        await OronBox.file.write('/data/resource.bin', btoa('\x00\xff'));
        await OronBox.provider.register({id: 'org.example.source', name: 'Source',
          categories: async () => [{id: 'watch', name: 'Watchfaces'}],
          query: async query => { await OronBox.storage.set('query', query); return {items: [{id: 'one', name: 'One', type: 'watchface', author: 'Author'}], total: 1, hasMore: false}; },
          detail: async ({id}) => ({id, name:'One', type:'watchface', authors:['Author'], description:'Details', supportedDevices:[{codename:'n67'}], files:[{id:'f', fileName:'resource.bin', size:2}]}),
          download: async () => ({path:'/data/resource.bin', fileName:'resource.bin'})
        });
      };
    ''',
      permissions: ['file', 'provider'],
    );
    final catalog = PluginCommunityCatalog(
      manager: manager,
      sourceId: CommunitySourceId.plugin('org.example.source'),
    );
    final page = await catalog.getPage(
      const CommunityResourceQuery(query: 'clock', page: 2),
    );
    expect(page.items.single.authors.single.name, 'Author');
    expect((storage()['query'] as Map)['keyword'], 'clock');
    expect(page.total, 1);
    final detail = await catalog.getDetail(page.items.single.ref);
    expect(detail.summary, 'Details');
    expect(detail.supportedDevices, {'n67'});
    final categories = await catalog.getDevices();
    expect(categories.single.codename, 'watch');
    final result = await catalog.download(
      CommunityDownloadRequest(resource: detail, file: detail.files.single),
    );
    expect(result.bytes, [0, 255]);
  });

  test(
    'ZML hooks return asynchronous results and detaching closes cleanly',
    () async {
      final tree = await install(
        r'''
      globalThis.activate = async () => {
        const context = await OronBox.appside.attach({appId: 42,
          onRequest: async request => ({echo: await OronBox.storage.get('message'), request})
        });
        await OronBox.storage.set('message', 'hello');
        await OronBox.ui.render(OronBox.ui.Button('detach', {onClick: () => context.detach()}));
      };
    ''',
        permissions: ['ui', 'appside'],
      ) as Map;
      expect(await devices.hook!('onRequest', {'id': 1}), {
        'result': {
          'echo': 'hello',
          'request': {'id': 1},
        },
      });
      await manager.invoke(
        'org.example.js-host',
        (tree['props'] as Map)['onClick'].toString(),
        null,
      );
      expect(devices.stops, [42]);
      await manager.closePlugin('org.example.js-host');
      expect(devices.stops, [42]);
    },
  );
  test(
    'immediate reopening waits for the previous App-side stop before attaching',
    () async {
      await install(
        r'''
      globalThis.activate = () => OronBox.appside.attach({appId:42, onRequest: async () => 'active'});
    ''',
        permissions: ['appside'],
      );
      final previous = devices.hook!;
      final stop = Completer<void>();
      devices.stopGate = stop.future;
      final closing = manager.closePlugin('org.example.js-host');
      await waitFor(() => devices.stops.isNotEmpty);
      final opening = manager.open('org.example.js-host');
      try {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(devices.attachments, 1);
        stop.complete();
        await closing;
        await opening;
        expect(devices.attachments, 2);
        expect(await previous('onRequest', null), isNull);
        expect(await devices.hook!('onRequest', null), {'result': 'active'});
      } finally {
        if (!stop.isCompleted) stop.complete();
        devices.stopGate = null;
      }
    },
  );
}

class _Devices extends Fake implements DeviceManager {
  final events = StreamController<DeviceEvent>.broadcast();
  final sent = <List<int>>[];
  final stops = <int>[];
  int rawReads = 0;
  int rawWrites = 0;
  int? requestChannel;
  Duration? requestTimeout;
  ZeppOsZmlHookHandler? hook;
  Future<void>? stopGate;
  int attachments = 0;
  DeviceManagerState current = const DeviceManagerState(
    currentDevice: MiWearState(
      name: 'Watch',
      addr: 'watch',
      connectType: 'spp',
    ),
  );
  @override
  Set<String> get connectedAddresses => {'watch'};
  @override
  Stream<InterconnectMessage> get interconnectMessages => const Stream.empty();
  @override
  Stream<DeviceEvent> get deviceEvents => events.stream;
  @override
  Stream<Uint8List> get rawProtocolFrames {
    rawReads++;
    return const Stream.empty();
  }

  @override
  Future<void> sendRaw(Uint8List payload) async {
    rawWrites++;
  }

  @override
  Future<void> sendProtocolPacket(
    Uint8List payload, {
    String? deviceId,
    int? channel,
  }) async {
    sent.add(payload.toList());
  }

  @override
  Future<Uint8List> requestProtocolPacket(
    Uint8List payload, {
    String? deviceId,
    int? channel,
    Duration timeout = const Duration(seconds: 5),
    Stream<void>? cancellation,
  }) async {
    requestChannel = channel;
    requestTimeout = timeout;
    return Uint8List.fromList([8, 6, 16, 1]);
  }

  @override
  Future<void> attachZeppOsZml(int appId, ZeppOsZmlHookHandler handler) async {
    attachments++;
    hook = handler;
  }

  @override
  Future<void> stopZeppOsAppSide(int appId) async {
    stops.add(appId);
    await stopGate;
  }
}
