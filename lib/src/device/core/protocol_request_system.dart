import 'dart:async';
import 'dart:typed_data';

import 'package:oronbox/src/device/core/entity.dart';
import 'package:oronbox/src/device/core/event_bus.dart';
import 'package:oronbox/src/device/core/system.dart';

/// Matches opaque channel replies, whose payloads have no shared request ID.
class ProtocolRequestSystem extends System {
  final _pending = <int, Completer<Uint8List>>{};
  final _retired = <int, DateTime>{};
  StreamSubscription<DeviceEvent>? _subscription;
  bool _disposed = false;

  @override
  void attach(DeviceEntity entity) {
    super.attach(entity);
    _subscription = entity.eventBus.stream.listen((event) {
      if (event.deviceId != entity.id) return;
      if (event is TransportDisconnected) {
        _cancelPending('Device disconnected');
        return;
      }
      if (event is! ProtocolPacketReceived) return;
      _pruneRetired();
      if (_retired.remove(event.channel) != null) return;
      final pending = _pending[event.channel];
      if (pending != null && !pending.isCompleted) {
        pending.complete(Uint8List.fromList(event.payload));
      }
    });
  }

  Future<Uint8List> request({
    required int channel,
    required Future<void> Function() send,
    required Duration timeout,
    Stream<void>? cancellation,
  }) async {
    if (_disposed) throw StateError('Device protocol is closed');
    if (timeout <= Duration.zero) {
      throw const FormatException('Timeout must be positive');
    }
    _pruneRetired();
    if (_pending.containsKey(channel) || _retired.containsKey(channel)) {
      throw StateError('An earlier request still owns this response channel');
    }
    final response = Completer<Uint8List>();
    _pending[channel] = response;
    void fail(Object error) {
      if (!response.isCompleted) response.completeError(error);
    }

    final timer = Timer(timeout, () {
      fail(TimeoutException('Protocol request timed out', timeout));
    });
    final cancelled = cancellation?.listen((_) {
      fail(StateError('Protocol request cancelled'));
    });
    // Sending may still be awaiting a transport acknowledgement when cancelled.
    var completed = false;
    try {
      await Future.any<void>([send(), response.future.then<void>((_) {})]);
      final result = await response.future;
      completed = true;
      return result;
    } finally {
      timer.cancel();
      await cancelled?.cancel();
      _pending.remove(channel);
      if (!completed && !_disposed) {
        _retired[channel] = DateTime.now().add(timeout);
      }
    }
  }

  void _pruneRetired() {
    final now = DateTime.now();
    _retired.removeWhere((_, deadline) => !deadline.isAfter(now));
  }

  void _cancelPending(String reason) {
    for (final response in _pending.values) {
      if (!response.isCompleted) response.completeError(StateError(reason));
    }
  }

  @override
  void onData(Uint8List data) {}

  @override
  Future<void> dispose() async {
    _disposed = true;
    _cancelPending('Device protocol is closed');
    _retired.clear();
    await _subscription?.cancel();
  }
}
