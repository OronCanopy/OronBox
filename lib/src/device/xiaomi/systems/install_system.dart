import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:oronbox/src/core/errors/coded_error.dart';
import 'package:oronbox/src/device/xiaomi/systems/watchface_system.dart';
import 'package:fixnum/fixnum.dart';
import 'package:oronbox/src/core/logging/logging_service.dart';
import 'package:oronbox/src/device/core/event_bus.dart';
import 'package:oronbox/src/device/core/watchface_install_policy.dart';
import 'package:oronbox/src/device/xiaomi/systems/info_system.dart';
import 'package:oronbox/src/device/xiaomi/systems/mass_system.dart';
import 'package:oronbox/src/device/xiaomi/systems/xiaomi_system.dart';
import 'package:oronbox/src/device/core/device_state.dart';
import 'package:oronbox/src/device/xiaomi/protocol/generated/wear.pb.dart'
    as pb;
import 'package:oronbox/src/device/xiaomi/protocol/generated/wear_common.pbenum.dart'
    as pb_common;
import 'package:oronbox/src/device/xiaomi/protocol/generated/wear_notification.pb.dart'
    as pb_notification;
import 'package:oronbox/src/device/xiaomi/protocol/generated/wear_system.pb.dart'
    as pb_system;
import 'package:oronbox/src/device/xiaomi/protocol/generated/wear_thirdparty_app.pb.dart'
    as pb_thirdparty;
import 'package:oronbox/src/device/xiaomi/protocol/generated/wear_watch_face.pb.dart'
    as pb_watchface;
import 'package:oronbox/src/device/xiaomi/protocol/packet/mass_packet.dart';
import 'package:oronbox/src/device/xiaomi/protocol/transport/mass_transfer.dart';

class XiaomiInstallSystem extends XiaomiPbSystem {
  static final _log = getLogger('XiaomiInstallSystem');
  final _inProgress = <MassDataType>{};
  _ProtoWaiter? _resultWaiter;
  int _generation = 0;

  XiaomiMassSystem get _massSystem => entity.system<XiaomiMassSystem>()!;
  XiaomiInfoSystem get _infoSystem => entity.system<XiaomiInfoSystem>()!;

  Future<void> installApp(
    Uint8List packageBytes, {
    String? packageName,
    void Function(double progress)? onProgress,
  }) async {
    return _runInstall(
      dataType: MassDataType.thirdPartyApp,
      fileData: packageBytes,
      onProgress: onProgress,
      run: () async {
        final name = packageName ?? 'com.oronbox.unknown';
        const versionCode = 114514;

        final prepareRet = await component.requestPool.request<pb.WearPacket>(
          packet: pb.WearPacket(
            type: pb.WearPacket_Type.THIRDPARTY_APP,
            id: pb_thirdparty
                .ThirdpartyApp_ThirdpartyAppID
                .PREPARE_INSTALL_APP
                .value,
            thirdpartyApp: pb_thirdparty.ThirdpartyApp(
              installRequest: pb_thirdparty.AppInstaller_Request(
                packageName: name,
                versionCode: versionCode,
                packageSize: packageBytes.length,
              ),
            ),
          ),
          typeMatcher: (p) =>
              p.whichPayload() == pb.WearPacket_Payload.thirdpartyApp &&
              p.id ==
                  pb_thirdparty
                      .ThirdpartyApp_ThirdpartyAppID
                      .PREPARE_INSTALL_APP
                      .value,
          responseMapper: (p) => p,
        );

        final status = prepareRet.thirdpartyApp.installResponse.prepareStatus;
        _checkPrepareStatus(status, 'App prepare not READY: $status');

        final result = await _sendMassAndWaitResult(
          dataType: MassDataType.thirdPartyApp,
          fileData: packageBytes,
          onProgress: onProgress,
          resultType: pb.WearPacket_Type.THIRDPARTY_APP.value,
          resultId: pb_thirdparty
              .ThirdpartyApp_ThirdpartyAppID
              .REPORT_INSTALL_RESULT
              .value,
          timeout: const Duration(seconds: 60),
        );

        final code = result!.thirdpartyApp.installResult.code;
        _log.info('[${entity.id}] app install result: $code');
        if (code != pb_thirdparty.AppInstaller_Result_Code.INSTALL_SUCCESS) {
          final error = ProtocolException('App install failed: $code');
          component.sar.abortPendingTransmissions(error);
          throw error;
        }
      },
    );
  }

