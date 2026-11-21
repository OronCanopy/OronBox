import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:oronbox/src/device/core/event_bus.dart';
import 'package:oronbox/src/device/core/transport.dart';
import 'package:oronbox/src/device/xiaomi/protocol/crypto/miwear_crypto.dart';
import 'package:oronbox/src/device/xiaomi/protocol/generated/wear.pb.dart'
    as pb;
import 'package:oronbox/src/device/xiaomi/protocol/generated/wear_account.pb.dart'
    as account;
import 'package:oronbox/src/device/xiaomi/protocol/packet/l1_packet.dart';
import 'package:oronbox/src/device/xiaomi/protocol/packet/l1cmd_packet.dart';
import 'package:oronbox/src/device/xiaomi/protocol/packet/l2_packet.dart';
import 'package:oronbox/src/device/xiaomi/systems/auth_system.dart';
import 'package:oronbox/src/device/xiaomi/systems/bind_system.dart';
import 'package:oronbox/src/device/xiaomi/systems/xiaomi_device_component.dart';
import 'package:oronbox/src/device/xiaomi/xiaomi_device_factory.dart';

void main() {
  const key = '00112233445566778899aabbccddeeff';
  late _Transport transport;
  late DeviceEventBus bus;
  late XiaomiDeviceComponent component;
  late XiaomiAuthSystem auth;
  late XiaomiBindSystem binding;
  late Future<void> Function() dispose;

  setUp(() {
    transport = _Transport();
    bus = DeviceEventBus();
    final entity = XiaomiDeviceFactory().create(
      id: 'watch',
      kind: 'xiaomi',
      transport: transport,
      eventBus: bus,
    );
    component = entity.getRequired<XiaomiDeviceComponent>();
    auth = entity.system<XiaomiAuthSystem>()!;
    binding = entity.system<XiaomiBindSystem>()!;
    dispose = () async {
      await entity.dispose();
      await component.dispose();
      bus.dispose();
    };
  });
  tearDown(() => dispose());

  List<pb.WearPacket> sentAuth() => transport.writes
      .map(L1Packet.fromBytes)
      .where((packet) => packet.pktType == L1DataType.data)
      .map((packet) => L2Packet.fromBytes(packet.payload))
      .where(
        (packet) =>
            packet.channel == L2Channel.pb && packet.opcode == L2OpCode.write,
      )
      .map((packet) => packet.toWearPacket())
      .where((packet) => packet.type == pb.WearPacket_Type.ACCOUNT)
      .toList();

  void reset() => component.sar.onL1Packet(
    L1Packet(
      pktType: L1DataType.cmd,
      frx: false,
      seq: 0,
      payload: L1CmdBuilder()
          .cmd(CmdCode.cmdL1startReq)
          .txWin(16)
          .build()
          .toPayloadBytes(),
    ),
  );

  account.Auth_DeviceVerify verify(List<int> nonce, {bool valid = true}) {
    final watch = Uint8List.fromList(List.filled(16, 7));
    final phone = Uint8List.fromList(nonce);
    final block = kdfMiwear(parseAuthKey(key), phone, watch);
    return account.Auth_DeviceVerify(
      deviceRandom: watch,
      deviceSign: valid
          ? hmacSha256(Uint8List.sublistView(block, 0, 16), [watch, phone])
          : List.filled(32, 0),
    );
  }

  void reply(account.Auth_DeviceVerify value) => auth.onWearPacket(
    pb.WearPacket(
      type: pb.WearPacket_Type.ACCOUNT,
      id: account.Account_AccountID.AUTH_VERIFY.value,
      account: account.Account(authDeviceVerify: value),
    ),
  );

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  test(
    'binding capability query distinguishes an already paired device',
    () async {
      final query = binding.query();
      final rejected = expectLater(
        query,
        throwsA(
          isA<XiaomiBindRejected>().having(
            (error) => error.code,
            'code',
            account.Account_ErrorCode.HAVE_BOUND,
          ),
        ),
      );
      await flush();
      final request = sentAuth().single;
      expect(request.account.hasBindStartV2(), isTrue);
      binding.onWearPacket(
        pb.WearPacket(
          type: pb.WearPacket_Type.ACCOUNT,
          id: request.id,
          account: account.Account(
            errorCode: account.Account_ErrorCode.HAVE_BOUND,
          ),
        ),
      );
      await rejected;
    },
  );

  test('reconnect reports an explicit unbound response separately', () async {
    final result = auth.authenticate(key);
    final rejected = expectLater(
      result,
      throwsA(
        isA<XiaomiAuthRejected>().having(
          (error) => error.notBound,
          'notBound',
          isTrue,
        ),
      ),
    );
    await flush();
    auth.onWearPacket(
      pb.WearPacket(
        type: pb.WearPacket_Type.ACCOUNT,
        id: account.Account_AccountID.AUTH_VERIFY.value,
        account: account.Account(errorCode: account.Account_ErrorCode.NO_BOUND),
      ),
    );
    await rejected;
  });

  test(
    'local binding credentials authenticate a device requiring OOB',
    () async {
      const oob = '654321';
      final result = auth.authenticate(
        key,
        appDeviceId: 'bound-phone',
        oob: oob,
      );
      await flush();
      final request = sentAuth().single.account.authAppVerify;
      expect(request.appDeviceId, 'bound-phone');
      expect(request.checkDynamicCode, isTrue);
      final appRandom = Uint8List.fromList(request.appRandom);
      final watchRandom = Uint8List.fromList(List.filled(16, 7));
      final keys = kdfMiwear(parseAuthKey(key), appRandom, watchRandom);
      reply(
        account.Auth_DeviceVerify(
          deviceRandom: watchRandom,
          deviceSign: hmacSha256(Uint8List.sublistView(keys, 0, 16), [
            watchRandom,
            appRandom,
            Uint8List.fromList(oob.codeUnits),
          ]),
        ),
      );
      await flush();
      auth.onWearPacket(
        pb.WearPacket(
          type: pb.WearPacket_Type.ACCOUNT,
          id: account.Account_AccountID.AUTH_CONFIRM.value,
          account: account.Account(
            authDeviceConfirm: account.Auth_DeviceConfirm(confirmResult: true),
          ),
        ),
      );
      await result.timeout(const Duration(seconds: 1));
    },
  );

  test(
    'device L1 reset refreshes nonce twice then ends the authentication wait',
    () async {
      final authenticating = auth.authenticate(key);
      final failed = expectLater(authenticating, throwsStateError);
      await flush();
      var nonce = sentAuth().last.account.authAppVerify.appRandom.toList();
      for (var i = 0; i < 2; i++) {
        reset();
        await flush();
        final next = sentAuth().last.account.authAppVerify.appRandom;
        expect(next, isNot(nonce));
        nonce = next.toList();
        expect(component.authKeys, isNull);
      }
      reset();
      await failed.timeout(const Duration(seconds: 1));
      expect(
        transport.writes
            .map(L1Packet.fromBytes)
            .where((p) => p.pktType == L1DataType.cmd)
            .map((p) => L1CmdPacket.fromPayloadBytes(p.payload)!.cmd),
        everyElement(CmdCode.cmdL1startRsp),
      );
    },
  );

  test('one delayed HMAC reply after reset is ignored and current nonce can authenticate', () async {
    final authenticating = auth.authenticate(key);
    await flush();
    final oldNonce = sentAuth().last.account.authAppVerify.appRandom.toList();
    reset();
    await flush();
    final nonce = sentAuth().last.account.authAppVerify.appRandom.toList();
    reply(verify(oldNonce));
    await flush();
    expect(component.authKeys, isNull);
    reply(verify(nonce));
    await flush();
    expect(component.authKeys, isNotNull);
    auth.onWearPacket(
      pb.WearPacket(
        type: pb.WearPacket_Type.ACCOUNT,
        id: account.Account_AccountID.AUTH_CONFIRM.value,
        account: account.Account(
          authDeviceConfirm: account.Auth_DeviceConfirm(confirmResult: true),
        ),
      ),
    );
    await authenticating.timeout(const Duration(seconds: 1));
    final count = sentAuth().length;
    reset();
    await flush();
    expect(sentAuth(), hasLength(count));
  });

  test('invalid HMAC without reset fails immediately and installation abort does not restart auth', () async {
    final authenticating = auth.authenticate(key);
    final failed = expectLater(authenticating, throwsArgumentError);
    await flush();
    final nonce = sentAuth().last.account.authAppVerify.appRandom.toList();
    component.sar.abortPendingTransmissions();
    await flush();
    expect(sentAuth(), hasLength(1));
    reply(verify(nonce, valid: false));
    await failed;
  });
}

class _Transport implements Transport {
  final writes = <Uint8List>[];
  @override
  String get deviceId => 'watch';
  @override
  String get deviceName => 'Watch';
  @override
  Stream<Uint8List> get incomingData => const Stream.empty();
  @override
  Stream<bool> get connectionState => const Stream.empty();
  @override
  Future<void> send(Uint8List bytes) async =>
      writes.add(Uint8List.fromList(bytes));
  @override
  Future<void> dispose() async {}
}
