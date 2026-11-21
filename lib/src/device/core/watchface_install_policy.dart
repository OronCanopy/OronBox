import 'package:oronbox/src/core/errors/coded_error.dart';

/// Watchface IDs with this prefix are restricted from local installation.
const restrictedWatchfaceIdPrefix = '1209';

bool isRestrictedWatchfaceId(String? id) {
  final normalized = id?.trim();
  return normalized != null &&
      normalized.startsWith(restrictedWatchfaceIdPrefix);
}

const _velaWatchfaceIdOffset = 0x28;
const _velaWatchfaceIdEnd = 0x68;
final _velaWatchfaceIdPattern = RegExp(r'^[A-Za-z0-9_-]{1,63}$');

bool isValidVelaWatchfaceId(String? id) =>
    id != null &&
    _velaWatchfaceIdPattern.hasMatch(id) &&
    id.codeUnits.any((byte) => byte != 0x30);

/// Reads the NUL-terminated identifier before the Vela watchface title.
String? extractVelaWatchfaceId(List<int> bytes) {
  if (bytes.length < _velaWatchfaceIdEnd) return null;
  var end = _velaWatchfaceIdOffset;
  while (end < _velaWatchfaceIdEnd && bytes[end] != 0) {
    end++;
  }
  if (end == _velaWatchfaceIdOffset || end == _velaWatchfaceIdEnd) return null;
  return String.fromCharCodes(bytes, _velaWatchfaceIdOffset, end);
}

bool isZeroVelaWatchfaceId(List<int> bytes) {
  if (bytes.length < _velaWatchfaceIdEnd) return false;
  final id = extractVelaWatchfaceId(bytes);
  return bytes[_velaWatchfaceIdOffset] == 0 ||
      (id != null && id.codeUnits.every((byte) => byte == 0x30));
}

bool writeVelaWatchfaceId(List<int> bytes, String id) {
  if (bytes.length < _velaWatchfaceIdEnd || !isValidVelaWatchfaceId(id)) {
    return false;
  }
  bytes.fillRange(_velaWatchfaceIdOffset, _velaWatchfaceIdEnd, 0);
  bytes.setAll(_velaWatchfaceIdOffset, id.codeUnits);
  return true;
}

/// Returns the first restricted ID found in the payload or install metadata.
String? restrictedWatchfaceIdFor({
  List<int>? payload,
  String? identifier,
  String? analyzedIdentifier,
  String? fallbackIdentifier,
}) {
  final embedded = payload == null ? null : extractVelaWatchfaceId(payload);
  for (final candidate in [
    embedded,
    analyzedIdentifier,
    identifier,
    fallbackIdentifier,
  ]) {
    if (isRestrictedWatchfaceId(candidate)) return candidate!.trim();
  }
  return null;
}

class WatchfaceInstallBlockedException implements CodedError {
  const WatchfaceInstallBlockedException(this.watchfaceId);

  final String watchfaceId;

  @override
  String get code => 'watchface_install_blocked';

  @override
  String get message =>
      '为尊重知识产权及遵守相关政策，应小米方面要求\nOronBox 无法安装疑似来自官方表盘商城的表盘\n如果你认为这是一个误报，请让表盘作者联系我们';

  @override
  Object get details => {
    'watchfaceId': watchfaceId,
    'restrictedPrefix': restrictedWatchfaceIdPrefix,
  };

  @override
  String toString() => message;
}
