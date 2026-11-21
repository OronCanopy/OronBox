import 'oronbox_plugin_repository.dart';

import 'package:oronbox/src/features/plugins/application/astrobox_ng_plugin_repository.dart';
import 'package:oronbox/src/features/plugins/application/plugin_manager.dart';
import 'package:oronbox/src/features/plugins/application/plugin_repository.dart';

/// daemon 侧的插件目录与安装入口，UI 通过命令总线访问。
class PluginRepositories {
  PluginRepositories({required this.manager});

  final PluginManager manager;

  late final Map<String, PluginRepository> _repositories = {
    'oronbox': OronBoxPluginRepository(),
    'astrobox_ng': AstroBoxNgPluginRepository(),
  };

  List<Map<String, Object?>> sources() => _repositories.values
      .map(
        (repository) => {'id': repository.id, 'name': repository.displayName},
      )
      .toList(growable: false);

  Future<List<Map<String, Object?>>> catalog(
    String source, {
    bool force = false,
  }) async {
    final repository = _requireRepository(source);
    final entries = await repository.load(force: force);
    final versions = await _installedVersions();

    return entries
        .map((entry) {
          final installedVersion = versions[(entry.runtime, entry.installedId)];
          final updateAvailable =
              installedVersion != null &&
              comparePluginVersions(entry.version, installedVersion) > 0;
          return {
            ...entry.toJson(),
            'installed': installedVersion != null && !updateAvailable,
            if (installedVersion != null) 'installedVersion': installedVersion,
            'updateAvailable': updateAvailable,
          };
        })
        .toList(growable: false);
  }

  Future<List<Map<String, Object?>>> updates({bool force = false}) async {
    final versions = await _installedVersions();
    if (versions.isEmpty) return const [];
    final candidates = await Future.wait(
      _repositories.values.map((repository) async {
        try {
          return await repository.load(force: force);
        } catch (_) {
          return const <PluginCatalogEntry>[];
        }
      }),
    );
    return [
      for (final entries in candidates)
        for (final entry in entries)
          if (versions[(entry.runtime, entry.installedId)]
              case final String version)
            if (comparePluginVersions(entry.version, version) > 0)
              {...entry.toJson(), 'installedVersion': version},
    ];
  }

  Future<Map<(String, String), String>> _installedVersions() async {
    final installed = await manager.list(includeIcons: false);
    return {
      for (final plugin in installed)
        if (plugin['runtime'] case final String runtime)
          if (plugin['id'] case final String id when id.isNotEmpty)
            (runtime, id): plugin['version']?.toString() ?? '1.0.0',
    };
  }

  Future<Map<String, Object?>> install(
    String source,
    String id, {
    String? expectedVersion,
  }) async {
    final repository = _requireRepository(source);
    final entry = await _findEntry(repository, id);
    if (expectedVersion != null && entry.version != expectedVersion) {
      throw StateError('Plugin update changed');
    }
    final bytes = await repository.download(entry);
    return manager.install(
      bytes,
      includeIcon: false,
      expectedUpdate: expectedVersion == null
          ? null
          : (
              id: entry.installedId,
              runtime: entry.runtime,
              version: expectedVersion,
            ),
    );
  }

  Future<PluginCatalogEntry> _findEntry(
    PluginRepository repository,
    String id,
  ) async {
    final entries = await repository.load();
    for (final entry in entries) {
      if (entry.id == id) return entry;
    }
    throw StateError('Plugin not found in ${repository.id} repository: $id');
  }

  PluginRepository _requireRepository(String source) {
    final repository = _repositories[source];
    if (repository == null) {
      throw StateError('Unknown plugin repository: $source');
    }
    return repository;
  }
}
