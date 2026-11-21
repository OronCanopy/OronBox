import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:oronbox/src/core/wasm/wasm_runtime.dart';
import 'package:oronbox/src/core/wasm/wasm_compilation_cache.dart';
import 'package:wasm_abp/wasm_abp.dart';

Uint8List additionModule() => Uint8List.fromList([
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('uncached scope releases its compiled module and instance', () async {
    final engine = WasmAbpEngine.shared;
    final before = engine.diagnostics;
    final scope = WasmRuntime.shared.openScope('uncached');
    try {
      final instance = await scope.instantiate(additionModule());
      expect(instance.call('add', [20, 22]), [42]);
    } finally {
      scope.dispose();
    }
    final after = engine.diagnostics;
    expect(after['instances'], before['instances']);
    expect(after['modules'], before['modules']);
  });

  test('numeric calls preserve floating-point arguments and results', () async {
    final bytes = additionModule();
    // Change the three i64 types and add instruction to f64.
    bytes[13] = 0x7c;
    bytes[14] = 0x7c;
    bytes[16] = 0x7c;
    bytes[bytes.length - 2] = 0xa0;
    final scope = WasmRuntime.shared.openScope('numeric');
    try {
      final instance = await scope.instantiate(bytes, withWasi: false);
      expect(await instance.callNumbersAsync('add', [1.5, 2.25]), [3.75]);
      await expectLater(
        instance.callNumbersAsync('add', [1e308, 1e308]),
        throwsA(isA<WasmAbpException>()),
      );
    } finally {
      scope.dispose();
    }
  });

  test('failed instantiation releases an uncached module', () async {
    final before = WasmAbpEngine.shared.diagnostics;
    final scope = WasmRuntime.shared.openScope('failed-start');
    // A valid module whose start function traps.
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
      4,
      1,
      96,
      0,
      0,
      3,
      2,
      1,
      0,
      8,
      1,
      0,
      10,
      5,
      1,
      3,
      0,
      0,
      11,
    ]);
    try {
      await expectLater(
        scope.instantiate(bytes),
        throwsA(isA<WasmAbpException>()),
      );
    } finally {
      scope.dispose();
    }
    final after = WasmAbpEngine.shared.diagnostics;
    expect(after['modules'], before['modules']);
    expect(after['instances'], before['instances']);
  });

  test(
    'identical active modules share code and survive disk cache clearing',
    () async {
      final engine = WasmAbpEngine.shared;
      final before = engine.diagnostics;
      final scope = WasmRuntime().openScope('sharing');
      try {
        final first = await scope.instantiate(additionModule());
        final second = await scope.instantiate(additionModule());
        final cache = engine.diagnostics['cache'] as Map;
        final previous = before['cache'] as Map;
        expect(cache['memoryHits'], (previous['memoryHits'] as int) + 1);
        await WasmCompilationCache.clear();
        expect(first.call('add', [4, 5]), [9]);
        expect(second.call('add', [20, 22]), [42]);
      } finally {
        scope.dispose();
      }
      expect(engine.diagnostics['modules'], before['modules']);
      expect(engine.diagnostics['instances'], before['instances']);
      expect((engine.diagnostics['cache'] as Map)['activeCompiledObjects'], 0);
    },
  );

  test(
    'changed content executes independently while both instances are active',
    () async {
      final scope = WasmRuntime().openScope('changed-content');
      try {
        final first = await scope.instantiate(additionModule());
        final subtract = additionModule();
        subtract[subtract.length - 2] = 0x7d;
        final second = await scope.instantiate(subtract);
        expect(first.call('add', [40, 2]), [42]);
        expect(second.call('add', [40, 2]), [38]);
      } finally {
        scope.dispose();
      }
    },
  );

  test(
    'scope disposed during asynchronous compilation releases the result',
    () async {
      final engine = WasmAbpEngine.shared;
      final before = engine.diagnostics;
      final scope = WasmRuntime().openScope('cancelled-start');
      final loading = scope.instantiate(additionModule());
      scope.dispose();
      await expectLater(loading, throwsStateError);
      expect(engine.diagnostics['modules'], before['modules']);
      expect(engine.diagnostics['instances'], before['instances']);
    },
  );

  test('disposed scope refuses startup without allocating a module', () async {
    final scope = WasmRuntime.shared.openScope('already-closed')..dispose();
    final before = WasmAbpEngine.shared.diagnostics;
    await expectLater(scope.instantiate(additionModule()), throwsStateError);
    expect(WasmAbpEngine.shared.diagnostics['modules'], before['modules']);
  });
}
