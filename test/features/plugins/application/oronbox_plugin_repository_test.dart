import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oronbox/src/features/plugins/application/oronbox_plugin_repository.dart';
import 'package:oronbox/src/features/plugins/domain/plugin_package.dart';

void main() {
  test('public catalog resolves package URLs and installs a JS package with its declared ID', () async {
    final manifest = utf8.encode(
      jsonEncode({
        'id': 'org.example.js',
        'name': 'Example',
        'version': '1.0.0',
        'author': 'Author',
        'description': '',
        'runtime': 'js',
        'entry': 'main.js',
        'api_level': 1,
        'permissions': <String>[],
      }),
    );
    final script = utf8.encode('console.log("hello");');
    final archive = Archive()
      ..addFile(ArchiveFile('manifest.json', manifest.length, manifest))
      ..addFile(ArchiveFile('main.js', script.length, script));
    final bytes = Uint8List.fromList(ZipEncoder().encode(archive));
    final dio = _Dio(bytes);
    final repo = OronBoxPluginRepository(
      dio: dio,
      baseUrl: 'https://example.invalid',
    );
    final entries = await repo.load();
    expect(entries.single.runtime, 'js');
    expect(entries.single.iconUrl, 'https://example.invalid/icon.png');
    expect(await repo.load(), same(entries));
    expect(dio.catalogRequests, 1);
    final package = const PluginPackageReader().read(
      await repo.download(entries.single),
    );
    expect(package.manifest.id, entries.single.installedId);
    expect(package.manifest.runtime, PluginRuntimeType.js);
    expect(package.files['main.js'], script);
  });
}

class _Dio extends Fake implements Dio {
  _Dio(this.bytes);
  final Uint8List bytes;
  var catalogRequests = 0;

  @override
  Future<Response<T>> get<T>(
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
    ProgressCallback? onReceiveProgress,
  }) async {
    Object value;
    if (path == 'https://example.invalid/api/v1/plugins') {
      catalogRequests++;
      value = {
        'plugins': [
          {
            'id': 'org.example.js',
            'name': 'Example',
            'version': '1.0.0',
            'author': 'Author',
            'description': '',
            'runtime': 'js',
            'permissions': <String>[],
            'packageUrl': '/api/v1/plugins/org.example.js/package',
            'iconUrl': '/icon.png',
          },
        ],
      };
    } else {
      expect(
        path,
        'https://example.invalid/api/v1/plugins/org.example.js/package',
      );
      value = bytes;
    }
    return Response<T>(
      data: value as T,
      requestOptions: RequestOptions(path: path),
      statusCode: 200,
    );
  }
}
