import 'dart:convert';

import 'package:archive/archive.dart';

const coronaPackageMaxBytes = 64 * 1024 * 1024;
const coronaPackageMaxEntries = 16384;

class CoronaPackageManifest {
  const CoronaPackageManifest(this.themeId, this.name);

  final String themeId;
  final String? name;

  static bool isManifest(ArchiveFile entry) =>
      entry.isFile &&
      (entry.name == 'corona.json' || entry.name == 'canora.json');

  static CoronaPackageManifest read(ArchiveFile entry) {
    if (entry.size > 64 * 1024) {
      throw const FormatException('Corona manifest is too large');
    }
    final manifest = jsonDecode(utf8.decode(entry.content));
    if (manifest is! Map ||
        manifest['format'] != 'canopus-resource-pack' ||
        manifest['formatVersion'] != 1) {
      throw const FormatException('Unsupported Corona resource pack format');
    }
    final themeId = manifest['themeId'];
    if (themeId is! String ||
        !RegExp(r'^[a-z0-9_-]{1,64}$').hasMatch(themeId)) {
      throw const FormatException('Invalid Corona theme ID');
    }
    final name = manifest['name'];
    return CoronaPackageManifest(themeId, name is String ? name : null);
  }
}
