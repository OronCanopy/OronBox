import 'package:flutter_test/flutter_test.dart';
import 'package:oronbox/src/device/zeppos/zeppos_capabilities.dart';

void main() {
  const services = {0x000d, 0x00a0, 0x0046, 0x0001, 0x0033, 0x001a, 0x000f};

  test('unknown or absent services do not enable operations', () {
    expect(resolveZeppOsFeatures(name: 'Amazfit GTR 4', services: {}), isEmpty);
  });

  test('Mi Band 7 cannot screenshot even when generic services are present', () {
    for (final name in ['Xiaomi Smart Band 7', 'Xiaomi Smart Band 7 1A2B']) {
      expect(
        resolveZeppOsFeatures(name: name, services: services),
        isNot(contains(ZeppOsFeature.screenshot)),
      );
    }
    expect(
      resolveZeppOsFeatures(
        name: 'Custom name',
        codename: 'zepp:mi-band-7',
        services: services,
      ),
      isNot(contains(ZeppOsFeature.screenshot)),
    );
    for (final source in [260, 262, 263, 264, 265]) {
      expect(
        resolveZeppOsFeatures(
          name: 'Custom name',
          deviceSource: source,
          services: services,
        ),
        isNot(contains(ZeppOsFeature.screenshot)),
      );
    }
  });

  test('file operations require their services and the file channel', () {
    final features = resolveZeppOsFeatures(
      name: 'Amazfit GTR 4',
      services: services,
    );
    expect(features, containsAll(ZeppOsFeature.values));
    final noFiles = resolveZeppOsFeatures(
      name: 'Amazfit GTR 4',
      services: {0x00a0, 0x0046, 0x0001, 0x0033, 0x001a},
    );
    expect(
      noFiles,
      unorderedEquals([ZeppOsFeature.findDevice, ZeppOsFeature.appSide]),
    );
    final noHttp = resolveZeppOsFeatures(
      name: 'Amazfit GTR 4',
      services: {0x000d, 0x0046},
    );
    expect(noHttp, isNot(contains(ZeppOsFeature.maps)));
    final noApps = resolveZeppOsFeatures(
      name: 'Amazfit GTR 4',
      services: {0x000d, 0x0033},
    );
    expect(noApps, isNot(contains(ZeppOsFeature.voiceMemos)));
  });
}
