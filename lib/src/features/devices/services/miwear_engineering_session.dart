import 'dart:async';
import 'dart:typed_data';

import 'package:oronbox/src/device/core/bluetooth_platform.dart';
import 'package:oronbox/src/device/core/connect_type.dart';
import 'package:oronbox/src/device/core/entity.dart';
import 'package:oronbox/src/device/core/event_bus.dart';
import 'package:oronbox/src/device/core/system.dart';
import 'package:oronbox/src/device/xiaomi/engineering/miwear_engineering_system.dart';
import 'package:oronbox/src/device/xiaomi/engineering/miwear_engineering_transport.dart';

class MiWearEngineeringSession {
  MiWearEngineeringSession(this.bluetooth, {required this.onChanged});
  final BluetoothPlatform bluetooth;
  final void Function(Map<String, Object?>) onChanged;
  DeviceEntity? _entity;
  final _events = DeviceEventBus();
  StreamSubscription<DeviceEvent>? _disconnect;
  final _devices = <String, BluetoothEndpoint>{};
  final _logs = <String>[];
  BluetoothEndpoint? _endpoint;
  String _phase = 'idle';
  double _progress = 0;
  int _totalBytes = 0;
  int _sentBytes = 0;
  double _bytesPerSecond = 0;
  Completer<void>? _scanStop;
  Future<void>? _scanFuture;
  String? _version;
  String? _battery;
  bool _closing = false;
  Future<void>? _closeFuture;
  int _generation = 0;
  bool _hasScanned = false;
  bool _waitingForEngineering = false;

  bool get connected => _entity != null;
  bool get busy =>
      ['scanning', 'connecting', 'uploading', 'restarting'].contains(_phase);
  Map<String, Object?> get snapshot => {
    'phase': _phase,
    'hasScanned': _hasScanned,
    'waitingForEngineering': _waitingForEngineering,
    'progress': _progress,
    'totalBytes': _totalBytes,
    'sentBytes': _sentBytes,
    'bytesPerSecond': _bytesPerSecond,
    'name': _endpoint?.name,
    'address': _endpoint?.address,
    'connected': connected,
    'version': _version,
    'battery': _battery,
    'devices': [
      for (final d in _devices.values)
        {'name': d.name, 'address': d.address, 'type': d.connectType.name},
    ],
    'logs': List<String>.of(_logs),
  };
  void _emit() => onChanged(snapshot);
  void _log(String text) {
    _logs.add('${DateTime.now().toIso8601String()} $text');
    if (_logs.length > 100) _logs.removeAt(0);
    _emit();
  }

  void _set(String phase) {
    _phase = phase;
    _emit();
  }

  Future<void> scan() {
    final stop = Completer<void>();
    if (busy || connected || _scanFuture != null || _closing) {
      throw const MiWearEngineeringException(
        'engineering_busy',
        'engineering_busy',
      );
    }
    _scanStop = stop;
    return _scanFuture = _scan(stop).whenComplete(() {
      _scanStop = null;
      _scanFuture = null;
    });
  }

  Future<void> _stopScan() async {
    final stop = _scanStop;
    if (stop == null) return;
    if (!stop.isCompleted) stop.complete();
    await _scanFuture;
  }

  Future<void> _scan(Completer<void> stop) async {
    final generation = ++_generation;
    _devices.clear();
    _hasScanned = true;
    _set('scanning');
    void remember(BluetoothEndpoint d) {
      if (generation != _generation) return;
      final isEngineeringEndpoint = d.connectType == ConnectType.ble
          ? d.serviceUuids.any(
              (uuid) =>
                  uuid.toLowerCase() ==
                  miwearEngineeringCharacteristic.serviceUuid,
            )
          : RegExp(r'-FAC-BT(?:-|$)', caseSensitive: false).hasMatch(d.name);
      if (!isEngineeringEndpoint) return;
      _devices['${d.connectType.name}:${d.address}'] = d;
      _emit();
    }

    final subscription = bluetooth.scanStream.listen(remember);
    try {
      await bluetooth.requestPermissions();
      if (stop.isCompleted) return;
      await bluetooth.startScan(BluetoothScanOptions.all());
      await stop.future.timeout(const Duration(seconds: 15), onTimeout: () {});
    } finally {
      try {
        for (final d in await bluetooth.stopScan()) {
          remember(d);
        }
      } finally {
        await subscription.cancel();
        if (generation == _generation) _set('idle');
      }
    }
  }