  Future<String> installWatchface(
    Uint8List watchfaceBytes, {
    required String watchfaceId,
    String? replaceWatchfaceId,
    void Function(double progress)? onProgress,
  }) async {
    final restrictedId = restrictedWatchfaceIdFor(
      payload: watchfaceBytes,
      identifier: watchfaceId,
    );
    if (restrictedId != null) {
      _log.warning(
        '[${entity.id}] blocked restricted watchface install id=$restrictedId',
      );
      throw WatchfaceInstallBlockedException(restrictedId);
    }
    return _runInstall(
      dataType: MassDataType.watchface,
      fileData: watchfaceBytes,
      onProgress: onProgress,
      run: () async {
        final fileData = Uint8List.fromList(watchfaceBytes);
        final effectiveWatchfaceId = _normalizeWatchfaceId(
          watchfaceId,
          fileData,
        );
        if (!writeVelaWatchfaceId(fileData, effectiveWatchfaceId)) {
          throw const FormatException('Invalid Vela watchface ID field');
        }

        final generation = _generation;
        if (replaceWatchfaceId != null &&
            replaceWatchfaceId != effectiveWatchfaceId) {
          throw StateError(
            'Watchface replacement ID no longer matches the payload',
          );
        }
        Future<pb.WearPacket> prepare() =>
            component.requestPool.request<pb.WearPacket>(
              packet: pb.WearPacket(
                type: pb.WearPacket_Type.WATCH_FACE,
                id: pb_watchface
                    .WatchFace_WatchFaceID
                    .PREPARE_INSTALL_WATCH_FACE
                    .value,
                watchFace: pb_watchface.WatchFace(
                  prepareInfo: pb_watchface.PrepareInfo(
                    id: effectiveWatchfaceId,
                    size: fileData.length,
                    versionCode: Int64(65536),
                  ),
                ),
              ),
              typeMatcher: (p) =>
                  p.whichPayload() == pb.WearPacket_Payload.watchFace &&
                  p.id ==
                      pb_watchface
                          .WatchFace_WatchFaceID
                          .PREPARE_INSTALL_WATCH_FACE
                          .value,
              responseMapper: (p) => p,
              timeout: const Duration(seconds: 30),
            );

        var prepareRet = await prepare();
        if (entity.isDisposed || generation != _generation) {
          throw StateError('Device disconnected during watchface preparation');
        }
        var status = _watchfacePrepareStatus(prepareRet);
        if (status == pb_common.PrepareStatus.DOWNGRADE &&
            replaceWatchfaceId != null) {
          final watchfaces = entity.system<XiaomiWatchfaceSystem>();
          if (watchfaces == null) {
            throw StateError('Watchface management is unavailable');
          }
          await watchfaces.uninstallWatchface(effectiveWatchfaceId);
          if (entity.isDisposed || generation != _generation) {
            throw StateError(
              'Device disconnected during watchface replacement',
            );
          }
          prepareRet = await prepare();
          if (entity.isDisposed || generation != _generation) {
            throw StateError(
              'Device disconnected during watchface preparation',
            );
          }
          status = _watchfacePrepareStatus(prepareRet);
        }
        if (status == pb_common.PrepareStatus.DOWNGRADE) {
          throw WatchfaceDowngradeException(
            watchfaceId: effectiveWatchfaceId,
            deviceId: entity.id,
          );
        }
        _checkPrepareStatus(status, 'Watchface prepare not READY: $status');

        final result = await _sendMassAndWaitResult(
          dataType: MassDataType.watchface,
          fileData: fileData,
          onProgress: onProgress,
          resultType: pb.WearPacket_Type.WATCH_FACE.value,
          resultId:
              pb_watchface.WatchFace_WatchFaceID.REPORT_INSTALL_RESULT.value,
          timeout: const Duration(seconds: 120),
          expectedSliceLength:
              prepareRet.watchFace.hasPrepareReply() &&
                  prepareRet.watchFace.prepareReply.hasExpectedSliceLength()
              ? prepareRet.watchFace.prepareReply.expectedSliceLength
              : null,
        );

        final code = result!.watchFace.installResult.code;
        _log.info('[${entity.id}] watchface install result: $code');
        if (code != pb_watchface.InstallResult_Code.INSTALL_SUCCESS &&
            code != pb_watchface.InstallResult_Code.INSTALL_USED) {
          final error = ProtocolException('Watchface install failed: $code');
          component.sar.abortPendingTransmissions(error);
          throw error;
        }
        return effectiveWatchfaceId;
      },
    );
  }

