import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import 'plugin_permission.dart';

enum PluginRuntimeType { wasm, js, hybrid }

extension PluginRuntimeTypeJson on PluginRuntimeType {
  String get manifestValue => name;
}

class PluginManifest {
  const PluginManifest({
    required this.id,
    required this.name,
    required this.version,
    required this.author,
    required this.description,
    required this.apiLevel,
    required this.runtime,
    required this.entry,
    required this.permissions,
    this.website,
    this.iconPath,
  });

  final String id;
  final String name;
  final String version;
  final String author;
  final String description;
  final int apiLevel;
  final PluginRuntimeType runtime;
  final String entry;
  final List<String> permissions;
  final String? website;
  final String? iconPath;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'version': version,
    'author': author,
    'description': description,
    'apiLevel': apiLevel,
    'runtime': runtime.manifestValue,
    'entry': entry,
    'permissions': permissions,
    if (website != null) 'website': website,
    if (iconPath != null) 'iconPath': iconPath,
  };
}

class InstalledPlugin {
  const InstalledPlugin({
    required this.manifest,
    required this.entryBytes,
    required this.config,
    this.iconBase64,
  });

  final PluginManifest manifest;
  final Uint8List entryBytes;
  final Map<String, Object?> config;
  final String? iconBase64;

  InstalledPlugin copyWith({Map<String, Object?>? config}) => InstalledPlugin(
    manifest: manifest,
    entryBytes: entryBytes,
    config: config ?? this.config,
    iconBase64: iconBase64,
  );

  Map<String, Object?> summaryJson({bool includeIcon = true}) => {
    ...manifest.toJson(),
    if (includeIcon && iconBase64 != null) 'icon': iconBase64,
  };
}

class PluginPackage {
  const PluginPackage({required this.manifest, required this.files});

  final PluginManifest manifest;
  final Map<String, Uint8List> files;

  InstalledPlugin installed({Map<String, Object?> config = const {}}) {
    final sourceBytes = files[manifest.entry];
    if (sourceBytes == null) {
      throw FormatException('ABP entry is missing: ${manifest.entry}');
    }
    final iconBytes = manifest.iconPath == null
        ? null
        : files[manifest.iconPath];
    return InstalledPlugin(
      manifest: manifest,
      entryBytes: Uint8List.fromList(sourceBytes),
      config: config,
      iconBase64: iconBytes == null ? null : base64Encode(iconBytes),
    );
  }
}

class PluginPackageReader {
  const PluginPackageReader();

  PluginPackage read(Uint8List bytes) {
    if (bytes.isEmpty) {
      throw const FormatException('Empty ABP package');
    }

    final archive = ZipDecoder().decodeBytes(bytes, verify: true);
    final entries = <String, Uint8List>{};
    for (final file in archive) {
      if (!file.isFile) continue;
      final name = _normalizePath(file.name);
      if (entries.containsKey(name)) {
        throw FormatException('Duplicate ABP entry: $name');
      }
      entries[name] = Uint8List.fromList(file.content as List<int>);
    }

    final manifestBytes = entries['manifest.json'];
    if (manifestBytes == null) {
      throw const FormatException('ABP manifest.json is missing');
    }
    final manifest = readManifest(manifestBytes);
    if (!entries.containsKey(manifest.entry)) {
      throw FormatException('ABP entry is missing: ${manifest.entry}');
    }
    final wasm = entries[manifest.entry]!;
    if (manifest.runtime == PluginRuntimeType.wasm &&
        (wasm.length < 4 ||
            wasm[0] != 0x00 ||
            wasm[1] != 0x61 ||
            wasm[2] != 0x73 ||
            wasm[3] != 0x6d)) {
      throw const FormatException(
        'Plugin entry has an invalid WebAssembly header',
      );
    }
    if (manifest.runtime != PluginRuntimeType.wasm) utf8.decode(wasm);
    if (manifest.iconPath != null && !entries.containsKey(manifest.iconPath)) {
      throw FormatException('ABP icon is missing: ${manifest.iconPath}');
    }
    return PluginPackage(manifest: manifest, files: Map.unmodifiable(entries));
  }

  PluginManifest readManifest(Uint8List manifestBytes) {
    final raw = jsonDecode(utf8.decode(manifestBytes));
    if (raw is! Map) throw const FormatException('Invalid ABP manifest');
    final json = raw.cast<String, Object?>();
    final apiLevel = (json['api_level'] as num?)?.toInt() ?? 1;
    final name = _requiredString(json, 'name');
    final rawRuntime = json['runtime']?.toString().trim();
    final runtime = switch (rawRuntime) {
      null || '' || 'wasm' => PluginRuntimeType.wasm,
      'js' => PluginRuntimeType.js,
      'hybrid' => PluginRuntimeType.hybrid,
      _ => throw FormatException('Unsupported plugin runtime: $rawRuntime'),
    };
    final entry = _normalizePath(
      json['entry']?.toString().trim().isNotEmpty == true
          ? json['entry']!.toString()
          : runtime == PluginRuntimeType.wasm
          ? 'plugin.wasm'
          : 'main.js',
    );
    final iconPath = json['icon']?.toString().trim();
    final normalizedIcon = iconPath == null || iconPath.isEmpty
        ? null
        : _normalizePath(iconPath);
    final id = _extractPluginId(json, name);
    final suffix = entry.split('.').last.toLowerCase();
    if (runtime == PluginRuntimeType.wasm
        ? suffix != 'wasm'
        : !{'js', 'mjs', 'cjs'}.contains(suffix)) {
      throw FormatException(
        'Invalid entry extension for ${runtime.name}: $entry',
      );
    }
    final permissions =
        (json['permissions'] as List?)
            ?.map((value) => value.toString())
            .where((value) => !isRetiredPluginPermission(value))
            .toSet()
            .toList(growable: false) ??
        const <String>[];

    return PluginManifest(
      id: id,
      name: name,
      version: json['version']?.toString().trim().isNotEmpty == true
          ? json['version']!.toString().trim()
          : '1.0.0',
      author: json['author']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      apiLevel: apiLevel,
      runtime: runtime,
      entry: entry,
      permissions: permissions,
      website: json['website']?.toString(),
      iconPath: normalizedIcon,
    );
  }

  String _extractPluginId(Map<String, Object?> json, String name) {
    final rawId = json['id']?.toString().trim();
    if (rawId != null &&
        rawId.isNotEmpty &&
        RegExp(r'^[a-z0-9_.-]+$', caseSensitive: false).hasMatch(rawId)) {
      return rawId.toLowerCase();
    }
    return pluginIdFromName(name);
  }

  static String pluginIdFromName(String name) {
    final hash = sha256.convert(utf8.encode(name)).toString().substring(0, 8);
    final slug = name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return '${slug.isEmpty ? 'plugin' : slug}-$hash';
  }

  String _normalizePath(String value) {
    final path = value.replaceAll('\\', '/');
    final parts = path.split('/');
    if (path.startsWith('/') ||
        path.contains('\x00') ||
        parts.any(
          (part) => part == '..' || part.isEmpty || part.contains(':'),
        )) {
      throw FormatException('Unsafe ABP path: $value');
    }
    return parts.where((part) => part != '.').join('/');
  }

  String _requiredString(Map<String, Object?> json, String key) {
    final value = json[key]?.toString().trim() ?? '';
    if (value.isEmpty) throw FormatException('ABP $key is missing');
    return value;
  }
}
