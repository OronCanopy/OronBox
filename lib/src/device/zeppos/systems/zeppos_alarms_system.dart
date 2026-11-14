import 'dart:async';
import 'dart:typed_data';

import 'package:oronbox/src/device/core/system.dart';
import 'package:oronbox/src/device/core/entity.dart';
import 'package:oronbox/src/device/core/event_bus.dart';
import 'package:oronbox/src/device/zeppos/zeppos_device_component.dart';

class ZeppOsAlarm {
  const ZeppOsAlarm({
    required this.position,
    required this.hour,
    required this.minute,
    required this.repetition,
    this.enabled = true,
    this.smartWakeup = false,
  });
  final int position, hour, minute, repetition;
  final bool enabled, smartWakeup;
  ZeppOsAlarm copyWith({
    int? position,
    int? hour,
    int? minute,
    int? repetition,
    bool? enabled,
    bool? smartWakeup,
  }) => ZeppOsAlarm(
    position: position ?? this.position,
    hour: hour ?? this.hour,
    minute: minute ?? this.minute,
    repetition: repetition ?? this.repetition,
    enabled: enabled ?? this.enabled,
    smartWakeup: smartWakeup ?? this.smartWakeup,
  );
  @override
  bool operator ==(Object other) =>
      other is ZeppOsAlarm &&
      position == other.position &&
      hour == other.hour &&
      minute == other.minute &&
      repetition == other.repetition &&
      enabled == other.enabled &&
      smartWakeup == other.smartWakeup;
  @override int get hashCode => Object.hash(position, hour, minute, repetition, enabled, smartWakeup);
}

class ZeppOsAlarmsSystem extends System {
  static const endpoint = 0x000f;
  static const createCommand = 3;
  static const createAck = 4;
  static const deleteCommand = 5;
  static const deleteAck = 6;
  static const updateCommand = 7;
  static const updateAck = 8;
  static const request = 9;
  static const response = 10;
  static const notifyChange = 15;
  static const flagSmart = 1, flagEnabled = 4;
  static const defaultTimeout = Duration(seconds: 8);
  ZeppOsAlarmsSystem({
    this.encrypted = false,
    int maxAlarms = 10,
  }) : _maxAlarms = maxAlarms;
  bool encrypted;
  int? _maxAlarms;
  Completer<Object>? _pending;
  int? _expected;
  Future<void> _serial = Future<void>.value();
  bool _disposed = false;
  StreamSubscription<TransportDisconnected>? _disconnectSubscription;

  @override
  void attach(DeviceEntity entity) {
    super.attach(entity);
    _disconnectSubscription = entity.on<TransportDisconnected>().listen((_) {
      _stopPending();
    });
  }

