import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oronbox/src/features/resources/services/resource_payload_analyzer.dart';

void main() {
  final analyzer = ResourcePayloadAnalyzer();

  test(
    'RPK publishing versions follow manifest-watch without changing bytes',
    () {
      final archive = Archive();
      for (final entry in {
        'manifest.json': {
          'package': 'org.demo.app',
          'versionName': '1.0',
          'versionCode': 1,
        },
        'manifest-watch.json': {'versionName': '2.0', 'versionCode': 2.0},
      }.entries) {
        final bytes = utf8.encode(jsonEncode(entry.value));
        archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
      }
      final bytes = Uint8List.fromList(ZipEncoder().encode(archive));
      final result = analyzer.analyze(fileName: 'demo.rpk', bytes: bytes);
      expect(result?.version, '2.0');
      expect(result?.versionCode, 2);
      expect(result?.payload, same(bytes));
    },
  );

  test('watchface version code preserves zero and uses the actual header', () {
    final bytes = Uint8List(0xa8)..setAll(0, [0x5a, 0xa5, 0x34, 0x12]);
    bytes.setAll(0x28, ascii.encode('123456789'));
    expect(
      analyzer.analyze(fileName: 'face.bin', bytes: bytes)?.versionCode,
      0,
    );
    bytes.setAll(4, [3, 2, 1]);
    final result = analyzer.analyze(fileName: 'face.bin', bytes: bytes);
    expect(result?.versionCode, 66051);
    expect(result?.payload, same(bytes));
  });

  test('recognizes a Vela incremental OTA from its manifest and files', () {
    Uint8List package({required bool includePayload}) {
      final archive = Archive()
        ..addFile(
          ArchiveFile.string(
            'ota.json',
            jsonEncode({
              'magic_string': 'o66',
              'sw_version': '3.1.33',
              'firmware_type': 'diff',
              'sections': [
                {'location_path': 'vela_ap.bin'},
                {'location_path': 'version'},
              ],
            }),
          ),
        )
        ..addFile(ArchiveFile.string('version', 'res.version=3.1.33'));
      if (includePayload) {
        archive.addFile(ArchiveFile('vela_ap.bin', 3, [1, 2, 3]));
      }
      return Uint8List.fromList(ZipEncoder().encode(archive));
    }

    final bytes = package(includePayload: true);
    final result = analyzer.analyze(fileName: 'update.bin', bytes: bytes);
    expect(result?.type, LocalDeviceInstallType.firmware);
    expect(result?.platform, ResourcePlatform.vela);
    expect(result?.packageKind, ResourcePackageKind.velaOta);
    expect(result?.version, '3.1.33');
    expect(result?.target, 'o66');
    expect(result?.payload, same(bytes));
    expect(
      analyzer.analyze(
        fileName: 'update.bin',
        bytes: package(includePayload: false),
        hint: LocalDeviceInstallType.firmware,
      ),
      isNull,
    );
  });

  test('recognizes a CRPack from its manifest and keeps the original ZIP', () {
    final bytes = Uint8List.fromList(
      ZipEncoder().encode(
        Archive()..addFile(
          ArchiveFile.string(
            'corona.json',
            jsonEncode({
              'format': 'canopus-resource-pack',
              'formatVersion': 1,
              'themeId': 'demo-pack',
              'name': 'Demo',
            }),
          ),
        ),
      ),
    );
    final result = analyzer.analyze(fileName: 'renamed.zip', bytes: bytes);
    expect(result?.type, LocalDeviceInstallType.resPack);
    expect(result?.platform, ResourcePlatform.vela);
    expect(result?.identifier, 'demo-pack');
    expect(result?.payload, same(bytes));
  });

  test('recognizes a Canopus tar package when manifest.json is preceded by large entries', () {
    final elfBytes = Uint8List(8192);
    final archive = Archive()
      ..addFile(
        ArchiveFile(
          'artifacts/cortex-m33/module.elf',
          elfBytes.length,
          elfBytes,
        ),
      )
      ..addFile(
        ArchiveFile.string(
          'manifest.json',
          jsonEncode({
            'schema': 1,
            'module_id': 'complex_module',
            'canopus_abi': '2',
            'lifecycle': 'removable',
            'version': '1.2.3',
            'version_code': 12,
            'artifacts': ['artifacts/cortex-m33/module.elf'],
          }),
        ),
      );
    final bytes = Uint8List.fromList(TarEncoder().encode(archive));
    final result = analyzer.analyze(
      fileName: 'complex_module.canopus',
      bytes: bytes,
    );
    expect(result?.type, LocalDeviceInstallType.canopus);
    expect(result?.packageKind, ResourcePackageKind.canopus);
    expect(result?.identifier, 'complex_module');
    expect(result?.version, '1.2.3');
  });
}
