import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:oronbox/src/core/logging/logging_service.dart';
import 'package:oronbox/src/core/network/app_http_transport.dart';
import 'package:oronbox/src/features/plugins/application/plugin_repository.dart';
import 'package:oronbox/src/features/plugins/domain/plugin_package.dart';

class AstroBoxNgPluginRepository implements PluginRepository {
  AstroBoxNgPluginRepository({Dio? dio})
    : _dio = dio ?? createAppHttpTransport();

  static final _log = getLogger('AstroBoxNgPluginRepository');
  static const primaryIndexUrl =
      'https://raw.githubusercontent.com/AstralSightStudios/AstroBox-NG-Plugin-Repo/main/index.json';
  static const fallbackIndexUrl =
      'https://fastly.jsdelivr.net/gh/AstralSightStudios/AstroBox-NG-Plugin-Repo@main/index.json';

  final Dio _dio;
  List<PluginCatalogEntry>? _cachedEntries;
  final Map<String, _AbNgPluginSourceMetadata> _metadataMap = {};

  @override
  String get id => 'astrobox_ng';

  @override
  String get displayName => 'AstroBox-NG';

  @override
  Future<List<PluginCatalogEntry>> load({bool force = false}) async {
    if (!force && _cachedEntries != null) {
      return _cachedEntries!;
    }

    dynamic responseData;
    try {
      final res = await _dio.get<String>(
        primaryIndexUrl,
        options: Options(responseType: ResponseType.plain),
      );
      responseData = jsonDecode(res.data!);
    } catch (e) {
      _log.warning('Failed to fetch from primary repo, trying fallback: $e');
      final res = await _dio.get<String>(
        fallbackIndexUrl,
        options: Options(responseType: ResponseType.plain),
      );
      responseData = jsonDecode(res.data!);
    }

    if (responseData is! Map<String, dynamic> ||
        responseData['plugins'] is! List) {
      throw const FormatException('Invalid AstroBox-NG plugin index format');
    }

    final rawPlugins = responseData['plugins'] as List;
    final entries = <PluginCatalogEntry>[];
    _metadataMap.clear();

    for (var i = 0; i < rawPlugins.length; i++) {
      final item = rawPlugins[i];
      if (item is! Map<String, dynamic>) continue;
      final rawRepo = (item['repo'] ?? '').toString();
      final folder = (item['folder'] ?? '').toString();
      final manifest = item['manifest'];
      if (manifest is! Map<String, dynamic>) continue;

      final PluginManifest identity;
      try {
        identity = const PluginPackageReader().readManifest(
          Uint8List.fromList(utf8.encode(jsonEncode(manifest))),
        );
      } on FormatException {
        continue;
      }
      final name = identity.name;
      final version = identity.version;
      final description = (manifest['description'] ?? '').toString().trim();
      final author = (manifest['author'] ?? '').toString().trim();
      final iconName = (manifest['icon'] ?? '').toString().trim();
      final entryWasm = (manifest['entry'] ?? '').toString().trim();
      final permissions = (manifest['permissions'] as List? ?? [])
          .map((e) => e.toString())
          .toList(growable: false);
      final additionalFiles = (manifest['additional_files'] as List? ?? [])
          .map((e) => e.toString())
          .toList(growable: false);

      final normalizedBase = _buildFolderBase(rawRepo, folder);
      final iconUrl = iconName.isNotEmpty ? '$normalizedBase$iconName' : null;
      final pluginId = 'abng_${name.hashCode.toRadixString(16)}';

      final meta = _AbNgPluginSourceMetadata(
        baseUrl: normalizedBase,
        manifestRaw: manifest,
        entryFile: entryWasm,
        iconFile: iconName,
        additionalFiles: additionalFiles,
      );
      _metadataMap[pluginId] = meta;

      entries.add(
        PluginCatalogEntry(
          source: id,
          id: pluginId,
          installedId: identity.id,
          runtime: identity.runtime.name,
          name: name,
          version: version,
          author: author,
          description: description,
          permissions: permissions,
          iconUrl: iconUrl,
        ),
      );
    }

    _cachedEntries = entries;
    return entries;
  }

  @override
  Future<Uint8List> download(PluginCatalogEntry entry) async {
    final meta = _metadataMap[entry.id];
    if (meta == null) {
      throw StateError('Plugin metadata not found for entry ${entry.id}');
    }

    final archive = Archive();

    // 1. manifest.json
    final manifestBytes = utf8.encode(jsonEncode(meta.manifestRaw));
    archive.addFile(
      ArchiveFile('manifest.json', manifestBytes.length, manifestBytes),
    );

    // 2. entry wasm file
    if (meta.entryFile.isNotEmpty) {
      final entryBytes = await _downloadFile(
        '${meta.baseUrl}${meta.entryFile}',
      );
      archive.addFile(
        ArchiveFile(meta.entryFile, entryBytes.length, entryBytes),
      );
    }

    // 3. icon file
    if (meta.iconFile.isNotEmpty) {
      try {
        final iconBytes = await _downloadFile(
          '${meta.baseUrl}${meta.iconFile}',
        );
        archive.addFile(
          ArchiveFile(meta.iconFile, iconBytes.length, iconBytes),
        );
      } catch (e) {
        _log.warning('Optional icon download failed: $e');
      }
    }

    // 4. additional files
    for (final addFile in meta.additionalFiles) {
      if (addFile.isEmpty) continue;
      try {
        final fileBytes = await _downloadFile('${meta.baseUrl}$addFile');
        archive.addFile(ArchiveFile(addFile, fileBytes.length, fileBytes));
      } catch (e) {
        _log.warning('Additional file $addFile download failed: $e');
      }
    }

    final encodedZip = ZipEncoder().encode(archive);
    return Uint8List.fromList(encodedZip);
  }

  Future<Uint8List> _downloadFile(String url) async {
    final res = await _dio.get<List<int>>(
      url,
      options: Options(responseType: ResponseType.bytes),
    );
    return Uint8List.fromList(res.data!);
  }

  static String _buildFolderBase(String repoRaw, String folder) {
    var repo = repoRaw.trim();
    if (repo.startsWith('https://github.com/')) {
      repo = repo.replaceFirst(
        'https://github.com/',
        'https://raw.githubusercontent.com/',
      );
      if (!repo.contains('/refs/heads/') && !repo.contains('/raw/')) {
        repo = '$repo/refs/heads/main/';
      }
    }
    if (!repo.endsWith('/')) repo = '$repo/';
    final cleanFolder = folder.trim().replaceAll(RegExp(r'^/+|/+$'), '');
    return cleanFolder.isNotEmpty ? '$repo$cleanFolder/' : repo;
  }
}

class _AbNgPluginSourceMetadata {
  const _AbNgPluginSourceMetadata({
    required this.baseUrl,
    required this.manifestRaw,
    required this.entryFile,
    required this.iconFile,
    required this.additionalFiles,
  });

  final String baseUrl;
  final Map<String, dynamic> manifestRaw;
  final String entryFile;
  final String iconFile;
  final List<String> additionalFiles;
}
