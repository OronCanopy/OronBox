import 'package:oronbox/src/device/zeppos/zeppos_device_catalog.dart';

enum ZeppOsFeature { screenshot, maps, voiceMemos, findDevice, appSide, alarms }

/// Service presence is a prerequisite, not proof of every format's support.
Set<ZeppOsFeature> resolveZeppOsFeatures({
  required String name,
  String? codename,
  int? deviceSource,
  required Set<int> services,
}) {
  final model = codename != null && codename.startsWith('zepp:')
      ? codename.substring(5)
      : zeppOsDeviceForBluetoothName(name)?.id;
  // Gadgetbridge MiBand7Coordinator explicitly excludes screenshots (OS 1).
  final isMiBand7 =
      model == 'mi-band-7' ||
      const {260, 262, 263, 264, 265}.contains(deviceSource);
  final hasFiles = services.contains(0x000d);
  return Set.unmodifiable({
    if (!isMiBand7 && hasFiles && services.contains(0x00a0))
      ZeppOsFeature.screenshot,
    if (hasFiles && services.contains(0x0046) && services.contains(0x0001))
      ZeppOsFeature.maps,
    if (hasFiles && services.contains(0x00a0) && services.contains(0x0033))
      ZeppOsFeature.voiceMemos,
    if (services.contains(0x001a)) ZeppOsFeature.findDevice,
    if (services.contains(0x000f)) ZeppOsFeature.alarms,
    if (services.contains(0x00a0)) ZeppOsFeature.appSide,
  });
}
