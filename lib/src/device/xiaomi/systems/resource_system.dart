import 'dart:async';

import 'package:oronbox/src/core/logging/logging_service.dart';
import 'package:oronbox/src/device/xiaomi/systems/xiaomi_system.dart';
import 'package:oronbox/src/device/xiaomi/protocol/generated/wear.pb.dart'
    as pb;
import 'package:oronbox/src/device/xiaomi/protocol/generated/wear_thirdparty_app.pb.dart'
    as pb_thirdparty;
import 'package:oronbox/src/device/xiaomi/protocol/generated/wear_watch_face.pb.dart'
    as pb_watchface;

class XiaomiResourceSystem extends XiaomiPbSystem {
  static final _log = getLogger('XiaomiResourceSystem');

  final _watchfaceWaiters = <Completer<List<pb_watchface.WatchFaceItem>>>[];
  final _quickAppWaiters = <Completer<List<pb_thirdparty.AppItem>>>[];
  Future<List<pb_thirdparty.AppItem>>? _quickAppRequest;
  bool _disposed = false;

  Future<List<pb_watchface.WatchFaceItem>> fetchInstalledWatchfaces() {
    _log.fine('[${entity.id}] fetching installed watchfaces');
    return _fetchInstalled(_watchfaceWaiters, _buildWatchfaceGetInstalled());
  }

  Future<List<pb_thirdparty.AppItem>> fetchInstalledQuickApps() =>
      _quickAppRequest ??= _fetchQuickApps().whenComplete(
        () => _quickAppRequest = null,
      );

  Future<List<pb_thirdparty.AppItem>> _fetchQuickApps() {
    _log.fine('[${entity.id}] fetching installed quick apps');
    return _fetchInstalled(_quickAppWaiters, _buildThirdpartyAppGetInstalled());
  }

  Future<List<T>> _fetchInstalled<T>(
    List<Completer<List<T>>> waiters,
    pb.WearPacket request,
  ) async {
    if (_disposed) throw StateError('Resource system disposed');
    final completer = Completer<List<T>>();
    waiters.add(completer);
    try {
      // Listen for cancellation while the transport is still sending.
      final results = await Future.wait<Object?>([
        Future.sync(() => component.sendPbPacket(request)),
        completer.future,
      ], eagerError: true).timeout(const Duration(seconds: 10));
      return results[1] as List<T>;
    } finally {
      waiters.remove(completer);
    }
  }

  void abortPending(Object error) {
    for (final waiter in [..._watchfaceWaiters, ..._quickAppWaiters]) {
      if (!waiter.isCompleted) waiter.completeError(error);
    }
    _watchfaceWaiters.clear();
    _quickAppWaiters.clear();
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    abortPending(StateError('Resource system disposed'));
    await super.dispose();
  }

  @override
  void onWearPacket(pb.WearPacket packet) {
    if (packet.whichPayload() == pb.WearPacket_Payload.watchFace &&
        packet.id ==
            pb_watchface.WatchFace_WatchFaceID.GET_INSTALLED_LIST.value) {
      final list = packet.watchFace.watchFaceList.list;
      _fulfillAll(_watchfaceWaiters, list);
      return;
    }

    if (packet.whichPayload() == pb.WearPacket_Payload.thirdpartyApp &&
        packet.id ==
            pb_thirdparty
                .ThirdpartyApp_ThirdpartyAppID
                .GET_INSTALLED_LIST
                .value) {
      final list = packet.thirdpartyApp.appItemList.list;
      _fulfillAll(_quickAppWaiters, list);
      return;
    }
  }

  void _fulfillAll<T>(List<Completer<T>> waiters, T value) {
    for (final completer in waiters) {
      if (!completer.isCompleted) {
        completer.complete(value);
      }
    }
    waiters.clear();
  }
}

pb.WearPacket _buildWatchfaceGetInstalled() {
  return pb.WearPacket(
    type: pb.WearPacket_Type.WATCH_FACE,
    id: pb_watchface.WatchFace_WatchFaceID.GET_INSTALLED_LIST.value,
    watchFace: pb_watchface.WatchFace(),
  );
}

pb.WearPacket _buildThirdpartyAppGetInstalled() {
  return pb.WearPacket(
    type: pb.WearPacket_Type.THIRDPARTY_APP,
    id: pb_thirdparty.ThirdpartyApp_ThirdpartyAppID.GET_INSTALLED_LIST.value,
    thirdpartyApp: pb_thirdparty.ThirdpartyApp(),
  );
}
