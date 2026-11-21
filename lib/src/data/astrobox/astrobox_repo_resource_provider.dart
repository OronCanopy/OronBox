import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:cross_file/cross_file.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:oronbox/src/core/logging/logging_service.dart';
import 'package:oronbox/src/core/network/app_http_transport.dart';
import 'package:oronbox/src/core/network/github_cdn.dart';
import 'package:oronbox/src/core/network/oronbox_metadata_client.dart';
import 'package:oronbox/src/core/storage/managed_temporary_files.dart';
import 'package:oronbox/src/data/astrobox/astrobox_repo_description.dart';
import 'package:oronbox/src/data/astrobox/models/astrobox_models.dart';
import 'package:oronbox/src/data/community/community_source.dart';
import 'package:oronbox/src/device/xiaomi/xiaomi_device_catalog.dart';
import 'package:oronbox/src/features/resources/domain/community_resource.dart';
import 'package:oronbox/src/features/resources/domain/resource_catalog.dart';

import 'astrobox_resource_access.dart';
import 'astrobox_resource_decryption.dart';
import 'astrobox_resource_decryption_stub.dart'
    if (dart.library.io) 'astrobox_resource_decryption_io.dart';

bool astroBoxManifestUsesCreatorFeatures(AstroBoxManifest manifest) =>
    manifest.ext['enableAstroBoxCreatorFeatures'] == true;

class AstroBoxRepoCatalog implements CommunityResourceCatalog {
  AstroBoxRepoCatalog({
    Dio? dio,
    this.cdn = GitHubCdn.raw,
    bool useServerMetadata = false,
  }) : _dio = dio ?? createAppHttpTransport() {
    _metadata = useServerMetadata ? OronBoxMetadataClient(_dio) : null;
  }

  final Dio _dio;
  static final _log = getLogger('AstroBoxRepoCatalog');
  late final OronBoxMetadataClient? _metadata;
  final GitHubCdn cdn;
  Future<List<AstroBoxIndexItem>>? _indexRequest;
  final _manifests = <String, (String, AstroBoxManifest)>{};

  Future<void> refreshUpdateIndex() async {
    await _fetchIndex(refresh: true);
  }

  Future<AstroBoxManifest?> findUpdateManifest(String id) async {
    if (!_indexById.containsKey(id)) return null;
    try {
      final (_, manifest) = await _resourceManifest(id);
      return manifest;
    } on DioException catch (error) {
      if (_metadata != null && error.response?.statusCode == 404) return null;
      rethrow;
    }
  }

  List<AstroBoxIndexItem>? _index;
  final Map<String, AstroBoxIndexItem> _indexById = {};

  static const String _repoBase =
      'https://raw.githubusercontent.com/AstralSightStudios/AstroBox-Repo/refs/heads/main';
  static const _metadataBase = 'sources/astrobox';

  @override
  CommunitySourceId get sourceId => CommunitySourceId.astroboxRepo;

  @override
  String get displayName => sourceId.displayName;

  @override
  CommunityCatalogCapabilities get capabilities =>
      const CommunityCatalogCapabilities(search: true, serverSort: false);

  @override
  Future<CommunityResourcePage> getPage(CommunityResourceQuery query) async {
    var items = List<AstroBoxIndexItem>.from(
      await _fetchIndex(refresh: query.page == 0),
    );
    if (query.type != null) {
      items = items.where((item) => _mapType(item.type) == query.type).toList();
    }
    if (query.hidePaid) {
      items = items
          .where((item) => item.paidType != AstroBoxPaidType.paid)
          .toList();
    }
    if (query.hideForcePaid) {
      items = items
          .where((item) => item.paidType != AstroBoxPaidType.forcePaid)
          .toList();
    }
    if (query.selectedDevices.isNotEmpty) {
      items = items
          .where((item) => item.devices.any(query.selectedDevices.contains))
          .toList();
    }
    final needle = query.query.trim().toLowerCase();
    if (needle.isNotEmpty) {
      items = items.where((item) {
        return item.name.toLowerCase().contains(needle) ||
            item.tags.any((tag) => tag.toLowerCase().contains(needle));
      }).toList();
    }
    switch (query.sort) {
      case CommunitySortRule.recommendation:
        items = items.reversed.toList();
      case CommunitySortRule.random:
        // A deterministic seed prevents duplicated/skipped entries between pages.
        items.shuffle(Random(0));
      case CommunitySortRule.name:
        items.sort((a, b) => a.name.compareTo(b.name));
      case CommunitySortRule.time:
        items = items.reversed.toList();
    }
    final start = query.page * query.pageSize;
    final pageItems = start >= items.length
        ? const <AstroBoxIndexItem>[]
        : items.sublist(start, min(start + query.pageSize, items.length));
    return CommunityResourcePage(
      items: pageItems.map(_summaryFromIndex).toList(),
      page: query.page,
      hasMore: start + pageItems.length < items.length,
      total: items.length,
    );
  }

