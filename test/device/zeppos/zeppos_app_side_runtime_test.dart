import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:oronbox/src/device/zeppos/app_side/zeppos_app_side_runtime.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'WasmQuickJsZeppOsAppSideRuntime executes JS and dispatches host calls',
    () async {
      final runtime = createZeppOsAppSideRuntime();
      expect(runtime.diagnostics['engine'], equals('quickjs-wasm'));
      expect(runtime.diagnostics['running'], isFalse);

      final hostCalls = <({String method, List<Object?> args})>[];
      final hostCallCompleter = Completer<void>();

      const bootstrap = '''
globalThis.__obSetRuntimeGlobals = function(id, name, ver, rtVer) {
  globalThis.__pluginId = id;
};
globalThis.__obDispatchEvent = function(event, payload) {
  globalThis.__lastEvent = {event, payload};
  sendMessage('OronBoxHost', JSON.stringify({
    requestId: 'req-event',
    method: 'event.received',
    args: [event, payload]
  }));
};
globalThis.__obSettleHostRequest = function(reqId, ok, res) {
  globalThis.__settled = {reqId, ok, res};
};
''';

      const entry = '''
sendMessage('OronBoxHost', JSON.stringify({
  requestId: 'req-1',
  method: 'app.init',
  args: ['ready', 123]
}));
''';

      await runtime.start(
        pluginId: 'test.app',
        pluginName: 'Test App',
        pluginVersion: '1.0.0',
        runtimeVersion: '1.0.0',
        entryBytes: Uint8List.fromList(utf8.encode(entry)),
        bootstrap: bootstrap,
        hostCall: (method, args) async {
          hostCalls.add((method: method, args: args));
          if (method == 'app.init') {
            return {'status': 'ok'};
          }
          if (method == 'event.received') {
            if (!hostCallCompleter.isCompleted) {
              hostCallCompleter.complete();
            }
            return null;
          }
          return null;
        },
      );

      expect(runtime.diagnostics['running'], isTrue);
      expect(hostCalls.length, equals(1));
      expect(hostCalls.first.method, equals('app.init'));
      expect(hostCalls.first.args, equals(['ready', 123]));

      // Dispatch event from host
      await runtime.dispatchEvent('test_event', jsonEncode({'hello': 'world'}));
      await hostCallCompleter.future.timeout(const Duration(seconds: 2));

      expect(hostCalls.length, equals(2));
      expect(hostCalls[1].method, equals('event.received'));
      expect(hostCalls[1].args[0], equals('test_event'));

      await runtime.close();
      expect(runtime.diagnostics['running'], isFalse);
    },
  );
}
