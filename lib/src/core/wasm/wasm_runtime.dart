import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:wasm_run_flutter/wasm_run_flutter.dart';

import 'wasm_unsupported_dialog.dart';

typedef WasmInstanceConfigurator = void Function(WasmInstanceBuilder builder);

final class WasmUnsupportedPlatformException implements Exception {
  const WasmUnsupportedPlatformException([
    this.message = 'WebAssembly runtime is not supported on this platform',
  ]);

  final String message;

  @override
  String toString() => 'WasmUnsupportedPlatformException: $message';
}

final class WasmRuntime {
  WasmRuntime._();

  static final WasmRuntime shared = WasmRuntime._();

  static bool? _isPlatformSupported;

  static bool get isPlatformSupported {
    if (_isPlatformSupported != null) return _isPlatformSupported!;

    if (!kIsWeb && Platform.isAndroid) {
      final sdk = _getAndroidSdkInt();
      // Android 8.0 (API 26) and 8.1 (API 27) seccomp rules omit __NR_membarrier
      if (sdk != null && (sdk == 26 || sdk == 27)) {
        _isPlatformSupported = false;
        return false;
      }
    }
    _isPlatformSupported = true;
    return true;
  }

  @visibleForTesting
  static void setPlatformSupportedForTesting(bool? supported) {
    _isPlatformSupported = supported;
  }

  static int? _getAndroidSdkInt() {
    try {
      final file = File('/system/build.prop');
      if (file.existsSync()) {
        for (final line in file.readAsLinesSync()) {
          if (line.startsWith('ro.build.version.sdk=')) {
            final val = int.tryParse(
              line.substring('ro.build.version.sdk='.length).trim(),
            );
            if (val != null) return val;
          }
        }
      }
    } catch (_) {}
    return null;
  }

  final Map<String, Future<WasmModule>> _compiledModules = {};
  Future<void>? _libraryInitialization;

  WasmScope openScope(String owner) => WasmScope._(this, owner);

  Future<WasmModule> _compile(
    Uint8List bytes, {
    required String? cacheKey,
  }) async {
    if (!isPlatformSupported) {
      unawaited(showWasmUnsupportedDialogIfNeeded());
      throw const WasmUnsupportedPlatformException(
        'WebAssembly JIT is disabled on Android 8.0/8.1 due to system seccomp policy',
      );
    }

    await _ensureLibraryInitialized();

    if (cacheKey == null) return compileWasmModule(bytes);

    final cached = _compiledModules[cacheKey];
    if (cached != null) return cached;

    late final Future<WasmModule> pending;
    pending = () async {
      try {
        return await compileWasmModule(bytes);
      } catch (_) {
        if (identical(_compiledModules[cacheKey], pending)) {
          _compiledModules.remove(cacheKey);
        }
        rethrow;
      }
    }();
    _compiledModules[cacheKey] = pending;
    return pending;
  }

  Future<void> _ensureLibraryInitialized() async {
    if (!isPlatformSupported) {
      throw const WasmUnsupportedPlatformException(
        'WebAssembly JIT is disabled on Android 8.0/8.1 due to system seccomp policy',
      );
    }

    final pending = _libraryInitialization;
    if (pending != null) {
      return pending;
    }

    final initialization = WasmRunLibrary.setUp(
      isFlutter: true,
      loadAsset: rootBundle.load,
    );
    _libraryInitialization = initialization;
    try {
      await initialization;
    } catch (_) {
      if (identical(_libraryInitialization, initialization)) {
        _libraryInitialization = null;
      }
      rethrow;
    }
  }
}

final class WasmScope {
  WasmScope._(this._runtime, this.owner);

  final WasmRuntime _runtime;
  final String owner;
  final Set<ScopedWasmInstance> _instances = {};
  bool _disposed = false;

  bool get isDisposed => _disposed;

  Future<ScopedWasmInstance> instantiateAsset(
    String assetPath, {
    WasmInstanceConfigurator? configure,
    WasiConfig? wasiConfig,
  }) async {
    _ensureActive();
    final data = await rootBundle.load(assetPath);
    return instantiate(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      cacheKey: 'asset:$assetPath',
      configure: configure,
      wasiConfig: wasiConfig,
    );
  }

  Future<ScopedWasmInstance> instantiate(
    Uint8List bytes, {
    String? cacheKey,
    WasmInstanceConfigurator? configure,
    WasiConfig? wasiConfig,
  }) async {
    _ensureActive();
    final module = await _runtime._compile(bytes, cacheKey: cacheKey);
    _ensureActive();

    final builder = module.builder(wasiConfig: wasiConfig);
    configure?.call(builder);
    final instance = await builder.build();
    if (_disposed) {
      instance.dispose();
      throw StateError('WASM scope "$owner" was disposed during startup');
    }

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
    _instances.clear();
  }

  void _ensureActive() {
    if (_disposed) throw StateError('WASM scope "$owner" is disposed');
  }
}

final class ScopedWasmInstance {
  ScopedWasmInstance._(this._instance, this._onDispose);

  final WasmInstance _instance;
  final void Function() _onDispose;
  bool _disposed = false;

  Stream<Uint8List> get stdout => _instance.stdout;
  Stream<Uint8List> get stderr => _instance.stderr;

  WasmFunction function(String name) {
    _ensureActive();
    final function = _instance.getFunction(name);
    if (function == null) {
      throw StateError('WASM function "$name" is not exported');
    }
    return function;
  }

  WasmFunction? functionOrNull(String name) {
    _ensureActive();
    return _instance.getFunction(name);
  }

  WasmMemory memory(String name) {
    _ensureActive();
    final memory = _instance.getMemory(name);
    if (memory == null) {
      throw StateError('WASM memory "$name" is not exported');
    }
    return memory;
  }

  List<Object?> call(String name, [List<Object?> arguments = const []]) {
    return function(name).call(arguments);
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
