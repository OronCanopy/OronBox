import 'dart:js_interop';

import 'package:flutter/services.dart';

import 'wasm_compatibility.dart';

@JS('OronBoxPluginRuntime.instantiateCore')
external JSPromise<_BrowserWasm> _instantiate(
  JSUint8Array bytes,
  bool withWasi,
);

extension type _BrowserWasm._(JSObject _) implements JSObject {
  external JSArray<JSNumber> call(String name, JSArray<JSNumber> arguments);
  external JSUint8Array read(String name, int offset, int length);
  external void write(String name, int offset, JSUint8Array data);
}

final class WasmRuntime {
  WasmRuntime({WasmCompatibility? compatibility});

  static final shared = WasmRuntime();
  Map<String, Object?> get diagnostics => const {};

  WasmScope openScope(String owner) => WasmScope._(owner);
}

final class WasmScope {
  WasmScope._(this.owner);

  final String owner;
  final _instances = <ScopedWasmInstance>{};
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
  }) async {
    _ensureActive();
    if (preopens.isNotEmpty) {
      throw UnsupportedError(
        'Wasm filesystem mounts are unavailable in the browser',
      );
    }
    final instance = await _instantiate(bytes.toJS, withWasi).toDart;
    _ensureActive();
    late final ScopedWasmInstance scoped;
    scoped = ScopedWasmInstance._(instance, () => _instances.remove(scoped));
    _instances.add(scoped);
    return scoped;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final instance in _instances.toList(growable: false)) {
      instance.dispose();
    }
  }

  void _ensureActive() {
    if (_disposed) throw StateError('WASM scope "$owner" is disposed');
  }
}

final class ScopedWasmInstance {
  ScopedWasmInstance._(this._instance, this._onDispose);

  _BrowserWasm? _instance;
  final void Function() _onDispose;

  _BrowserWasm get _active =>
      _instance ?? (throw StateError('WASM instance is disposed'));

  List<int> call(String name, [List<int> arguments = const []]) => [
    for (final result in _call(name, arguments)) result.toInt(),
  ];

  Future<List<num>> callNumbersAsync(String name, List<num> arguments) async =>
      _call(name, arguments);

  List<num> _call(String name, List<num> arguments) => [
    for (final result
        in _active
            .call(name, arguments.map((n) => n.toDouble().toJS).toList().toJS)
            .toDart)
      result.toDartDouble,
  ];

  WasmMemoryView memory([String name = 'memory']) =>
      WasmMemoryView._(this, name);

  void dispose() {
    if (_instance == null) return;
    _instance = null;
    _onDispose();
  }
}

final class WasmMemoryView {
  WasmMemoryView._(this._owner, this._name);

  final ScopedWasmInstance _owner;
  final String _name;

  Uint8List read(int offset, int length) =>
      _owner._active.read(_name, offset, length).toDart;

  void write(int offset, Uint8List data) =>
      _owner._active.write(_name, offset, data.toJS);
}
