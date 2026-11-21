import 'package:oronbox/src/core/models/bt_models.dart';
import 'package:oronbox/src/device/core/bluetooth_platform.dart';
import 'package:oronbox/src/device/core/connect_type.dart';
import 'package:oronbox/src/device/core/device_kind.dart';
import 'package:oronbox/src/device/core/device_profile.dart';
import 'package:oronbox/src/features/devices/utils/device_address.dart';

/// Merges one native scan event into the user-visible device list.
///
/// Android Classic discovery reports every discoverable Bluetooth device as
/// an SPP candidate even when it exposes no RFCOMM service. If BLE reports the
/// same physical address, keep the concrete BLE advertisement and discard the
/// speculative Classic duplicate. Zepp OS is excluded because its BLE and
/// BTBR endpoints are intentionally selectable independently.
List<BTDeviceInfo> mergeScannedDeviceEndpoint(
  List<BTDeviceInfo> current,
  BluetoothEndpoint endpoint, {
  required String displayName,
  required DeviceProfile profile,
}) {
  final sameAddress = current.where(
    (device) => deviceAddressEquals(device.addr, endpoint.address),
  );
  if (profile.kind != DeviceKind.zepp) {
    final hasBle = sameAddress.any(
      (device) => device.connectType.toLowerCase() == ConnectType.ble.name,
    );
    if (endpoint.connectType == ConnectType.spp && hasBle) return current;
  }

  final updated = List<BTDeviceInfo>.from(current);
  if (profile.kind != DeviceKind.zepp &&
      endpoint.connectType == ConnectType.ble) {
    updated.removeWhere(
      (device) =>
          deviceAddressEquals(device.addr, endpoint.address) &&
          device.connectType.toLowerCase() == ConnectType.spp.name,
    );
  }
  final existing = updated.indexWhere(
    (device) =>
        deviceAddressEquals(device.addr, endpoint.address) &&
        device.connectType.toLowerCase() == endpoint.connectType.name,
  );
  final value = BTDeviceInfo(
    name: displayName,
    addr: formatDeviceAddress(endpoint.address),
    connectType: endpoint.connectType.name,
    xiaomiRegistered: profile.kind == DeviceKind.xiaomi
        ? endpoint.xiaomiRegistered
        : null,
  );
  if (existing >= 0) {
    updated[existing] = value;
  } else {
    updated.add(value);
  }
  return updated;
}
