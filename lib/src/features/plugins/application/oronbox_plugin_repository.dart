import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:oronbox/src/core/constants/oronbox_server.dart';
import 'package:oronbox/src/core/network/app_http_transport.dart';

import 'plugin_repository.dart';

class OronBoxPluginRepository implements PluginRepository {
  OronBoxPluginRepository({Dio? dio, this.baseUrl = oronBoxServerBaseUrl})
    : _dio = dio ?? createAppHttpTransport();

  final Dio _dio;
  final String baseUrl;
  List<PluginCatalogEntry>? _entries;
  final Map<String, String> _downloads = {};

  @override
  String get id => 'oronbox';

  @override
  String get displayName => 'OronBox';

  @override
  Future<List<PluginCatalogEntry>> load({bool force = false}) async {
    if (!force && _entries != null) return _entries!;
    final response = await _dio.get<Object?>('$baseUrl/api/v1/plugins');
    final root = response.data;
    if (root is! Map || root['plugins'] is! List) {
      throw const FormatException('Invalid OronBox plugin catalog');
    }
    final entries = <PluginCatalogEntry>[];
    final downloads = <String, String>{};
    for (final row in root['plugins'] as List) {
      final plugin = (row as Map).cast<String, Object?>();
      final pluginId = plugin['id'] as String;
      downloads[pluginId] = plugin['packageUrl'] as String;
      final icon = plugin['iconUrl'] as String?;
      entries.add(
        PluginCatalogEntry(
          source: id,
          id: pluginId,
          installedId: pluginId,
          name: plugin['name'] as String,
          version: plugin['version'] as String,
          author: plugin['author'] as String? ?? '',
          description: plugin['description'] as String? ?? '',
          permissions: (plugin['permissions'] as List? ?? const [])
              .cast<String>(),
          runtime: plugin['runtime'] as String? ?? 'js',
          iconUrl: icon == null
              ? null
              : Uri.parse(baseUrl).resolve(icon).toString(),
        ),
      );
    }
    _downloads
      ..clear()
      ..addAll(downloads);
    return _entries = entries;
  }

  @override
  Future<Uint8List> download(PluginCatalogEntry entry) async {
    if (entry.source != id) {
      throw StateError('Plugin belongs to another source');
    }
    if (_entries == null) await load();
    final path = _downloads[entry.id];
    if (path == null) throw StateError('Plugin not found: ${entry.id}');
    final response = await _dio.get<List<int>>(
      Uri.parse(baseUrl).resolve(path).toString(),
      options: Options(responseType: ResponseType.bytes),
    );
    return Uint8List.fromList(response.data ?? const []);
  }
}
