import 'dart:typed_data';
import 'dart:convert';

import 'package:oronbox/src/core/javascript/quickjs_wasm_runtime.dart';

import 'zeppos_app_side_runtime.dart';

ZeppOsAppSideRuntime createAppSideRuntimeImplementation() =>
    _WasmQuickJsZeppOsAppSideRuntime();

class _WasmQuickJsZeppOsAppSideRuntime implements ZeppOsAppSideRuntime {
  final _runtime = QuickJsWasmRuntime();

  @override
  Map<String, Object?> get diagnostics => _runtime.diagnostics;

  @override
  Future<void> start({
    required String pluginId,
    required String pluginName,
    required String pluginVersion,
    required String runtimeVersion,
    required Uint8List entryBytes,
    required String bootstrap,
    required ZeppOsHostCall hostCall,
  }) async {
    try {
      await _runtime.start(
        owner: 'zeppos.appside.$pluginId',
        bootstrap: bootstrap,
        hostCall: hostCall,
      );
      if (bootstrap.isNotEmpty) {
        await _runtime.invoke('__obSetRuntimeGlobals', [
          pluginId,
          pluginName,
          pluginVersion,
          runtimeVersion,
        ]);
      }
      await _runtime.evaluate(utf8.decode(entryBytes), name: 'index.js');
    } catch (_) {
      await close();
      rethrow;
    }
  }

  @override
  Future<void> dispatchEvent(String event, String payload) async {
    await _runtime.invoke('__obDispatchEvent', [event, payload]);
  }

  @override
  Future<Object?> invokeRegistered(
    String method, [
    List<Object?> arguments = const [],
  ]) => _runtime.invoke('__obInvokeRegistered', [method, arguments]);

  @override
  Future<void> close() => _runtime.close();
}
