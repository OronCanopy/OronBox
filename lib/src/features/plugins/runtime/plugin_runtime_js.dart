import 'dart:convert';
import 'dart:typed_data';

import 'package:oronbox/src/core/javascript/quickjs_wasm_runtime.dart'
    if (dart.library.js_interop) 'quickjs_runtime_web.dart';

import 'plugin_js_bootstrap.dart';
import 'plugin_runtime.dart';

final class JavaScriptPluginRuntime implements PluginRuntime {
  JavaScriptPluginRuntime({
    this.entryName = 'main.js',
    this.modules = const {},
  });

  final String entryName;
  final Map<String, String> modules;
  final _runtime = QuickJsWasmRuntime();

  @override
  Map<String, Object?> get diagnostics => _runtime.diagnostics;

  @override
  Future<void> start({
    required String pluginId,
    required String pluginName,
    required String pluginVersion,
    required String runtimeVersion,
    int apiLevel = 1,
    required Uint8List entryBytes,
    required PluginHostCall hostCall,
  }) async {
    try {
      await _runtime.start(
        owner: 'plugin.$pluginId',
        bootstrap: oronBoxPluginBootstrap,
        hostCall: hostCall,
      );
      await _runtime.invoke('__obSetRuntimeGlobals', [
        pluginId,
        pluginName,
        pluginVersion,
        runtimeVersion,
      ]);
      await _runtime.evaluateEntry(
        utf8.decode(entryBytes),
        name: entryName,
        modules: modules,
      );
      await _runtime.invoke('__obStartPlugin');
    } catch (_) {
      await close();
      rethrow;
    }
  }

  @override
  Future<void> invokeCallback(String callbackId, [Object? value]) async {
    final payload = value is Map && value.containsKey('eventType')
        ? value['payload']
        : value;
    await invokeRegistered(callbackId, payload == null ? const [] : [payload]);
  }

  Future<Object?> invokeRegistered(String id, List<Object?> args) =>
      _runtime.invoke('__obInvokeRegistered', [id, args]);

  @override
  Future<void> dispatchEvent(String name, String payload) async {
    await _runtime.invoke('__obDispatchEvent', [name, payload]);
  }

  @override
  String? get latestRenderedUi => null;

  @override
  Future<String?> renderUi({String elementId = 'root'}) async => null;

  @override
  Future<String> callExport(String name, List<Object?> args) async =>
      jsonEncode(await invokeRegistered(name, args));

  @override
  Future<void> close() => _runtime.close();
}
