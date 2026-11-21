import 'dart:typed_data';

import 'zeppos_app_side_runtime_stub.dart'
    if (dart.library.io) 'zeppos_app_side_runtime_io.dart'
    if (dart.library.js_interop) 'zeppos_app_side_runtime_web.dart';

typedef ZeppOsHostCall = Future<Object?> Function(
  String method,
  List<Object?> arguments,
);

abstract class ZeppOsAppSideRuntime {
  Map<String, Object?> get diagnostics;

  Future<void> start({
    required String pluginId,
    required String pluginName,
    required String pluginVersion,
    required String runtimeVersion,
    required Uint8List entryBytes,
    required String bootstrap,
    required ZeppOsHostCall hostCall,
  });

  Future<void> close();

  Future<void> dispatchEvent(String event, String payload);

  Future<Object?> invokeRegistered(
    String method, [
    List<Object?> arguments = const [],
  ]);
}

ZeppOsAppSideRuntime createZeppOsAppSideRuntime() =>
    createAppSideRuntimeImplementation();
