import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'managed_temporary_files.dart';

final _leases = <String, RandomAccessFile>{};
Future<Directory> _root() async =>
    Directory('${(await getTemporaryDirectory()).path}/oronbox/managed');

Future<String> create(
  TemporaryFilePurpose purpose,
  String name,
  Future<void> Function(String) write,
) async {
  if (name.isEmpty ||
      name.contains('/') ||
      name.contains('\\') ||
      name.contains('\x00') ||
      name == '.' ||
      name == '..' ||
      name.startsWith('.')) {
    throw const FormatException('Invalid temporary filename');
  }
  final directory = Directory(
    '${(await _root()).path}/${purpose.name}/${const Uuid().v4()}',
  );
  await directory.create(recursive: true);
  final path = '${directory.path}/$name';
  final lease = await File('${directory.path}/.lease')
      .open(mode: FileMode.append);
  try {
    await lease.lock(FileLock.exclusive);
    await File('${directory.path}/.owner').writeAsString('$pid', flush: true);
    _leases[path] = lease;
    await write(path);
    return path;
  } catch (_) {
    if (_leases.containsKey(path)) {
      await release(path);
    } else {
      await lease.close();
      await directory.delete(recursive: true);
    }
    rethrow;
  }
}

Future<void> release(String path, {bool delete = true}) async {
  final lease = _leases.remove(path);
  if (lease == null) return;
  final directory = File(path).parent;
  try {
    await File('${directory.path}/.owner').writeAsString('0', flush: true);
  } finally {
    await lease.close();
  }
  if (delete) await directory.delete(recursive: true);
}

Future<int> cleanup(Duration minimumAge, Set<String> protectedPaths) async {
  final root = await _root();
  if (!await root.exists()) return 0;
  final cutoff = DateTime.now().subtract(minimumAge);
  var removed = 0;
  for (final purpose in TemporaryFilePurpose.values) {
    final category = Directory('${root.path}/${purpose.name}');
    if (!await category.exists()) continue;
    await for (final entry in category.list(followLinks: false)) {
      if (entry is! Directory ||
          [
            ..._leases.keys,
            ...protectedPaths,
          ].any((path) => File(path).parent.path == entry.path)) {
        continue;
      }
      RandomAccessFile? lock;
      try {
        final owner = File('${entry.path}/.owner');
        if (!await owner.exists() ||
            (await owner.stat()).modified.isAfter(cutoff)) {
          continue;
        }
        // POSIX locks are process-scoped, so another engine in this process is protected too.
        if (await owner.readAsString() == '$pid') continue;
        lock = await File('${entry.path}/.lease').open(mode: FileMode.append);
        await lock.lock(FileLock.exclusive);
        await owner.writeAsString('$pid', flush: true);
        await lock.close();
        lock = null;
        await entry.delete(recursive: true);
        removed++;
      } on FileSystemException {
        // A live owner or a concurrent cleaner retains ownership.
      } finally {
        await lock?.close();
      }
    }
  }
  return removed;
}

Future<List<Directory>> _importRoots() async {
  final temporary = await getTemporaryDirectory();
  return [
    for (final name in ['file_picker', 'flutter_file_picker', 'file_open'])
      Directory('${temporary.path}/$name'),
    if (Platform.isIOS || Platform.isMacOS)
      for (final name in ['flutter_file_picker', 'file_open'])
        Directory('${Directory.systemTemp.path}/$name'),
  ];
}

Future<void> releaseImport(String path) async {
  if (path.isEmpty) return;
  try {
    final file = File(path);
    if (!await file.exists()) return;
    final resolved = await file.resolveSymbolicLinks();
    for (final root in await _importRoots()) {
      if (!await root.exists()) continue;
      final rootPath = await root.resolveSymbolicLinks();
      final prefix = '$rootPath${Platform.pathSeparator}';
      if (!resolved.startsWith(prefix)) continue;
      await file.delete();
      var directory = File(resolved).parent;
      while (directory.path.startsWith(prefix) && await directory.exists()) {
        if (!await directory.list().isEmpty) break;
        await directory.delete();
        directory = directory.parent;
      }
      return;
    }
  } on FileSystemException {
    // A later cleanup can reclaim a file still held by the picker.
  }
}

Future<int> cleanupImports(
  Duration minimumAge,
  Set<String> protectedPaths,
) async {
  final cutoff = DateTime.now().subtract(minimumAge);
  final protected = <String>{};
  for (final path in protectedPaths) {
    try {
      protected.add(await File(path).resolveSymbolicLinks());
    } on FileSystemException {
      protected.add(path);
    }
  }
  var removed = 0;
  for (final root in await _importRoots()) {
    if (!await root.exists()) continue;
    final files = await root
        .list(recursive: true, followLinks: false)
        .where((entry) => entry is File)
        .cast<File>()
        .toList();
    for (final file in files) {
      try {
        if (protected.contains(await file.resolveSymbolicLinks()) ||
            (await file.stat()).modified.isAfter(cutoff)) {
          continue;
        }
        await releaseImport(file.path);
        if (!await file.exists()) removed++;
      } on FileSystemException {
        // A concurrent consumer may have released this file already.
      }
    }
  }
  return removed;
}
