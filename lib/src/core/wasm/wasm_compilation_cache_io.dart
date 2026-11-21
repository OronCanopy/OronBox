import 'dart:io';
import 'dart:isolate';

import 'wasm_compatibility.dart';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wasm_abp/wasm_abp.dart';

final class WasmCompilationCache {
  static Future<String?>? _directory;
  static Future<void> _operations = Future.value();
  static bool _corePrepared = false;

  static Future<String?> _resolveDirectory() async {
    try {
      final cache = await getApplicationCacheDirectory();
      return Directory.fromUri(cache.uri.resolve('wasm/compiled/')).path;
    } on MissingPluginException {
      return null;
    } on MissingPlatformDirectoryException {
      return null;
    } on PlatformException {
      return null;
    } on FileSystemException {
      return null;
    }
  }

  static Future<void> _exclusive(Future<void> Function() operation) {
    final result = _operations.then((_) => operation());
    _operations = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  static Future<String?> prepare() async {
    await _exclusive(() async {
      if (_corePrepared) return;
      final directory = await (_directory ??= _resolveDirectory());
      await _configure(directory);
      _corePrepared = true;
    });
    return _directory!;
  }

  static void inheritConfiguration(String? directory) {
    WasmCompatibility.inheritAuthorization();
    // Native cache state is process-wide. The root isolate prepares it first.
    _directory = Future.value(directory);
    _corePrepared = true;
  }

  static Future<void> _configure(String? directory) async {
    // Both API groups share the same process-wide native cache configuration.
    WasmAbpEngine.shared;
    await Isolate.run(() => WasmAbpEngine.shared.configureCache(directory));
  }

  static Future<void> clear() => _exclusive(() async {
    final directory = await (_directory ??= _resolveDirectory());
    if (directory == null) return;
    try {
      // Native configuration waits for readers before suspending disk writes.
      if (WasmAbpEngine.isLoaded || AbpComponent.isRuntimeLoaded) {
        await _configure(null);
      }
      final root = Directory(directory);
      if (await root.exists()) await root.delete(recursive: true);
    } finally {
      if (WasmAbpEngine.isLoaded || AbpComponent.isRuntimeLoaded) {
        await _configure(directory);
      }
    }
  });
}
