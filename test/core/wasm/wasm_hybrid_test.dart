import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:oronbox/src/core/wasm/wasm_runtime.dart';
import 'package:wasm_abp/wasm_abp.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a busy hybrid instance keeps diagnostics and other Core instances responsive', () async {
    final scope = WasmRuntime.shared.openScope('hybrid-concurrency');
    final bytes = await File('test/core/wasm/fixtures/hybrid.wasm')
        .readAsBytes();
    try {
      final busy = await scope.instantiate(bytes);
      final other = await scope.instantiate(bytes);
      final running = busy.callNumbersAsync('spin', [2000000000]);
      var observedBusy = false;
      for (var i = 0; i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
        if ((WasmAbpEngine.shared.diagnostics['busyInstances'] as int) > 0) {
          observedBusy = true;
          break;
        }
      }
      expect(observedBusy, true);
      expect(other.call('add', [0, 0]), [0]);
      expect(WasmAbpEngine.shared.diagnostics['busyInstances'], 1);
      busy.dispose();
      expect(await running, [1999999999]);
      expect(await other.callNumbersAsync('add', [1.5, 2.25]), [3.75]);
    } finally {
      scope.dispose();
    }
  });

  test(
    'WASI preopens enforce package read-only and writable sandbox roots',
    () async {
      final root = await Directory.systemTemp.createTemp('hybrid-sandbox-');
      final scope = WasmRuntime.shared.openScope('hybrid-sandbox');
      try {
        for (final name in ['plugin', 'data', 'cache', 'temp']) {
          await Directory('${root.path}/$name').create();
        }
        await File('${root.path}/plugin/source.txt').writeAsString('package');
        await File('${root.path}/outside.txt').writeAsString('outside');
        final instance = await scope.instantiate(
          await File('test/core/wasm/fixtures/hybrid.wasm').readAsBytes(),
          preopens: {
            for (final name in ['plugin', 'data', 'cache', 'temp'])
              '/$name': '${root.path}/$name',
          },
        );
        instance.call('_initialize');
        Future<int> open(String path, {bool write = false}) async {
          instance.memory().write(
            16384,
            Uint8List.fromList([...utf8.encode(path), 0]),
          );
          return (await instance.callNumbersAsync('open_path', [
            16384,
            write ? 1 : 0,
          ])).single.toInt();
        }

        expect(await open('/plugin/source.txt'), 0);
        expect(await open('/plugin/source.txt', write: true), lessThan(0));
        expect(await open('/plugin/new.txt', write: true), lessThan(0));
        for (final name in ['data', 'cache', 'temp']) {
          expect(await open('/$name/output.txt', write: true), 0);
          expect(File('${root.path}/$name/output.txt').existsSync(), true);
        }
        expect(await open('/data/../outside.txt', write: true), lessThan(0));
        expect(await open('/outside.txt'), lessThan(0));
        expect(
          await File('${root.path}/outside.txt').readAsString(),
          'outside',
        );
        expect(await instance.callNumbersAsync('add', [1.5, 2.25]), [3.75]);
        instance.memory().write(16384, Uint8List.fromList([0, 128, 255]));
        expect(instance.memory().read(16384, 3), [0, 128, 255]);
        instance.dispose();
        expect(
          () => instance.callNumbersAsync('add', [1, 2]),
          throwsStateError,
        );
      } finally {
        scope.dispose();
        await root.delete(recursive: true);
      }
    },
  );
}