  Future<void> installFirmware(
    Uint8List firmwareBytes, {
    void Function(double progress)? onProgress,
  }) async {
    return _runInstall(
      dataType: MassDataType.firmware,
      fileData: firmwareBytes,
      onProgress: onProgress,
      run: () async {
        final fileMd5 = _calcMd5(firmwareBytes);

        final prepareRet = await component.requestPool.request<pb.WearPacket>(
          packet: pb.WearPacket(
            type: pb.WearPacket_Type.SYSTEM,
            id: pb_system.System_SystemID.PREPARE_OTA.value,
            system: pb_system.System(
              prepareOtaRequest: pb_system.PrepareOta_Request(
                force: true,
                type: pb_system.PrepareOta_Type.ALL,
                firmwareVersion: '99.99.99',
                fileMd5: _toHexString(fileMd5),
                changeLog: 'OronBox Firmware Update',
                fileUrl: '',
              ),
            ),
          ),
          typeMatcher: (p) =>
              p.whichPayload() == pb.WearPacket_Payload.system &&
              p.id == pb_system.System_SystemID.PREPARE_OTA.value,
          responseMapper: (p) => p,
        );

        final status = prepareRet.system.prepareOtaResponse.prepareStatus;
        _checkPrepareStatus(status, 'Firmware prepare not READY: $status');

        final result = await _sendMassAndWaitResult(
          dataType: MassDataType.firmware,
          fileData: firmwareBytes,
          onProgress: onProgress,
          resultType: pb.WearPacket_Type.SYSTEM.value,
          resultId: pb_system.System_SystemID.PREPARE_OTA.value,
          timeout: const Duration(seconds: 30),
          allowMissingResult: true,
        );
        if (result == null) return;

        final resp = result.system.prepareOtaResponse;
        final resultStatus = resp.prepareStatus;
        _log.info('[${entity.id}] firmware install result: $resultStatus');
        _checkPrepareStatus(
          resultStatus,
          'Firmware install failed: $resultStatus',
        );
      },
    );
  }

  Future<void> installNotificationIcon(
    Uint8List iconBytes, {
    required String packageName,
    void Function(double progress)? onProgress,
  }) async {
    return _runInstall(
      dataType: MassDataType.notificationIcon,
      fileData: iconBytes,
      onProgress: onProgress,
      run: () async {
        final prepareRet = await component.requestPool
            .request<pb_notification.Notification>(
              packet: pb.WearPacket(
                type: pb.WearPacket_Type.NOTIFICATION,
                id: pb_notification
                    .Notification_NotificationID
                    .PREPARE_APP_ICON
                    .value,
                notification: pb_notification.Notification(
                  appIconRequest: pb_notification.PrepareAppIcon_Request(
                    packageName: packageName,
                  ),
                ),
              ),
              typeMatcher: (p) =>
                  p.whichPayload() == pb.WearPacket_Payload.notification &&
                  p.id ==
                      pb_notification
                          .Notification_NotificationID
                          .PREPARE_APP_ICON
                          .value,
              responseMapper: (p) => p.notification,
            );

        final status = prepareRet.appIconResponse.prepareStatus;
        _checkPrepareStatus(
          status,
          'Notification icon prepare not READY: $status',
        );

        final expectedSliceLength =
            prepareRet.appIconResponse.hasExpectedSliceLength()
            ? prepareRet.appIconResponse.expectedSliceLength
            : null;

        await _massSystem.sendFile(
          fileData: iconBytes,
          dataType: MassDataType.notificationIcon,
          expectedSliceLength: expectedSliceLength,
          onProgress: (data) => _emitProgress(data, onProgress),
        );
      },
    );
  }

