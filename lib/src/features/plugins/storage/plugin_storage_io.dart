import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:oronbox/src/features/plugins/domain/plugin_package.dart';

import 'plugin_storage.dart';

Future<PluginStorage> createPluginStorage() async {
  final localAppData = Platform.environment['LOCALAPPDATA'];
  final support = Platform.isWindows
      ? Directory(
          '${localAppData ?? (await getApplicationSupportDirectory()).path}'
          '${Platform.pathSeparator}OronBox',
        )
      : await getApplicationSupportDirectory();
  final cache = Platform.isWindows
      ? Directory(
          '${localAppData ?? (await getApplicationCacheDirectory()).path}'
          '${Platform.pathSeparator}OronBox'
          '${Platform.pathSeparator}cache',
        )
      : await getApplicationCacheDirectory();
  final temporary = await getTemporaryDirectory();
  final temporaryBase = await Directory('${temporary.path}/oronbox')
      .create(recursive: true);
  await cleanupPluginTemporaryFiles();
  return createIoPluginStorage(
    installedRoot: Directory('${support.path}${Platform.pathSeparator}plugins'),
    metadataRoot: Directory(
      '${support.path}${Platform.pathSeparator}plugin_metadata',
    ),
    cacheRoot: Directory('${cache.path}${Platform.pathSeparator}plugins'),
    temporaryRoot: await temporaryBase.createTemp('plugins-$pid-'),
  );
}

Future<PluginStorage> createIoPluginStorage({
  required Directory installedRoot,
  Directory? metadataRoot,
  required Directory cacheRoot,
  required Directory temporaryRoot,
}) async {
  final resolvedMetadataRoot =
      metadataRoot ??
      Directory(
        '${installedRoot.parent.path}${Platform.pathSeparator}plugin_metadata',
      );
  final storage = _IoPluginStorage(
    installedRoot: installedRoot,
    metadataRoot: resolvedMetadataRoot,
    cacheRoot: cacheRoot,
    temporaryRoot: temporaryRoot,
  );
  try {
    await storage.initialize();
    return storage;
  } catch (_) {
    await storage.close();
    rethrow;
  }
}

class _IoPluginStorage implements PluginStorage {
  _IoPluginStorage({
    required this.installedRoot,
    required this.metadataRoot,
    required this.cacheRoot,
    required this.temporaryRoot,
  });

  static const _manifestFile = 'manifest.json';
  static const _configFile = 'config.json';
  static const _permissionsFile = 'permissions.json';

  final Directory installedRoot;
  final Directory metadataRoot;
  final Directory cacheRoot;
  final Directory temporaryRoot;
  RandomAccessFile? _temporaryLease;

  Future<void> initialize() async {
    await installedRoot.create(recursive: true);
    await metadataRoot.create(recursive: true);
    await cacheRoot.create(recursive: true);
    await temporaryRoot.create(recursive: true);
    _temporaryLease = await File(_join(temporaryRoot.path, '.lease'))
        .open(mode: FileMode.append);
    await _temporaryLease!.lock(FileLock.exclusive);
    await File(_join(temporaryRoot.path, '.owner')).writeAsString('$pid');
    await _migrateLegacyMetadata();
  }

  Future<void> _migrateLegacyMetadata() async {
    if (!await installedRoot.exists()) return;
    await for (final entity in installedRoot.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final id = _leafName(entity.path);
      if (!_isPluginId(id)) continue;
      final legacy = Directory(_join(entity.path, '.oronbox'));
      if (await legacy.exists()) {
        final target = _metadataDirectory(id);
        await target.create(recursive: true);
        for (final name in [_configFile, _permissionsFile]) {
          final src = File(_join(legacy.path, name));
          final dst = File(_join(target.path, name));
          if (await src.exists() && !await dst.exists()) {
            await src.copy(dst.path);
          }
        }
        await legacy.delete(recursive: true);
      }
    }
  }

  @override
  Future<List<InstalledPlugin>> loadInstalled() async {
    final plugins = <InstalledPlugin>[];
    await for (final entity in installedRoot.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final id = _leafName(entity.path);
      if (!_isPluginId(id)) continue;
      try {
        plugins.add(await _loadPlugin(id));
      } catch (_) {
        // A damaged plugin is isolated from the rest of the registry
      }
    }
    return plugins;
  }