  @override
  Future<CommunityResourceDetail> getDetail(ResourceRef ref) async {
    _requireSource(ref);
    final (item, manifest) = await _resourceManifest(ref.id);
    final usesCreatorFeatures = astroBoxManifestUsesCreatorFeatures(manifest);
    final purchases = usesCreatorFeatures
        ? await _detailPurchaseInfo(manifest.item.id)
        : const <String, AstroBoxPurchaseDevice>{};
    final iconUrl = _assetUri(item, manifest.item.icon);
    final coverUrl = _assetUri(item, manifest.item.cover) ?? iconUrl;
    final files = <CommunityResourceFile>[];
    for (final entry in manifest.downloads.entries) {
      final download = entry.value;
      final name = download.fileName.trim();
      final purchaseInfo = purchases[entry.key];
      files.add(
        CommunityResourceFile(
          id: entry.key,
          fileName: name,
          displayName: download.displayName,
          version: download.version,
          versionCode: download.versionCode,
          sha256: download.sha256,
          purchaseRequired:
              purchaseInfo != null &&
              purchaseInfo.version == download.version &&
              purchaseInfo.fileName == download.fileName &&
              purchaseInfo.isPaid,
          downloadUrl: Uri.tryParse(_resolveDownloadUrl(item, download)),
          supportedDevices: entry.key == 'default' ? const {} : {entry.key},
        ),
      );
    }
    final manifestItem = manifest.item;
    final description = normalizeAstroBoxRepoDescription(
      manifestItem.description,
    );
    final purchase = manifest.links
        .where(
          (link) =>
              link.title.trim() == '购买链接' ||
              link.title.trim() == '购买完整版' ||
              link.title.trim().toLowerCase() == 'purchase full version',
        )
        .map((link) => Uri.tryParse(_resolveAssetUrl(item, link.url)))
        .whereType<Uri>()
        .firstOrNull;
    return CommunityResourceDetail(
      ref: ref,
      name: manifestItem.name,
      type: _mapType(manifestItem.restype),
      paidType: _mapPaid(manifestItem.paidType ?? item.paidType),
      authors: manifestItem.author
          .where((author) => author.name.isNotEmpty)
          .map((author) => CommunityResourceAuthor(name: author.name))
          .toList(),
      supportedDevices: files.expand((file) => file.supportedDevices).toSet(),
      iconUrl: iconUrl,
      coverUrl: coverUrl,
      publicUrl: _repositoryUrl(item),
      tags: item.tags,
      sourceRepoOwner: item.repoOwner,
      sourceRepoName: item.repoName,
      sourceRepoCommitHash: item.repoCommitHash,
      purchaseLink: purchase,
      summary: description.value,
      content: CommunityResourceContent(
        format: ResourceContentFormat.markdown,
        value: description.value,
      ),
      previews: manifestItem.preview
          .map((path) => _assetUri(item, path))
          .whereType<Uri>()
          .toList(),
      previewImages: manifestItem.preview
          .map((path) => _assetUri(item, path))
          .whereType<Uri>()
          .map((url) => CommunityResourceImage(url: url))
          .toList(),
      links: manifest.links
          .where(
            (link) =>
                link.title.trim() != '购买链接' &&
                link.title.trim() != '购买完整版' &&
                link.title.trim().toLowerCase() != 'purchase full version',
          )
          .map(
            (link) => CommunityResourceLink(
              title: link.title,
              url: Uri.parse(_resolveAssetUrl(item, link.url)),
            ),
          )
          .toList(),
      files: files,
    );
  }

