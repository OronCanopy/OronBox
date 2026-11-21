import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';
import 'package:oronbox/src/device/xiaomi/protocol/crypto/miwear_crypto.dart';
import 'package:oronbox/src/device/xiaomi/protocol/generated/wear.pb.dart'
    as wear;
import 'package:oronbox/src/device/xiaomi/protocol/generated/wear_account.pb.dart'
    as account;
import 'package:oronbox/src/device/xiaomi/systems/xiaomi_system.dart';

class XiaomiBindRejected implements Exception {
  const XiaomiBindRejected(this.code);
  final account.Account_ErrorCode code;
}

class XiaomiBindSystem extends XiaomiPbSystem {
  Completer<account.Account>? _pending;
  int? _packetId;

  @override
  void onWearPacket(wear.WearPacket packet) {
    final pending = _pending;
    if (pending == null ||
        pending.isCompleted ||
        packet.type != wear.WearPacket_Type.ACCOUNT ||
        packet.id != _packetId) {
      return;
    }
    final response = packet.account;
    if (response.hasErrorCode() &&
        response.errorCode != account.Account_ErrorCode.NO_ERROR) {
      pending.completeError(XiaomiBindRejected(response.errorCode));
    } else {
      pending.complete(response);
    }
  }

  void abort(Object error) {
    final pending = _pending;
    if (pending != null && !pending.isCompleted) pending.completeError(error);
  }

  @override
  Future<void> dispose() async {
    abort(StateError('Binding connection closed'));
  }

  Future<account.Account> _exchange(
    account.Account_AccountID id,
    account.Account request,
  ) async {
    if (_pending != null) throw StateError('Binding request already active');
    final pending = _pending = Completer<account.Account>();
    _packetId = id.value;
    final reply = pending.future.timeout(const Duration(seconds: 15));
    // The link can close before the write itself finishes.
    unawaited(reply.then<void>((_) {}, onError: (Object _) {}));
    try {
      await component
          .sendPbPacketUnencrypted(
            wear.WearPacket(
              type: wear.WearPacket_Type.ACCOUNT,
              id: id.value,
              account: request,
            ),
          )
          .timeout(const Duration(seconds: 15));
      return await reply;
    } finally {
      _pending = null;
      _packetId = null;
    }
  }

  Future<account.BindInfoV2> query({
    String? userId,
    bool checkDynamicCode = false,
  }) async {
    final reply = await _exchange(
      account.Account_AccountID.BIND_START_V2,
      account.Account(
        bindStartV2: account.BindStartV2(
          checkDynamicCode: checkDynamicCode,
          hashUserId: userId == null
              ? null
              : md5.convert(utf8.encode(userId)).bytes,
        ),
      ),
    );
    if (!reply.hasBindInfoV2() ||
        !reply.bindInfoV2.hasVerifyMode() ||
        !reply.bindInfoV2.hasOobMode()) {
      throw const FormatException('Invalid binding capability response');
    }
    return reply.bindInfoV2;
  }

  Future<account.BindPsk_DeviceVerify> verifyServer(
    account.BindPsk_ServerVerify verification,
  ) async {
    final reply = await _exchange(
      account.Account_AccountID.BIND_VERIFY,
      account.Account(pskServerVerify: verification),
    );
    if (!reply.hasPskDeviceVerify()) {
      throw const FormatException('Missing device verification');
    }
    return reply.pskDeviceVerify;
  }

  Future<account.BindPsk_DeviceConfirm> confirmServer({
    required Uint8List deviceKey,
    required String bindKey,
    required String code,
  }) async {
    final codeBytes = Uint8List.fromList(utf8.encode(code));
    final random = generateRandomBytes(16);
    final reply = await _exchange(
      account.Account_AccountID.BIND_CONFIRM,
      account.Account(
        pskAppConfirm: account.BindPsk_AppConfirm(
          appRandom: random,
          appSign: hmacSha256(deviceKey, [random, codeBytes]),
          bindKey: utf8.encode(bindKey),
        ),
      ),
    );
    if (!reply.hasPskDeviceConfirm()) {
      throw const FormatException('Missing device confirmation');
    }
    final confirmed = reply.pskDeviceConfirm;
    _verifySignature(
      confirmed.deviceSign,
      hmacSha256(deviceKey, [
        Uint8List.fromList(confirmed.deviceRandom),
        codeBytes,
      ]),
    );
    return confirmed;
  }

