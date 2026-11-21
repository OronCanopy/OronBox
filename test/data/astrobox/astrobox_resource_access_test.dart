import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oronbox/src/core/storage/managed_temporary_files.dart';
import 'package:oronbox/src/data/astrobox/astrobox_repo_resource_provider.dart';
import 'package:oronbox/src/data/astrobox/astrobox_resource_access.dart';
import 'package:oronbox/src/data/astrobox/astrobox_resource_decryption.dart';
import 'package:oronbox/src/data/community/community_source.dart';
import 'package:oronbox/src/features/resources/domain/community_resource.dart';
import 'package:oronbox/src/features/resources/domain/resource_catalog.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  final ResponseBody Function(RequestOptions) respond;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => respond(options);

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Object value, [int status = 200]) => ResponseBody.fromString(
  jsonEncode(value),
  status,
  headers: {
    Headers.contentTypeHeader: ['application/json'],
  },
);

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late Dio dio;
  late AstroBoxRepoCatalog catalog;
  late List<RequestOptions> requests;
  var creatorFeatures = true;
  var indexName = 'Sample';
  var indexId = 'sample';
  var indexCommit = 'commit';
  var indexStatus = 200;
  var cryptoStatus = 404;
  Object cryptoResponse = 'file_not_found';
  var purchaseVersion = '1.0';
  var purchaseStatus = 200;
  var downloadBytes = <int>[1, 2, 3];
  final keyBytes = List.generate(32, (index) => index);
  final ciphertext = Uint8List.fromList(
    List.generate(
      32,
      (index) => int.parse(
        '2952df6cb71f65f8a6b8e9472bb4cbbf9f3b7504926f8bd36e3118e903a4cd4a'
            .substring(index * 2, index * 2 + 2),
        radix: 16,
      ),
    ),
  );

  void encryptedResponse() {
    cryptoStatus = 200;
    cryptoResponse = {
      'payload': {
        'hash': sha256.convert(downloadBytes).toString(),
        'key': base64Encode(keyBytes),
        'operatorId': '',
      },
    };
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('oronbox-access-');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => root.path,
    );
    requests = [];
    indexName = 'Sample';
    indexId = 'sample';
    indexCommit = 'commit';
    indexStatus = 200;
    creatorFeatures = true;
    cryptoStatus = 404;
    cryptoResponse = 'file_not_found';
    purchaseVersion = '1.0';
    purchaseStatus = 200;
    downloadBytes = [1, 2, 3];
    dio = Dio()
      ..httpClientAdapter = _Adapter((request) {
        requests.add(request);
        final path = request.uri.path;
        if (path.endsWith('/sources/astrobox/index')) {
          return ResponseBody.fromString('invalid catalog', 200);
        }
        if (path.endsWith('/sources/astrobox/resources/sample')) {
          return _json({'error': 'unavailable'}, 503);
        }
        if (path.endsWith('index_v2.csv')) {
          return ResponseBody.fromString(
            'id,name,restype,repo_owner,repo_name,repo_commit_hash,icon,cover,devices,paid_type\n'
            '$indexId,$indexName,quick_app,owner,repo,$indexCommit,icon.png,cover.png,xmb11,free',
            indexStatus,
          );
        }
        if (path.endsWith('manifest_v2.json')) {
          return _json({
            'item': {
              'id': 'sample',
              'name': 'Sample',
              'restype': 'quick_app',
              'description': '',
              'icon': 'icon.png',
              'cover': 'cover.png',
            },
            'downloads': {
              'xmb11': {'version': '1.0', 'file_name': 'downloads/free.bin'},
              'xmb10': {'version': '1.0', 'file_name': 'downloads/paid.bin'},
            },
            'ext': {'enableAstroBoxCreatorFeatures': creatorFeatures},
          });
        }
        if (path.endsWith('purchase_info')) {
          expect(request.data, {'resourceId': 'sample'});
          if (purchaseStatus != 200) {
            return _json({'error': 'unavailable'}, purchaseStatus);
          }
          return _json({
            'resourceId': 'sample',
            'devices': [
              {
                'deviceId': 'xmb11',
                'version': purchaseVersion,
                'fileName': 'downloads/free.bin',
                'isPaid': false,
              },
              {
                'deviceId': 'xmb10',
                'version': '1.0',
                'fileName': 'downloads/paid.bin',
                'isPaid': true,
              },
            ],
          });
        }
        if (path.endsWith('query_crypto_info')) {
          expect(request.data, {
            'id': 'sample',
            'deviceId': 'xmb11',
            'hash': sha256.convert(downloadBytes).toString(),
          });
          return _json(cryptoResponse, cryptoStatus);
        }
        if (path.endsWith('free.bin')) {
          return ResponseBody.fromBytes(downloadBytes, 200);
        }
        throw StateError('Unexpected request ${request.uri}');
      });
    catalog = AstroBoxRepoCatalog(dio: dio);
  });
  tearDown(() async {
    dio.close();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    await root.delete(recursive: true);
  });

  Future<CommunityResourceDetail> detail() => catalog.getDetail(
    const ResourceRef(source: CommunitySourceId.astroboxRepo, id: 'sample'),
  );
  Future<CommunityResourceDownloadResult> download(
    CommunityResourceDetail resource, [
    int index = 0,
  ]) => catalog.download(
    CommunityDownloadRequest(resource: resource, file: resource.files[index]),
  );
  Matcher error(String code) => throwsA(
    isA<AstroBoxResourceAccessError>().having((e) => e.code, 'code', code),
  );

  test(
    'invalid server index and unavailable detail fall back to GitHub',
    () async {
      catalog = AstroBoxRepoCatalog(dio: dio, useServerMetadata: true);
      final page = await catalog.getPage(const CommunityResourceQuery());
      expect(page.items.single.name, 'Sample');
      expect((await detail()).sourceRepoCommitHash, 'commit');
      expect(requests.map((request) => request.uri.path.split('/').last), [
        'index',
        'index_v2.csv',
        'sample',
        'manifest_v2.json',
        'purchase_info',
      ]);
    },
  );

  test(
    'purchase service failure leaves detail available and blocks download',
    () async {
      purchaseStatus = 503;
      final resource = await detail();
      expect(resource.files, hasLength(2));
      await expectLater(
        download(resource),
        error('astrobox_access_check_failed'),
      );
      expect(
        requests.any((request) => request.uri.path.endsWith('free.bin')),
        isFalse,
      );
    },
  );

  test(
    'server metadata uses the detail commit and downloads directly',
    () async {
      dio.httpClientAdapter = _Adapter((request) {
        requests.add(request);
        final path = request.uri.path;
        if (path.endsWith('/resources/sample')) {
          if (request.headers['If-None-Match'] == '"detail"') {
            return ResponseBody.fromString('', 304);
          }
          return ResponseBody.fromString(
            jsonEncode({
              'item': {
                'id': 'sample',
                'name': 'Sample',
                'restype': 'quick_app',
                'repo_owner': 'owner',
                'repo_name': 'repo',
                'repo_commit_hash': 'new-commit',
              },
              'manifest': {
                'item': {
                  'id': 'sample',
                  'name': 'Sample',
                  'restype': 'quick_app',
                  'description': '',
                  'icon': 'icon.png',
                  'cover': 'cover.png',
                },
                'downloads': {
                  'xmb11': {'version': '1.0', 'file_name': 'free.bin'},
                },
              },
            }),
            200,
            headers: {
              'etag': ['"detail"'],
            },
          );
        }
        expect(request.uri.host, 'raw.githubusercontent.com');
        expect(path, '/owner/repo/new-commit/free.bin');
        return ResponseBody.fromBytes(downloadBytes, 200);
      });
      catalog = AstroBoxRepoCatalog(dio: dio, useServerMetadata: true);
      final resource = await detail();
      expect(resource.coverUrl?.path, '/owner/repo/new-commit/cover.png');
      expect(resource.sourceRepoCommitHash, 'new-commit');
      await download(resource);
      expect(requests, hasLength(3));
      expect(requests[1].headers['If-None-Match'], '"detail"');
    },
  );

  test(
    'loading the first page refreshes the index and the detail commit',
    () async {
      final first = await catalog.getPage(const CommunityResourceQuery());
      expect(first.items.single.name, 'Sample');
      indexName = 'Updated';
      indexCommit = 'new-commit';
      final refreshed = await catalog.getPage(const CommunityResourceQuery());
      expect(refreshed.items.single.name, 'Updated');
      await detail();
      expect(
        requests
            .where((request) => request.uri.path.endsWith('manifest_v2.json'))
            .last
            .uri
            .path,
        contains('/new-commit/'),
      );
    },
  );

  test(
    'a failed index request can be retried using the same catalog',
    () async {
      indexStatus = 503;
      await expectLater(
        catalog.getPage(const CommunityResourceQuery()),
        throwsA(isA<DioException>()),
      );
      indexStatus = 200;
      final recovered = await catalog.getPage(const CommunityResourceQuery());
      expect(recovered.items.single.name, 'Sample');
    },
  );

  test(
    'concurrent first pages share a request and pagination reuses the index',
    () async {
      final pages = await Future.wait([
        catalog.getPage(const CommunityResourceQuery()),
        catalog.getPage(const CommunityResourceQuery(query: 'Sample')),
      ]);
      expect(pages.map((page) => page.items.single.name), ['Sample', 'Sample']);
      await catalog.getPage(const CommunityResourceQuery(page: 1));
      await detail();
      expect(
        requests.where((request) => request.uri.path.endsWith('index_v2.csv')),
        hasLength(1),
      );
    },
  );

  test('failed refresh preserves the snapshot and a successful refresh removes old IDs', () async {
    await catalog.getPage(const CommunityResourceQuery());
    indexStatus = 503;
    await expectLater(
      catalog.getPage(const CommunityResourceQuery()),
      throwsA(isA<DioException>()),
    );
    await detail();
    indexStatus = 200;
    indexId = 'replacement';
    final page = await catalog.getPage(const CommunityResourceQuery());
    expect(page.items.single.ref.id, 'replacement');
    await expectLater(detail(), throwsA(isA<StateError>()));
  });

  test('mixed resource keeps free files installable and blocks paid files before downloading', () async {
    final resource = await detail();
    expect(resource.canDownload, isTrue);
    expect(resource.files.map((file) => file.purchaseRequired), [false, true]);
    await expectLater(
      download(resource, 1),
      error('astrobox_purchase_required'),
    );
    expect(
      requests.any((request) => request.uri.path.endsWith('.bin')),
      isFalse,
    );
    expect(
      requests.any((request) => request.uri.path.endsWith('query_crypto_info')),
      isFalse,
    );
    final result = await download(resource);
    expect(await File(result.path).readAsBytes(), [1, 2, 3]);
    await ManagedTemporaryFiles.release(result.path);
  });

  test(
    'free encrypted file is decrypted before returning the download',
    () async {
      downloadBytes = ciphertext;
      encryptedResponse();
      final result = await download(await detail());
      expect(
        await File(result.path).readAsBytes(),
        utf8.encode('OronBox resource'),
      );
      expect(await File('${result.path}.decrypted').exists(), isFalse);
      await ManagedTemporaryFiles.release(result.path);
    },
  );

  test(
    'decryption spans multiple file chunks and strips only final padding',
    () async {
      downloadBytes = [
        for (var block = 0; block < 8193; block++) ...ciphertext.take(16),
        ...ciphertext.skip(16),
      ];
      encryptedResponse();
      final result = await download(await detail());
      expect(await File(result.path).readAsString(), 'OronBox resource' * 8193);
      expect(
        await decryptAstroBoxResourceBytes(
          Uint8List.fromList(downloadBytes),
          Uint8List.fromList(keyBytes),
        ),
        utf8.encode('OronBox resource' * 8193),
      );
      await ManagedTemporaryFiles.release(result.path);
    },
  );

  test(
    'invalid encrypted length or padding fails and removes temporary files',
    () async {
      final resource = await detail();
      for (final invalid in [
        ciphertext.take(31).toList(),
        ciphertext.take(16).toList(),
      ]) {
        downloadBytes = invalid;
        encryptedResponse();
        await expectLater(
          download(resource),
          error('astrobox_decryption_failed'),
        );
        expect(
          await root
              .list(recursive: true)
              .where((entry) => entry is File)
              .toList(),
          isEmpty,
        );
      }
    },
  );

  test('mismatched hash and invalid key cannot decrypt a download', () async {
    final resource = await detail();
    downloadBytes = ciphertext;
    for (final payload in [
      {'hash': 'wrong', 'key': base64Encode(keyBytes)},
      {'hash': sha256.convert(ciphertext).toString(), 'key': 'invalid'},
    ]) {
      cryptoStatus = 200;
      cryptoResponse = {'payload': payload};
      await expectLater(
        download(resource),
        error('astrobox_access_check_failed'),
      );
      expect(
        await root
            .list(recursive: true)
            .where((entry) => entry is File)
            .toList(),
        isEmpty,
      );
    }
  });

  test('byte decryption accepts the upstream key formats and rejects invalid padding', () async {
    final hex = keyBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    for (final key in [hex, base64Encode(keyBytes)]) {
      expect(
        await decryptAstroBoxResourceBytes(
          ciphertext,
          decodeAstroBoxResourceKey(key),
        ),
        utf8.encode('OronBox resource'),
      );
    }
    const raw = 'abcdefghijklmnopqrstuvwxyz012345';
    expect(decodeAstroBoxResourceKey(raw), utf8.encode(raw));
    for (final invalid in [
      Uint8List(0),
      Uint8List.fromList(ciphertext.take(31).toList()),
      Uint8List.sublistView(ciphertext, 0, 16),
    ]) {
      await expectLater(
        decryptAstroBoxResourceBytes(invalid, Uint8List.fromList(keyBytes)),
        throwsA(anyOf(isA<FormatException>(), isA<ArgumentError>())),
      );
    }
  });

  test('network failures and unexpected crypto responses cannot pass as ordinary files', () async {
    final resource = await detail();
    for (final response in [
      (503, <String, Object?>{'error': 'unavailable'}),
      (200, <String, Object?>{}),
      (401, <String, Object?>{'error': 'unauthorized'}),
    ]) {
      cryptoStatus = response.$1;
      cryptoResponse = response.$2;
      await expectLater(
        download(resource),
        error('astrobox_access_check_failed'),
      );
    }
    expect(
      await root.list(recursive: true).where((entry) => entry is File).toList(),
      isEmpty,
    );
    cryptoStatus = 404;
    cryptoResponse = 'file_not_found';
    final result = await download(resource);
    expect(await File(result.path).readAsBytes(), downloadBytes);
    await ManagedTemporaryFiles.release(result.path);
  });

  test('purchase metadata must match the selected manifest version', () async {
    final resource = await detail();
    purchaseVersion = '2.0';
    await expectLater(
      download(resource),
      error('astrobox_access_check_failed'),
    );
    expect(
      requests.any((request) => request.uri.path.endsWith('.bin')),
      isFalse,
    );
  });

  test('firmware archive assets download without a community lookup', () async {
    final url = Uri.parse(
      'https://github.com/AstralSightStudios/MiWearFirmwareArchives/'
      'releases/download/firmware-release/free.bin',
    );
    final resource = CommunityResourceDetail(
      ref: const ResourceRef(
        source: CommunitySourceId.astroboxRepo,
        id: 'free.bin',
      ),
      name: 'free.bin',
      type: CommunityResourceType.firmware,
      paidType: CommunityPaidType.free,
      authors: const [],
      supportedDevices: const {},
      content: const CommunityResourceContent(
        format: ResourceContentFormat.plainText,
        value: '',
      ),
      files: [
        CommunityResourceFile(
          id: 'free.bin',
          fileName: 'free.bin',
          version: '3.1.33',
          downloadUrl: url,
        ),
      ],
      canDownload: true,
    );
    final result = await download(resource);
    expect(requests.map((request) => request.uri), [url]);
    expect(result.fileName, 'free.bin');
    expect(await File(result.path).readAsBytes(), downloadBytes);
    await ManagedTemporaryFiles.release(result.path);
  });

  test('ordinary resources do not depend on creator APIs', () async {
    creatorFeatures = false;
    final result = await download(await detail());
    expect(
      requests.any(
        (request) =>
            request.uri.host == Uri.parse(AstroBoxResourceAccess.apiBase).host,
      ),
      isFalse,
    );
    expect(await File(result.path).readAsBytes(), [1, 2, 3]);
    await ManagedTemporaryFiles.release(result.path);
  });
}
