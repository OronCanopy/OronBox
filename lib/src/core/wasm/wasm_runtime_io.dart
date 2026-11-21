import 'package:flutter/services.dart';
import 'package:wasm_abp/wasm_abp.dart';

import 'wasm_compatibility.dart';
import 'wasm_compilation_cache.dart';

final class WasmRuntime {
  WasmRuntime({WasmCompatibility? compatibility})
    : _compatibility = compatibility ?? WasmCompatibility.shared;

  final WasmCompatibility _compatibility;

  static final WasmRuntime shared = WasmRuntime();
  Map<String, Object?> get diagnostics => {
    if (WasmAbpEngine.isLoaded) 'native': WasmAbpEngine.shared.diagnostics,
  };

  WasmScope openScope(String owner) => WasmScope._(this, owner);

  Future<WasmAbpModule> _compile(Uint8List bytes) async {
    await WasmCompilationCache.prepare();
    return WasmAbpEngine.shared.compileAsync(bytes);
  }
}

final class WasmScope {
  WasmScope._(this._runtime, this.owner);

  final WasmRuntime _runtime;
  final String owner;
  final Set<ScopedWasmInstance> _instances = {};
  bool _disposed = false;

  bool get isDisposed => _disposed;

  Future<ScopedWasmInstance> instantiateAsset(String assetPath) async {
    _ensureActive();
    final data = await rootBundle.load(assetPath);
    return instantiate(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
  }

  Future<ScopedWasmInstance> instantiate(
    Uint8List bytes, {
    bool withWasi = true,
    Map<String, String> preopens = const {},
  }) => _runtime._compatibility.run('core', () async {
    _ensureActive();
    final module = await _runtime._compile(bytes);
    late final WasmAbpInstance instance;
    try {
      _ensureActive();
      // Core assets such as QuickJS import WASI Preview 1.
      instance = await module.instantiateAsync(
        withWasi: withWasi,
        preopens: preopens,
      );
    } finally {
      module.dispose();
    }
    if (_disposed) {
      instance.dispose();
      throw StateError('WASM scope "$owner" was disposed during startup');
    }

    late final ScopedWasmInstance scoped;
    scoped = ScopedWasmInstance._(instance, () => _instances.remove(scoped));
    _instances.add(scoped);
    return scoped;
  });

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final instance in _instances.toList(growable: false)) {
      instance.dispose();
    }
    _instances.clear();
  }

  void _ensureActive() {
    if (_disposed) throw StateError('WASM scope "$owner" is disposed');
  }
}

final class ScopedWasmInstance {
  ScopedWasmInstance._(this._instance, this._onDispose);

  final WasmAbpInstance _instance;
  final void Function() _onDispose;
  bool _disposed = false;

  List<int> call(String name, [List<int> arguments = const []]) {
    _ensureActive();
    return _instance.call(name, arguments);
  }

  Future<List<num>> callNumbersAsync(String name, List<num> arguments) {
    _ensureActive();
    return _instance.callNumbersAsync(name, arguments);
  }

  WasmMemoryView memory([String name = 'memory']) {
    _ensureActive();
    return WasmMemoryView._(_instance.getMemory(name));
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _instance.dispose();
    _onDispose();
  }

  void _ensureActive() {
    if (_disposed) throw StateError('WASM instance is disposed');
  }
}

final class WasmMemoryView {
  WasmMemoryView._(this._memory);
  final WasmAbpMemory _memory;

  Uint8List read(int offset, int length) => _memory.read(offset, length);
  void write(int offset, Uint8List data) => _memory.write(offset, data);
}