  Future<({Uint8List token, Uint8List resultKey})> negotiateLocal({
    required String appDeviceId,
    String? oob,
    void Function()? waitingForDevice,
  }) async {
    final curve = ECDomainParameters('prime256v1');
    final secure = FortunaRandom()..seed(KeyParameter(generateRandomBytes(32)));
    final generator = ECKeyGenerator()
      ..init(ParametersWithRandom(ECKeyGeneratorParameters(curve), secure));
    final pair = generator.generateKeyPair();
    final public = pair.publicKey;
    final verify = _exchange(
      account.Account_AccountID.BIND_VERIFY,
      account.Account(
        localAppVerify: account.BindLocal_AppVerify(
          appDeviceId: appDeviceId,
          appPublicKey: public.Q!.getEncoded(false).sublist(1),
        ),
      ),
    );
    waitingForDevice?.call();
    final reply = await verify;
    if (!reply.hasLocalDeviceVerify()) {
      throw const FormatException('Missing local binding verification');
    }
    final device = reply.localDeviceVerify;
    if (device.devicePublicKey.length != 64 ||
        device.deviceRandom.length != 16) {
      throw const FormatException('Invalid device binding parameters');
    }
    final point = curve.curve.decodePoint(
      Uint8List.fromList([4, ...device.devicePublicKey]),
    );
    if (point == null || point.isInfinity) {
      throw const FormatException('Invalid device public key');
    }
    final agreement = ECDHBasicAgreement()
      ..init(pair.privateKey);
    final coordinate = agreement.calculateAgreement(ECPublicKey(point, curve));
    final hex = coordinate.toRadixString(16).padLeft(64, '0');
    final shared = Uint8List.fromList([
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ]);
    final deviceRandom = Uint8List.fromList(device.deviceRandom);
    final oobBytes = Uint8List.fromList(utf8.encode(oob ?? ''));
    _verifySignature(
      device.deviceSign,
      hmacSha256(shared, [deviceRandom, oobBytes]),
    );
    final appRandom = generateRandomBytes(16);
    final keyMaterial = hmacSha256(
      Uint8List.fromList([...appRandom, ...deviceRandom]),
      [shared],
    );
    final context = Uint8List.fromList(ascii.encode('miwear-bind'));
    final first = hmacSha256(keyMaterial, [
      context,
      Uint8List.fromList([1]),
    ]);
    final second = hmacSha256(keyMaterial, [
      first,
      context,
      Uint8List.fromList([2]),
    ]);
    final confirmation = await _exchange(
      account.Account_AccountID.BIND_CONFIRM,
      account.Account(
        localAppConfirm: account.BindLocal_AppConfirm(
          appRandom: appRandom,
          appSign: hmacSha256(shared, [appRandom, oobBytes]),
        ),
      ),
    );
    if (!confirmation.hasLocalDeviceConfirm() ||
        !confirmation.localDeviceConfirm.confirmResult) {
      throw const XiaomiBindRejected(account.Account_ErrorCode.CANCEL);
    }
    return (
      token: Uint8List.sublistView(second, 8, 24),
      resultKey: Uint8List.sublistView(first, 16, 32),
    );
  }

  Future<void> finish({
    required Uint8List resultKey,
    required Uint8List resultInfo,
  }) async {
    final encrypted = aes128CcmEncrypt(
      resultKey,
      Uint8List.fromList(List.generate(12, (i) => 16 + i)),
      Uint8List.fromList(ascii.encode('bind-data')),
      resultInfo,
    );
    await _exchange(
      account.Account_AccountID.BIND_RESULT_V2,
      account.Account(
        bindResultV2: account.BindResultV2(encryptResultInfo: encrypted),
      ),
    );
  }
}

void _verifySignature(List<int> actual, Uint8List expected) {
  if (actual.length != expected.length) {
    throw const XiaomiBindRejected(account.Account_ErrorCode.VERIFY_ERROR);
  }
  var difference = 0;
  for (var i = 0; i < actual.length; i++) {
    difference |= actual[i] ^ expected[i];
  }
  if (difference != 0) {
    throw const XiaomiBindRejected(account.Account_ErrorCode.VERIFY_ERROR);
  }
}