  @override
  Future<List<CommunityResourceDevice>> getDevices() async {
    const url = '$_repoBase/devices_v2.json';
    final map = await _loadMetadata(
      '$_metadataBase/devices',
      (body) => AstroBoxDeviceMap.fromJson(_decodeJsonObject(body)),
      () async => AstroBoxDeviceMap.fromJson(await _fetchJsonObject(url)),
    );
    return map.xiaomi.values
        .map(
          (device) => CommunityResourceDevice(
            codename: _normalizeDeviceKey(device.id),
            name: device.name,
            description: device.description,
          ),
        )
        .toList();
  }

  @override
  Future<CommunityResourceDownloadResult> download(
    CommunityDownloadRequest request,
  ) async {
    _requireSource(request.resource.ref);
    final archiveUrl = _firmwareArchiveUrl(request);
    if (archiveUrl != null) {
      return _downloadFile(request, archiveUrl, request.file.fileName);
    }
    final (item, manifest) = await _resourceManifest(request.resource.ref.id);
    final access = AstroBoxResourceAccess(_dio);
    final requiresCheck = astroBoxManifestUsesCreatorFeatures(manifest);
    final download = manifest.downloads[request.file.id];
    if (download == null ||
        (request.file.versionCode != null &&
            request.file.versionCode != download.versionCode) ||
        (request.file.sha256 != null &&
            request.file.sha256?.toLowerCase() !=
                download.sha256?.toLowerCase())) {
      throw StateError('AstroBox resource file changed');
    }
    final downloadUrl = Uri.parse(_resolveDownloadUrl(item, download));
    String deviceId = request.file.id;
    if (requiresCheck) {
      final devices = await _purchaseInfo(manifest.item.id);
      final selected = devices[request.file.id];
      if (selected == null ||
          selected.version != download.version ||
          selected.fileName != download.fileName) {
        throw const AstroBoxResourceAccessError('astrobox_access_check_failed');
      }
      deviceId = selected.deviceId;
      if (selected.isPaid) {
        throw const AstroBoxResourceAccessError('astrobox_purchase_required');
      }
    }
    return _downloadFile(
      request,
      downloadUrl,
      download.displayName ?? download.fileName,
      decryptionKey: requiresCheck
          ? (hash) => access.decryptionKey(
              resourceId: manifest.item.id,
              deviceId: deviceId,
              hash: hash,
            )
          : null,
    );
  }

  Uri? _firmwareArchiveUrl(CommunityDownloadRequest request) {
    final file = request.file;
    final url = file.downloadUrl;
    if (request.resource.type != CommunityResourceType.firmware ||
        request.resource.paidType != CommunityPaidType.free ||
        file.encrypted ||
        file.purchaseRequired ||
        url == null ||
        url.scheme != 'https' ||
        url.authority != 'github.com' ||
        url.hasQuery ||
        url.hasFragment) {
      return null;
    }
    final segments = url.pathSegments;
    if (segments.length == 6 &&
        segments[0] == 'AstralSightStudios' &&
        segments[1] == 'MiWearFirmwareArchives' &&
        segments[2] == 'releases' &&
        segments[3] == 'download' &&
        segments[4].isNotEmpty &&
        !segments[4].contains('/') &&
        segments[5] == file.fileName &&
        file.fileName.endsWith('.bin')) {
      return url;
    }
    return null;
  }

