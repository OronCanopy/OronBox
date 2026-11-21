import 'dart:async';
import 'dart:typed_data';

import 'package:oronbox/src/device/core/bluetooth_platform.dart';
import 'package:oronbox/src/device/core/ble_requirement.dart';
import 'package:oronbox/src/device/core/connect_type.dart';
import 'package:oronbox/src/device/core/transport.dart';

const miwearEngineeringCharacteristic = BleRequiredCharacteristic(
  serviceUuid: '1b7e8251-2877-41c3-b46e-cf057c562023',
  characteristicUuid: '8ac32d3f-5cb9-4d44-bec2-ee689169f626',
);

class MiWearEngineeringTransport implements Transport {
  MiWearEngineeringTransport(this.connection);
  final BluetoothConnection connection;
  @override
  String get deviceId => connection.deviceId;
  @override
  String get deviceName => connection.deviceName;
  @override
  Stream<Uint8List> get incomingData => connection.incomingData;
  @override
  Stream<bool> get connectionState => connection.connectionState;
  @override
  Future<void> send(Uint8List data) => connection.send(
    data,
    characteristic: connection.connectType == ConnectType.ble
        ? miwearEngineeringCharacteristic
        : null,
  );
  @override
  Future<void> dispose() => connection.dispose();
}
