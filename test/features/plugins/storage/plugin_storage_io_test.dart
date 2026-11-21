import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:oronbox/src/features/plugins/storage/plugin_storage.dart';
import 'package:oronbox/src/features/plugins/storage/plugin_storage_io.dart';

void main() {
  test(
    'independent storage sessions retain each other temporary files',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'oronbox-storage-sessions-',
      );
      addTearDown(() => root.delete(recursive: true));
      final first = await createIoPluginStorage(
        installedRoot: Directory('${root.path}/installed'),
        cacheRoot: Directory('${root.path}/cache'),
        temporaryRoot: Directory('${root.path}/temp-first'),
      );
      final path = PluginStoragePath.parse('/temp/selected.bin');
      await first.writeFile(
        'org.example.plugin',
        path,
        Uint8List.fromList([1]),
      );
      final second = await createIoPluginStorage(
        installedRoot: Directory('${root.path}/installed'),
        cacheRoot: Directory('${root.path}/cache'),
        temporaryRoot: Directory('${root.path}/temp-second'),
      );
      await second.writeFile(
        'org.example.plugin',
        path,
        Uint8List.fromList([2]),
      );
      final cache = PluginStoragePath.parse('/cache/retained.bin');
      final data = PluginStoragePath.parse('/data/retained.bin');
      await first.writeFile(
        'org.example.plugin',
        cache,
        Uint8List.fromList([3]),
      );
      await first.writeFile(
        'org.example.plugin',
        data,
        Uint8List.fromList([4]),
      );
      await first.writeFile('org.example.other', path, Uint8List.fromList([5]));
      await first.clearTemporaryFiles('org.example.plugin');
      expect(await first.stat('org.example.plugin', path), isNull);
      expect(await first.readFile('org.example.plugin', cache), [3]);
      expect(await first.readFile('org.example.plugin', data), [4]);
      expect(await first.readFile('org.example.other', path), [5]);
      expect(await second.readFile('org.example.plugin', path), [2]);
      await first.writeFile(
        'org.example.plugin',
        path,
        Uint8List.fromList([1]),
      );
      expect(await first.readFile('org.example.plugin', path), [1]);
      await second.close();
      expect(await first.readFile('org.example.plugin', path), [1]);
      await first.close();
      expect(await Directory('${root.path}/temp-first').exists(), isFalse);
      expect(await Directory('${root.path}/temp-second').exists(), isFalse);
    },
  );
  test('install file ownership moves to the host and failed enqueue preserves a replacement source', () async {
    final root = await Directory.systemTemp.createTemp(
      'oronbox-install-handoff-',
    );
    addTearDown(() => root.delete(recursive: true));
    final storage = await createIoPluginStorage(
      installedRoot: Directory('${root.path}/installed'),
      cacheRoot: Directory('${root.path}/cache'),
      temporaryRoot: Directory('${root.path}/temp'),
    );
    addTearDown(storage.close);
    const id = 'org.example.plugin';
    final source = PluginStoragePath.parse('/data/package.rpk');
    final destination = '${root.path}/host.rpk';
    await storage.writeFile(id, source, Uint8List.fromList([1, 2, 3]));
    await storage.moveToHost(id, source, destination);
    expect(await storage.stat(id, source), isNull);
    expect(await File(destination).readAsBytes(), [1, 2, 3]);
    await storage.restoreFromHost(id, source, destination);
    expect(await storage.readFile(id, source), [1, 2, 3]);
    expect(await File(destination).exists(), false);
    await storage.moveToHost(id, source, destination);
    await storage.writeFile(id, source, Uint8List.fromList([4]));
    await storage.restoreFromHost(id, source, destination);
    expect(await storage.readFile(id, source), [4]);
    expect(await File(destination).readAsBytes(), [1, 2, 3]);
    final link = PluginStoragePath.parse('/data/link.rpk');
    await Link(storage.nativePath(id, link)!).create(destination);
    await expectLater(
      storage.moveToHost(id, link, '${root.path}/escaped.rpk'),
      throwsA(anything),
    );
    expect(await File(destination).exists(), true);
  });
  test(
    'plugin data is isolated by plugin ID while package files stay read-only',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'oronbox-storage-test-',
      );
      addTearDown(() => root.delete(recursive: true));
      final storage = await createIoPluginStorage(
        installedRoot: Directory('${root.path}/installed'),
        cacheRoot: Directory('${root.path}/cache'),
        temporaryRoot: Directory('${root.path}/temp'),
      );
      addTearDown(storage.close);
      final dataPath = PluginStoragePath.parse('/data/settings.json');

      await storage.writeFile(
        'org.example.first',
        dataPath,
        Uint8List.fromList([1, 2, 3]),
      );

      expect(await storage.readFile('org.example.first', dataPath), [1, 2, 3]);
      await expectLater(
        storage.readFile('org.example.second', dataPath),
        throwsStateError,
      );
      await expectLater(
        storage.writeFile(
          'org.example.first',
          PluginStoragePath.parse('/plugin/main.js'),
          Uint8List(0),
        ),
        throwsUnsupportedError,
      );
    },
  );

  test('symbolic links cannot escape a plugin storage root', () async {
    final root = await Directory.systemTemp.createTemp('oronbox-storage-test-');
    addTearDown(() => root.delete(recursive: true));
    final storage = await createIoPluginStorage(
      installedRoot: Directory('${root.path}/installed'),
      cacheRoot: Directory('${root.path}/cache'),
      temporaryRoot: Directory('${root.path}/temp'),
    );
    addTearDown(storage.close);
    final dataRoot = PluginStoragePath.parse('/data');
    await storage.createDirectory('org.example.plugin', dataRoot);
    final outside = await Directory('${root.path}/outside').create();
    await File('${outside.path}/secret.txt').writeAsString('secret');
    await Link('${storage.nativePath('org.example.plugin', dataRoot)}/escape')
        .create(outside.path);
    final escaped = PluginStoragePath.parse('/data/escape/secret.txt');

    await expectLater(
      storage.readFile('org.example.plugin', escaped),
      throwsStateError,
    );
    await expectLater(
      storage.writeFile('org.example.plugin', escaped, Uint8List.fromList([1])),
      throwsStateError,
    );
  });

  test('failed replacement streams close their file and preserve the previous content', () async {
    final root = await Directory.systemTemp.createTemp(
      'oronbox-storage-stream-',
    );
    addTearDown(() => root.delete(recursive: true));
    final storage = await createIoPluginStorage(
      installedRoot: Directory('${root.path}/installed'),
      cacheRoot: Directory('${root.path}/cache'),
      temporaryRoot: Directory('${root.path}/temp'),
    );
    addTearDown(storage.close);
    final path = PluginStoragePath.parse('/data/download.bin');
    await storage.writeFile(
      'org.example.plugin',
      path,
      Uint8List.fromList([42]),
    );
    Stream<List<int>> failed() async* {
      yield [1, 2, 3];
      throw StateError('download cancelled');
    }

    await expectLater(
      storage.writeFileStream('org.example.plugin', path, failed()),
      throwsStateError,
    );
    expect(await storage.readFile('org.example.plugin', path), [42]);
    final entries = await storage.listDirectory(
      'org.example.plugin',
      PluginStoragePath.parse('/data'),
    );
    expect(entries.map((entry) => entry.path), ['/data/download.bin']);
    await storage.writeFileStream(
      'org.example.plugin',
      path,
      Stream.value([4, 5]),
    );
    expect(await storage.readFile('org.example.plugin', path), [4, 5]);
  });
}