  Future<CommunityResourceDownloadResult> _downloadFile(
    CommunityDownloadRequest request,
    Uri downloadUrl,
    String name, {
    Future<Uint8List?> Function(String hash)? decryptionKey,
  }) async {
    final fileName = _sanitizeLocalFilename(name);
    request.onProgress?.call(0);
    if (downloadUrl.scheme.isEmpty) {
      throw StateError('AstroBox resource file has an invalid download URL');
    }
    if (kIsWeb) {
      final response = await _dio.get<Uint8List>(
        downloadUrl.toString(),
        options: Options(responseType: ResponseType.bytes),
        onReceiveProgress: (received, total) {
          if (total > 0) request.onProgress?.call(received / total);
        },
      );
      var bytes = response.data;
      if (bytes == null || bytes.isEmpty) {
        throw StateError('AstroBox resource download returned empty data');
      }
      if (decryptionKey != null) {
        final key = await decryptionKey(sha256.convert(bytes).toString());
        if (key != null) {
          try {
            bytes = await decryptAstroBoxResourceBytes(bytes, key);
          } catch (_) {
            throw const AstroBoxResourceAccessError(
              'astrobox_decryption_failed',
            );
          }
        }
      }
      request.onProgress?.call(1, status: 'finished');
      return CommunityResourceDownloadResult(
        path: '/oronbox_downloads/$fileName',
        fileName: fileName,
        bytes: bytes,
      );
    }
    final path = await ManagedTemporaryFiles.create(
      TemporaryFilePurpose.downloads,
      fileName,
      (destination) async {
        await _dio.download(
          downloadUrl.toString(),
          destination,
          onReceiveProgress: (received, total) {
            if (total > 0) request.onProgress?.call(received / total);
          },
        );
        if (decryptionKey != null) {
          final hash = await sha256.bind(XFile(destination).openRead()).first;
          final key = await decryptionKey(hash.toString());
          if (key != null) {
            try {
              await decryptAstroBoxResourceFile(destination, key);
            } catch (_) {
              throw const AstroBoxResourceAccessError(
                'astrobox_decryption_failed',
              );
            }
          }
        }
      },
    );
    request.onProgress?.call(1, status: 'finished');
    return CommunityResourceDownloadResult(path: path, fileName: fileName);
  }

  @override
  Future<int?> probeDownloadSize(CommunityResourceFile file) async {
    if (file.size != null) return file.size;
    final url = file.downloadUrl;
    if (url == null) return null;
    final response = await _dio.head<Object>(url.toString());
    return int.tryParse(
      response.headers.value(Headers.contentLengthHeader) ?? '',
    );
  }

  Future<List<AstroBoxIndexItem>> _fetchIndex({bool refresh = false}) {
    if (_indexRequest case final request?) return request;
    if (!refresh && _index != null) return Future.value(_index!);
    return _indexRequest = _loadIndex()
        .then((items) {
          _index = items;
          _indexById
            ..clear()
            ..addEntries(items.map((item) => MapEntry(item.id, item)));
          _manifests.removeWhere(
            (id, entry) => _indexById[id]?.repoCommitHash != entry.$1,
          );
          return items;
        })
        .whenComplete(() => _indexRequest = null);
  }

  Future<List<AstroBoxIndexItem>> _loadIndex() =>
      _loadMetadata('$_metadataBase/index', _parseIndex, _loadDirectIndex);

  Future<List<AstroBoxIndexItem>> _loadDirectIndex() async => _parseIndex(
    (await _dio.get<String>('$_repoBase/index_v2.csv')).data ?? '',
  );

  List<AstroBoxIndexItem> _parseIndex(String data) {
    final rows = _parseCsvRows(_stripZeroWidth(data));
    final headers = rows.isEmpty
        ? const <String>[]
        : rows.first.map((value) => value.trim()).toList();
    if (!const [
      'id',
      'name',
      'restype',
      'repo_owner',
      'repo_name',
    ].every(headers.contains)) {
      throw const FormatException('Invalid AstroBox index headers');
    }
    final items = <AstroBoxIndexItem>[];
    for (final row in rows.skip(1)) {
      if (row.length < headers.length) continue;
      final values = <String, String>{
        for (var i = 0; i < headers.length; i++) headers[i]: row[i].trim(),
      };
      final id = values['id'] ?? '';
      if (id.isEmpty || id == '<placeholder>') continue;
      items.add(_indexItem(values));
    }
    return items;
  }

  AstroBoxIndexItem _indexItem(Map<String, String> values) => AstroBoxIndexItem(
    id: values['id'] ?? '',
    name: values['name'] ?? '',
    type: _parseDtoType(values['restype']),
    repoOwner: values['repo_owner'] ?? '',
    repoName: values['repo_name'] ?? '',
    repoCommitHash: values['repo_commit_hash'] ?? '',
    icon: values['icon'] ?? '',
    cover: values['cover'] ?? '',
    tags: _splitSemicolon(values['tags']),
    deviceVendors: _splitSemicolon(values['device_vendors']),
    devices: _normalizeDeviceKeys(_splitSemicolon(values['devices'])),
    paidType: _parseDtoPaid(values['paid_type']),
  );

