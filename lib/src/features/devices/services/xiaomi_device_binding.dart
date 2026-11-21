import 'dart:convert';

import 'package:oronbox/src/features/devices/utils/device_address.dart';
import 'package:flutter/foundation.dart';

import 'package:oronbox/src/device/xiaomi/protocol/generated/wear_account.pb.dart';
import 'package:oronbox/src/device/xiaomi/systems/bind_system.dart';
import 'package:oronbox/src/features/accounts/models/mi_account_models.dart';
import 'package:oronbox/src/features/accounts/services/mi_account_service.dart';

typedef XiaomiBindingCredential = ({
  String authKey,
  String? appDeviceId,
  String? oob,
});

typedef XiaomiOnlineBinding = ({String mac, String userId});

class XiaomiBindingInteraction {
  const XiaomiBindingInteraction({
    required this.ensureAccount,
    required this.confirmCode,
    required this.waitForDevice,
    required this.locale,
    required this.appDeviceId,
    required this.requestOob,
    required this.authenticating,
    required this.binding,
    required this.rememberCredential,
    required this.onlineBindingCompleted,
    this.oob,
  });

  final Future<MiAccountToken> Function() ensureAccount;
  final Future<bool> Function(String) confirmCode;
  final void Function() waitForDevice;
  final String locale;
  final String appDeviceId;
  final Future<String?> Function(String deviceMac) requestOob;
  final void Function() authenticating;
  final void Function(VerifyMode) binding;
  final void Function(XiaomiBindingCredential) rememberCredential;
  final void Function(XiaomiOnlineBinding) onlineBindingCompleted;
  final String? oob;
}

Future<XiaomiBindingCredential> bindXiaomiDevice({
  required XiaomiBindSystem system,
  required BindInfoV2 info,
  required XiaomiBindingInteraction interaction,
  required MiAccountService accounts,
  required String address,
  required void Function() checkActive,
}) async {
  final companion = CompanionDevice(
    deviceType: defaultTargetPlatform == TargetPlatform.iOS
        ? CompanionDevice_DeviceType.IOS
        : CompanionDevice_DeviceType.ANDROID,
    deviceName: 'OronBox',
  );
  if (info.verifyMode == VerifyMode.APP_LOCAL) {
    var oob = interaction.oob;
    if (info.oobMode == OOBMode.DYNAMIC_CODE && oob?.isNotEmpty != true) {
      oob = await interaction.requestOob(info.mac);
      checkActive();
      if (oob?.isNotEmpty != true) {
        throw const XiaomiBindRejected(Account_ErrorCode.CANCEL);
      }
    }
    if (info.oobMode == OOBMode.NUMERIC_COMPARISON) {
      throw const FormatException('Unsupported local confirmation mode');
    }
    final keys = await system.negotiateLocal(
      appDeviceId: interaction.appDeviceId,
      oob: oob,
      waitingForDevice: info.oobMode == OOBMode.BUTTON_CONFIRM
          ? interaction.waitForDevice
          : null,
    );
    checkActive();
    final credential = (
      authKey: _hex(keys.token),
      appDeviceId: interaction.appDeviceId,
      oob: oob,
    );
    interaction.rememberCredential(credential);
    final userId = (await accounts.loadStoredToken())?.userId ?? '';
    checkActive();
    await system.finish(
      resultKey: keys.resultKey,
      resultInfo: BindLocal_ResultInfo(
        userId: userId,
        companionDevice: companion,
      ).writeToBuffer(),
    );
    return credential;
  }

  final token = await interaction.ensureAccount();
  checkActive();
  Future<Map<String, dynamic>> request(
    String step,
    Map<String, Object?> data, {
    String? locale,
  }) => accounts.requestDeviceBinding(
    token: token,
    step: step,
    data: data,
    locale: locale,
  );

  final hello = await request('hello', {
    'mode': info.verifyMode.value,
    'model': info.model,
    'mac': info.mac.isEmpty ? address : info.mac,
    'randomMac': address,
    'phone_id': token.deviceId,
    'node_id': '',
    'sn': info.serialNumber,
    'did': info.did,
    'random_d': base64UrlEncode(info.deviceRandom),
    'is_support_find': false,
  });
  checkActive();
  final identity = {
    'bind_did': hello['bind_did'] as String,
    'bind_index': hello['bind_index'] as String,
  };
  final verify = await system.verifyServer(
    BindPsk_ServerVerify(
      serverPublicKey: base64.decode(hello['pub_s'] as String),
      serverRandom: base64.decode(hello['random_s'] as String),
      serverSign: base64.decode(hello['sign_s'] as String),
    ),
  );
  checkActive();
  final confirmed = await request('ecdh', {
    ...identity,
    'pub_d': base64UrlEncode(verify.devicePublicKey),
    'sign_d': base64UrlEncode(verify.deviceSign),
  });
  checkActive();
  final deviceKey = base64.decode(confirmed['device_key'] as String);
  if (deviceKey.length != 16) throw const FormatException('Invalid device key');
  final code = (confirmed['oob_code'] as int).toString().padLeft(6, '0');
  if (info.oobMode == OOBMode.BUTTON_CONFIRM) interaction.waitForDevice();
  final confirming = system.confirmServer(
    deviceKey: deviceKey,
    bindKey: confirmed['bind_key'] as String,
    code: code,
  );
  // The device and the user can reply in either order.
  final results = await Future.wait<Object>([
    confirming,
    if (info.oobMode == OOBMode.NUMERIC_COMPARISON)
      interaction.confirmCode(code).then((confirmed) {
        if (!confirmed) {
          throw const XiaomiBindRejected(Account_ErrorCode.CANCEL);
        }
        return confirmed;
      }),
  ], eagerError: true);
  checkActive();
  final deviceConfirmation = results.first as BindPsk_DeviceConfirm;
  final result = await request('bind', {
    ...identity,
    'bind_sign': base64UrlEncode(deviceConfirmation.bindSign),
  }, locale: interaction.locale);
  final ret = result['ret'];
  if (ret is! int) {
    throw const FormatException('Xiaomi binding confirmation is missing ret');
  }
  if (ret != 1) throw StateError('Xiaomi binding rejected (ret: $ret)');
  checkActive();
  await system.finish(
    resultKey: Uint8List.fromList(deviceKey),
    resultInfo: BindPsk_ResultInfo(
      userId: token.userId,
      companionDevice: companion,
    ).writeToBuffer(),
  );
  final mac = info.mac.trim().isEmpty ? address : info.mac;
  interaction.onlineBindingCompleted((mac: mac, userId: token.userId));
  for (var attempt = 0; attempt < 3; attempt++) {
    checkActive();
    final credential = await findXiaomiAccountCredential(accounts, token, mac);
    checkActive();
    if (credential != null) {
      interaction.rememberCredential(credential);
      return credential;
    }
    if (attempt < 2) await Future<void>.delayed(const Duration(seconds: 1));
  }
  throw const FormatException(
    'Xiaomi account has not returned a device connection key',
  );
}

Future<XiaomiBindingCredential?> findXiaomiAccountCredential(
  MiAccountService accounts,
  MiAccountToken token,
  String mac,
) async {
  final devices = await accounts.fetchBoundDevices(token: token);
  final keys = devices
      .where((device) => deviceAddressEquals(device.mac, mac))
      .map((device) => device.authKey.trim().toLowerCase())
      .where((key) => RegExp(r'^[0-9a-f]{32}$').hasMatch(key))
      .toSet();
  if (keys.length != 1) return null;
  return (authKey: keys.single, appDeviceId: null, oob: null);
}

String _hex(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
