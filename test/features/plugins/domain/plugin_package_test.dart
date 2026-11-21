import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oronbox/src/features/plugins/domain/plugin_package.dart';

void main() {
  group('PluginPackageReader', () {
    test('reads valid WebAssembly plugins', () {
      final package = const PluginPackageReader().read(
        _package(runtime: 'wasm', entry: 'plugin.wasm'),
      );

      expect(package.manifest.id, 'org.example.plugin');
      expect(package.manifest.runtime, PluginRuntimeType.wasm);
      expect(package.files['plugin.wasm'], isNotNull);
      expect(
        package.files['plugin.wasm']!.sublist(0, 4),
        equals([0, 97, 115, 109]),
      );
    });

    test('defaults runtime to wasm when omitted', () {
      final package = const PluginPackageReader().read(
        _package(entry: 'plugin.wasm'),
      );
      expect(package.manifest.runtime, PluginRuntimeType.wasm);
    });

    for (final runtime in ['js', 'hybrid']) {
      test('reads OronBox $runtime packages and preserves the source', () {
        final source = utf8.encode('globalThis.activate = async () => "天气";');
        final package = const PluginPackageReader().read(
          _package(runtime: runtime, entry: 'main.js', entryBytes: source),
        );
        expect(package.manifest.runtime.manifestValue, runtime);
        expect(package.installed().entryBytes, source);
      });
    }

    test('rejects non-wasm runtime in manifest', () {
      expect(
        () => const PluginPackageReader().read(
          _package(runtime: 'js', entry: 'plugin.wasm'),
        ),
        throwsFormatException,
      );
    });

    test('rejects non-wasm entry file extensions', () {
      expect(
        () => const PluginPackageReader().read(_package(entry: 'main.js')),
        throwsFormatException,
      );
    });

    test('preserves forward-compatible permissions without throwing', () {
      final package = const PluginPackageReader().read(
        _package(
          entry: 'plugin.wasm',
          permissions: const ['os.device-id', 'request'],
        ),
      );
      expect(
        package.manifest.permissions,
        containsAll(['os.device-id', 'request']),
      );
    });

    test('rejects a WASM entry without the WebAssembly magic header', () {
      expect(
        () => const PluginPackageReader().read(
          _package(entry: 'plugin.wasm', entryBytes: const [1, 2, 3, 4]),
        ),
        throwsFormatException,
      );
    });

    test('rejects archive entries that escape the package root', () {
      expect(
        () => const PluginPackageReader().read(
          _package(entry: 'plugin.wasm', archiveEntryName: '../plugin.wasm'),
        ),
        throwsFormatException,
      );
    });

    test('rejects a manifest whose runtime entry is missing', () {
      expect(
        () => const PluginPackageReader().read(
          _package(entry: 'plugin.wasm', includeEntry: false),
        ),
        throwsFormatException,
      );
    });
  });
}

Uint8List _package({
  String? runtime,
  required String entry,
  List<String> permissions = const [],
  List<int>? entryBytes,
  String? archiveEntryName,
  bool includeEntry = true,
}) {
  final manifest = <String, Object?>{
    'id': 'org.example.plugin',
    'name': 'Example Plugin',
    'version': '1.0.0',
    'author': 'OronBox',
    'description': 'Test plugin',
    'api_level': 1,
    if (runtime != null) 'runtime': runtime,
    'entry': entry,
    'permissions': permissions,
  };
  final content =
      entryBytes ??
      (entry.endsWith('.wasm')
          ? const <int>[0, 97, 115, 109, 1, 0, 0, 0]
          : utf8.encode('export {}'));
  final manifestBytes = utf8.encode(jsonEncode(manifest));
  final archive = Archive()
    ..addFile(
      ArchiveFile('manifest.json', manifestBytes.length, manifestBytes),
    );
  if (includeEntry) {
    archive.addFile(
      ArchiveFile(archiveEntryName ?? entry, content.length, content),
    );
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}