  Future<(AstroBoxIndexItem, AstroBoxManifest)> _resourceManifest(String id) =>
      _loadMetadata(
        '$_metadataBase/resources/${Uri.encodeComponent(id)}',
        (body) {
          final result = _decodeJsonObject(body);
          final values = result['item'];
          final raw = result['manifest'];
          if (values is! Map<String, dynamic> ||
              values['id'] != id ||
              raw is! Map<String, dynamic> ||
              values.values.any((value) => value is! String)) {
            throw const FormatException('Invalid AstroBox resource metadata');
          }
          final item = _indexItem(values.cast<String, String>());
          return (item, _parseManifest(item, raw));
        },
        () async {
          final item = await _findIndexItem(id);
          return (item, await _fetchManifest(item));
        },
      );

  Future<T> _loadMetadata<T>(
    String path,
    T Function(String body) parse,
    Future<T> Function() loadDirect,
  ) async {
    final metadata = _metadata;
    if (metadata != null) {
      try {
        return parse(await metadata.get(path));
      } on DioException catch (error) {
        if (error.type == DioExceptionType.cancel) rethrow;
        _log.fine('Metadata request failed for $path', error);
      } on FormatException catch (error) {
        _log.fine('Invalid metadata for $path', error);
      } on TypeError catch (error) {
        _log.fine('Invalid metadata for $path', error);
      }
    }
    return loadDirect();
  }

  Future<AstroBoxIndexItem> _findIndexItem(String id) async {
    await _fetchIndex();
    final indexed = _indexById[id];
    if (indexed != null) return indexed;
    if (_metadata != null) {
      final items = await _loadDirectIndex();
      final item = items.where((item) => item.id == id).firstOrNull;
      if (item != null) return item;
    }
    throw StateError('AstroBox resource not found: $id');
  }

  Future<AstroBoxManifest> _fetchManifest(AstroBoxIndexItem item) async {
    final commit = item.repoCommitHash;
    final cached = _manifests[item.id];
    if (commit.isNotEmpty && cached?.$1 == commit) return cached!.$2;
    final manifest = await _loadManifest(item);
    if (commit.isNotEmpty && _indexById[item.id]?.repoCommitHash == commit) {
      _manifests[item.id] = (commit, manifest);
    }
    return manifest;
  }

  Future<AstroBoxManifest> _loadManifest(AstroBoxIndexItem item) async {
    final base = _buildRepoRawUrl(item);
    final file = item.id.startsWith('LegacyItem')
        ? 'manifest.json'
        : 'manifest_v2.json';
    return _parseManifest(item, await _fetchJsonObject('$base/$file'));
  }

  AstroBoxManifest _parseManifest(
    AstroBoxIndexItem item,
    Map<String, dynamic> raw,
  ) => item.id.startsWith('LegacyItem')
      ? _legacyManifestV1ToV2(raw, item)
      : _normalizeManifestDeviceKeys(AstroBoxManifest.fromJson(raw));

  CommunityResource _summaryFromIndex(AstroBoxIndexItem item) {
    return CommunityResource(
      ref: ResourceRef(source: sourceId, id: item.id),
      name: item.name,
      type: _mapType(item.type),
      paidType: _mapPaid(item.paidType),
      authors: item.repoOwner.isEmpty
          ? const []
          : [CommunityResourceAuthor(name: item.repoOwner)],
      supportedDevices: item.devices.toSet(),
      iconUrl: _assetUri(item, item.icon),
      coverUrl: _assetUri(item, item.cover) ?? _assetUri(item, item.icon),
      publicUrl: _repositoryUrl(item),
      tags: item.tags,
      sourceRepoOwner: item.repoOwner,
      sourceRepoName: item.repoName,
      sourceRepoCommitHash: item.repoCommitHash,
    );
  }

  Future<Map<String, dynamic>> _fetchJsonObject(String url) async {
    final response = await _dio.get<String>(url);
    return _decodeJsonObject(response.data ?? '');
  }

  Map<String, dynamic> _decodeJsonObject(String body) {
    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return decoded.cast<String, dynamic>();
    throw const FormatException('AstroBox metadata is not a JSON object');
  }