  void _stopPending() {
    _disposed = true;
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(StateError('Alarm system disconnected'));
    }
  }
  bool _reading = false;
  bool _readAgain = false;
  List<ZeppOsAlarm> _alarms = const [];
  final _updates = StreamController<List<ZeppOsAlarm>>.broadcast();
  Stream<List<ZeppOsAlarm>> get updates => _updates.stream;
  int? get maxAlarms => _maxAlarms;
  List<ZeppOsAlarm> get alarms => List.unmodifiable(_alarms);
  ZeppOsDeviceComponent get _component => entity.getRequired<ZeppOsDeviceComponent>();

  Future<List<ZeppOsAlarm>> load() => _enqueue(() async {
    final a = await _loadNow();
    return List.unmodifiable(a);
  });

  Future<List<ZeppOsAlarm>> _loadNow() async {
    final p = await _response(request, response);
    final a = _decode(p);
    _alarms = a;
    if (!_disposed) _updates.add(List.unmodifiable(a));
    return a;
  }
  Future<void> create(ZeppOsAlarm a) => _mutate(createCommand, createAck, a);
  Future<void> update(ZeppOsAlarm a) => _mutate(createCommand, createAck, a);
  Future<void> delete(int position) => _enqueue(() async {
    _position(position);
    await _ack(Uint8List.fromList([deleteCommand, 1, position]), deleteAck);
    final current = await _loadNow();
    if (current.any((alarm) => alarm.position == position)) {
      throw StateError('ZeppOS alarm deletion was not confirmed by readback');
    }
  });
  Future<void> _mutate(
    int command,
    int ack,
    ZeppOsAlarm alarm,
  ) => _enqueue(() async {
    _validate(alarm);
    var flags = 0;
    if (alarm.enabled) flags |= flagEnabled;
    if (alarm.smartWakeup) flags |= flagSmart;
    await _ack(
      Uint8List.fromList([
        command,
        1,
        flags,
        alarm.position,
        alarm.hour,
        alarm.minute,
        alarm.repetition,
        0,
        0,
        0,
        0,
        0,
      ]),
      ack,
    );
    final current = await _loadNow();
    if (!current.contains(alarm)) {
      throw StateError('ZeppOS alarm write was not confirmed by readback');
    }
  });

  Future<T> _enqueue<T>(Future<T> Function() operation) {
    if (_disposed || entity.isDisposed) return Future.error(StateError('Alarm system is disposed'));
    final result = Completer<T>();
    _serial = _serial.catchError((_) {}).then((_) async {
      if (_disposed || entity.isDisposed) { result.completeError(StateError('Alarm system is disposed')); return; }
      try { result.complete(await operation()); } catch (e, st) { result.completeError(e, st); }
    });
    return result.future;
  }
  Future<void> _ack(Uint8List packet, int expected) async {
    await _exchange(packet, expected);
  }

  Future<Uint8List> _response(int command, int expected) async =>
      await _exchange(Uint8List.fromList([command]), expected) as Uint8List;

  Future<Object> _exchange(Uint8List packet, int expected) async {
    if (_disposed || entity.isDisposed) {
      throw StateError('Alarm system disconnected');
    }
    final pending = Completer<Object>();
    _pending = pending;
    _expected = expected;
    final reply = pending.future.timeout(defaultTimeout);
    unawaited(reply.then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    try {
      await _component.sendToEndpoint(
        endpoint, packet, encrypted: encrypted,
      ).timeout(defaultTimeout);
      return await reply;
    } finally {
      if (identical(_pending, pending)) {
        _pending = null;
        _expected = null;
      }
    }
  }

  void handlePayload(Uint8List p) {
    if (p.isEmpty || _disposed) return;
    if (p[0] == notifyChange) {
      _readAgain = true;
      if (!_reading) unawaited(_readNotifications());
      return;
    }
    final q = _pending;
    if (q == null || q.isCompleted || p[0] != _expected) return;
    if (p[0] == response) {
      q.complete(Uint8List.fromList(p));
    } else if (p.length >= 2) {
      q.complete(const Object());
    }
  }
  Future<void> _readNotifications() async {
    _reading = true;
    do {
      _readAgain = false;
      try {
        await load();
      } catch (error, stackTrace) {
        if (!_disposed) {
          _updates.addError(error, stackTrace);
        }
      }
    } while (_readAgain && !_disposed);
    _reading = false;
  }
  List<ZeppOsAlarm> _decode(Uint8List payload) {
    if (payload.length < 2) {
      throw const FormatException('Invalid alarm response');
    }
    final count = payload[1];
    if (payload.length != 2 + count * 10) {
      throw FormatException(
        'Invalid alarm response length: ${payload.length}',
      );
    }
    final alarms = <ZeppOsAlarm>[];
    final positions = <int>{};
    for (var i = 0; i < count; i++) {
      final offset = 2 + i * 10;
      final flags = payload[offset];
      final alarm = ZeppOsAlarm(
        position: payload[offset + 1],
        hour: payload[offset + 2],
        minute: payload[offset + 3],
        repetition: payload[offset + 4],
        enabled: flags & flagEnabled != 0,
        smartWakeup: flags & flagSmart != 0,
      );
      if (!positions.add(alarm.position)) {
        throw const FormatException('Duplicate alarm position');
      }
      _validate(alarm);
      alarms.add(alarm);
    }
    return alarms;
  }

  void _validate(ZeppOsAlarm alarm) {
    _position(alarm.position);
    if (alarm.hour < 0 ||
        alarm.hour > 23 ||
        alarm.minute < 0 ||
        alarm.minute > 59) {
      throw RangeError('Invalid alarm time');
    }
    if (alarm.repetition < 0 || alarm.repetition > 127) {
      throw RangeError('Alarm repetition must contain seven weekday bits');
    }
  }
  void _position(int p) {
    if (p < 0 ||
        p > 255 ||
        (_maxAlarms != null && p >= _maxAlarms!)) {
      throw RangeError('Alarm position exceeds device capacity');
    }
  }
  @override
  void onData(Uint8List data) {}
  @override
  Future<void> dispose() async {
    _stopPending();
    await _disconnectSubscription?.cancel();
    if (!_updates.isClosed) await _updates.close();
  }
}
