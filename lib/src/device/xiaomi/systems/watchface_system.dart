import 'dart:async';

import 'package:oronbox/src/core/logging/logging_service.dart';
import 'package:oronbox/src/device/core/device_state.dart';
import 'package:oronbox/src/device/xiaomi/systems/xiaomi_system.dart';
import 'package:oronbox/src/device/xiaomi/protocol/generated/wear.pb.dart'
    as pb;
import 'package:oronbox/src/device/xiaomi/protocol/generated/wear_watch_face.pb.dart'
    as pb_watchface;

class XiaomiWatchfaceSystem extends XiaomiPbSystem {
  static final _log = getLogger('XiaomiWatchfaceSystem');
  final _uninstallCancellation = StreamController<void>.broadcast(sync: true);
  bool _disposed = false;

  final _editWaiters = <Completer<pb_watchface.EditResponse>>[];
  final _bgImageWaiters = <Completer<pb_watchface.BgImageResult>>[];
  final _fontWaiters = <Completer<pb_watchface.FontResult>>[];
  final _supportDataWaiters = <Completer<List<int>>>[];

  Future<void> setWatchface(String watchfaceId) async {
    _log.info('[${entity.id}] set watchface: $watchfaceId');
    await component.sendPbPacket(_buildWatchfaceSet(watchfaceId));
  }

  Future<void> uninstallWatchface(String watchfaceId) async {
    if (_disposed || entity.isDisposed) {
      throw StateError('Watchface system has been disposed');
    }
    _log.info('[${entity.id}] uninstall watchface: $watchfaceId');
    final success = await component.requestPool.request<bool>(
      packet: _buildWatchfaceUninstall(watchfaceId),
      typeMatcher: (packet) =>
          packet.type == pb.WearPacket_Type.WATCH_FACE &&
          packet.id ==
              pb_watchface.WatchFace_WatchFaceID.REMOVE_WATCH_FACE.value &&
          packet.watchFace.hasSuccess(),
      responseMapper: (packet) => packet.watchFace.success,
      cancellation: _uninstallCancellation.stream,
    );
    if (!success) throw ProtocolException('Watch rejected watchface removal');
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _uninstallCancellation.add(null);
    await _uninstallCancellation.close();
    await super.dispose();
  }

  Future<pb_watchface.EditResponse> requestEdit(
    pb_watchface.EditRequest request,
  ) async {
    _log.info('[${entity.id}] request watchface edit');
    final completer = Completer<pb_watchface.EditResponse>();
    _editWaiters.add(completer);
    await component.sendPbPacket(_buildWatchfaceEdit(request));
    return completer.future.timeout(const Duration(seconds: 10));
  }

  Future<pb_watchface.BgImageResult> waitBgImageResult() async {
    final completer = Completer<pb_watchface.BgImageResult>();
    _bgImageWaiters.add(completer);
    return completer.future.timeout(const Duration(seconds: 60));
  }

  Future<pb_watchface.FontResult> waitFontResult() async {
    final completer = Completer<pb_watchface.FontResult>();
    _fontWaiters.add(completer);
    return completer.future.timeout(const Duration(seconds: 60));
  }

  Future<List<int>> requestSupportData() async {
    _log.info('[${entity.id}] request watchface support data');
    final completer = Completer<List<int>>();
    _supportDataWaiters.add(completer);
    await component.sendPbPacket(_buildWatchfaceGetSupportData());
    return completer.future.timeout(const Duration(seconds: 10));
  }

  @override
  void onWearPacket(pb.WearPacket packet) {
    if (packet.whichPayload() != pb.WearPacket_Payload.watchFace) return;
    final msg = packet.watchFace;

    switch (msg.whichPayload()) {
      case pb_watchface.WatchFace_Payload.editResponse:
        _fulfillAll(_editWaiters, msg.editResponse);
      case pb_watchface.WatchFace_Payload.bgImageResult:
        _fulfillAll(_bgImageWaiters, msg.bgImageResult);
      case pb_watchface.WatchFace_Payload.fontResult:
        _fulfillAll(_fontWaiters, msg.fontResult);
      case pb_watchface.WatchFace_Payload.supportDataList:
        _fulfillAll(_supportDataWaiters, msg.supportDataList.list);
      default:
        break;
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

pb.WearPacket _buildWatchfaceSet(String watchfaceId) {
  return pb.WearPacket(
    type: pb.WearPacket_Type.WATCH_FACE,
    id: pb_watchface.WatchFace_WatchFaceID.SET_WATCH_FACE.value,
    watchFace: pb_watchface.WatchFace(id: watchfaceId),
  );
}

pb.WearPacket _buildWatchfaceUninstall(String watchfaceId) {
  return pb.WearPacket(
    type: pb.WearPacket_Type.WATCH_FACE,
    id: pb_watchface.WatchFace_WatchFaceID.REMOVE_WATCH_FACE.value,
    watchFace: pb_watchface.WatchFace(id: watchfaceId),
  );
}

pb.WearPacket _buildWatchfaceEdit(pb_watchface.EditRequest request) {
  return pb.WearPacket(
    type: pb.WearPacket_Type.WATCH_FACE,
    id: pb_watchface.WatchFace_WatchFaceID.EDIT_WATCH_FACE.value,
    watchFace: pb_watchface.WatchFace(editRequest: request),
  );
}

pb.WearPacket _buildWatchfaceGetSupportData() {
  return pb.WearPacket(
    type: pb.WearPacket_Type.WATCH_FACE,
    id: pb_watchface.WatchFace_WatchFaceID.GET_SUPPORT_DATA.value,
    watchFace: pb_watchface.WatchFace(),
  );
}