  String _resolveAssetUrl(AstroBoxIndexItem item, String path) {
    final value = path.trim();
    if (value.isEmpty) return '';
    if (value.startsWith('http://') ||
        value.startsWith('https://') ||
        value.startsWith('data:') ||
        value.startsWith('/')) {
      return rewriteGithubCdnUrl(value, cdn);
    }
    return rewriteGithubCdnUrl(
      '${_buildRepoRawUrl(item)}/${Uri.encodeComponent(value.trimStartMatches('/'))}',
      cdn,
    );
  }

  Uri? _assetUri(AstroBoxIndexItem item, String path) {
    final url = _resolveAssetUrl(item, path);
    return url.isEmpty ? null : Uri.tryParse(url);
  }

  String _resolveDownloadUrl(
    AstroBoxIndexItem item,
    AstroBoxManifestDownload download,
  ) {
    if (download.url?.trim().isNotEmpty == true) {
      return _resolveAssetUrl(item, download.url!);
    }
    return _resolveAssetUrl(item, download.fileName);
  }

  String _buildRepoRawUrl(AstroBoxIndexItem item) =>
      'https://raw.githubusercontent.com/${item.repoOwner}/${item.repoName}/${item.repoCommitHash}';

  Uri? _repositoryUrl(AstroBoxIndexItem item) {
    if (item.repoOwner.trim().isEmpty || item.repoName.trim().isEmpty) {
      return null;
    }
    return Uri.https('github.com', '/${item.repoOwner}/${item.repoName}');
  }

  CommunityResourceType _mapType(AstroBoxResourceType value) => switch (value) {
    AstroBoxResourceType.quickApp => CommunityResourceType.quickApp,
    AstroBoxResourceType.watchface => CommunityResourceType.watchface,
    AstroBoxResourceType.firmware => CommunityResourceType.firmware,
    AstroBoxResourceType.canopus => CommunityResourceType.canopus,
    AstroBoxResourceType.resPack => CommunityResourceType.resPack,
  };

  CommunityPaidType _mapPaid(AstroBoxPaidType value) => switch (value) {
    AstroBoxPaidType.free => CommunityPaidType.free,
    AstroBoxPaidType.paid => CommunityPaidType.paid,
    AstroBoxPaidType.forcePaid => CommunityPaidType.forcePaid,
  };

  AstroBoxResourceType _parseDtoType(String? value) => switch (value) {
    'watchface' => AstroBoxResourceType.watchface,
    'firmware' => AstroBoxResourceType.firmware,
    'canopus' => AstroBoxResourceType.canopus,
    'res_pack' => AstroBoxResourceType.resPack,
    _ => AstroBoxResourceType.quickApp,
  };

  AstroBoxPaidType _parseDtoPaid(String? value) => switch (value) {
    'paid' => AstroBoxPaidType.paid,
    'force_paid' => AstroBoxPaidType.forcePaid,
    _ => AstroBoxPaidType.free,
  };

  List<String> _splitSemicolon(String? value) => value == null || value.isEmpty
      ? const []
      : value
            .split(';')
            .map((part) => part.trim())
            .where((part) => part.isNotEmpty)
            .toList();

  List<List<String>> _parseCsvRows(String csv) => const LineSplitter()
      .convert(csv)
      .where((line) => line.trim().isNotEmpty)
      .map(_parseCsvLine)
      .toList();

  List<String> _parseCsvLine(String line) {
    final values = <String>[];
    final buffer = StringBuffer();
    var quoted = false;
    for (var index = 0; index < line.length; index++) {
      final character = line[index];
      if (character == '"') {
        if (quoted && index + 1 < line.length && line[index + 1] == '"') {
          buffer.write(character);
          index++;
        } else {
          quoted = !quoted;
        }
      } else if (character == ',' && !quoted) {
        values.add(buffer.toString());
        buffer.clear();
      } else {
        buffer.write(character);
      }
    }
    values.add(buffer.toString());
    return values;
  }

  String _stripZeroWidth(String value) =>
      value.replaceAll(RegExp('[\u200b\u200c\u200d\u2060\ufeff]'), '');

  Future<Map<String, AstroBoxPurchaseDevice>> _purchaseInfo(
    String resourceId,
  ) async {
    final devices = await AstroBoxResourceAccess(_dio).purchaseInfo(resourceId);
    return {
      for (final entry in devices.entries)
        _normalizeDeviceKey(entry.key): entry.value,
    };
  }

