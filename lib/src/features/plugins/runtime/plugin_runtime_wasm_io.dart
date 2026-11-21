import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:oronbox/src/core/wasm/wasm_compilation_cache.dart';
import 'package:oronbox/src/features/plugins/storage/plugin_storage.dart';

import 'package:oronbox/src/core/wasm/wasm_compatibility.dart';

import 'plugin_runtime.dart';
import 'plugin_component_worker.dart';
import 'plugin_wasi_sandbox.dart';

final class WasmPluginRuntime implements PluginRuntime {
  WasmPluginRuntime({required this.storage});

  static final _log = Logger('WasmPluginRuntime');

  final PluginStorage storage;
  PluginComponentWorker? _componentWorker;
  var _closed = true;
  var _generation = 0;

  @override
  Map<String, Object?> get diagnostics => {
    'engine': 'wasm_abp',
    'format': 'component_model',
    'running': !_closed,
    'instantiated': _componentWorker != null,
    if (_componentWorker case final worker?) 'native': worker.nativeDiagnostics,
  };

  static bool _isComponentBinary(Uint8List bytes) {
    return bytes.length >= 8 &&
        bytes[0] == 0x00 &&
        bytes[1] == 0x61 &&
        bytes[2] == 0x73 &&
        bytes[3] == 0x6d &&
        bytes[4] == 0x0d &&
        bytes[5] == 0x00 &&
        bytes[6] == 0x01 &&
        bytes[7] == 0x00;
  }

  @override
  Future<void> start({
    required String pluginId,
    required String pluginName,
    required String pluginVersion,
    required String runtimeVersion,
    int apiLevel = 3,
    required Uint8List entryBytes,
    required PluginHostCall hostCall,
  }) async {
    await close();
    final generation = _generation;
    return WasmCompatibility.shared.run('component', () async {
      if (generation != _generation) {
        throw StateError('Plugin closed during startup');
      }
      _closed = false;

      if (_isComponentBinary(entryBytes)) {
        try {
          await WasmCompilationCache.prepare();
          final preopens = await createPluginWasiPreopens(
            pluginId: pluginId,
            storage: storage,
          );
          if (_closed || generation != _generation) {
            throw StateError('Plugin closed during startup');
          }
          // NG 插件以包目录为当前目录读取 manifest 和附加资源
          if (preopens['/plugin'] case final packagePath?) {
            preopens['.'] = packagePath;
          }
          final worker = await PluginComponentWorker.start(
            bytes: entryBytes,
            apiLevel: apiLevel,
            preopens: preopens,
            hostCall: (method, args) async => await hostCall(method, args),
            onReady: (worker) {
              if (_closed || generation != _generation) {
                unawaited(worker.close());
              } else {
                _componentWorker = worker;
              }
            },
            onFailure: (error) {
              if (_closed || generation != _generation) return;
              unawaited(
                Future.sync(() => hostCall('runtime.error', [error.toString()]))
                    .catchError((Object failure) {
                      _log.warning('Plugin failure reporting failed', failure);
                      return null;
                    }),
              );
            },
            onUi: (json) {
              if (_closed || generation != _generation) return;
              unawaited(
                Future.sync(() => hostCall('ui.render', [json])).then<void>(
                  (_) {},
                  onError: (Object error, StackTrace stackTrace) {
                    _log.warning('Plugin UI update failed', error, stackTrace);
                  },
                ),
              );
            },
          );
          if (_closed || generation != _generation) {
            await worker.close();
            throw StateError('Plugin closed during startup');
          }
          _componentWorker = worker;
          return;
        } catch (_) {
          if (generation == _generation) await close();
          rethrow;
        }
      }

      _closed = true;
      throw const FormatException(
        'AstroBox-NG plugins require a WebAssembly component',
      );
    });
  }

  @override
  String? get latestRenderedUi {
    return _componentWorker?.latestUi;
  }

  @override
  Future<String?> renderUi({String elementId = 'root'}) async {
    final instance = _componentWorker;
    if (instance == null) return null;
    final json = await instance.render(elementId);
    return json != null && json.isNotEmpty && json != '{}'
        ? json
        : instance.latestUi;
  }

  @override
  Future<void> invokeCallback(String callbackId, [Object? value]) async {
    final worker = _componentWorker;
    if (worker == null) throw StateError('Plugin is closed');
    final event = value is Map ? value['eventType']?.toString() : null;
    final payload = value is Map && value.containsKey('eventType')
        ? value['payload']
        : value;
    await worker.invoke(
      callbackId,
      event ?? 'CLICK',
      jsonEncode(payload ?? const {}),
    );
  }

  @override
  Future<void> dispatchEvent(String name, String payload) async {
    final worker = _componentWorker;
    if (worker == null) throw StateError('Plugin is closed');
    await worker.dispatch(name, payload);
  }

  @override
  Future<String> callExport(String name, List<Object?> args) async {
    final worker = _componentWorker;
    if (worker == null) throw StateError('Plugin is closed');
    return worker.callExport(name, args);
  }

  @override
  Future<void> close() async {
    _generation++;
    _closed = true;
    final worker = _componentWorker;
    _componentWorker = null;
    await worker?.close();
  }
}
