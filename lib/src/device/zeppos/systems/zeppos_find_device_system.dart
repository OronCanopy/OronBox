import 'dart:async';
import 'dart:typed_data';

import 'package:oronbox/src/device/core/entity.dart';
import 'package:oronbox/src/device/core/event_bus.dart';
import 'package:oronbox/src/device/core/system.dart';
import 'package:oronbox/src/device/zeppos/zeppos_device_component.dart';

class ZeppOsFindDeviceSystem extends System {
  static const endpoint = 0x001a;
  static const _repeatInterval = Duration(seconds: 10);
  static const _phoneStartDelay = Duration(milliseconds: 1500);

  bool encrypted = true;
  int _version = 0;
  bool _findingWatch = false;
  bool _phoneRequested = false;
  bool _findingPhone = false;
  bool _ring = true;
  bool _disposed = false;
  int _phoneGeneration = 0;
  int _watchGeneration = 0;
  Future<void>? _initialization;
  Timer? _watchTimer;
  Timer? _phoneTimer;
  StreamSubscription<TransportDisconnected>? _disconnectSubscription;

  int get version => _version;
  bool get supportsContinuousFindDevice => _version >= 2;

  @override
  void attach(DeviceEntity entity) {
    super.attach(entity);
    _disconnectSubscription = entity.on<TransportDisconnected>().listen((_) {
      _reset();
      _initialization = null;
      _version = 0;
    });
  }

  /// Call after service discovery has assigned [encrypted].
  Future<void> initialize() {
    if (_disposed) return Future<void>.value();
    return _initialization ??= _initialize();
  }

  Future<void> _initialize() async {
    try {
      await _send(const [0x01]);
    } catch (_) {
      _initialization = null;
      rethrow;
    }
  }

  Future<void> setFinding(bool finding) async {
    if (_disposed) return;
    final generation = ++_watchGeneration;
    _watchTimer?.cancel();
    _watchTimer = null;
    _findingWatch = finding;
    try {
      await _send([finding ? 0x03 : 0x06]);
      if (!_disposed && generation == _watchGeneration) {
        _emitWatch(finding);
      }
    } catch (_) {
      if (generation == _watchGeneration) _stopWatch();
      rethrow;
    }
  }

  /// Local phone feedback does not echo a start command to the watch.
  Future<void> setFindingPhone(bool finding) async {
    if (_disposed) return;
    if (!finding) {
      _stopPhone();
      await _send(const [0x14]);
    }
  }

  Future<void> stopFindingPhone() => setFindingPhone(false);

  void handlePayload(Uint8List payload) {
    if (_disposed || payload.isEmpty) return;
    switch (payload[0]) {
      case 0x02:
        if (payload.length != 3) return;
        _version = payload[2];
        if (supportsContinuousFindDevice) {
          _watchTimer?.cancel();
          _watchTimer = null;
        }
        break;
      case 0x04:
        if (payload.length != 1 ||
            !_findingWatch ||
            supportsContinuousFindDevice ||
            _watchTimer != null) {
          return;
        }
        // Each vibration must be acknowledged before another is scheduled.
        _watchTimer = Timer(_repeatInterval, () {
          _watchTimer = null;
          if (_findingWatch && !_disposed) _sendBackground(const [0x03]);
        });
        break;
      case 0x07:
        if (payload.length != 1) return;
        _stopWatch();
        break;
      case 0x11:
        if (payload.length != 1) return;
        _phoneTimer?.cancel();
        _phoneTimer = null;
        _phoneRequested = true;
        if (!_findingPhone) _ring = true;
        final generation = ++_phoneGeneration;
        unawaited(_acknowledgePhone(generation));
        break;
      case 0x13:
        if (payload.length != 1) return;
        _stopPhone();
        break;
      case 0x15:
        if (payload.length != 2 || payload[1] > 1 || !_phoneRequested) return;
        _phoneTimer?.cancel();
        _phoneTimer = null;
        _ring = payload[1] == 1;
        _startPhone();
        break;
    }
  }

  Future<void> _acknowledgePhone(int generation) async {
    try {
      // The watch sends the mode only after this acknowledgement.
      await _send(const [0x12, 0x01]);
      if (_disposed ||
          generation != _phoneGeneration ||
          !_phoneRequested ||
          _findingPhone) {
        return;
      }
      _phoneTimer = Timer(_phoneStartDelay, () {
        _phoneTimer = null;
        if (!_disposed && _phoneRequested && generation == _phoneGeneration) {
          _startPhone();
        }
      });
    } catch (error) {
      if (generation == _phoneGeneration) _stopPhone();
      _emitError(error);
    }
  }

  void _startPhone() {
    _findingPhone = true;
    entity.emit(
      ZeppOsFindPhoneRequested(
        deviceId: entity.id,
        finding: true,
        ring: _ring,
      ),
    );
  }

  void _stopPhone() {
    final requested = _phoneRequested || _findingPhone;
    _phoneGeneration++;
    _phoneTimer?.cancel();
    _phoneTimer = null;
    _phoneRequested = false;
    _findingPhone = false;
    if (requested) {
      entity.emit(
        ZeppOsFindPhoneRequested(
          deviceId: entity.id,
          finding: false,
          ring: _ring,
        ),
      );
    }
  }

  void _stopWatch() {
    _watchGeneration++;
    final finding = _findingWatch;
    _watchTimer?.cancel();
    _watchTimer = null;
    _findingWatch = false;
    if (finding) _emitWatch(false);
  }

  void _emitWatch(bool finding) {
    entity.emit(
      ZeppOsFindWearableRequested(
        deviceId: entity.id,
        finding: finding,
      ),
    );
  }

  void _reset() {
    _stopWatch();
    _stopPhone();
  }

  Future<void> _send(List<int> payload) =>
      entity.getRequired<ZeppOsDeviceComponent>().sendToEndpoint(
        endpoint,
        Uint8List.fromList(payload),
        encrypted: encrypted,
      );

  void _sendBackground(List<int> payload) {
    final generation = _watchGeneration;
    unawaited(
      _send(payload).catchError((Object error) {
        if (generation == _watchGeneration) _stopWatch();
        _emitError(error);
      }),
    );
  }

  void _emitError(Object error) {
    if (!_disposed) {
      entity.emit(DeviceError(deviceId: entity.id, error: error.toString()));
    }
  }

  @override
  void onData(Uint8List data) {}

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _reset();
    await _disconnectSubscription?.cancel();
    _disconnectSubscription = null;
  }
}
