import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oronbox/src/device/core/device_kind.dart';
import 'package:oronbox/src/features/devices/services/firmware_catalog.dart';

void main() {
  test('stops paging when the catalog has firmware for the device', () async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          expect(options.uri.queryParameters['page'], '1');
          handler.resolve(
            _catalogPage(options, [
              _release(
                product: 'miwear.watch.n67cn',
                version: 'v3.1.175',
                incrementalFrom: ['3.1.162'],
              ),
              _release(product: 'miwear.watch.n67cn', version: 'v3.1.171'),
            ], hasNext: true),
          );
        },
      ),
    );

    final releases = await DeviceFirmwareCatalog(dio).findUpdates(
      const FirmwareCatalogQuery(
        kind: DeviceKind.xiaomi,
        codename: 'n67',
        model: 'Xiaomi Smart Band 9 Pro',
        currentVersion: '3.1.162',
      ),
    );

    expect(releases.map((release) => release.version), ['3.1.175', '3.1.171']);
    expect(
      releases.first.fileName,
      'miwear.watch.n67cn_v3.1.175_full_test.bin',
    );
    expect(
      releases.first.packageFor('3.1.162').fileName,
      'miwear.watch.n67cn_v3.1.175_from_v3.1.162_incremental_test.bin',
    );
  });

  test(
    'keeps an exact firmware product isolated from regional aliases',
    () async {
      final dio = Dio();
      final pages = <String>[];
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            final page = options.uri.queryParameters['page']!;
            pages.add(page);
            handler.resolve(
              _catalogPage(options, [
                if (page == '1')
                  _release(product: 'miwear.watch.n67cn', version: 'v3.1.175')
                else
                  _release(product: 'miwear.watch.n67gl', version: 'v2.0.1'),
              ], hasNext: page == '1'),
            );
          },
        ),
      );

      final releases = await DeviceFirmwareCatalog(dio).findUpdates(
        const FirmwareCatalogQuery(
          kind: DeviceKind.xiaomi,
          codename: 'n67',
          model: 'miwear.watch.n67gl',
          currentVersion: '2.0.0',
        ),
      );

      expect(releases.single.version, '2.0.1');
      expect(releases.single.fileName, contains('n67gl'));
      expect(pages, ['1', '2']);
    },
  );

  test('resolves p62lte firmware product by CMIIT model M2517W1', () async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) => handler.resolve(
          _catalogPage(options, [
            _release(product: 'miwear.watch.p62', version: 'v1.0.10'),
            _release(product: 'miwear.watch.p62lte', version: 'v1.2.34'),
          ]),
        ),
      ),
    );

    final releases = await DeviceFirmwareCatalog(dio).findUpdates(
      const FirmwareCatalogQuery(
        kind: DeviceKind.xiaomi,
        codename: 'p62',
        model: 'M2517W1',
        currentVersion: '1.2.0',
      ),
    );

    expect(releases.single.version, '1.2.34');
    expect(releases.single.fileName, contains('p62lte'));
  });
}

Response<String> _catalogPage(
  RequestOptions options,
  List<Map<String, dynamic>> releases, {
  bool hasNext = false,
}) => Response(
  requestOptions: options,
  statusCode: 200,
  data: jsonEncode({'releases': releases, 'has_next': hasNext}),
);

Map<String, dynamic> _release({
  required String product,
  required String version,
  List<String> incrementalFrom = const [],
}) {
  return {
    'name': '$product $version',
    'body': 'Release notes',
    'assets': [
      for (final source in incrementalFrom)
        {
          'name': '${product}_${version}_from_v${source}_incremental_test.bin',
          'browser_download_url':
              'https://example.com/$product/$version-$source.bin',
          'size': 512,
          'digest': 'sha256:incremental-$source',
        },
      {
        'name': '${product}_${version}_full_test.bin',
        'browser_download_url': 'https://example.com/$product/$version.bin',
        'size': 1024,
        'digest': 'sha256:test',
      },
    ],
  };
}
