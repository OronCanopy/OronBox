import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oronbox/src/features/plugins/application/astrobox_ng_plugin_repository.dart';
import 'package:oronbox/src/features/plugins/domain/plugin_package.dart';

void main() {
  group('AstroBoxNgPluginRepository', () {
    test('loads and normalizes official AstroBox-NG plugin index', () async {
      final mockDio = _MockDio({
        AstroBoxNgPluginRepository.primaryIndexUrl: jsonEncode({
          'schemaVersion': 1,
          'plugins': [
            {
              'repo': 'https://raw.githubusercontent.com/sf-yuzifu/Daymatter-AstroBox-Plugin/refs/heads/v2/',
              'folder': 'dist',
              'manifest': {
                'name': '倒数日配置工具',
                'icon': 'icon.png',
                'version': '3.2',
                'description': '在AstroBox中快速添加和修改倒数日相关信息',
                'author': '小鱼yuzifu',
                'website':
                    'https://github.com/sf-yuzifu/Daymatter-AstroBox-Plugin',
                'entry': 'daymatter_astrobox_v2_plugin.wasm',
                'wasi_version': 3,
                'api_level': 4,
                'permissions': [
                  'interconnect',
                  'thirdpartyapp',
                  'device',
                  'register_interconnect_recv',
                ],
                'additional_files': [],
              },
            },
          ],
        }),
      });

      final repo = AstroBoxNgPluginRepository(dio: mockDio);
      expect(repo.id, equals('astrobox_ng'));
      expect(repo.displayName, contains('AstroBox-NG'));

      final entries = await repo.load();
      expect(entries.length, equals(1));

      final entry = entries.first;
      expect(entry.name, equals('倒数日配置工具'));
      expect(entry.version, equals('3.2'));
      expect(entry.author, equals('小鱼yuzifu'));
      expect(entry.permissions, contains('interconnect'));
      expect(entry.permissions, contains('device'));
      expect(entry.iconUrl, contains('icon.png'));
    });

    test('downloads and packages plugin into valid .abp archive', () async {
      final wasmBytes = Uint8List.fromList([
        0x00,
        0x61,
        0x73,
        0x6d,
        0x01,
        0x00,
        0x00,
        0x00,
      ]);
      final iconBytes = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47]);

      final mockDio = _MockDio({
        AstroBoxNgPluginRepository.primaryIndexUrl: jsonEncode({
          'schemaVersion': 1,
          'plugins': [
            {
              'repo': 'https://raw.githubusercontent.com/test-org/test-plugin/refs/heads/main/',
              'folder': 'dist',
              'manifest': {
                'name': 'Test Plugin',
                'icon': 'icon.png',
                'version': '1.0.0',
                'description': 'Test plugin description',
                'author': 'Tester',
                'entry': 'plugin.wasm',
                'api_level': 4,
                'permissions': ['ui', 'device'],
                'additional_files': [],
              },
            },
          ],
        }),
        'https://raw.githubusercontent.com/test-org/test-plugin/refs/heads/main/dist/plugin.wasm':
            wasmBytes,
        'https://raw.githubusercontent.com/test-org/test-plugin/refs/heads/main/dist/icon.png':
            iconBytes,
      });

      final repo = AstroBoxNgPluginRepository(dio: mockDio);
      final entries = await repo.load();
      final abpBytes = await repo.download(entries.first);

      // Verify that the generated zip is valid and readable by PluginPackageReader
      final package = const PluginPackageReader().read(abpBytes);
      expect(package.manifest.name, equals('Test Plugin'));
      expect(package.manifest.version, equals('1.0.0'));
      expect(package.manifest.apiLevel, equals(4));
      expect(package.manifest.permissions, equals(['ui', 'device']));
      expect(package.files['plugin.wasm'], equals(wasmBytes));
    });
  });
}

class _MockDio extends Fake implements Dio {
  _MockDio(this.responses);

  final Map<String, dynamic> responses;

  @override
  Future<Response<T>> get<T>(
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
    ProgressCallback? onReceiveProgress,
  }) async {
    final responsePayload = responses[path];
    if (responsePayload == null) {
      throw DioException(
        requestOptions: RequestOptions(path: path),
        error: 'Not found: $path',
      );
    }
    return Response<T>(
      data: responsePayload as T,
      statusCode: 200,
      requestOptions: RequestOptions(path: path),
    );
  }
}
