import 'dart:async';
import 'dart:typed_data';

typedef PluginHostCall = FutureOr<Object?> Function(
  String method,
  List<Object?> arguments,
);

abstract interface class PluginRuntime {
  Map<String, Object?> get diagnostics;

  Future<void> start({
    required String pluginId,
    required String pluginName,
    required String pluginVersion,
    required String runtimeVersion,
    int apiLevel = 3,
    required Uint8List entryBytes,
    required PluginHostCall hostCall,
  });

  Future<void> invokeCallback(String callbackId, [Object? value]);

  Future<void> dispatchEvent(String name, String payload);

  String? get latestRenderedUi => null;

  Future<String?> renderUi({String elementId = 'root'}) async => null;

  Future<String> callExport(String name, List<Object?> args);

  Future<void> close();
}
