import 'dart:typed_data';
import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:oronbox/src/features/plugins/runtime/plugin_runtime_wasm.dart';
import 'package:oronbox/src/features/plugins/domain/plugin_package.dart';
import 'package:oronbox/src/features/plugins/storage/plugin_storage.dart';
import 'package:oronbox/src/features/plugins/storage/plugin_storage_io.dart';
import 'package:wasm_abp/wasm_abp.dart';

import '../../../support/wasm_abp_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final api in [3, 4]) {
    test(
      'API $api reads bundled resources through relative WASI paths',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'oronbox-wasi-package-',
        );
        final storage = await createIoPluginStorage(
          installedRoot: Directory('${root.path}/installed'),
          cacheRoot: Directory('${root.path}/cache'),
          temporaryRoot: Directory('${root.path}/temp'),
        );
        final runtime = WasmPluginRuntime(storage: storage);
        addTearDown(() async {
          await runtime.close();
          await storage.close();
          await root.delete(recursive: true);
        });
        final files = <String, Uint8List>{
          'manifest.json': utf8.encode(
            '{"name":"Files","version":"1.2.3","api_level":$api}',
          ),
          'plugin.wasm': await File(
            'test/features/plugins/runtime/fixtures/package_file.wasm',
          ).readAsBytes(),
          'packs/index.json': utf8.encode('{"chapters":6}'),
          'web/icon.txt': utf8.encode('bundled icon'),
        };
        final package = PluginPackage(
          manifest: const PluginPackageReader().readManifest(
            files['manifest.json']!,
          ),
          files: files,
        );
        final plugin = await storage.install(package, config: {});
        await storage.writeFile(
          plugin.manifest.id,
          PluginStoragePath.parse('/data/manifest.json'),
          utf8.encode('user data'),
        );
        await runtime.start(
          pluginId: plugin.manifest.id,
          pluginName: plugin.manifest.name,
          pluginVersion: plugin.manifest.version,
          runtimeVersion: '1',
          apiLevel: api,
          entryBytes: plugin.entryBytes,
          hostCall: (_, _) => null,
        );
        for (final name in [
          'manifest.json',
          'packs/index.json',
          'web/icon.txt',
        ]) {
          expect(
            await runtime.renderUi(elementId: name),
            utf8.decode(files[name]!),
          );
        }
        expect(
          await runtime.renderUi(elementId: '../data/manifest.json'),
          'missing',
        );
      },
    );
    test(
      'closing API $api during a pending Host call releases native resources',
      () async {
        final runtime = WasmPluginRuntime(storage: const _DummyPluginStorage());
        final reachedHost = Completer<void>();
        final response = Completer<Object?>();
        final startup = runtime.start(
          pluginId: 'pending_host',
          pluginName: 'Pending',
          pluginVersion: '1',
          runtimeVersion: '1',
          apiLevel: api,
          entryBytes: readWasmAbpFixture('sync_host.wasm'),
          hostCall: (method, arguments) {
            reachedHost.complete();
            return response.future;
          },
        );
        final failedStartup = expectLater(startup, throwsStateError);
        await reachedHost.future.timeout(const Duration(seconds: 3));
        await runtime.close();
        await failedStartup;
        response.complete(480);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(runtime.latestRenderedUi, isNull);
        final backend = AbpComponent.runtimeDiagnostics;
        expect(backend['instances'], 0);
        expect(backend['stores'], 0);
        expect(backend['pendingHostRequests'], 0);
        expect(backend['renderedUiBytes'], 0);
        expect((backend['cache'] as Map)['activeCompiledObjects'], 0);
      },
    );
  }

  test('failed startup releases its worker and can be retried', () async {
    final runtime = WasmPluginRuntime(storage: const _DummyPluginStorage());
    final bytes = readWasmAbpFixture('ui_notification.wasm');
    await expectLater(
      runtime.start(
        pluginId: 'retry',
        pluginName: 'Retry',
        pluginVersion: '1',
        runtimeVersion: '1',
        entryBytes: bytes.sublist(0, bytes.length - 1),
        hostCall: (_, _) => null,
      ),
      throwsStateError,
    );
    await runtime.start(
      pluginId: 'retry',
      pluginName: 'Retry',
      pluginVersion: '1',
      runtimeVersion: '1',
      entryBytes: bytes,
      hostCall: (_, _) => null,
    );
    await runtime.close();
    expect(runtime.diagnostics['instantiated'], isFalse);
  });
  test('component UI notifications reach the existing host UI path', () async {
    final runtime = WasmPluginRuntime(storage: const _DummyPluginStorage());
    final rendered = Completer<String>();
    try {
      await runtime.start(
        pluginId: 'notification_component',
        pluginName: 'Notification',
        pluginVersion: '1',
        runtimeVersion: '1',
        entryBytes: readWasmAbpFixture('ui_notification.wasm'),
        hostCall: (method, arguments) {
          if (method == 'ui.render' && !rendered.isCompleted) {
            rendered.complete(arguments.single as String);
          }
          return null;
        },
      );
      expect(
        await rendered.future.timeout(const Duration(seconds: 2)),
        contains('Background'),
      );
    } finally {
      await runtime.close();
    }
  });

  test('API Level 4 uses WASI 0.3 through the shared runtime', () async {
    final runtime = WasmPluginRuntime(storage: const _DummyPluginStorage());
    try {
      await runtime.start(
        pluginId: 'wasi_p3_component',
        pluginName: 'WASI 0.3',
        pluginVersion: '1',
        runtimeVersion: '1',
        apiLevel: 4,
        entryBytes: readWasmAbpFixture('wasi_p3_environment.wasm'),
        hostCall: (_, _) => null,
      );
      expect(runtime.diagnostics['instantiated'], isTrue);
    } finally {
      await runtime.close();
    }
  });

  test('opening a plugin renders to a nonempty root target', () async {
    final runtime = WasmPluginRuntime(storage: const _DummyPluginStorage());
    try {
      await runtime.start(
        pluginId: 'render_target',
        pluginName: 'Render target',
        pluginVersion: '1',
        runtimeVersion: '1',
        apiLevel: 4,
        entryBytes: File(
          'test/features/plugins/runtime/fixtures/render_target.wasm',
        ).readAsBytesSync(),
        hostCall: (_, _) => null,
      );
      expect(await runtime.renderUi(elementId: ''), isNull);
      expect(await runtime.renderUi(), contains('"target_id":"root"'));
    } finally {
      await runtime.close();
    }
  });

  test('slow native UI render keeps the calling isolate responsive', () async {
    final runtime = WasmPluginRuntime(storage: const _DummyPluginStorage());
    try {
      await runtime.start(
        pluginId: 'slow_component',
        pluginName: 'Slow',
        pluginVersion: '1',
        runtimeVersion: '1',
        entryBytes: File(
          'test/features/plugins/runtime/fixtures/slow_ui_render.wasm',
        ).readAsBytesSync(),
        hostCall: (_, _) => null,
      );
      var renderCompleted = false;
      final rendering = runtime.renderUi().whenComplete(() {
        renderCompleted = true;
      });
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(
        renderCompleted,
        isFalse,
        reason: 'UI events must run while synchronous native work continues',
      );
      await rendering.timeout(const Duration(seconds: 2));
    } finally {
      await runtime.close();
    }
  });

  test('WasmPluginRuntime instantiates WebAssembly component model', () async {
    final runtime = WasmPluginRuntime(storage: const _DummyPluginStorage());
    final compBytes = Uint8List.fromList([
      0x00,
      0x61,
      0x73,
      0x6d,
      0x0d,
      0x00,
      0x01,
      0x00,
    ]);

    await runtime.start(
      pluginId: 'test_component',
      pluginName: 'Test Component',
      pluginVersion: '1.0.0',
      runtimeVersion: '1.0.0',
      entryBytes: compBytes,
      hostCall: (method, args) async => null,
    );

    expect(runtime.diagnostics['engine'], equals('wasm_abp'));
    expect(runtime.diagnostics['format'], equals('component_model'));
    expect(runtime.diagnostics['running'], isTrue);
    expect(runtime.diagnostics['instantiated'], isTrue);

    await runtime.close();
    expect(runtime.diagnostics['running'], isFalse);
  });
}

class _DummyPluginStorage implements PluginStorage {
  const _DummyPluginStorage();

  @override
  String? nativePath(String pluginId, PluginStoragePath path) => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
