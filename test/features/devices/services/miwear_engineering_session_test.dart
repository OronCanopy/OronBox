import 'package:oronbox/src/device/core/ble_requirement.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:oronbox/src/device/core/bluetooth_platform.dart';
import 'package:oronbox/src/device/core/connect_type.dart';
import 'package:oronbox/src/device/xiaomi/engineering/miwear_engineering_system.dart';
import 'package:oronbox/src/features/devices/services/miwear_engineering_session.dart';

final _firmware = Uint8List.fromList(List.generate(20, (i) => i));

class _Connection implements BluetoothConnection {
  final incoming = StreamController<Uint8List>.broadcast();
  final states = StreamController<bool>.broadcast();
  final controls = <String>[];
  bool rejectFile = false;
  bool receiving = false;
  bool disposed = false;
  @override
  String get deviceId => 'test-address';
  @override
  String get deviceName => 'N67-FACTEST';
  @override
  ConnectType get connectType => ConnectType.ble;
  @override
  Stream<Uint8List> get incomingData => incoming.stream;
  @override
  Stream<bool> get connectionState => states.stream;
  @override
  int? get maxWriteLength => 244;
  @override
  bool supportsCharacteristic(BleRequiredCharacteristic characteristic) => true;
  @override
  Future<void> subscribe({
    BleRequiredCharacteristic? characteristic,
    void Function(Uint8List)? onData,
  }) async {}
  @override
  Future<void> unsubscribe({BleRequiredCharacteristic? characteristic}) async {}
  @override
  Future<void> send(
    Uint8List bytes, {
    BleRequiredCharacteristic? characteristic,
    bool withResponse = false,
  }) async {
    String reply;
    if (receiving) {
      receiving = false;
      reply = '310';
    } else {
      final command = ascii.decode(bytes);
      controls.add(command);
      if (command == '00AT^SWVER=APP') {
        reply = 'SWVER=OK,3.1.100\r\n';
      } else if (command == '00AT^GETBATPERCENT') {
        reply = 'GETBATPERCENT=OK,90\r\n';
      } else if (command == '300') {
        reply = '300';
      } else if (command.startsWith('33')) {
        receiving = !rejectFile;
        reply = rejectFile ? '331' : '330';
      } else if (command == '32') {
        reply = '320';
      } else if (command == '00AT^OTA_UPDATE') {
        reply = 'OTA_UPDATE=OK\r\n';
      } else if (command == '00AT^JUMP=APP') {
        reply = 'JUMP=OK\r\n';
      } else {
        throw StateError('Unexpected command $command');
      }
    }
    incoming.add(Uint8List.fromList(ascii.encode(reply)));
  }

  @override
  Future<void> dispose() async {
    if (disposed) return;
    disposed = true;
    await incoming.close();
    await states.close();
  }
}

class _Bluetooth implements BluetoothPlatform {
  final connection = _Connection();
  final scans = StreamController<BluetoothEndpoint>.broadcast();
  bool scanning = false;
  static const endpoint = BluetoothEndpoint(
    name: 'Engineering device',
    serviceUuids: ['1b7e8251-2877-41c3-b46e-cf057c562023'],
    address: 'test-address',
    connectType: ConnectType.ble,
  );
  @override
  Stream<BluetoothEndpoint> get scanStream => scans.stream;
  @override
  Future<bool> isAvailable() async => true;
  @override
  Future<void> requestPermissions() async {}
  @override
  Future<void> startScan(BluetoothScanOptions options) async {
    scanning = true;
    scans.add(endpoint);
  }

  @override
  Future<List<BluetoothEndpoint>> stopScan() async {
    scanning = false;
    return [endpoint];
  }

  @override
  Future<BluetoothConnection> connect(
    String address,
    String name,
    BluetoothConnectOptions options,
  ) async => connection;
  @override
  Future<void> cancelPendingSppConnection() async {}
  @override
  Future<void> disconnect(String address) => connection.dispose();
  @override
  Future<void> disconnectAll() => connection.dispose();
}

void main() {
  late _Bluetooth bluetooth;
  late MiWearEngineeringSession session;
  late List<Map<String, Object?>> states;
  setUp(() {
    bluetooth = _Bluetooth();
    states = [];
    session = MiWearEngineeringSession(bluetooth, onChanged: states.add);
  });
  tearDown(() async {
    await session.dispose();
    await bluetooth.scans.close();
  });
  Future<void> connect() async {
    final scan = session.scan();
    await Future<void>.delayed(Duration.zero);
    expect(session.snapshot['phase'], 'scanning');
    await session.connect(
      'test-address',
      'ble',
      prepareConnection: () async => expect(bluetooth.scanning, isFalse),
    );
    await scan;
    expect(session.snapshot['phase'], 'connected');
  }

  test(
    'OTA releases the engineering connection and waits for reboot',
    () async {
      await connect();
      expect(session.snapshot['battery'], '90');
      await session.install(_firmware);
      expect(session.snapshot['phase'], 'waiting');
      expect(session.snapshot['sentBytes'], _firmware.length);
      expect(session.snapshot['totalBytes'], _firmware.length);
      expect(session.connected, isFalse);
      expect(bluetooth.connection.disposed, isTrue);
      expect(states.any((s) => s['phase'] == 'completed'), isFalse);
    },
  );

  test('upload rejection disconnects and never triggers OTA', () async {
    await connect();
    bluetooth.connection.rejectFile = true;
    await expectLater(
      session.install(_firmware),
      throwsA(isA<MiWearEngineeringException>()),
    );
    expect(session.snapshot['phase'], 'failed');
    expect(bluetooth.connection.controls, isNot(contains('00AT^OTA_UPDATE')));
    expect(bluetooth.connection.disposed, isTrue);
  });

  test('return to user mode uses the confirmed jump branch and releases the connection', () async {
    await connect();
    await session.returnToUser();
    expect(bluetooth.connection.controls.last, '00AT^JUMP=APP');
    expect(session.snapshot['phase'], 'waiting');
    expect(session.connected, isFalse);
  });
}