  Future<T> _runInstall<T>({
    required MassDataType dataType,
    required Uint8List fileData,
    required void Function(double progress)? onProgress,
    required Future<T> Function() run,
  }) async {
    if (entity.isDisposed) throw StateError('Xiaomi install system disposed');
    if (_inProgress.isNotEmpty) {
      throw StateError('install already in progress for ${_inProgress.first}');
    }
    _inProgress.add(dataType);

    _log.info(
      '[${entity.id}] start install $dataType, ${fileData.length} bytes',
    );
    entity.emit(InstallPrepared(deviceId: entity.id));

    try {
      final result = await run();
      _log.info('[${entity.id}] install $dataType completed');
      entity.emit(InstallCompleted(deviceId: entity.id));
      await _refreshPostInstallState(dataType);
      return result;
    } catch (e, st) {
      _log.severe('[${entity.id}] install $dataType failed', e, st);
      entity.emit(InstallFailed(deviceId: entity.id, error: e.toString()));
      rethrow;
    } finally {
      _inProgress.remove(dataType);
    }
  }

  static String _normalizeWatchfaceId(String watchfaceId, Uint8List fileData) {
    if (isValidVelaWatchfaceId(watchfaceId)) return watchfaceId;
    final extracted = extractVelaWatchfaceId(fileData);
    if (isValidVelaWatchfaceId(extracted)) return extracted!;
    return _generateWatchfaceId();
  }

  static String _generateWatchfaceId() {
    final random = Random.secure();
    final length = 9 + random.nextInt(4);
    final buffer = StringBuffer(1 + random.nextInt(9));
    for (var i = 1; i < length; i++) {
      buffer.write(random.nextInt(10));
    }
    final id = buffer.toString();
    _log.info('[watchface] generated missing watchface id: $id');
    return id;
  }

  static void _checkPrepareStatus(
    pb_common.PrepareStatus status,
    String failureMessage,
  ) {
    if (status == pb_common.PrepareStatus.READY) return;
    if (status == pb_common.PrepareStatus.LOW_STORAGE) {
      throw const XiaomiInstallException('install_low_storage');
    }
    if (status == pb_common.PrepareStatus.LOW_BATTERY) {
      throw const XiaomiInstallException('install_low_battery');
    }
    if (status == pb_common.PrepareStatus.EXCEED_QUANTITY_LIMIT) {
      throw const XiaomiInstallException('install_quantity_limit');
    }
    throw ProtocolException(failureMessage);
  }

  static pb_common.PrepareStatus _watchfacePrepareStatus(pb.WearPacket packet) {
    if (packet.watchFace.hasPrepareReply()) {
      return packet.watchFace.prepareReply.prepareStatus;
    }
    if (packet.watchFace.hasPrepareStatus()) {
      return packet.watchFace.prepareStatus;
    }
    throw const FormatException('Watchface prepare response has no status');
  }

  @override
  void onWearPacket(pb.WearPacket packet) {
    // Installation results use the temporary packet listener.
  }

  void abortPending([Object? reason, StackTrace? stackTrace]) {
    _generation++;
    _resultWaiter?.cancel(
      reason ?? StateError('Xiaomi install aborted'),
      stackTrace,
    );
  }

  @override
  Future<void> dispose() async {
    abortPending(StateError('Xiaomi install system disposed'));
    await super.dispose();
  }

  Future<void> _refreshPostInstallState(MassDataType dataType) async {
    try {
      switch (dataType) {
        case MassDataType.gnssAgpsOnline:
        case MassDataType.gnssAgpsOffline:
        case MassDataType.gnssBeidouOnline:
        case MassDataType.gnssBeidouOffline:
        case MassDataType.gnssGalileoOnline:
        case MassDataType.gnssGalileoOffline:
        case MassDataType.watchface:
          await _infoSystem.fetchInstalledWatchfaces();
        case MassDataType.thirdPartyApp:
          await _infoSystem.fetchInstalledApps();
        case MassDataType.firmware:
        case MassDataType.notificationIcon:
        case MassDataType.music:
        case MassDataType.audioRecord:
        case MassDataType.watchfaceImage:
        case MassDataType.watchfaceFont:
          break;
      }
    } catch (e, st) {
      _log.warning('[${entity.id}] post-install refresh failed', e, st);
    }
  }

