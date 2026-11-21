import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oronbox/src/core/storage/app_data_directory_io.dart';
import 'package:oronbox/src/core/wasm/wasm_compatibility.dart';
import 'package:oronbox/src/core/wasm/wasm_compatibility_probe.dart';
import 'package:oronbox/src/core/wasm/wasm_runtime.dart';
import 'package:wasm_abp/wasm_abp.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late IoAppDataDirectory directory;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('oronbox-compatibility-');
    directory = IoAppDataDirectory(root);
  });
  tearDown(() => root.delete(recursive: true));

  WasmCompatibility controller({bool highRisk = true}) => WasmCompatibility(
    directory: directory,
    android: true,
    highRisk: highRisk,
  );
  Future<String?> savedState() async {
    final bytes = await directory.read('compatibility.json');
    return bytes == null
        ? null
        : (jsonDecode(utf8.decode(bytes)) as Map)['state'] as String;
  }

  test('only Android 8~9 with Linux 4.x prompts proactively', () async {
    for (final sdk in [24, 25, 26, 27, 28, 29, 36]) {
      for (final kernel in ['3.10.0', '4.9.123', '4.19.0', '5.4.0', '6.1.0']) {
        expect(
          WasmCompatibility.isHighRisk(sdk, kernel),
          sdk >= 26 && sdk <= 28 && kernel.startsWith('4.'),
        );
      }
    }
    expect(WasmCompatibility.isHighRisk(null, '4.9'), isFalse);
    final risk = controller();
    await risk.initialize();
    expect(risk.shouldPromptOnStartup, isTrue);
    final ordinary = controller(highRisk: false);
    await ordinary.initialize();
    expect(ordinary.shouldPromptOnStartup, isFalse);
    await ordinary.ensureAllowed();
  });

  test(
    'deferral survives restart and blocks native compilation before loading',
    () async {
      await controller().initialize();
      final first = controller();
      await first.initialize();
      await first.defer();
      final restarted = controller();
      await restarted.initialize();
      expect(restarted.shouldPromptOnStartup, isFalse);
      final scope = WasmRuntime(compatibility: restarted).openScope('paused');
      addTearDown(scope.dispose);
      await expectLater(
        scope.instantiate(Uint8List(0)),
        throwsA(isA<WasmCompatibilityRequired>()),
      );
      expect(await savedState(), 'deferred');
      var prompts = 0;
      restarted.requestTest = () async {
        prompts++;
        await restarted.defer();
        return false;
      };
      await expectLater(
        restarted.ensureAllowed(interactive: true),
        throwsA(isA<WasmCompatibilityRequired>()),
      );
      expect(prompts, 1);
      await expectLater(
        restarted.ensureAllowed(),
        throwsA(isA<WasmCompatibilityRequired>()),
      );
      expect(prompts, 1);
    },
  );

  test(
    'interrupted normal startup and explicit test recover silently as deferred',
    () async {
      for (final highRisk in [true, false]) {
        await directory.write(
          'compatibility.json',
          Uint8List.fromList(utf8.encode('{"state":"running"}')),
        );
        final restarted = controller(highRisk: highRisk);
        await restarted.initialize();
        expect(restarted.state, WasmCompatibilityState.deferred);
        expect(restarted.shouldPromptOnStartup, isFalse);
        expect(await savedState(), 'deferred');
        await expectLater(
          restarted.run('core', () async => fail('Native code was reached')),
          throwsA(isA<WasmCompatibilityRequired>()),
        );
      }
    },
  );

  test('ordinary errors restore prior state and allow a later test', () async {
    final runtime = controller();
    await runtime.initialize();
    for (final state in [
      WasmCompatibilityState.unknown,
      WasmCompatibilityState.deferred,
    ]) {
      if (state == WasmCompatibilityState.deferred) await runtime.defer();
      await expectLater(
        runtime.test(() async {
          expect(await savedState(), 'running');
          throw StateError('Asset could not be read');
        }),
        throwsStateError,
      );
      expect(runtime.state, state);
      expect(await savedState(), state.name);
    }
    await runtime.test(() async {});
    expect(await savedState(), 'ready');
    await runtime.ensureAllowed();
  });

  test(
    'concurrent entry points keep the crash marker until both finish',
    () async {
      final runtime = controller(highRisk: false);
      final firstEntered = Completer<void>();
      final secondEntered = Completer<void>();
      final firstRelease = Completer<void>();
      final secondRelease = Completer<void>();
      final first = runtime.run('core', () async {
        firstEntered.complete();
        await firstRelease.future;
      });
      await firstEntered.future;
      final second = runtime.run('component-legacy', () async {
        secondEntered.complete();
        await secondRelease.future;
      });
      await secondEntered.future;
      firstRelease.complete();
      await first;
      expect(await savedState(), 'running');
      secondRelease.complete();
      await second;
      expect(await savedState(), 'ready');
    },
  );

  test('ready devices still mark the first startup of each native backend per process', () async {
    final runtime = controller(highRisk: false);
    await runtime.run(
      'core',
      () async => expect(await savedState(), 'running'),
    );
    await runtime.run('core', () async => expect(await savedState(), 'ready'));
    await runtime.run(
      'component-legacy',
      () async => expect(await savedState(), 'running'),
    );
    final nextProcess = controller();
    await nextProcess.run(
      'core',
      () async => expect(await savedState(), 'running'),
    );
    expect(await savedState(), 'ready');
  });

  test(
    'callbacks retained after startup guard later native backends again',
    () async {
      final runtime = controller(highRisk: false);
      late Future<void> Function() callback;
      await runtime.run('core', () async {
        callback = Zone.current.bindCallback(
          () => runtime.run('component-legacy', () async {
            expect(await savedState(), 'running');
          }),
        );
      });
      expect(await savedState(), 'ready');
      await callback();
      expect(await savedState(), 'ready');
    },
  );

  test('interactive callers share one prompt and resume only after a successful test', () async {
    final runtime = controller();
    var prompts = 0;
    final shown = Completer<void>();
    final answer = Completer<void>();
    runtime.requestTest = () async {
      prompts++;
      shown.complete();
      await answer.future;
      await runtime.test(() async {
        await runtime.run('core', () async {});
      });
      return true;
    };
    final first = runtime.ensureAllowed(interactive: true);
    await shown.future;
    final second = runtime.ensureAllowed(interactive: true);
    await expectLater(
      runtime.ensureAllowed(),
      throwsA(isA<WasmCompatibilityRequired>()),
    );
    answer.complete();
    await Future.wait([first, second]);
    expect(prompts, 1);
    expect(await savedState(), 'ready');
  });

  test('corrupt records pause safely and a failed marker write prevents native entry', () async {
    await directory.write('compatibility.json', Uint8List.fromList([123]));
    final runtime = controller();
    await runtime.initialize();
    expect(runtime.state, WasmCompatibilityState.deferred);
    await directory.remove('compatibility.json');
    await Directory('${root.path}/compatibility.json').create(recursive: true);
    var entered = false;
    await expectLater(
      runtime.test(() async {
        entered = true;
      }),
      throwsA(isA<FileSystemException>()),
    );
    expect(entered, isFalse);
    await Directory('${root.path}/compatibility.json').delete();
    await runtime.test(() async {});
    expect(await savedState(), 'ready');
  });

  test(
    'non-Android platforms never write Android compatibility state',
    () async {
      final runtime = WasmCompatibility(directory: directory, android: false);
      var prompts = 0;
      runtime.requestTest = () async {
        prompts++;
        return false;
      };
      await runtime.initialize();
      await runtime.ensureAllowed(interactive: true);
      await runtime.run('core', () async {});
      await runtime.test(() async {});
      expect(prompts, 0);
      expect(await directory.files(), isEmpty);
    },
  );

  test(
    'real icon WebP test resumes a paused device and releases native instances',
    () async {
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (_) async => root.path,
      );
      addTearDown(() {
        WasmAbpEngine.shared.configureCache(null);
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      });
      final runtime = controller();
      await runtime.initialize();
      await runtime.defer();
      final before = WasmAbpEngine.shared.diagnostics;
      await testWasmCompatibility(compatibility: runtime);
      expect(await savedState(), 'ready');
      final after = WasmAbpEngine.shared.diagnostics;
      expect(after['instances'], before['instances']);
      expect(after['modules'], before['modules']);
      expect(
        await Directory('${root.path}/wasm/compiled')
            .list(recursive: true)
            .where((file) => file.path.endsWith('.cwasm'))
            .length,
        1,
      );
    },
  );
}
