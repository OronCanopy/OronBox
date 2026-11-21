part of 'plugin_manager.dart';

extension _PluginFiles on PluginManager {
  Future<T> _withSessionFiles<T>(
    String id,
    _PluginSession session,
    Future<T> Function() action,
  ) {
    final operation = session.fileOperations.then((_) {
      if (!identical(_sessions[id], session)) {
        throw StateError('Plugin session ended');
      }
      return action();
    });
    session.fileOperations = operation.then<void>((_) {}, onError: (_, _) {});
    return operation;
  }

  Future<Object?> _jsFileCall(
    String id,
    _PluginSession session,
    String method,
    List<Object?> args,
  ) => _withSessionFiles(id, session, () async {
    switch (method) {
      case 'file.read':
        return _readSandboxFile(id, args);
      case 'file.write':
        await _writeSandboxFile(id, args);
        return null;
      case 'file.list':
        return _listSandboxDirectory(id, args);
      case 'file.stat':
        return _statSandboxPath(id, args);
      case 'file.mkdir':
        await _mkdirSandboxPath(id, args);
        return null;
      case 'file.copy':
        await _copySandboxPath(id, args);
        return null;
      case 'file.move':
        await _moveSandboxPath(id, args);
        return null;
      case 'file.remove':
        await _removeSandboxPath(id, args);
        return null;
      default:
        throw UnsupportedError(method);
    }
  });

  Future<Map<String, String>> _javaScriptSources(String id) async {
    final storage = await _storage;
    final sources = <String, String>{};
    Future<void> readDirectory(String directory) async {
      for (final entry in await storage.listDirectory(
        id,
        PluginStoragePath.parse(directory),
      )) {
        if (entry.isDirectory) {
          await readDirectory(entry.path);
        } else if ({
          'js',
          'mjs',
          'cjs',
        }.contains(entry.path.split('.').last.toLowerCase())) {
          sources[entry.path.substring('/plugin/'.length)] = utf8.decode(
            await storage.readFile(id, PluginStoragePath.parse(entry.path)),
          );
        }
      }
    }

    await readDirectory('/plugin');
    return sources;
  }

  Future<Map<String, Object?>?> _pickSandboxFile(
    String pluginId,
    List<Object?> arguments,
  ) async {
    final session = _sessions[pluginId];
    if (session == null) throw StateError('Plugin session ended');
    final options = _jsonMap(arguments.firstOrNull);
    final response = await _requestHost(pluginId, 'pickFile', {
      'options': options,
    }, session: session);
    if (response['cancelled'] == true) return null;
    final bytes = _bytes(response['bytes']);
    final rawName = response['name']?.toString() ?? 'plugin-file';
    final name = rawName.replaceAll(RegExp(r'[/\\\x00]'), '_');
    final path = PluginStoragePath.parse(
      '/temp/picker/${DateTime.now().microsecondsSinceEpoch}/$name',
    );
    await _withSessionFiles(pluginId, session, () async {
      await (await _storage).writeFile(pluginId, path, bytes);
    });
    return {'name': name, 'path': path.virtualPath, 'size': bytes.length};
  }

  Future<Map<String, Object?>> _unloadSandboxFile(
    String pluginId,
    List<Object?> arguments,
  ) async {
    final path = PluginStoragePath.parse(
      arguments.firstOrNull?.toString() ?? '',
    );
    final session = _sessions[pluginId];
    if (session == null) throw StateError('Plugin session ended');
    final bytes = await _withSessionFiles(
      pluginId,
      session,
      () async => (await _storage).readFile(pluginId, path),
    );
    final options = _jsonMap(arguments.elementAtOrNull(1));
    final name = options['suggestedName']?.toString().trim();
    return _requestHost(pluginId, 'saveFile', {
      'name': name?.isNotEmpty == true
          ? name
          : path.relativePath.split('/').last,
      'bytes': bytes.toList(growable: false),
    }, session: session);
  }

  Future<String> _readSandboxFile(
    String pluginId,
    List<Object?> arguments,
  ) async {
    final path = PluginStoragePath.parse(
      arguments.firstOrNull?.toString() ?? '',
    );
    final options = _jsonMap(arguments.elementAtOrNull(1));
    final bytes = await (await _storage).readFile(
      pluginId,
      path,
      offset: (options['offset'] as num?)?.toInt() ?? 0,
      length: (options['length'] as num?)?.toInt(),
    );
    return switch (options['encoding']?.toString().toLowerCase()) {
      'utf8' || 'utf-8' || 'text' => utf8.decode(bytes),
      null || '' || 'base64' => base64Encode(bytes),
      final encoding => throw FormatException(
        'Unsupported plugin file encoding: $encoding',
      ),
    };
  }