  void _emitProgress(
    SendMassCallbackData data,
    void Function(double progress)? onProgress,
  ) {
    _log.fine(
      '[${entity.id}] install progress ${data.currentPartNum}/${data.totalParts}',
    );
    entity.emit(
      InstallProgress(
        deviceId: entity.id,
        progress: data.progress,
        totalParts: data.totalParts,
        currentPart: data.currentPartNum,
      ),
    );
    onProgress?.call(data.progress);
  }

  Future<pb.WearPacket?> _sendMassAndWaitResult({
    required MassDataType dataType,
    required Uint8List fileData,
    required void Function(double progress)? onProgress,
    required int resultType,
    required int resultId,
    required Duration timeout,
    bool allowMissingResult = false,
    int? expectedSliceLength,
  }) async {
    final resultWaiter = _resultWaiter = _ProtoWaiter(
      expectType: resultType,
      expectId: resultId,
      allowMissingResult: allowMissingResult,
      listeners: component.requestPool.onPacketListeners,
    );
    try {
      await _massSystem.sendFile(
        fileData: fileData,
        dataType: dataType,
        expectedSliceLength: expectedSliceLength,
        onProgress: (data) => _emitProgress(data, onProgress),
      );

      try {
        return await resultWaiter.wait(timeout);
      } on TimeoutException {
        if (!allowMissingResult) rethrow;
        _log.info(
          '[${entity.id}] $dataType payload sent; install result message missing because the device may be rebooting',
        );
        return null;
      }
    } finally {
      resultWaiter.dispose();
      if (identical(_resultWaiter, resultWaiter)) _resultWaiter = null;
    }
  }

  static Uint8List _calcMd5(Uint8List data) {
    return Uint8List.fromList(crypto.md5.convert(data).bytes);
  }

  static String _toHexString(Uint8List data) {
    return data.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}

class XiaomiInstallException implements CodedError {
  const XiaomiInstallException(this.code);

  @override
  final String code;
  @override
  String get message => code;
  @override
  Object? get details => null;
  @override
  String toString() => message;
}

class WatchfaceDowngradeException extends XiaomiInstallException {
  const WatchfaceDowngradeException({
    required this.watchfaceId,
    required this.deviceId,
  }) : super('watchface_downgrade');

  final String watchfaceId;
  final String deviceId;

  @override
  Map<String, Object?> get details => {
    'watchfaceId': watchfaceId,
    'deviceId': deviceId,
  };
}

class _ProtoWaiter {
  _ProtoWaiter({
    required this.expectType,
    required this.expectId,
    required this.allowMissingResult,
    required this.listeners,
  }) {
    listeners.add(_onPacket);
    // Cancellation can arrive before the MASS transfer has finished.
    unawaited(_completer.future.then<void>((_) {}, onError: (_, _) {}));
  }

  final int expectType;
  final int expectId;
  final bool allowMissingResult;
  final List<void Function(pb.WearPacket packet)> listeners;
  final _completer = Completer<pb.WearPacket?>();
  var _disposed = false;

  Future<pb.WearPacket?> wait(Duration timeout) async {
    try {
      return await _completer.future.timeout(timeout);
    } on TimeoutException {
      throw TimeoutException(
        'Timeout waiting for proto type=$expectType id=$expectId',
        timeout,
      );
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    listeners.remove(_onPacket);
  }

  void cancel(Object error, [StackTrace? stackTrace]) {
    if (!_completer.isCompleted) {
      if (allowMissingResult) {
        // The caller still requires the MASS transfer to complete successfully.
        _completer.complete();
      } else {
        _completer.completeError(error, stackTrace);
      }
    }
    dispose();
  }

  void _onPacket(pb.WearPacket packet) {
    if (packet.type.value == expectType && packet.id == expectId) {
      if (!_completer.isCompleted) {
        _completer.complete(packet);
      }
    }
  }
}
