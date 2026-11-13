import 'package:flutter_test/flutter_test.dart';
import 'package:oronbox/src/device/core/connect_type.dart';
import 'package:oronbox/src/device/core/device_kind.dart';
import 'package:oronbox/src/device/core/device_profile.dart';
import 'package:oronbox/src/device/zeppos/zeppos_device_catalog.dart';

void main() {
  test('catalog entries have unique IDs and Bluetooth names', () {
    final ids = zeppOsDeviceCatalog.map((entry) => entry.id).toList();
    final names = zeppOsDeviceCatalog
        .expand((entry) => entry.bluetoothNames)
        .map((name) => name.toLowerCase())
        .toList();

    expect(ids.toSet(), hasLength(ids.length));
    expect(names.toSet(), hasLength(names.length));
    expect(ids, everyElement(matches(RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$'))));
    expect(names, everyElement(isNotEmpty));
  });

  test('matches exact names and Gadgetbridge four-character suffixes', () {
    expect(
      zeppOsDeviceForBluetoothName('Active 2 (Round)')?.id,
      'active-2-round',
    );
    expect(
      zeppOsDeviceForBluetoothName('Active 2 (Round) A1B2')?.id,
      'active-2-round',
    );
    expect(zeppOsDeviceForBluetoothName('Amazfit GTR 4-12AF')?.id, 'gtr-4');
    expect(zeppOsDeviceForBluetoothName('Amazfit GTR 4-CALL'), isNull);
  });

  test('Mi Band 7 resolves to ZeppOS before the Xiaomi catalog', () {
    final profile = DeviceRegistry.resolveIdentity(
      name: 'Xiaomi Smart Band 7 1A2B',
    );
    expect(profile.kind, DeviceKind.zepp);
  });

  for (final name in [
    '小米手环7',
    '小米手环7 NFC版',
    'Xiaomi Smart Band 7 NFC',
  ]) {
    test('resolves imported $name to ZeppOS over BLE', () {
      expect(zeppOsDeviceForBluetoothName(name)?.id, 'mi-band-7');
      final profile = DeviceRegistry.resolveIdentity(name: name);
      expect(profile.kind, DeviceKind.zepp);
      expect(profile.preferredConnectType, ConnectType.ble);
    });
  }

  test('does not classify other Xiaomi bands as Mi Band 7', () {
    for (final name in [
      '小米手环7 Pro',
      'Xiaomi Smart Band 7 Pro',
      '小米手环8',
      '小米手环10 NFC',
    ]) {
      expect(zeppOsDeviceForBluetoothName(name), isNull, reason: name);
      expect(
        DeviceRegistry.resolveIdentity(name: name).kind,
        DeviceKind.xiaomi,
        reason: name,
      );
    }
  });

  test('records Gadgetbridge BOTH connection capability', () {
    expect(
      zeppOsDeviceForBluetoothName('Active 3 Premium')?.connectionCapability,
      ZeppOsConnectionCapability.both,
    );
  });

  test('uses the configured artwork for both ZeppOS band models', () {
    expect(
      DeviceRegistry.resolveIdentity(
        name: 'Xiaomi Smart Band 7',
        codename: 'zepp:mi-band-7',
      ).illustrationAsset,
      'assets/images/devices/xiaomi-band.svg',
    );
    expect(
      DeviceRegistry.resolveIdentity(
        name: 'Amazfit Band 7',
        codename: 'zepp:band-7',
      ).illustrationAsset,
      'assets/images/devices/xiaomi-band-pro.svg',
    );
  });
}