  Future<void> _writeSandboxFile(
    String pluginId,
    List<Object?> arguments,
  ) async {
    final path = PluginStoragePath.parse(
      arguments.firstOrNull?.toString() ?? '',
    );
    final value = arguments.elementAtOrNull(1);
    final options = _jsonMap(arguments.elementAtOrNull(2));
    final bytes = switch (options['encoding']?.toString().toLowerCase()) {
      'utf8' ||
      'utf-8' ||
      'text' => Uint8List.fromList(utf8.encode(value?.toString() ?? '')),
      null || '' || 'base64' => _bytes(value),
      final encoding => throw FormatException(
        'Unsupported plugin file encoding: $encoding',
      ),
    };
    final storage = await _storage;
    if (options['append'] == true) {
      await storage.writeFileStream(
        pluginId,
        path,
        Stream.value(bytes),
        append: true,
      );
    } else {
      await storage.writeFile(pluginId, path, bytes);
    }
  }

  Future<List<Map<String, Object?>>> _listSandboxDirectory(
    String pluginId,
    List<Object?> arguments,
  ) async {
    final path = PluginStoragePath.parse(
      arguments.firstOrNull?.toString() ?? '',
    );
    final entries = await (await _storage).listDirectory(pluginId, path);
    return entries.map((entry) => entry.toJson()).toList(growable: false);
  }

  Future<Map<String, Object?>?> _statSandboxPath(
    String pluginId,
    List<Object?> arguments,
  ) async {
    final path = PluginStoragePath.parse(
      arguments.firstOrNull?.toString() ?? '',
    );
    final stat = await (await _storage).stat(pluginId, path);
    return stat?.toJson();
  }

  Future<void> _mkdirSandboxPath(
    String pluginId,
    List<Object?> arguments,
  ) async {
    final path = PluginStoragePath.parse(
      arguments.firstOrNull?.toString() ?? '',
    );
    await (await _storage).createDirectory(pluginId, path);
  }

  Future<void> _copySandboxPath(
    String pluginId,
    List<Object?> arguments,
  ) async {
    final source = PluginStoragePath.parse(
      arguments.firstOrNull?.toString() ?? '',
    );
    final destination = PluginStoragePath.parse(
      arguments.elementAtOrNull(1)?.toString() ?? '',
    );
    await _copyStorageEntry(pluginId, source, destination);
  }

  Future<void> _moveSandboxPath(
    String pluginId,
    List<Object?> arguments,
  ) async {
    final source = PluginStoragePath.parse(
      arguments.firstOrNull?.toString() ?? '',
    );
    final destination = PluginStoragePath.parse(
      arguments.elementAtOrNull(1)?.toString() ?? '',
    );
    if (source.area == PluginStorageArea.package) {
      throw UnsupportedError('/plugin is read-only');
    }
    await _copyStorageEntry(pluginId, source, destination);
    await (await _storage).removeFile(pluginId, source);
  }

  Future<void> _copyStorageEntry(
    String pluginId,
    PluginStoragePath source,
    PluginStoragePath destination,
  ) async {
    final storage = await _storage;
    final stat = await storage.stat(pluginId, source);
    if (stat == null) {
      throw StateError('Plugin file does not exist: ${source.virtualPath}');
    }
    if (!stat.isDirectory) {
      await storage.writeFile(
        pluginId,
        destination,
        await storage.readFile(pluginId, source),
      );
      return;
    }
    if (destination.area == source.area &&
        (source.relativePath.isEmpty ||
            destination.relativePath == source.relativePath ||
            destination.relativePath.startsWith('${source.relativePath}/'))) {
      throw const FormatException('A directory cannot be copied into itself');
    }
    await storage.createDirectory(pluginId, destination);
    for (final child in await storage.listDirectory(pluginId, source)) {
      final name = child.path.split('/').last;
      await _copyStorageEntry(
        pluginId,
        PluginStoragePath.parse(child.path),
        PluginStoragePath.parse('${destination.virtualPath}/$name'),
      );
    }
  }

  Future<void> _removeSandboxPath(
    String pluginId,
    List<Object?> arguments,
  ) async {
    final path = PluginStoragePath.parse(
      arguments.firstOrNull?.toString() ?? '',
    );
    await (await _storage).removeFile(pluginId, path);
  }
}