  Future<void> connect(
    String address,
    String type, {
    Future<void> Function()? prepareConnection,
  }) async {
    if ((busy && _phase != 'scanning') || connected || _closing) {
      throw const MiWearEngineeringException(
        'engineering_busy',
        'engineering_busy',
      );
    }
    final endpoint = _devices['$type:$address'];
    if (endpoint == null) {
      throw const MiWearEngineeringException(
        'engineering_device',
        'engineering_device',
      );
    }
    final generation = ++_generation;
    _endpoint = endpoint;
    _set('connecting');
    BluetoothConnection? connection;
    try {
      await _stopScan();
      if (generation != _generation) {
        throw const MiWearEngineeringException('cancelled', 'cancelled');
      }
      if (prepareConnection != null) {
        await prepareConnection();
        if (generation != _generation) {
          throw const MiWearEngineeringException('cancelled', 'cancelled');
        }
      }
      final ble = endpoint.connectType == ConnectType.ble;
      connection = await bluetooth.connect(
        endpoint.address,
        endpoint.name,
        BluetoothConnectOptions(
          connectType: endpoint.connectType,
          bleRequiredCharacteristics: ble
              ? const [miwearEngineeringCharacteristic]
              : const [],
          bleDesiredMtu: 247,
          bleAttemptPair: false,
          sppServiceUuid: '00001101-0000-1000-8000-00805f9b34fb',
          sppFallbackChannels: const [2],
        ),
      );
      if (generation != _generation) {
        throw const MiWearEngineeringException('cancelled', 'cancelled');
      }
      final entity = DeviceEntity(
        id: endpoint.address,
        kind: 'miwear-engineering',
        transport: MiWearEngineeringTransport(connection),
        eventBus: _events,
      );
      entity.setDispatcher(_EngineeringDispatcher());
      entity.registerSystem(
        MiWearEngineeringSystem(
          ble: ble,
          writeLength: ble ? connection.maxWriteLength ?? 20 : 1024,
          onLog: _log,
        ),
      );
      _entity = entity;
      _endpoint = endpoint;
      _disconnect = _events.stream.listen((event) {
        if (event is TransportDisconnected && !_closing) {
          final waiting = _phase == 'waiting';
          unawaited(close(phase: waiting ? 'waiting' : 'disconnected'));
        }
      });
      entity.startListening();
      if (ble) {
        await connection.subscribe(
          characteristic: miwearEngineeringCharacteristic,
        );
      }
      _set('connected');
      await refresh();
    } catch (_) {
      if (_entity != null) {
        await close();
      } else {
        await connection?.dispose();
        if (generation == _generation) {
          _endpoint = null;
          _set('idle');
        }
      }
      rethrow;
    }
  }

  MiWearEngineeringSystem get _system {
    final system = _entity?.system<MiWearEngineeringSystem>();
    if (system == null) {
      throw const MiWearEngineeringException(
        'engineering_disconnected',
        'engineering_disconnected',
      );
    }
    return system;
  }

  Future<void> refresh() async {
    _version = await _system.at('AT^SWVER=APP', 'SWVER=');
    _battery = await _system.at('AT^GETBATPERCENT', 'GETBATPERCENT=');
    if (!_version!.startsWith('SWVER=OK,') ||
        !_battery!.startsWith('GETBATPERCENT=OK,')) {
      throw const MiWearEngineeringException(
        'engineering_response',
        'engineering_response',
      );
    }
    _version = _version!.substring('SWVER=OK,'.length);
    _battery = _battery!.substring('GETBATPERCENT=OK,'.length);
    _emit();
  }

  Future<void> install(Uint8List bytes) async {
    final system = _system;
    if (busy) {
      throw const MiWearEngineeringException(
        'engineering_busy',
        'engineering_busy',
      );
    }
    _waitingForEngineering = false;
    _progress = 0;
    _totalBytes = bytes.length;
    _sentBytes = 0;
    _bytesPerSecond = 0;
    _set('uploading');
    final clock = Stopwatch()..start();
    final samples = <(int, int)>[(0, 0)];
    try {
      await system.uploadFirmware(bytes, (value) {
        _progress = value;
        _sentBytes = (value * _totalBytes).round();
        final now = clock.elapsedMilliseconds;
        if (value < 1 && now - samples.last.$1 < 250) return;
        samples.add((now, _sentBytes));
        while (samples.length > 2 && now - samples[1].$1 >= 2000) {
          samples.removeAt(0);
        }
        final elapsed = now - samples.first.$1;
        _bytesPerSecond = elapsed == 0
            ? 0
            : (_sentBytes - samples.first.$2) * 1000 / elapsed;
        _emit();
      });
      _set('restarting');
      final reply = await system.at('AT^OTA_UPDATE', 'OTA_UPDATE=');
      if (reply != 'OTA_UPDATE=OK') {
        throw const MiWearEngineeringException(
          'engineering_response',
          'engineering_response',
        );
      }
      await close(phase: 'waiting');
    } catch (_) {
      // A failed raw transfer must not be reused as an AT command channel.
      await close(phase: 'failed');
      rethrow;
    }
  }

  Future<void> returnToUser() async {
    final reply = await _system.at('AT^JUMP=APP', 'JUMP=');
    if (reply != 'JUMP=OK') {
      throw const MiWearEngineeringException(
        'engineering_response',
        'engineering_response',
      );
    }
    _waitingForEngineering = false;
    _totalBytes = 0;
    await close(phase: 'waiting');
  }

  void expectRestart({required bool engineering}) {
    _totalBytes = 0;
    _waitingForEngineering = engineering;
    _set('waiting');
  }

  Future<void> close({String phase = 'idle'}) {
    final active = _closeFuture;
    if (active != null) return active;
    final operation = _close(phase);
    _closeFuture = operation;
    operation.then<void>(
      (_) {
        _closeFuture = null;
      },
      onError: (Object _) {
        _closeFuture = null;
      },
    );
    return operation;
  }

  Future<void> _close(String phase) async {
    _closing = true;
    ++_generation;
    final entity = _entity;
    _entity = null;
    entity?.system<MiWearEngineeringSystem>()?.cancel();
    try {
      await _disconnect?.cancel();
      _disconnect = null;
      try {
        await _stopScan();
      } finally {
        try {
          await entity?.dispose();
        } finally {
          if (entity != null) await bluetooth.disconnect(entity.id);
        }
      }
    } finally {
      _closing = false;
      if (phase != 'waiting') _endpoint = null;
      _set(phase);
    }
  }

  Future<void> dispose() async {
    await close();
    _events.dispose();
  }
}

class _EngineeringDispatcher extends Dispatcher {}
