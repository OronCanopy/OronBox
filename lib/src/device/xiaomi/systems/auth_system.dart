import 'dart:async';
import 'dart:typed_data';

import 'package:oronbox/src/core/logging/logging_service.dart';
import 'package:oronbox/src/device/core/event_bus.dart';
import 'package:oronbox/src/device/xiaomi/systems/screenshot_system.dart';
import 'package:oronbox/src/device/xiaomi/systems/xiaomi_system.dart';
import 'package:oronbox/src/device/xiaomi/utils/auth_utils.dart';
import 'package:oronbox/src/device/xiaomi/protocol/generated/wear.pb.dart'
    as pb;
import 'package:oronbox/src/device/xiaomi/protocol/generated/wear_account.pb.dart'
    as pb_account;
import 'package:oronbox/src/device/xiaomi/protocol/crypto/miwear_crypto.dart';

class XiaomiAuthRejected extends StateError {
  XiaomiAuthRejected(super.message, {this.notBound = false});

  final bool notBound;
}

enum _AuthStage { idle, verifying, confirming, finishing }

class XiaomiAuthSystem extends XiaomiPbSystem {
  static final _log = getLogger('XiaomiAuthSystem');
  Completer<void>? _completer;
  String? _authKeyHex;
  String? _appDeviceId;
  String? _oob;
  Uint8List? _appRandom;
  int _generation = 0;
  int _restarts = 0;
  int _staleReplies = 0;
  _AuthStage _stage = _AuthStage.idle;

  Future<void> authenticate(
    String authKeyHex, {
    String? appDeviceId,
    String? oob,
  }) {
    if (_completer != null) {
      return Future.error(StateError('Authentication already in progress'));
    }
    _log.info('[${entity.id}] starting auth');
    entity.system<XiaomiScreenshotSystem>()?.resetSession();
    _authKeyHex = authKeyHex;
    _appDeviceId = appDeviceId;
    _oob = oob;
    _completer = Completer<void>();
    _restarts = 0;
    _staleReplies = 0;
    final result = _completer!.future;
    unawaited(_sendStep1(++_generation));
    return result;
  }

  void onLinkReset(Object error) {
    if (_completer == null) return;
    if (_restarts >= 2) {
      failPending(
        StateError('Authentication interrupted by L1 session reset: $error'),
      );
      return;
    }
    _restarts++;
    _staleReplies++;
    _log.warning(
      '[${entity.id}] restarting authentication after L1 reset ($_restarts/2)',
    );
    unawaited(_sendStep1(++_generation));
  }

  Future<void> _sendStep1(int generation) async {
    _stage = _AuthStage.verifying;
    _appRandom = generateRandomBytes(16);
    component.authKeys = null;
    final packet = buildAuthStep1(
      _appRandom!,
      appDeviceId: _appDeviceId,
      oob: _oob,
    );
    try {
      await component.sendPbPacketUnencrypted(packet);
    } catch (e, st) {
      _log.severe('[${entity.id}] failed to send auth step 1', e, st);
      if (generation == _generation) failPending(e);
    }
  }

  @override
  void onWearPacket(pb.WearPacket packet) {
    if (packet.whichPayload() != pb.WearPacket_Payload.account) return;
    final account = packet.account;
    _log.fine('[${entity.id}] account payload: ${account.whichPayload()}');
    switch (account.whichPayload()) {
      case pb_account.Account_Payload.errorCode:
        if (_stage == _AuthStage.verifying &&
            packet.id == pb_account.Account_AccountID.AUTH_VERIFY.value &&
            account.errorCode == pb_account.Account_ErrorCode.NO_BOUND) {
          failPending(XiaomiAuthRejected('device is not bound', notBound: true));
        }

      case pb_account.Account_Payload.authDeviceVerify:
        _onDeviceVerify(account.authDeviceVerify);
      case pb_account.Account_Payload.authDeviceConfirm:
        _onDeviceConfirm(account.authDeviceConfirm);
      default:
        break;
    }
  }

  Future<void> _onDeviceVerify(pb_account.Auth_DeviceVerify verify) async {
    if (_stage != _AuthStage.verifying) return;
    final generation = _generation;
    try {
      if (_authKeyHex == null || _appRandom == null) {
        throw StateError('auth state missing');
      }
      _log.info('[${entity.id}] received device verify, building confirm');
      final (keys, confirmPacket) = buildAuthStep2(
        authKeyHex: _authKeyHex!,
        appRandom: _appRandom!,
        deviceVerify: verify,
        oob: _oob,
      );
      component.authKeys = keys;
      _stage = _AuthStage.confirming;
      await component.sendPbPacketUnencrypted(confirmPacket);
    } catch (e, st) {
      if (generation != _generation) return;
      if (_staleReplies > 0 &&
          e is ArgumentError &&
          e.message.toString().contains('Auth HMAC mismatch')) {
        _staleReplies--;
        _log.fine('[${entity.id}] ignored verify for a nonce before L1 reset');
        return;
      }
      _log.severe('[${entity.id}] auth step 2 failed', e, st);
      failPending(e);
    }
  }

  void _onDeviceConfirm(pb_account.Auth_DeviceConfirm confirm) {
    if (_stage != _AuthStage.confirming) return;
    if (confirm.confirmResult) {
      _log.info('[${entity.id}] auth confirmed');
      final cap1 = confirm.hasDeviceCapability() ? confirm.deviceCapability : 0;
      final cap2 = confirm.hasDeviceCapability2()
          ? confirm.deviceCapability2
          : 0;
      entity.emit(
        XiaomiDeviceCapabilitiesUpdated(
          deviceId: entity.id,
          deviceCapability: cap1,
          deviceCapabilityV2: cap2,
        ),
      );
      _stage = _AuthStage.finishing;
      unawaited(_finishAuthentication(_generation));
    } else {
      final error = 'auth confirm rejected by device';
      _log.warning('[${entity.id}] $error');
      failPending(XiaomiAuthRejected(error));
    }
  }

  Future<void> _finishAuthentication(int generation) async {
    // Capability registration is best effort.  It must not turn an otherwise
    // usable device connection into an auth failure.
    await entity
        .system<XiaomiScreenshotSystem>()
        ?.negotiateAfterAuthentication();
    if (generation != _generation || _completer == null) return;
    entity.emit(DeviceAuthenticated(deviceId: entity.id));
    final c = _completer;
    _completer = null;
    _stage = _AuthStage.idle;
    _authKeyHex = null;
    _appDeviceId = null;
    _oob = null;
    _appRandom = null;
    if (c != null && !c.isCompleted) {
      c.complete();
    }
  }

  void failPending(Object error) {
    final c = _completer;
    if (c == null) return;
    _completer = null;
    _generation++;
    _stage = _AuthStage.idle;
    _authKeyHex = null;
    _appDeviceId = null;
    _oob = null;
    _appRandom = null;
    component.authKeys = null;
    entity.emit(AuthFailed(deviceId: entity.id, error: error.toString()));
    if (!c.isCompleted) {
      c.completeError(error);
    }
  }

  @override
  Future<void> dispose() async {
    failPending(StateError('auth system disposed'));
    await super.dispose();
  }
}
