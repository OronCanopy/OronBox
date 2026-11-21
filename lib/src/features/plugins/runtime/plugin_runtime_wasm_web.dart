import 'dart:typed_data';

import 'package:oronbox/src/features/plugins/storage/plugin_storage.dart';

import 'plugin_runtime.dart';

final class WasmPluginRuntime implements PluginRuntime {
  WasmPluginRuntime({required PluginStorage storage});

  @override
  Map<String, Object?> get diagnostics => const {'running': false};

  @override
  Future<void> start({
    required String pluginId,
    required String pluginName,
    required String pluginVersion,
    required String runtimeVersion,
    int apiLevel = 3,
    required Uint8List entryBytes,
    required PluginHostCall hostCall,
  }) async => throw UnsupportedError(
    'AstroBox-NG WebAssembly components are unavailable in the browser',
  );

  @override
  String? get latestRenderedUi => null;

  @override
  Future<String?> renderUi({String elementId = 'root'}) async => null;

  @override
  Future<void> invokeCallback(String callbackId, [Object? value]) async =>
      throw StateError('Plugin is closed');

  @override
  Future<void> dispatchEvent(String name, String payload) async {}

  @override
  Future<String> callExport(String name, List<Object?> args) async =>
      throw StateError('Plugin is closed');

  @override
  Future<void> close() async {}
}
