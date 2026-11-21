import 'dart:async';

import 'package:oronbox/src/device/core/device_state.dart';
import 'package:oronbox/src/device/xiaomi/protocol/generated/wear.pb.dart'
    as pb;
import 'package:oronbox/src/device/xiaomi/protocol/generated/wear_system.pb.dart'
    as pb_system;

class XiaomiRequestSlot<T> {
  XiaomiRequestSlot({
    required this.requestId,
    required this.requestType,
    required this.typeMatcher,
    required this.responseMapper,
    this.timeout = const Duration(seconds: 10),
  });

  final int requestId;
  final int requestType;
  final bool Function(pb.WearPacket packet) typeMatcher;
  final T Function(pb.WearPacket packet) responseMapper;
  final Duration timeout;

  final _completer = Completer<T>();
  Timer? _timer;

  Future<T> get future => _completer.future;

  void startTimeout() {
    _timer = Timer(timeout, () {
      if (!_completer.isCompleted) {
        _completer.completeError(
          ProtocolException('Request $requestId timed out'),
        );
      }
    });
  }

  void cancel() {
    _timer?.cancel();
    if (!_completer.isCompleted) {
      _completer.completeError(ProtocolException('Request cancelled'));
    }
  }

  bool tryComplete(pb.WearPacket packet) {
    if (_completer.isCompleted) return false;
    if (!typeMatcher(packet)) return false;
    _timer?.cancel();
    try {
      final result = responseMapper(packet);
      _completer.complete(result);
      return true;
    } catch (e) {
      _completer.completeError(e);
      return true;
    }
  }
}

class XiaomiRequestPool {
  XiaomiRequestPool({
    required this.sendPacket,
    this.defaultTimeout = const Duration(seconds: 10),
  });

  final Future<void> Function(pb.WearPacket packet) sendPacket;
  final Duration defaultTimeout;
  final _slots = <XiaomiRequestSlot<Object?>>[];
  final _pluginRequests = <(int, int), XiaomiRequestSlot<Object?>>{};
  final _retiredPluginRequests = <(int, int), DateTime>{};
  final _packetListeners = <void Function(pb.WearPacket packet)>[];

  List<void Function(pb.WearPacket packet)> get onPacketListeners =>
      _packetListeners;

  Future<T> request<T>({
    required pb.WearPacket packet,
    required bool Function(pb.WearPacket packet) typeMatcher,
    required T Function(pb.WearPacket packet) responseMapper,
    Duration? timeout,
    Stream<void>? cancellation,
  }) async {
    final key = (packet.type.value, packet.id);
    _retiredPluginRequests.removeWhere(
      (_, deadline) => !deadline.isAfter(DateTime.now()),
    );
    if (_pluginRequests.containsKey(key) ||
        _retiredPluginRequests.containsKey(key) ||
        (cancellation != null &&
            _slots.any(
              (slot) => slot.requestType == key.$1 && slot.requestId == key.$2,
            ))) {
      throw ProtocolException(
        'An earlier request still owns this response key',
      );
    }
    var completed = false;
    final slot = XiaomiRequestSlot<T>(
      requestId: packet.id,
      requestType: packet.type.value,
      typeMatcher: typeMatcher,
      responseMapper: responseMapper,
      timeout: timeout ?? defaultTimeout,
    );
    _slots.add(slot as XiaomiRequestSlot<Object?>);
    if (cancellation != null) _pluginRequests[key] = slot;
    slot.startTimeout();
    unawaited(slot.future.then<void>((_) {}, onError: (_, _) {}));
    final cancelled = cancellation?.listen((_) => slot.cancel());
    try {
      // Keep the slot lifecycle covered by the same finally block as the
      // send. A transport error before the response wait used to leave a
      // live matcher in the pool until its timeout, so the next request could
      // consume the next matching response on behalf of the failed request.
      await Future.any<void>([
        sendPacket(packet),
        slot.future.then<void>((_) {}),
      ]);
      final result = await slot.future;
      completed = true;
      return result;
    } finally {
      await cancelled?.cancel();
      slot._timer?.cancel();
      _slots.remove(slot);
      if (identical(_pluginRequests[key], slot)) {
        _pluginRequests.remove(key);
        if (!completed) {
          // Devices carry no plugin generation. Reserve the response key until
          // the late response arrives or this request's timeout has elapsed.
          _retiredPluginRequests[key] = DateTime.now().add(
            timeout ?? defaultTimeout,
          );
        }
      }
    }
  }

  void onPacket(pb.WearPacket packet) {
    for (final listener in _packetListeners.toList()) {
      listener(packet);
    }
    final key = (packet.type.value, packet.id);
    _retiredPluginRequests.removeWhere(
      (_, deadline) => !deadline.isAfter(DateTime.now()),
    );
    if (_retiredPluginRequests.remove(key) != null) return;
    // A response belongs to one request. Several callers can legitimately
    // use the same response predicate, so completing every matching slot
    // would broadcast one device response to unrelated requests.
    for (final slot in _slots.toList()) {
      if (!slot.tryComplete(packet)) continue;
      _slots.remove(slot);
      break;
    }
  }

  void clear() {
    for (final slot in _slots) {
      if (!slot._completer.isCompleted) {
        slot._completer.completeError(ProtocolException('Pool cleared'));
      }
      slot._timer?.cancel();
    }
    _slots.clear();
    _pluginRequests.clear();
    _retiredPluginRequests.clear();
  }
}

pb.WearPacket buildSystemPacket(pb_system.System_SystemID id) {
  return pb.WearPacket(
    type: pb.WearPacket_Type.SYSTEM,
    id: id.value,
    system: pb_system.System(),
  );
}