  Future<Map<String, AstroBoxPurchaseDevice>> _detailPurchaseInfo(
    String resourceId,
  ) async {
    try {
      return await _purchaseInfo(resourceId);
    } on AstroBoxResourceAccessError catch (error) {
      _log.fine('Unable to display purchase status for $resourceId', error);
      return const {};
    }
  }

  List<String> _normalizeDeviceKeys(List<String> keys) => keys
      .map(_normalizeDeviceKey)
      .where((key) => key.isNotEmpty)
      .toSet()
      .toList();

  String _normalizeDeviceKey(String value) {
    final normalized = normalizeXiaomiWearableCodename(value);
    return normalized.isEmpty ? value.trim() : normalized;
  }

  AstroBoxManifest _normalizeManifestDeviceKeys(AstroBoxManifest manifest) {
    return manifest.copyWith(
      downloads: {
        for (final entry in manifest.downloads.entries)
          _normalizeDeviceKey(entry.key): entry.value,
      },
    );
  }

  static const _fallbackV1DeviceKeyMap = {
    'n62': 'xmws3',
    'o62': 'xmws4',
    'o62m': 'xmws4xring',
    'p62': 'xmws5',
    'p62m': 'xmws5xring',
    'o65': 'xmrw5',
    'o65m': 'xmrw5xring',
    'n66': 'xmb9',
    'n67': 'xmb9p',
    'o66': 'xmb10',
    'o66nfc': 'xmb10nfc',
    'p65': 'xmrw6',
  };

  AstroBoxManifest _legacyManifestV1ToV2(
    Map<String, dynamic> raw,
    AstroBoxIndexItem item,
  ) {
    final itemMap = raw['item'] is Map
        ? (raw['item'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    final downloadMap = raw['downloads'] is Map
        ? (raw['downloads'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    final downloads = <String, AstroBoxManifestDownload>{};
    for (final entry in downloadMap.entries) {
      if (entry.value is! Map) continue;
      final data = (entry.value as Map).cast<String, dynamic>();
      final mappedKey =
          _fallbackV1DeviceKeyMap[entry.key] ?? _normalizeDeviceKey(entry.key);
      downloads[mappedKey] = AstroBoxManifestDownload(
        version: data['version']?.toString() ?? '',
        fileName: data['file_name']?.toString() ?? '',
        url: data['url']?.toString(),
        sha256: data['sha256']?.toString(),
        displayName: data['display_name']?.toString(),
      );
    }
    final authors = _parseAuthors(itemMap['author']);
    return AstroBoxManifest(
      item: AstroBoxManifestItem(
        id: item.id,
        restype: item.type,
        name: itemMap['name']?.toString() ?? item.name,
        description: itemMap['description']?.toString() ?? '',
        preview: _toStringList(itemMap['preview']),
        icon: itemMap['icon']?.toString() ?? item.icon,
        cover: itemMap['cover']?.toString() ?? item.cover,
        paidType: item.paidType,
        author: authors.isEmpty
            ? [AstroBoxManifestAuthor(name: item.repoOwner)]
            : authors,
      ),
      downloads: downloads,
    );
  }

  List<AstroBoxManifestAuthor> _parseAuthors(Object? value) {
    if (value is List) {
      return value
          .whereType<Map>()
          .map((entry) {
            final data = entry.cast<String, dynamic>();
            return AstroBoxManifestAuthor(name: data['name']?.toString() ?? '');
          })
          .where((author) => author.name.isNotEmpty)
          .toList();
    }
    if (value is String && value.isNotEmpty) {
      return [AstroBoxManifestAuthor(name: value)];
    }
    return const [];
  }

  List<String> _toStringList(Object? value) => value is List
      ? value.map((entry) => entry.toString()).toList()
      : const [];

  String _sanitizeLocalFilename(String value) {
    final result = value.trim().replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    return result.isEmpty || result == '.' || result == '..'
        ? 'download'
        : result;
  }

  void _requireSource(ResourceRef ref) {
    if (ref.source != sourceId) {
      throw ArgumentError.value(ref, 'ref', 'Wrong resource source');
    }
  }
}

extension on String {
  String trimStartMatches(String prefix) {
    var value = this;
    while (value.startsWith(prefix)) {
      value = value.substring(prefix.length);
    }
    return value;
  }
}
