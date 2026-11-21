import 'package:oronbox/src/device/core/watchface_install_policy.dart';

export 'package:oronbox/src/device/core/watchface_install_policy.dart'
    show isZeroVelaWatchfaceId;

List<int>? replaceVelaWatchfaceId(List<int> bytes, String id) {
  final result = [...bytes];
  return writeVelaWatchfaceId(result, id) ? result : null;
}
