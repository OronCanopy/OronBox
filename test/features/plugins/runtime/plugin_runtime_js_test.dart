import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:oronbox/src/features/plugins/runtime/plugin_runtime_js.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'closing immediately cancels pending startup and permits a fresh start',
    () async {
      final runtime = JavaScriptPluginRuntime();
      addTearDown(runtime.close);
      Future<void> start() => runtime.start(
        pluginId: 'cancelled',
        pluginName: 'Cancelled',
        pluginVersion: '1',
        runtimeVersion: '1',
        entryBytes: Uint8List.fromList(
          utf8.encode('globalThis.activate = () => {};'),
        ),
        hostCall: (_, _) => null,
      );
      final starting = start();
      final cancelled = expectLater(starting, throwsStateError);
      await runtime.close();
      await cancelled;
      expect(runtime.diagnostics['running'], false);
      await start();
      expect(runtime.diagnostics['running'], true);
    },
  );

  test(
    'module imports stay inside the plugin package and await top-level work',
    () async {
      final runtime = JavaScriptPluginRuntime(
        entryName: 'src/main.mjs',
        modules: {'src/value.mjs': 'export const value = 42;'},
      );
      addTearDown(runtime.close);
      final messages = <Object?>[];
      await runtime.start(
        pluginId: 'module',
        pluginName: 'Module',
        pluginVersion: '1',
        runtimeVersion: '1',
        entryBytes: Uint8List.fromList(
          utf8.encode('''
import {value} from './value.mjs';
await OronBox.storage.set('value', value);
globalThis.activate = async () => OronBox.ui.render(OronBox.ui.Text(atob(btoa('done'))));
'''),
        ),
        hostCall: (method, args) {
          messages.add([method, args]);
          return null;
        },
      );
      expect(messages.first, [
        'storage.set',
        ['value', 42],
      ]);
      expect((messages.last as List).first, 'ui.render');
      final invalid = JavaScriptPluginRuntime(entryName: 'main.mjs');
      addTearDown(invalid.close);
      await expectLater(
        invalid.start(
          pluginId: 'invalid',
          pluginName: 'Invalid',
          pluginVersion: '1',
          runtimeVersion: '1',
          entryBytes: Uint8List.fromList(
            utf8.encode("import value from '../outside.mjs';"),
          ),
          hostCall: (_, _) => null,
        ),
        throwsStateError,
      );
    },
  );

  test('timers fire, host bursts complete, and synchronous work leaves the caller responsive', () async {
    final runtime = JavaScriptPluginRuntime();
    addTearDown(runtime.close);
    final fired = Completer<void>();
    await runtime.start(
      pluginId: 'timers',
      pluginName: 'Timers',
      pluginVersion: '1',
      runtimeVersion: '1',
      entryBytes: Uint8List.fromList(
        utf8.encode('''
globalThis.activate = async () => {
  await Promise.all(Array.from({length: 600}, (_, i) => OronBox.storage.set(String(i), i)));
  OronBox.ui.callback(async () => {
    const start = Date.now();
    while (Date.now() - start < 200) {}
    return 42;
  });
  setTimeout(() => OronBox.storage.set('timer', true), 5);
};
'''),
      ),
      hostCall: (method, args) {
        if (args.firstOrNull == 'timer' && !fired.isCompleted) fired.complete();
        return null;
      },
    );
    await fired.future.timeout(const Duration(seconds: 2));
    var completed = false;
    final result = runtime
        .invokeRegistered('ob_callback_1', const [])
        .whenComplete(() => completed = true);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(completed, false);
    expect(await result, 42);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(runtime.diagnostics['hostRequests'], 0);
    await runtime.close();
    expect(runtime.diagnostics['timers'], 0);
  });

  test(
    'JS bootstrap awaits host Promises and returns callback results',
    () async {
      final runtime = JavaScriptPluginRuntime();
      addTearDown(runtime.close);
      final calls = <String>[];
      await runtime.start(
        pluginId: 'test.js',
        pluginName: 'Test',
        pluginVersion: '1',
        runtimeVersion: '1',
        entryBytes: Uint8List.fromList(
          utf8.encode('''
globalThis.activate = async () => {
  const setting = await OronBox.storage.get('name');
  await OronBox.ui.render(OronBox.ui.Button(setting, {
    onClick: async value => ({value, result: await OronBox.storage.get('number')})
  }));
};
'''),
        ),
        hostCall: (method, args) async {
          calls.add(method);
          if (method == 'storage.get') return args[0] == 'name' ? '天气' : 42;
          return null;
        },
      );
      expect(calls, ['storage.get', 'ui.render']);
      expect(await runtime.invokeRegistered('ob_callback_1', [true]), {
        'value': true,
        'result': 42,
      });
      expect(runtime.diagnostics['hostRequests'], 0);
      expect(runtime.diagnostics['operations'], 0);
    },
  );

  test(
    'closing a pending request cancels its caller and isolates reopening',
    () async {
      final runtime = JavaScriptPluginRuntime();
      addTearDown(runtime.close);
      final pending = Completer<Object?>();
      final reached = Completer<void>();
      final opening = runtime.start(
        pluginId: 'test.js',
        pluginName: 'Test',
        pluginVersion: '1',
        runtimeVersion: '1',
        entryBytes: Uint8List.fromList(
          utf8.encode('globalThis.activate = () => OronBox.storage.get("a");'),
        ),
        hostCall: (_, _) {
          reached.complete();
          return pending.future;
        },
      );
      final cancelled = expectLater(opening, throwsStateError);
      await reached.future;
      await runtime.close();
      await cancelled;
      await runtime.start(
        pluginId: 'test.js',
        pluginName: 'Test',
        pluginVersion: '1',
        runtimeVersion: '1',
        entryBytes: Uint8List.fromList(
          utf8.encode('globalThis.activate = () => {};'),
        ),
        hostCall: (_, _) => null,
      );
      pending.complete('late');
      await Future<void>.delayed(Duration.zero);
      expect(runtime.diagnostics['running'], true);
      expect(runtime.diagnostics['hostRequests'], 0);
    },
  );
}
