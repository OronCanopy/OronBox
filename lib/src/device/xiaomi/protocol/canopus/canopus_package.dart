import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

class CanopusPackage {
  const CanopusPackage({
    required this.moduleId,
    required this.targetId,
    required this.receipt,
    required this.artifact,
    this.resources = const [],
  });

  final String moduleId;
  final String targetId;
  final Uint8List receipt;
  final Uint8List artifact;
  final List<CanopusPackageResource> resources;
}

class CanopusPackageResource {
  const CanopusPackageResource({
    required this.name,
    required this.sha256,
    required this.data,
  });

  final String name;
  final Uint8List sha256;
  final Uint8List data;
}

class CanopusPackageTargetMismatch extends FormatException {
  const CanopusPackageTargetMismatch(super.message);
}

class CanopusPackageParser {
  const CanopusPackageParser();

  CanopusPackage parse(Uint8List data, {required String targetId}) {
    if (targetId.trim().isEmpty) {
      throw const FormatException('Canopus target_id is unavailable');
    }
    if (data.length < 262 ||
        utf8.decode(data.sublist(257, 262), allowMalformed: true) != 'ustar') {
      throw const FormatException('Canopus package must be a tar archive');
    }

    final files = _readArchive(data);
    final manifest = _readManifest(files);
    if (manifest['schema'] != 1 || manifest['canopus_abi']?.toString() != '2') {
      throw const FormatException('Invalid Canopus manifest');
    }
    final moduleId = manifest['module_id']?.toString() ?? '';
    if (!_validModuleId(moduleId)) {
      throw const FormatException('Invalid Canopus module_id');
    }

    final artifacts = manifest['artifacts'];
    if (artifacts is! List || artifacts.isEmpty) {
      throw const FormatException('Canopus package has no artifacts');
    }
    Map<dynamic, dynamic>? selected;
    for (final value in artifacts) {
      if (value is! Map) {
        throw const FormatException('Invalid Canopus artifact declaration');
      }
      if (value['target_id']?.toString() == targetId) {
        selected = value;
        break;
      }
    }
    if (selected == null) {
      throw CanopusPackageTargetMismatch(
        'Canopus package has no artifact for target $targetId',
      );
    }

    final artifact = _file(files, selected['path'], 'artifact');
    final receipt = _file(files, selected['receipt_path'], 'receipt');
    if (artifact.isEmpty || receipt.isEmpty) {
      throw const FormatException('Canopus artifact or receipt is empty');
    }

    return CanopusPackage(
      moduleId: moduleId,
      targetId: targetId,
      receipt: receipt,
      artifact: artifact,
      resources: _resources(manifest, files, targetId),
    );
  }

  static Map<String, Uint8List> _readArchive(Uint8List data) {
    final files = <String, Uint8List>{};
    for (final entry in TarDecoder().decodeBytes(data, verify: true)) {
      final path = _canonicalPath(entry.name);
      if (!entry.isFile || entry.isSymbolicLink || files.containsKey(path)) {
        throw FormatException('Invalid Canopus archive entry: $path');
      }
      files[path] = Uint8List.fromList(entry.content);
    }
    return files;
  }

  static Map<dynamic, dynamic> _readManifest(Map<String, Uint8List> files) {
    final bytes = files['manifest.json'];
    if (bytes == null) {
      throw const FormatException('Canopus package has no manifest.json');
    }
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map) throw const FormatException('Invalid Canopus manifest');
    return value;
  }

  static Uint8List _file(
    Map<String, Uint8List> files,
    Object? value,
    String label,
  ) {
    final path = _canonicalPath(value?.toString() ?? '');
    final bytes = files[path];
    if (bytes == null) {
      throw FormatException('Canopus $label is missing: $path');
    }
    return Uint8List.fromList(bytes);
  }

  static List<CanopusPackageResource> _resources(
    Map<dynamic, dynamic> manifest,
    Map<String, Uint8List> files,
    String targetId,
  ) {
    final declarations = <Map<dynamic, dynamic>>[];
    void addList(Object? value) {
      if (value is List) {
        declarations.addAll(value.whereType<Map>());
      }
    }

    addList(manifest['resources']);
    final nativeApp = manifest['native_app'];
    if (nativeApp is Map) {
      addList(nativeApp['resources']);
      final hashes = nativeApp['resource_hashes'];
      if (hashes is Map) {
        for (final entry in hashes.entries) {
          declarations.add({'path': entry.key, 'sha256': entry.value});
        }
      }
    }

    final common = <String, CanopusPackageResource>{};
    final target = <String, CanopusPackageResource>{};
    final declaredHashes = <String, String>{};
    for (final declaration in declarations) {
      final path = _canonicalPath(declaration['path']?.toString() ?? '');
      if (!path.startsWith('resources/')) {
        throw FormatException('Invalid Canopus resource path: $path');
      }
      final parts = path.split('/');
      final scope = parts.length == 2 || parts[1] == 'common' ? null : parts[1];
      if (scope != null && scope != targetId) continue;
      final name = parts.last;
      final digest = declaration['sha256']?.toString().toLowerCase() ?? '';
      final previous = declaredHashes[path];
      if (previous != null) {
        if (previous != digest) {
          throw FormatException('Conflicting Canopus resource hashes: $path');
        }
        continue;
      }
      final hash = _hash(digest);
      final data = _file(files, path, 'resource');
      final selected = scope == null ? common : target;
      if (selected.containsKey(name)) {
        throw FormatException('Canopus resource basename collision: $name');
      }
      declaredHashes[path] = digest;
      selected[name] = CanopusPackageResource(
        name: name,
        sha256: hash,
        data: data,
      );
    }
    return {...common, ...target}.values.toList(growable: false);
  }

  static Uint8List _hash(Object? value) {
    final text = value?.toString() ?? '';
    if (text.length != 64) {
      throw const FormatException('Invalid Canopus resource hash');
    }
    final bytes = Uint8List(32);
    for (var index = 0; index < bytes.length; index++) {
      final byte = int.tryParse(
        text.substring(index * 2, index * 2 + 2),
        radix: 16,
      );
      if (byte == null) {
        throw const FormatException('Invalid Canopus resource hash');
      }
      bytes[index] = byte;
    }
    return bytes;
  }

  static String _canonicalPath(String value) {
    if (value.isEmpty ||
        value.startsWith('/') ||
        value.contains('\\') ||
        value.contains('\u0000') ||
        value
            .split('/')
            .any((part) => part.isEmpty || part == '.' || part == '..')) {
      throw FormatException('Invalid Canopus archive path: $value');
    }
    return value;
  }

  static bool _validModuleId(String value) =>
      RegExp(r'^[a-z][a-z0-9_]{0,15}$').hasMatch(value);
}
