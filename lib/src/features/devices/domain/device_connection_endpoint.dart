import 'package:oronbox/src/core/models/bt_models.dart';
import 'package:oronbox/src/device/core/connect_type.dart';
import 'package:oronbox/src/device/core/device_profile.dart';
import 'package:oronbox/src/device/xiaomi/xiaomi_device_catalog.dart';
import 'package:oronbox/src/device/zeppos/zeppos_device_catalog.dart';
import 'package:oronbox/src/features/devices/utils/device_address.dart';

typedef DeviceConnectionEndpoint = ({String addr, String name});

final _classicAddressPattern = RegExp(
  r'^[0-9a-fA-F]{2}([:-][0-9a-fA-F]{2}){5}$',
);

bool _isClassicAddress(String value) =>
    _classicAddressPattern.hasMatch(value.trim());

/// Resolves the physical endpoint used to connect a device card.
///
/// A saved device owns an exact address/transport pair. Scanned endpoints are
/// consulted when a device needs a different transport or when a BLE-only
/// identifier must be paired with its classic SPP endpoint.
DeviceConnectionEndpoint? resolveDeviceConnectionEndpoint({
  required MiWearState device,
  required bool saved,
  required String connectType,
  required List<BTDeviceInfo> scannedDevices,
}) {
  final normalizedType = connectType.toLowerCase();
  final hasClassicAddress = _isClassicAddress(device.addr);
  if (device.connectType.toLowerCase() == normalizedType &&
      !(normalizedType == ConnectType.spp.name && !hasClassicAddress)) {
    return (addr: device.addr, name: device.name);
  }

  final sourceIdentity = zeppOsDeviceForBluetoothName(device.name);
  if (sourceIdentity == null) {
    final profile = DeviceRegistry.resolveIdentity(
      name: device.name,
      codename: device.codename,
    );
    if (profile.id == DeviceRegistry.unknown.id) return null;

    // A BLE scan on Apple platforms exposes a CoreBluetooth UUID, while the
    // VelaOS transport must use the classic SPP address. When the user opens
    // a scanned Xiaomi BLE card and switches to SPP, resolve the matching
    // classic endpoint by the catalog identity instead of forwarding the BLE
    // UUID to the RFCOMM driver.
    if (normalizedType == ConnectType.spp.name) {
      final xiaomiIdentity =
          xiaomiWearableIdentityForCodename(device.codename) ??
          normalizeXiaomiWearableIdentity(device.name);
      if (xiaomiIdentity != null) {
        for (final endpoint in scannedDevices) {
          if (endpoint.connectType.toLowerCase() != ConnectType.spp.name) {
            continue;
          }
          final endpointIdentity = normalizeXiaomiWearableIdentity(
            endpoint.name,
          );
          if (endpointIdentity?.codename == xiaomiIdentity.codename) {
            return (
              addr: formatDeviceAddress(endpoint.addr),
              name: endpoint.name,
            );
          }
        }
      }
    }

    for (final endpoint in scannedDevices) {
      if (deviceAddressEquals(endpoint.addr, device.addr)) {
        if (normalizedType == ConnectType.spp.name &&
            !_isClassicAddress(endpoint.addr)) {
          continue;
        }
        return (addr: formatDeviceAddress(endpoint.addr), name: endpoint.name);
      }
    }
    return null;
  }
  for (final endpoint in scannedDevices) {
    if (endpoint.connectType.toLowerCase() != normalizedType) continue;
    final candidateIdentity = zeppOsDeviceForBluetoothName(endpoint.name);
    if (candidateIdentity?.id == sourceIdentity.id) {
      return (addr: endpoint.addr, name: endpoint.name);
    }
  }

  if (saved &&
      normalizedType == ConnectType.spp.name &&
      sourceIdentity.connectionCapability != ZeppOsConnectionCapability.ble) {
    return (addr: device.addr, name: device.name);
  }
  return null;
}
