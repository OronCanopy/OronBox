import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oronbox/src/core/wasm/wasm_compilation_cache.dart';
import 'package:oronbox/src/core/wasm/wasm_runtime.dart';
import 'package:wasm_abp/wasm_abp.dart';

import '../../support/wasm_abp_fixtures.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  test('normal core and both component entry points persist code and share manual clearing', () async {
    final root = await Directory.systemTemp.createTemp('oronbox-wasm-cache-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) async => root.path,
    );
    final scope = WasmRuntime().openScope('cache-integration');
    final components = <AbpComponent>[];
    final instances = <AbpComponentInstance>[];
    try {
      final bytes = Uint8List.fromList([
        0,
        97,
        115,
        109,
        1,
        0,
        0,
        0,
        1,
        7,
        1,
        96,
        2,
        126,
        126,
        1,
        126,
        3,
        2,
        1,
        0,
        7,
        7,
        1,
        3,
        97,
        100,
        100,
        0,
        0,
        10,
        9,
        1,
        7,
        0,
        32,
        0,
        32,
        1,
        124,
        11,
      ]);
      final core = await scope.instantiate(bytes);
      await WasmCompilationCache.prepare();
      for (final api in [3, 4]) {
        final component = AbpComponent.compile(
          readWasmAbpFixture('ui_notification.wasm'),
          apiLevel: api,
        );
        components.add(component);
        final instance = component.instantiate();
        instances.add(instance);
        await instance.callOnLoad();
      }
      final compiled = Directory.fromUri(root.uri.resolve('wasm/compiled/'));
      final files = await compiled
          .list(recursive: true)
          .where((file) => file.path.endsWith('.cwasm'))
          .toList();
      expect(files, hasLength(2));
      expect(files.map((file) => file.parent.path).toSet(), hasLength(2));
      await WasmCompilationCache.clear();
      expect(await compiled.exists(), isFalse);
      expect(core.call('add', [20, 22]), [42]);
      for (final instance in instances) {
        expect(instance.getRenderedUi(), contains('Background'));
      }
      scope.dispose();
      for (final instance in instances) {
        instance.dispose();
      }
      for (final component in components) {
        component.dispose();
      }
      await scopeForReload(bytes);
      expect(
        await compiled
            .list(recursive: true)
            .where((file) => file.path.endsWith('.cwasm'))
            .toList(),
        hasLength(1),
      );
    } finally {
      scope.dispose();
      for (final instance in instances) {
        instance.dispose();
      }
      for (final component in components) {
        component.dispose();
      }
      WasmAbpEngine.shared.configureCache(null);
      if (AbpComponent.isRuntimeLoaded) AbpComponent.configureCache(null);
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      await root.delete(recursive: true);
    }
  });
}

Future<void> scopeForReload(Uint8List bytes) async {
  final scope = WasmRuntime().openScope('reload');
  try {
    await scope.instantiate(bytes);
  } finally {
    scope.dispose();
  }
}
