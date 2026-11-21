import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oronbox/src/commands/command_protocol.dart';
import 'package:oronbox/src/core/services/shared_prefs_service.dart';
import 'package:oronbox/src/device/core/event_bus.dart';
import 'package:oronbox/src/features/devices/controllers/device_manager.dart';
import 'package:oronbox/src/features/plugins/application/plugin_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../support/wasm_abp_fixtures.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  test('closing during preparation cancels startup without waiting and isolates its late failure from an immediate reopen', () async {
    SharedPreferences.setMockInitialValues({});
    await SharedPrefsService.instance.init();
    final root = await Directory.systemTemp.createTemp(
      'oronbox-manager-lifecycle-',
    );
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    Completer<void>? gate;
    final reachedCache = Completer<void>();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'getApplicationCacheDirectory' && gate != null) {
        if (!reachedCache.isCompleted) reachedCache.complete();
        await gate.future;
      }
      return root.path;
    });
    final manager = PluginManager(
      deviceManager: _Devices(),
      readDeviceState: () => const DeviceManagerState(),
      emitEvent: (_) {},
    );
    try {
      final fixture = readWasmAbpFixture('ui_notification.wasm');
      final manifest = utf8.encode(
        jsonEncode({
          'id': 'org.example.lifecycle',
          'name': 'Lifecycle',
          'version': '1',
          'entry': 'plugin.wasm',
          'api_level': 4,
        }),
      );
      final archive = Archive()
        ..addFile(ArchiveFile('manifest.json', manifest.length, manifest))
        ..addFile(ArchiveFile('plugin.wasm', fixture.length, fixture));
      await manager.install(Uint8List.fromList(ZipEncoder().encode(archive)));
      gate = Completer<void>();
      final opening = manager.open('org.example.lifecycle');
      final cancelled = expectLater(
        opening,
        throwsA(isA<PluginExecutionException>()),
      );
      await reachedCache.future.timeout(const Duration(seconds: 3));
      await manager
          .closePlugin('org.example.lifecycle')
          .timeout(const Duration(seconds: 1));
      final reopening = manager.open('org.example.lifecycle');
      gate.complete();
      await cancelled;
      await reopening;
      final summary = await manager.get('org.example.lifecycle');
      expect(summary['failure'], isNull);
      expect(summary['running'], isTrue);
      await manager.closePlugin('org.example.lifecycle');
      expect((await manager.get('org.example.lifecycle'))['ui'], isEmpty);
    } finally {
      if (gate != null && !gate.isCompleted) gate.complete();
      await manager.close();
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      await root.delete(recursive: true);
    }
  });
  test('JS package installs, renders, updates storage and handles scalar callbacks', () async {
    SharedPreferences.setMockInitialValues({});
    await SharedPrefsService.instance.init();
    final root = await Directory.systemTemp.createTemp('oronbox-js-host-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) async => root.path,
    );
    final events = <CommandEvent>[];
    late PluginManager manager;
    manager = PluginManager(
      deviceManager: _Devices(),
      readDeviceState: () => const DeviceManagerState(),
      emitEvent: (event) {
        events.add(event);
        if (event.event == 'plugin.hostRequest') {
          unawaited(
            manager.respondToHostRequest(event.data['requestId'].toString(), {
              'decision': 'session',
            }),
          );
        }
      },
    );
    try {
      final manifest = utf8.encode(
        jsonEncode({
          'id': 'org.example.js',
          'name': 'JS',
          'api_level': 1,
          'runtime': 'hybrid',
          'entry': 'main.js',
          'permissions': ['ui', 'file', 'provider'],
        }),
      );
      final script = utf8.encode(r'''globalThis.activate = async () => {
        await Promise.all([OronBox.storage.set('a', 1), OronBox.storage.set('b', 2)]);
        await OronBox.file.write('/data/test.txt', '天气', {encoding: 'utf8'});
        await OronBox.file.write('/cache/retained.bin', 'cache', {encoding: 'utf8'});
        await OronBox.file.write('/temp/session/picked-session.tmp', 'temporary', {encoding: 'utf8'});
        const text = await OronBox.file.read('/data/test.txt', {encoding: 'utf8'});
        await OronBox.provider.register({id: 'org.example.source', name: 'Source', query: async () => ({items: [], hasMore: false}), detail: async args => args, download: async () => ({path: '/data/test.txt'})});
        await OronBox.ui.render(OronBox.ui.Switch(false, {key: 'switch', onChange: async value => {
          await OronBox.storage.set('checked', value);
          await OronBox.ui.render(OronBox.ui.Text(text + ':' + value));
        }}));
      };''');
      final archive = Archive()
        ..addFile(ArchiveFile('manifest.json', manifest.length, manifest))
        ..addFile(ArchiveFile('main.js', script.length, script));
      await manager.install(Uint8List.fromList(ZipEncoder().encode(archive)));
      final tree = (await manager.open('org.example.js')) as Map;
      expect(tree['type'], 'Switch');
      final callback = (tree['props'] as Map)['onChange'].toString();
      await manager.invoke('org.example.js', callback, {
        'eventType': 'CHANGE',
        'payload': true,
      });
      final updated = (await manager.get('org.example.js'))['ui'] as Map;
      expect((updated['props'] as Map)['value'], '天气:true');
      expect(manager.diagnosticSnapshot('org.example.js')['storage'], {
        'a': 1,
        'b': 2,
        'checked': true,
      });
      expect(
        await manager.callProvider('org.example.source', 'query', const []),
        {'items': [], 'hasMore': false},
      );
      expect(
        utf8.decode(
          await manager.readProviderFile(
            'org.example.source',
            '/data/test.txt',
          ),
        ),
        '天气',
      );
      final temporaryFiles = await root
          .list(recursive: true)
          .where((file) => file.path.endsWith('picked-session.tmp'))
          .toList();
      expect(temporaryFiles, hasLength(1));
      await manager.closePlugin('org.example.js');
      expect(await File(temporaryFiles.single.path).exists(), isFalse);
      expect(
        await File('${root.path}/plugins/org.example.js/retained.bin')
            .readAsString(),
        'cache',
      );
      expect(
        await File('${root.path}/plugins/org.example.js/data/test.txt')
            .readAsString(),
        '天气',
      );
      expect((await manager.providers()), isEmpty);
      expect(manager.diagnosticSnapshot('org.example.js')['running'], false);
    } finally {
      await manager.close();
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      await root.delete(recursive: true);
    }
  });
  group('host lifecycle settings', () {
    const id = 'org.example.background';
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    const background = MethodChannel('org.oroncanopy.oronbox/background_tasks');
    late Directory root;
    late PluginManager manager;
    late _Devices devices;
    late List<CommandEvent> events;
    late Set<int> handles;
    var nextHandle = 0;
    var unavailable = false;
    Completer<void>? backgroundGate;
    Future<void> Function(CommandEvent)? respond;

    PluginManager createManager({
      Duration idleTimeout = const Duration(minutes: 10),
    }) => PluginManager(
      backgroundIdleTimeout: idleTimeout,
      deviceManager: devices,
      readDeviceState: () => const DeviceManagerState(),
      emitEvent: (event) {
        events.add(event);
        if (respond != null) unawaited(respond!(event));
      },
    );

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await SharedPrefsService.instance.init();
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      root = await Directory.systemTemp.createTemp('oronbox-background-');
      devices = _Devices();
      events = [];
      handles = {};
      nextHandle = 0;
      unavailable = false;
      backgroundGate = null;
      respond = null;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        paths,
        (_) async => root.path,
      );
      binding.defaultBinaryMessenger.setMockMethodCallHandler(background, (
        call,
      ) async {
        if (call.method == 'beginPlugin') {
          if (unavailable) {
            throw PlatformException(code: 'BACKGROUND_UNAVAILABLE');
          }
          final handle = ++nextHandle;
          handles.add(handle);
          await backgroundGate?.future;
          return handle;
        }
        if (call.method == 'end') handles.remove((call.arguments as Map)['id']);
        return null;
      });
      manager = createManager();
      await manager.install(
        _jsPackage(id, r'''
        globalThis.activate = async () => {
          const starts = (await OronBox.storage.get('starts')) || 0;
          await OronBox.storage.set('starts', starts + 1);
          await OronBox.ui.render(OronBox.ui.Text('Ready'));
          let tick = 0;
          setInterval(() => OronBox.storage.set('tick', ++tick), 20);
        };
      '''),
      );
    });

    tearDown(() async {
      await manager.close();
      await devices.interconnect.close();
      binding.defaultBinaryMessenger.setMockMethodCallHandler(paths, null);
      binding.defaultBinaryMessenger.setMockMethodCallHandler(background, null);
      debugDefaultTargetPlatformOverride = null;
      await root.delete(recursive: true);
    });

    test('defaults use active background without automatic startup', () async {
      await manager.startAutomaticPlugins();
      final state = await manager.get(id);
      expect(state, containsPair('enabled', true));
      expect(state, containsPair('background', 'active'));
      expect(state, containsPair('autoStart', false));
      expect(state, containsPair('running', false));
      expect(handles, isEmpty);
    });

    test('leaving a page keeps the active session through app background transitions', () async {
      await manager.attachView(id, 'view');
      await manager.detachView(id, 'view');
      await _until(
        () =>
            (manager.diagnosticSnapshot(id)['storage'] as Map)['tick'] != null,
      );
      expect((await manager.get(id))['running'], true);
      expect(handles, isEmpty);
      await manager.setForeground(false);
      expect(handles, hasLength(1));
      expect((await manager.get(id))['running'], true);
      await manager.setForeground(true);
      expect(handles, isEmpty);
      expect((manager.diagnosticSnapshot(id)['storage'] as Map)['starts'], 1);
      expect(manager.failures(), isEmpty);
    });

    test(
      'automatic startup persists and activates once with the active policy',
      () async {
        await manager.setSettings(id, {'autoStart': true});
        await manager.close();
        manager = createManager();
        await Future.wait([
          manager.startAutomaticPlugins(),
          manager.startAutomaticPlugins(),
        ]);
        expect((await manager.get(id))['running'], true);
        expect((manager.diagnosticSnapshot(id)['storage'] as Map)['starts'], 1);
        expect((await manager.get(id))['background'], 'active');
        await manager.setForeground(false);
        expect((await manager.get(id))['running'], true);
        await manager.setForeground(true);
        expect((manager.diagnosticSnapshot(id)['storage'] as Map)['starts'], 1);
      },
    );

    test('background permission alone never starts a plugin and preserves an opened session', () async {
      await manager.setSettings(id, {'background': 'continuous'});
      await manager.startAutomaticPlugins();
      expect((await manager.get(id))['running'], false);
      await manager.attachView(id, 'view');
      await manager.detachView(id, 'view');
      expect(handles, isEmpty);
      await manager.setForeground(false);
      expect(handles, hasLength(1));
      await _until(
        () =>
            (manager.diagnosticSnapshot(id)['storage'] as Map)['tick'] != null,
      );
      expect((await manager.get(id))['running'], true);
      await manager.setSettings(id, {'background': 'forbidden'});
      expect(handles, isEmpty);
      expect((await manager.get(id))['running'], false);
      await manager.setForeground(true);
      expect((await manager.get(id))['running'], false);
      expect((manager.diagnosticSnapshot(id)['storage'] as Map)['starts'], 1);
    });

    test('disabled plugins cannot be started and settings mutations retain call order', () async {
      await Future.wait([
        manager.setSettings(id, {'autoStart': true}),
        manager.setSettings(id, {'background': 'continuous'}),
        manager.setSettings(id, {'enabled': false}),
      ]);
      await manager.startAutomaticPlugins();
      await expectLater(manager.attachView(id, 'blocked'), throwsStateError);
      expect((await manager.get(id))['running'], false);
      expect((await manager.get(id))['background'], 'continuous');
      expect(manager.failures(), isEmpty);
      await manager.setSettings(id, {'enabled': true});
      await manager.attachView(id, 'opened');
      expect((await manager.get(id))['running'], true);
    });

    test('rapid pause and resume restores one live session without recording a failure', () async {
      await manager.open(id);
      for (var i = 0; i < 5; i++) {
        await Future.wait([
          manager.setForeground(false),
          manager.setForeground(true),
        ]);
        expect((await manager.get(id))['running'], true);
      }
      expect(manager.failures(), isEmpty);
      expect(
        (manager.diagnosticSnapshot(id)['storage'] as Map)['starts'],
        lessThanOrEqualTo(6),
      );
    });

    test('closing while the native background handle is pending cannot activate a cancelled plugin', () async {
      backgroundGate = Completer<void>();
      await manager.setSettings(id, {'background': 'continuous'});
      await manager.setForeground(false);
      final starting = manager.open(id);
      final rejected = expectLater(
        starting,
        throwsA(isA<PluginExecutionException>()),
      );
      await _until(() => handles.isNotEmpty);
      await manager.closePlugin(id);
      backgroundGate!.complete();
      await rejected;
      expect(handles, isEmpty);
      expect(
        (manager.diagnosticSnapshot(id)['storage'] as Map)['starts'],
        isNull,
      );
      expect((await manager.get(id))['running'], false);
      expect(manager.failures(), isEmpty);
    });

    test('background service failure suspends the session and can recover in the foreground', () async {
      unavailable = true;
      await manager.setSettings(id, {'background': 'continuous'});
      await manager.open(id);
      expect(handles, isEmpty);
      await manager.setForeground(false);
      expect((await manager.get(id))['running'], false);
      unavailable = false;
      await manager.setForeground(true);
      expect((await manager.get(id))['running'], true);
      expect(handles, isEmpty);
    });

    test('native expiration releases the background runtime and resume reacquires a handle', () async {
      await manager.setSettings(id, {'background': 'continuous'});
      await manager.open(id);
      await manager.setForeground(false);
      final expired = handles.single;
      final notified = Completer<void>();
      binding.defaultBinaryMessenger.handlePlatformMessage(
        'org.oroncanopy.oronbox/background_tasks',
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('expired', {
            'ids': [expired],
          }),
        ),
        (_) => notified.complete(),
      );
      await notified.future;
      handles.remove(expired);
      await _until(() => manager.diagnosticSnapshot(id)['running'] == false);
      await manager.setForeground(true);
      expect((await manager.get(id))['running'], true);
      expect(handles, isEmpty);
      await manager.setForeground(false);
      expect(handles, hasLength(1));
      expect(handles.single, isNot(expired));
      expect(manager.failures(), isEmpty);
    });

    test('active policy reclaims an idle plugin despite storage timers and does not revive it on app resume', () async {
      await manager.close();
      manager = createManager(idleTimeout: const Duration(milliseconds: 400));
      await manager.attachView(id, 'view');
      await manager.detachView(id, 'view');
      await _until(() => manager.diagnosticSnapshot(id)['running'] == false);
      final storage = Map.of(manager.diagnosticSnapshot(id)['storage'] as Map);
      await manager.setForeground(false);
      await manager.setForeground(true);
      expect((await manager.get(id))['running'], false);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(manager.diagnosticSnapshot(id)['storage'], storage);
      await manager.attachView(id, 'reopened');
      expect((manager.diagnosticSnapshot(id)['storage'] as Map)['starts'], 2);
      expect(manager.failures(), isEmpty);
    });

    test(
      'active policy starts its idle window after the last view leaves',
      () async {
        await manager.close();
        manager = createManager(idleTimeout: const Duration(milliseconds: 350));
        await manager.attachView(id, 'first');
        await manager.attachView(id, 'second');
        await manager.detachView(id, 'first');
        await Future<void>.delayed(const Duration(milliseconds: 500));
        expect((await manager.get(id))['running'], true);
        await manager.detachView(id, 'second');
        expect((await manager.get(id))['running'], true);
        await _until(() => manager.diagnosticSnapshot(id)['running'] == false);
      },
    );

    test('hidden navigation views no longer prevent idle reclamation and visibility restores the session', () async {
      await manager.close();
      manager = createManager(idleTimeout: const Duration(milliseconds: 350));
      await manager.attachView(id, 'first');
      await manager.attachView(id, 'second');
      await manager.setViewVisibility(id, 'first', false);
      await Future<void>.delayed(const Duration(milliseconds: 450));
      expect((await manager.get(id))['running'], true);
      await manager.setViewVisibility(id, 'second', false);
      await _until(() => manager.diagnosticSnapshot(id)['running'] == false);
      await manager.setForeground(false);
      await manager.setForeground(true);
      expect((await manager.get(id))['running'], false);
      await manager.setViewVisibility(id, 'first', true);
      expect((await manager.get(id))['running'], true);
      expect((manager.diagnosticSnapshot(id)['storage'] as Map)['starts'], 2);
      await Future<void>.delayed(const Duration(milliseconds: 450));
      expect((await manager.get(id))['running'], true);
    });

    test(
      'forbidden policy stops on the last view leaving and releases timers',
      () async {
        await manager.setSettings(id, {'background': 'forbidden'});
        await manager.attachView(id, 'first');
        await manager.attachView(id, 'second');
        await manager.detachView(id, 'first');
        expect((await manager.get(id))['running'], true);
        await manager.detachView(id, 'second');
        expect((await manager.get(id))['running'], false);
        await manager.setForeground(true);
        expect((await manager.get(id))['running'], false);
        expect(manager.failures(), isEmpty);
      },
    );

    test('automatic startup with forbidden background finishes initialization once and stops', () async {
      await manager.setSettings(id, {
        'background': 'forbidden',
        'autoStart': true,
      });
      await manager.startAutomaticPlugins();
      expect((manager.diagnosticSnapshot(id)['storage'] as Map)['starts'], 1);
      expect((await manager.get(id))['running'], false);
      await manager.setForeground(true);
      expect((await manager.get(id))['running'], false);
      await manager.attachView(id, 'manual');
      expect((manager.diagnosticSnapshot(id)['storage'] as Map)['starts'], 2);
    });

    test('continuous policy outlives the idle window and switching to active grants a fresh window', () async {
      await manager.close();
      manager = createManager(idleTimeout: const Duration(milliseconds: 300));
      await manager.setSettings(id, {'background': 'continuous'});
      await manager.attachView(id, 'view');
      await manager.detachView(id, 'view');
      await Future<void>.delayed(const Duration(milliseconds: 450));
      expect((await manager.get(id))['running'], true);
      await manager.setSettings(id, {'background': 'active'});
      expect((await manager.get(id))['running'], true);
      await _until(() => manager.diagnosticSnapshot(id)['running'] == false);
      expect(handles, isEmpty);
    });

    test('unmatched incoming messages do not renew an idle plugin', () async {
      await manager.close();
      manager = createManager(idleTimeout: const Duration(milliseconds: 400));
      await manager.open(id);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      devices.interconnect.add(
        InterconnectMessage(
          deviceId: 'unrelated',
          pkgName: 'other',
          payload: Uint8List(0),
        ),
      );
      await _until(() => manager.diagnosticSnapshot(id)['running'] == false);
      expect(manager.failures(), isEmpty);
    });

    test('matched interconnect activity renews the idle window', () async {
      respond = (event) async {
        if (event.event == 'plugin.hostRequest') {
          await manager.respondToHostRequest(
            event.data['requestId'].toString(),
            {'decision': 'session'},
          );
        }
      };
      await manager.install(
        _jsPackage(
          id,
          r'''
        globalThis.activate = async () => {
          await OronBox.interconnect.onMessage(async () => {
            await OronBox.storage.set('received', true);
          });
          await OronBox.ui.render(OronBox.ui.Text('Listening'));
        };
      ''',
          permissions: ['ui', 'interconnect'],
        ),
      );
      await manager.close();
      manager = createManager(idleTimeout: const Duration(milliseconds: 800));
      await manager.attachView(id, 'view');
      await manager.detachView(id, 'view');
      await Future<void>.delayed(const Duration(milliseconds: 500));
      devices.interconnect.add(
        InterconnectMessage(
          deviceId: 'watch',
          pkgName: 'app',
          payload: Uint8List(0),
        ),
      );
      await _until(
        () =>
            (manager.diagnosticSnapshot(id)['storage'] as Map)['received'] ==
            true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect((await manager.get(id))['running'], true);
      await _until(() => manager.diagnosticSnapshot(id)['running'] == false);
    });

    test('an incoming callback is protected until completion before its next idle window', () async {
      respond = (event) async {
        if (event.event == 'plugin.hostRequest') {
          await manager.respondToHostRequest(
            event.data['requestId'].toString(),
            {'decision': 'session'},
          );
        }
      };
      await manager.install(
        _jsPackage(
          id,
          r'''
        globalThis.activate = async () => {
          await OronBox.interconnect.onMessage(async () => {
            await OronBox.storage.set('entered', true);
            await new Promise(resolve => setTimeout(resolve, 750));
            await OronBox.storage.set('finished', true);
          });
        };
      ''',
          permissions: ['interconnect'],
        ),
      );
      await manager.close();
      manager = createManager(idleTimeout: const Duration(milliseconds: 350));
      await manager.open(id);
      devices.interconnect.add(
        InterconnectMessage(
          deviceId: 'watch',
          pkgName: 'app',
          payload: Uint8List(0),
        ),
      );
      await _until(
        () =>
            (manager.diagnosticSnapshot(id)['storage'] as Map)['entered'] ==
            true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect((await manager.get(id))['running'], true);
      await _until(
        () =>
            (manager.diagnosticSnapshot(id)['storage'] as Map)['finished'] ==
            true,
      );
      expect((await manager.get(id))['running'], true);
      await _until(() => manager.diagnosticSnapshot(id)['running'] == false);
      expect(manager.failures(), isEmpty);
    });

    test('failed network retries do not renew the idle window', () async {
      respond = (event) async {
        if (event.event == 'plugin.hostRequest') {
          await manager.respondToHostRequest(
            event.data['requestId'].toString(),
            {'decision': 'session'},
          );
        }
      };
      await manager.install(
        _jsPackage(
          id,
          r'''
        globalThis.activate = () => {
          setInterval(() => OronBox.network.fetch('invalid').catch(() => {}), 40);
        };
      ''',
          permissions: ['network'],
        ),
      );
      await manager.close();
      manager = createManager(idleTimeout: const Duration(milliseconds: 400));
      await manager.open(id);
      await _until(() => manager.diagnosticSnapshot(id)['running'] == false);
      expect(manager.failures(), isEmpty);
    });

    test('successful network activity extends the idle window and a pending transfer stays alive', () async {
      final previousHttpOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requested = Completer<void>();
      final release = Completer<void>();
      final served = Completer<void>();
      server.listen((request) async {
        requested.complete();
        await release.future;
        request.response.write('ok');
        await request.response.close();
        served.complete();
      });
      respond = (event) async {
        if (event.event == 'plugin.hostRequest') {
          await manager.respondToHostRequest(
            event.data['requestId'].toString(),
            {'decision': 'session'},
          );
        }
      };
      try {
        await manager.install(
          _jsPackage(
            id,
            """
          globalThis.activate = () => {
            setTimeout(async () => {
              await OronBox.network.fetch('http://127.0.0.1:${server.port}/');
              await OronBox.storage.set('downloaded', true);
            }, 100);
          };
        """,
            permissions: ['network'],
          ),
        );
        await manager.close();
        manager = createManager(
          idleTimeout: const Duration(milliseconds: 1500),
        );
        await manager.open(id);
        await requested.future.timeout(const Duration(seconds: 3));
        await Future<void>.delayed(const Duration(milliseconds: 1800));
        expect((await manager.get(id))['running'], true);
        release.complete();
        await served.future;
        await _until(
          () =>
              (manager.diagnosticSnapshot(id)['storage']
                  as Map)['downloaded'] ==
              true,
          reason: 'Network result was not delivered to the guest',
        );
        expect((await manager.get(id))['running'], true);
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect((await manager.get(id))['running'], true);
        await _until(
          () => manager.diagnosticSnapshot(id)['running'] == false,
          reason:
              'Completed network operation did not release its idle session',
        );
        expect(manager.failures(), isEmpty);
      } finally {
        if (!release.isCompleted) release.complete();
        await server.close(force: true);
        HttpOverrides.global = previousHttpOverrides;
      }
    });

    test(
      'an expired active window is not restarted after a system suspension',
      () async {
        await manager.close();
        manager = createManager(idleTimeout: const Duration(milliseconds: 350));
        await manager.open(id);
        unavailable = true;
        await manager.setForeground(false);
        expect((await manager.get(id))['running'], false);
        await Future<void>.delayed(const Duration(milliseconds: 500));
        unavailable = false;
        await manager.setForeground(true);
        expect((await manager.get(id))['running'], false);
        expect((manager.diagnosticSnapshot(id)['storage'] as Map)['starts'], 1);
      },
    );

    test('revoking a live observation removes device event delivery without stopping the plugin', () async {
      respond = (event) async {
        if (event.event == 'plugin.hostRequest' &&
            event.data['type'] == 'permission') {
          await manager.respondToHostRequest(
            event.data['requestId'].toString(),
            {'decision': 'session'},
          );
        }
      };
      await manager.install(
        _jsPackage(
          id,
          r'''
        globalThis.activate = async () => {
          await OronBox.interconnect.onMessage(async () => {
            const messages = (await OronBox.storage.get('messages')) || 0;
            await OronBox.storage.set('messages', messages + 1);
          });
          await OronBox.ui.render(OronBox.ui.Text('Listening'));
        };
      ''',
          permissions: ['ui', 'interconnect'],
        ),
      );
      await manager.open(id);
      devices.interconnect.add(
        InterconnectMessage(
          deviceId: 'watch',
          pkgName: 'app',
          payload: Uint8List(0),
        ),
      );
      await _until(
        () =>
            (manager.diagnosticSnapshot(id)['storage'] as Map)['messages'] == 1,
      );
      await manager.setPermission(id, 'interconnect', {'decision': 'deny'});
      devices.interconnect.add(
        InterconnectMessage(
          deviceId: 'watch',
          pkgName: 'app',
          payload: Uint8List(0),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect((manager.diagnosticSnapshot(id)['storage'] as Map)['messages'], 1);
      expect((await manager.get(id))['running'], true);
      expect(manager.failures(), isEmpty);
    });

    test(
      'enabling a plugin with an attached view restores its foreground session',
      () async {
        await manager.attachView(id, 'open-view');
        await manager.setSettings(id, {'enabled': false});
        expect((await manager.get(id))['running'], false);
        await manager.setSettings(id, {'enabled': true});
        expect((await manager.get(id))['running'], true);
        expect((manager.diagnosticSnapshot(id)['storage'] as Map)['starts'], 2);
      },
    );

    test(
      'a corrupt host settings file is isolated from other automatic plugins',
      () async {
        const sibling = 'org.example.sibling';
        await manager.install(
          _jsPackage(
            sibling,
            "globalThis.activate = () => OronBox.ui.render(OronBox.ui.Text('Sibling'));",
          ),
        );
        await manager.setSettings(sibling, {'autoStart': true});
        await manager.close();
        await File('${root.path}/plugin_metadata/$id/host.json')
            .writeAsString('{invalid');
        manager = createManager();
        await manager.startAutomaticPlugins();
        expect((await manager.get(id))['enabled'], false);
        expect((await manager.get(sibling))['running'], true);
      },
    );

    test(
      'system file selection keeps the session across pause and resume',
      () async {
        respond = (event) async {
          if (event.event == 'plugin.hostRequest' &&
              event.data['type'] == 'permission') {
            await manager.respondToHostRequest(
              event.data['requestId'].toString(),
              {'decision': 'session'},
            );
          }
        };
        await manager.install(
          _jsPackage(
            id,
            r'''
        globalThis.activate = () => OronBox.ui.render(OronBox.ui.Button('Pick', {
          onClick: async () => { await OronBox.file.pick(); },
        }));
      ''',
            permissions: ['ui', 'file'],
          ),
        );
        final tree = await manager.open(id) as Map;
        final selecting = manager.invoke(
          id,
          (tree['props'] as Map)['onClick'].toString(),
          null,
        );
        await _until(
          () => events.any(
            (event) =>
                event.event == 'plugin.hostRequest' &&
                event.data['type'] == 'pickFile',
          ),
        );
        final request = events
            .lastWhere(
              (event) =>
                  event.event == 'plugin.hostRequest' &&
                  event.data['type'] == 'pickFile',
            )
            .data['requestId']
            .toString();
        await manager.setForeground(false);
        expect((await manager.get(id))['running'], true);
        await manager.setForeground(true);
        await manager.respondToHostRequest(request, {'cancelled': true});
        await selecting;
        expect((await manager.get(id))['running'], true);
        expect(manager.failures(), isEmpty);
      },
    );

    test('host request claims isolate windows and late responses after permission revocation', () async {
      await manager.install(
        _jsPackage(
          id,
          r'''
        globalThis.activate = async () => { await OronBox.device.list(); };
      ''',
          permissions: ['device'],
        ),
      );
      final starting = manager.open(id);
      final rejected = expectLater(
        starting,
        throwsA(isA<PluginExecutionException>()),
      );
      await _until(
        () => events.any((event) => event.event == 'plugin.hostRequest'),
      );
      final request = events
          .lastWhere((event) => event.event == 'plugin.hostRequest')
          .data['requestId']
          .toString();
      expect(manager.claimHostRequest(request, 'first'), true);
      expect(manager.claimHostRequest(request, 'second'), false);
      manager.releaseHostRequests('first');
      expect(manager.claimHostRequest(request, 'second'), true);
      await manager.respondToHostRequest(request, {
        'decision': 'always',
      }, owner: 'first');
      expect(manager.hasHostRequest(request), true);
      await manager.setPermission(id, 'device', {'decision': 'deny'});
      await manager.respondToHostRequest(request, {
        'decision': 'always',
      }, owner: 'second');
      await rejected;
      expect(manager.hasHostRequest(request), false);
      expect(
        events.any((event) => event.event == 'plugin.hostCancelled'),
        true,
      );
      expect(manager.failures(), isEmpty);
    });
  });
}

class _Devices extends Fake implements DeviceManager {
  final interconnect = StreamController<InterconnectMessage>.broadcast();
  @override
  Stream<InterconnectMessage> get interconnectMessages => interconnect.stream;
  @override
  Stream<DeviceEvent> get deviceEvents => const Stream.empty();
}

Uint8List _jsPackage(
  String id,
  String source, {
  List<String> permissions = const ['ui'],
}) {
  final manifest = utf8.encode(
    jsonEncode({
      'id': id,
      'name': 'Lifecycle',
      'version': '1',
      'api_level': 1,
      'runtime': 'js',
      'entry': 'main.js',
      'permissions': permissions,
    }),
  );
  final script = utf8.encode(source);
  final archive = Archive()
    ..addFile(ArchiveFile('manifest.json', manifest.length, manifest))
    ..addFile(ArchiveFile('main.js', script.length, script));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

Future<void> _until(
  bool Function() condition, {
  String reason = 'Condition did not become true',
}) async {
  final elapsed = Stopwatch()..start();
  while (!condition()) {
    if (elapsed.elapsed > const Duration(seconds: 4)) {
      fail(reason);
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
