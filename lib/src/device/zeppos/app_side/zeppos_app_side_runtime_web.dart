import 'dart:typed_data';

import 'zeppos_app_side_runtime.dart';

ZeppOsAppSideRuntime createAppSideRuntimeImplementation() =>
    const _WebZeppOsAppSideRuntime();

class _WebZeppOsAppSideRuntime implements ZeppOsAppSideRuntime {
  const _WebZeppOsAppSideRuntime();

  @override
  Map<String, Object?> get diagnostics => const {
    'engine': 'quickjs-emscripten',
    'running': false,
  };

  @override
  Future<void> start({
    required String pluginId,
    required String pluginName,
    required String pluginVersion,
    required String runtimeVersion,
    required Uint8List entryBytes,
    required String bootstrap,
    required ZeppOsHostCall hostCall,
  }) async {}

  @override
  Future<void> close() async {}

  @override
  Future<void> dispatchEvent(String event, String payload) async {}

  @override
  Future<Object?> invokeRegistered(
    String method, [
    List<Object?> arguments = const [],
  ]) async => null;
}