  Future<InstalledPlugin> _loadPlugin(String id) async {
    final package = _packageDirectory(id);
    final manifestFile = File(_join(package.path, _manifestFile));
    final manifest = const PluginPackageReader().readManifest(
      await manifestFile.readAsBytes(),
    );
    if (manifest.id != id) {
      throw const FormatException(
        'Plugin directory ID does not match manifest',
      );
    }
    final entryBytes = await _packageFile(id, manifest.entry).readAsBytes();
    final icon = manifest.iconPath == null
        ? null
        : await _packageFile(id, manifest.iconPath!).readAsBytes();
    await readPermissionGrants(id);
    return InstalledPlugin(
      manifest: manifest,
      entryBytes: entryBytes,
      config: await _readConfig(id),
      iconBase64: icon == null ? null : base64Encode(icon),
    );
  }

  Future<Map<String, Object?>> _readConfig(String id) async {
    await _ensureMetadataSafe(id);
    final file = _metadataFile(id, _configFile);
    if (!await file.exists()) return const {};
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) throw const FormatException('Invalid plugin config');
    return decoded.cast<String, Object?>();
  }

  @override
  Future<InstalledPlugin> install(
    PluginPackage package, {
    required Map<String, Object?> config,
  }) async {
    final id = package.manifest.id;
    _requirePluginId(id);
    final pluginRoot = _pluginDirectory(id);
    if (await FileSystemEntity.type(pluginRoot.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw StateError('Symbolic links are not allowed in plugin storage');
    }
    await pluginRoot.create(recursive: true);
    final nonce = DateTime.now().microsecondsSinceEpoch;
    final staging = Directory(_join(pluginRoot.path, '.package-$nonce'));
    final target = _packageDirectory(id);
    final backup = Directory(_join(pluginRoot.path, '.package-backup-$nonce'));
    await staging.create(recursive: true);
    try {
      for (final entry in package.files.entries) {
        final file = _fileBelow(staging, entry.key);
        await file.parent.create(recursive: true);
        await file.writeAsBytes(entry.value, flush: true);
      }
      await writeConfig(id, config);
      if (await target.exists()) await target.rename(backup.path);
      try {
        await staging.rename(target.path);
      } catch (_) {
        if (await backup.exists() && !await target.exists()) {
          await backup.rename(target.path);
        }
        rethrow;
      }
      if (await backup.exists()) await backup.delete(recursive: true);
      return package.installed(config: config);
    } finally {
      if (await staging.exists()) await staging.delete(recursive: true);
    }
  }

  @override
  Future<void> writeConfig(String pluginId, Map<String, Object?> config) async {
    _requirePluginId(pluginId);
    await _ensureMetadataSafe(pluginId);
    final directory = _metadataDirectory(pluginId);
    await directory.create(recursive: true);
    final target = File(_join(directory.path, _configFile));
    final temporary = File('${target.path}.tmp-$pid');
    await temporary.writeAsString(jsonEncode(config), flush: true);
    await _replaceFile(temporary, target);
  }

  @override
  Future<Map<String, Object?>> readHostSettings(String pluginId) async {
    _requirePluginId(pluginId);
    await _ensureMetadataSafe(pluginId);
    final file = _metadataFile(pluginId, 'host.json');
    if (!await file.exists()) return {};
    return (jsonDecode(await file.readAsString()) as Map)
        .cast<String, Object?>();
  }

  @override
  Future<void> writeHostSettings(
    String pluginId,
    Map<String, Object?> settings,
  ) async {
    _requirePluginId(pluginId);
    await _ensureMetadataSafe(pluginId);
    await _metadataDirectory(pluginId).create(recursive: true);
    final target = _metadataFile(pluginId, 'host.json');
    final temporary = File('${target.path}.tmp-$pid');
    await temporary.writeAsString(jsonEncode(settings), flush: true);
    await _replaceFile(temporary, target);
  }

  @override
  Future<Set<String>> readPermissionGrants(String pluginId) async {
    _requirePluginId(pluginId);
    await _ensureMetadataSafe(pluginId);
    final file = _metadataFile(pluginId, _permissionsFile);
    if (!await file.exists()) return <String>{};
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! List) {
      throw const FormatException('Invalid plugin permission grants');
    }
    return decoded.map((value) => value.toString()).toSet();
  }

  @override
  Future<void> writePermissionGrants(
    String pluginId,
    Set<String> grants,
  ) async {
    _requirePluginId(pluginId);
    await _ensureMetadataSafe(pluginId);
    final directory = _metadataDirectory(pluginId);
    await directory.create(recursive: true);
    final target = File(_join(directory.path, _permissionsFile));
    final temporary = File('${target.path}.tmp-$pid');
    await temporary.writeAsString(
      jsonEncode(grants.toList()..sort()),
      flush: true,
    );
    await _replaceFile(temporary, target);
  }

  @override
  Future<void> removePlugin(String pluginId) async {
    _requirePluginId(pluginId);
    for (final directory in [
      _pluginDirectory(pluginId),
      _metadataDirectory(pluginId),
      _cacheDirectory(pluginId),
      _temporaryDirectory(pluginId),
    ]) {
      if (await directory.exists()) await directory.delete(recursive: true);
    }
  }

  @override
  Future<void> clearPluginData(String pluginId) async {
    _requirePluginId(pluginId);
    for (final directory in [
      _dataDirectory(pluginId),
      _metadataDirectory(pluginId),
      _cacheDirectory(pluginId),
      _temporaryDirectory(pluginId),
    ]) {
      if (await directory.exists()) await directory.delete(recursive: true);
    }
    await _dataDirectory(pluginId).create(recursive: true);
    await _cacheDirectory(pluginId).create(recursive: true);
    await _temporaryDirectory(pluginId).create(recursive: true);
  }

  @override
  Future<Uint8List> readFile(
    String pluginId,
    PluginStoragePath path, {
    int offset = 0,
    int? length,
  }) async {
    await _ensureNoSymbolicLinks(pluginId, path);
    final file = _resolveFile(pluginId, path);
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw StateError('Plugin file does not exist: ${path.virtualPath}');
    }
    if (offset == 0 && length == null) return file.readAsBytes();
    final handle = await file.open();
    try {
      final count = pluginFileReadLength(await handle.length(), offset, length);
      await handle.setPosition(offset);
      return await handle.read(count);
    } finally {
      await handle.close();
    }
  }

  @override
  Future<void> writeFile(
    String pluginId,
    PluginStoragePath path,
    Uint8List bytes, {
    bool allowPackageWrite = false,
  }) async {
    if (path.area == PluginStorageArea.package && !allowPackageWrite) {
      throw UnsupportedError('/plugin is read-only');
    }
    if (path.relativePath.isEmpty) {
      throw const FormatException('A file path is required');
    }
    await _ensureNoSymbolicLinks(pluginId, path);
    final file = _resolveFile(pluginId, path);
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp-$pid');
    await temporary.writeAsBytes(bytes, flush: true);
    await _replaceFile(temporary, file);
  }

  @override
  Future<int> writeFileStream(
    String pluginId,
    PluginStoragePath path,
    Stream<List<int>> stream, {
    bool append = false,
  }) async {
    if (path.area == PluginStorageArea.package) {
      throw UnsupportedError('/plugin is read-only');
    }
    if (path.relativePath.isEmpty) {
      throw const FormatException('A file path is required');
    }
    await _ensureNoSymbolicLinks(pluginId, path);
    final file = _resolveFile(pluginId, path);
    await file.parent.create(recursive: true);
    var written = 0;
    final target = append ? file : File('${file.path}.tmp-$pid');
    final sink = target.openWrite(
      mode: append ? FileMode.append : FileMode.write,
    );
    // A source cancellation must close the file and release its descriptor.
    unawaited(sink.done.then<void>((_) {}, onError: (_, _) {}));
    try {
      try {
        await for (final chunk in stream) {
          sink.add(chunk);
          written += chunk.length;
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (!append) await _replaceFile(target, file);
      return written;
    } finally {
      if (!append && await target.exists()) await target.delete();
    }
  }

  @override
  Future<List<PluginFileStat>> listDirectory(
    String pluginId,
    PluginStoragePath path,
  ) async {
    await _ensureNoSymbolicLinks(pluginId, path);
    final directory = _resolveDirectory(pluginId, path);
    if (!await directory.exists()) return const [];
    final result = <PluginFileStat>[];
    await for (final entity in directory.list(followLinks: false)) {
      final name = _leafName(entity.path);
      final type = await FileSystemEntity.type(entity.path, followLinks: false);
      if (type == FileSystemEntityType.link) continue;
      final childPath = '${path.virtualPath}/$name';
      result.add(
        PluginFileStat(
          path: childPath,
          size: type == FileSystemEntityType.file
              ? await File(entity.path).length()
              : 0,
          isDirectory: type == FileSystemEntityType.directory,
        ),
      );
    }
    result.sort((a, b) => a.path.compareTo(b.path));
    return result;
  }

  @override
  Future<void> createDirectory(String pluginId, PluginStoragePath path) async {
    if (path.area == PluginStorageArea.package) {
      throw UnsupportedError('/plugin is read-only');
    }
    await _ensureNoSymbolicLinks(pluginId, path);
    await _resolveDirectory(pluginId, path).create(recursive: true);
  }

  @override
  Future<PluginFileStat?> stat(String pluginId, PluginStoragePath path) async {
    await _ensureNoSymbolicLinks(pluginId, path);
    final entityPath = _resolvePath(pluginId, path);
    final type = await FileSystemEntity.type(entityPath, followLinks: false);
    if (type == FileSystemEntityType.notFound ||
        type == FileSystemEntityType.link) {
      return null;
    }
    return PluginFileStat(
      path: path.virtualPath,
      size: type == FileSystemEntityType.file
          ? await File(entityPath).length()
          : 0,
      isDirectory: type == FileSystemEntityType.directory,
    );
  }

  @override
  Future<void> removeFile(String pluginId, PluginStoragePath path) async {
    if (path.area == PluginStorageArea.package) {
      throw UnsupportedError('/plugin is read-only');
    }
    if (path.relativePath.isEmpty) {
      throw const FormatException('Cannot remove a storage root');
    }
    await _ensureNoSymbolicLinks(pluginId, path);
    final entityPath = _resolvePath(pluginId, path);
    final type = await FileSystemEntity.type(entityPath, followLinks: false);
    if (type == FileSystemEntityType.file) {
      await File(entityPath).delete();
    } else if (type == FileSystemEntityType.directory) {
      await Directory(entityPath).delete(recursive: true);
    } else if (type == FileSystemEntityType.link) {
      throw StateError('Symbolic links are not allowed in plugin storage');
    }
  }

  @override
  String nativePath(String pluginId, PluginStoragePath path) {
    return _resolvePath(pluginId, path);
  }

  @override
  Future<void> moveToHost(
    String pluginId,
    PluginStoragePath path,
    String destination,
  ) async {
    await _ensureNoSymbolicLinks(pluginId, path);
    final source = _resolveFile(pluginId, path);
    if (!await source.exists() || await source.length() == 0) {
      throw StateError('Install source must be a nonempty file');
    }
    await _moveHostFile(source, File(destination));
  }

  @override
  Future<void> restoreFromHost(
    String pluginId,
    PluginStoragePath path,
    String source,
  ) async {
    await _ensureNoSymbolicLinks(pluginId, path);
    final target = _resolveFile(pluginId, path);
    if (await FileSystemEntity.type(target.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      return;
    }
    await target.parent.create(recursive: true);
    await _moveHostFile(File(source), target);
  }

  Future<void> _moveHostFile(File source, File target) async {
    try {
      await source.rename(target.path);
    } on FileSystemException {
      try {
        await source.copy(target.path);
        await source.delete();
      } catch (_) {
        if (await target.exists()) await target.delete();
        rethrow;
      }
    }
  }

  @override
  Future<void> close() async {
    await _temporaryLease?.close();
    _temporaryLease = null;
    if (await temporaryRoot.exists()) {
      await temporaryRoot.delete(recursive: true);
    }
  }

  Directory _pluginDirectory(String id) {
    _requirePluginId(id);
    return Directory(_join(installedRoot.path, id));
  }

  Directory _packageDirectory(String id) =>
      Directory(_join(_pluginDirectory(id).path, 'package'));

  Directory _dataDirectory(String id) =>
      Directory(_join(_pluginDirectory(id).path, 'data'));

  Directory _metadataDirectory(String id) {
    _requirePluginId(id);
    return Directory(_join(metadataRoot.path, id));
  }

  File _metadataFile(String id, String name) =>
      File(_join(_metadataDirectory(id).path, name));

  Directory _cacheDirectory(String id) {
    _requirePluginId(id);
    return Directory(_join(cacheRoot.path, id));
  }

  Directory _temporaryDirectory(String id) {
    _requirePluginId(id);
    return Directory(_join(temporaryRoot.path, id));
  }

  File _packageFile(String id, String relativePath) =>
      _fileBelow(_packageDirectory(id), relativePath);

  File _resolveFile(String id, PluginStoragePath path) {
    if (path.relativePath.isEmpty) {
      throw const FormatException('A file path is required');
    }
    return File(_resolvePath(id, path));
  }

  Directory _resolveDirectory(String id, PluginStoragePath path) =>
      Directory(_resolvePath(id, path));

  String _resolvePath(String id, PluginStoragePath path) {
    final root = _rootDirectory(id, path.area);
    return path.relativePath.isEmpty
        ? root.path
        : _fileBelow(root, path.relativePath).path;
  }

  Directory _rootDirectory(String id, PluginStorageArea area) => switch (area) {
    PluginStorageArea.package => _packageDirectory(id),
    PluginStorageArea.data => _dataDirectory(id),
    PluginStorageArea.cache => _cacheDirectory(id),
    PluginStorageArea.temporary => _temporaryDirectory(id),
  };

  Future<void> _ensureNoSymbolicLinks(String id, PluginStoragePath path) async {
    var current = _rootDirectory(id, path.area).path;
    final rootType = await FileSystemEntity.type(current, followLinks: false);
    if (rootType == FileSystemEntityType.link) {
      throw StateError('Symbolic links are not allowed in plugin storage');
    }
    for (final part in path.relativePath.split('/')) {
      if (part.isEmpty) continue;
      current = _join(current, part);
      final type = await FileSystemEntity.type(current, followLinks: false);
      if (type == FileSystemEntityType.link) {
        throw StateError('Symbolic links are not allowed in plugin storage');
      }
      if (type == FileSystemEntityType.notFound) break;
    }
  }

  Future<void> _ensureMetadataSafe(String id) async {
    final metaDir = _metadataDirectory(id);
    if (await metaDir.exists()) {
      final metadataType = await FileSystemEntity.type(
        metaDir.path,
        followLinks: false,
      );
      if (metadataType == FileSystemEntityType.link) {
        throw StateError('Symbolic links are not allowed in plugin storage');
      }
    }
  }

  Future<void> _replaceFile(File temporary, File target) async {
    final backup = File(
      '${target.path}.backup-${DateTime.now().microsecondsSinceEpoch}',
    );
    if (await target.exists()) await target.rename(backup.path);
    try {
      await temporary.rename(target.path);
      if (await backup.exists()) await backup.delete();
    } catch (_) {
      if (await backup.exists() && !await target.exists()) {
        await backup.rename(target.path);
      }
      rethrow;
    }
  }

  File _fileBelow(Directory root, String relativePath) {
    final parts = relativePath.split('/');
    if (relativePath.isEmpty ||
        parts.any(
          (part) =>
              part.isEmpty ||
              part == '.' ||
              part == '..' ||
              part.contains('\\'),
        )) {
      throw FormatException('Unsafe plugin path: $relativePath');
    }
    return File([root.path, ...parts].join(Platform.pathSeparator));
  }

  bool _isPluginId(String id) =>
      RegExp(r'^[a-z][a-z0-9]*(?:[.-][a-z0-9][a-z0-9-]*)+$').hasMatch(id) ||
      RegExp(r'^[a-z0-9][a-z0-9-]{0,127}$').hasMatch(id);

  void _requirePluginId(String id) {
    if (!_isPluginId(id)) throw FormatException('Invalid plugin ID: $id');
  }

  String _join(String parent, String child) =>
      '$parent${Platform.pathSeparator}$child';

  String _leafName(String path) =>
      path.split(Platform.pathSeparator).where((part) => part.isNotEmpty).last;
}

Future<void> cleanupPluginTemporaryFiles() async {
  final base = Directory('${(await getTemporaryDirectory()).path}/oronbox');
  if (!await base.exists()) return;
  await for (final entry in base.list(followLinks: false)) {
    if (entry is! Directory ||
        !entry.uri.pathSegments
            .where((part) => part.isNotEmpty)
            .last
            .startsWith('plugins-')) {
      continue;
    }
    RandomAccessFile? lease;
    try {
      final owner = File('${entry.path}/.owner');
      if (await owner.exists() && await owner.readAsString() == '$pid') {
        continue;
      }
      lease = await File('${entry.path}/.lease').open(mode: FileMode.append);
      await lease.lock(FileLock.exclusive);
      await owner.writeAsString('$pid', flush: true);
      await lease.close();
      lease = null;
      await entry.delete(recursive: true);
    } on FileSystemException {
      // Another process may still own this temporary directory.
    } finally {
      await lease?.close();
    }
  }
}
