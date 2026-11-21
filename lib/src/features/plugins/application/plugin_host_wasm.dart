part of 'plugin_manager.dart';

extension _PluginHybridWasm on PluginManager {
  Future<Object?> _jsWasm(
    InstalledPlugin plugin,
    _PluginSession session,
    String method,
    List<Object?> args,
  ) async {
    if (plugin.manifest.runtime != PluginRuntimeType.hybrid) {
      throw UnsupportedError('Wasm is only available to hybrid plugins');
    }
    if (method == 'wasm.load') {
      final scope = session.wasmScope ??= WasmRuntime.shared.openScope(
        'plugin.hybrid.${plugin.manifest.id}',
      );
      final bytes = await (await _storage).readFile(
        plugin.manifest.id,
        PluginStoragePath.parse(args[0].toString()),
      );
      final withWasi = _jsonMap(args.elementAtOrNull(1))['wasi'] != false;
      final preopens = withWasi
          ? await createPluginWasiPreopens(
              pluginId: plugin.manifest.id,
              storage: await _storage,
            )
          : const <String, String>{};
      final instance = await scope.instantiate(
        bytes,
        withWasi: withWasi,
        preopens: preopens,
      );
      final id = 'wasm_${++session.nextWasm}';
      session.wasmInstances[id] = instance;
      return id;
    }
    if (method == 'wasm.dispose') {
      session.wasmInstances.remove(args[0].toString())?.dispose();
      return null;
    }
    final instance = session.wasmInstances[args[0].toString()];
    if (instance == null) throw StateError('Unknown Wasm instance');
    if (method == 'wasm.call') {
      return instance.callNumbersAsync(
        args[1].toString(),
        (args[2] as List).cast<num>(),
      );
    }
    final memory = instance.memory(args[1].toString());
    if (method == 'wasm.memory.read') {
      return base64Encode(
        memory.read((args[2] as num).toInt(), (args[3] as num).toInt()),
      );
    }
    memory.write((args[2] as num).toInt(), _bytes(args[3]));
    return null;
  }
}
