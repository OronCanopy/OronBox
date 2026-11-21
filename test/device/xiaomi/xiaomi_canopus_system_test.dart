import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oronbox/src/device/core/entity.dart';
import 'package:oronbox/src/device/core/event_bus.dart';
import 'package:oronbox/src/device/core/transport.dart';
import 'package:oronbox/src/device/xiaomi/protocol/canopus/canopus_package.dart';
import 'package:oronbox/src/device/xiaomi/protocol/packet/l2_packet.dart';
import 'package:oronbox/src/device/xiaomi/protocol/transport/xiaomi_sar_controller.dart';
import 'package:oronbox/src/device/xiaomi/systems/canopus_system.dart';
import 'package:oronbox/src/device/xiaomi/systems/xiaomi_device_component.dart';

class _FakeTransport implements Transport {
  @override
  String get deviceId => 'test-device';
  @override
  String get deviceName => 'Test Device';
  @override
  Stream<Uint8List> get incomingData => const Stream.empty();
  @override
  Stream<bool> get connectionState => const Stream.empty();
  @override
  Future<void> send(Uint8List data) async {}
  @override
  Future<void> dispose() async {}
}

class _TestXiaomiDeviceComponent extends XiaomiDeviceComponent {
  _TestXiaomiDeviceComponent()
    : super(transport: _FakeTransport(), sppV1: false);

  final List<Uint8List> sentL2Frames = [];
  void Function(L2Channel channel, Uint8List payload)? onSend;

  @override
  Future<void> sendL2Data(L2Channel channel, Uint8List l2Payload) async {
    sentL2Frames.add(l2Payload);
    onSend?.call(channel, l2Payload);
  }

  @override
  Future<RegisteredAck> sendL2DataRegisterAck(
    L2Channel channel,
    Uint8List l2Payload, {
    Duration? timeout,
  }) async {
    sentL2Frames.add(l2Payload);
    onSend?.call(channel, l2Payload);
    return RegisteredAck(seq: 1, ack: Future<void>.value());
  }
}

Uint8List _makeCpcResponse(
  Uint8List request, {
  int? opcode,
  required int result,
  required Uint8List payload,
}) {
  const headerSize = 36;
  final total = headerSize + payload.length;
  final output = Uint8List(total);
  final data = ByteData.sublistView(output);
  data.setUint32(0, 0x43504332, Endian.little); // CPC2
  data.setUint16(4, headerSize, Endian.little);
  data.setUint16(6, 2, Endian.little); // RESPONSE = 2
  data.setUint16(8, 2, Endian.little); // ABI major
  data.setUint16(10, 0, Endian.little); // ABI minor
  data.setUint32(12, total, Endian.little);
  final requestHeader = ByteData.sublistView(request);
  data.setUint32(
    16,
    opcode ?? requestHeader.getUint32(16, Endian.little),
    Endian.little,
  );
  data.setUint32(20, requestHeader.getUint32(20, Endian.little), Endian.little);
  data.setUint32(24, 0, Endian.little); // flags
  data.setUint32(28, result, Endian.little);
  data.setUint32(32, payload.length, Endian.little);
  output.setRange(headerSize, total, payload);
  return output;
}

Uint8List _makeCqd1Payload({
  required int magic,
  required int size,
  String? targetId,
  int moduleCount = 3,
}) {
  final payload = Uint8List(size);
  final data = ByteData.sublistView(payload);
  data.setUint32(0, magic, Endian.little);
  data.setUint32(4, size, Endian.little);
  data.setUint32(8, 2, Endian.little); // framework revision
  data.setUint32(12, 0, Endian.little); // safe mode
  data.setUint32(16, moduleCount, Endian.little); // module count
  data.setUint32(20, 0, Endian.little); // reason
  data.setUint32(24, 0, Endian.little); // error
  data.setUint32(28, 0, Endian.little); // flags
  data.setUint32(32, 0x10, Endian.little); // scan summary
  if (targetId != null && size >= 84) {
    final targetBytes = utf8.encode(targetId);
    payload.setRange(36, 36 + targetBytes.length, targetBytes);
  }
  return payload;
}

Uint8List _makeCqm1Payload({
  int magic = 0x43514D31,
  int size = 64,
  int slot = 0,
  int state = 3,
  int lifecycleClass = 1,
  int version = 100,
  int flags = 0,
  required String moduleId,
  int activationError = 0,
}) {
  final payload = Uint8List(size);
  final data = ByteData.sublistView(payload);
  data.setUint32(0, magic, Endian.little);
  data.setUint32(4, size, Endian.little);
  data.setUint32(8, slot, Endian.little);
  data.setUint32(12, state, Endian.little);
  data.setUint32(16, lifecycleClass, Endian.little);
  data.setUint32(20, version, Endian.little);
  data.setUint32(24, flags, Endian.little);
  final modBytes = utf8.encode(moduleId);
  payload.setRange(28, 28 + modBytes.length, modBytes);
  data.setUint32(60, activationError, Endian.little);
  return payload;
}

void main() {
  late DeviceEventBus bus;
  late _TestXiaomiDeviceComponent component;
  late XiaomiCanopusSystem system;
  late DeviceEntity entity;

  setUp(() {
    bus = DeviceEventBus();
    component = _TestXiaomiDeviceComponent();
    system = XiaomiCanopusSystem();
    entity = DeviceEntity(
      id: 'test-device',
      kind: 'xiaomi',
      transport: _FakeTransport(),
      eventBus: bus,
    );
    entity.set<XiaomiDeviceComponent>(component);
    entity.registerSystem(system);
  });

  tearDown(() async {
    await system.dispose();
  });

  test(
    'selects hashed resources with target files overriding common files',
    () {
      const targetId = 'xiaomi-band-10-3.1.28';
      const targetPath = 'resources/$targetId/icon.bin';
      const commonPath = 'resources/common/icon.bin';
      const rootPath = 'resources/config.bin';
      final targetHash = sha256.convert([1]).toString();
      final manifest = jsonEncode({
        'schema': 1,
        'canopus_abi': 2,
        'module_id': 'demo',
        'artifacts': [
          {
            'target_id': targetId,
            'path': 'module.elf',
            'receipt_path': 'receipt',
          },
        ],
        'resources': [
          {'path': targetPath, 'sha256': targetHash},
          {
            'path': commonPath,
            'sha256': sha256.convert([2]).toString(),
          },
        ],
        'native_app': {
          'resource_hashes': {
            targetPath: targetHash,
            rootPath: sha256.convert([3]).toString(),
          },
        },
      });
      final archive = Archive();
      for (final entry in {
        'manifest.json': utf8.encode(manifest),
        'module.elf': [0],
        'receipt': [0],
        targetPath: [1],
        commonPath: [2],
        rootPath: [3],
      }.entries) {
        archive.addFile(
          ArchiveFile(entry.key, entry.value.length, entry.value),
        );
      }
      final package = const CanopusPackageParser().parse(
        Uint8List.fromList(TarEncoder().encode(archive)),
        targetId: targetId,
      );
      expect(
        {
          for (final resource in package.resources)
            resource.name: resource.data,
        },
        {
          'icon.bin': [1],
          'config.bin': [3],
        },
      );
    },
  );

  test('CPC2 lifecycle states distinguish installed and enabled modules', () {
    const enabledStates = {5, 6, 7, 8, 9, 13};
    for (final state in [...List.generate(21, (index) => index), 255]) {
      final module = XiaomiCanopusSystem.parseModuleInfo(
        _makeCqm1Payload(slot: 0, moduleId: 'neomusic', state: state),
      );
      expect(module.state, state);
      expect(
        module.isEnabled,
        enabledStates.contains(state),
        reason: 'state=$state',
      );
    }
  });

  test(
    'CPC2 lifecycle mutations accept completed and reboot required',
    () async {
      var result = 5;
      final opcodes = <int>[];
      component.onSend = (channel, frame) {
        opcodes.add(ByteData.sublistView(frame).getUint32(16, Endian.little));
        final response = _makeCpcResponse(
          frame,
          result: result,
          payload: Uint8List(0),
        );
        scheduleMicrotask(() {
          system.onLayer2Packet(channel, L2OpCode.writeEnc, response);
        });
      };
      for (result in [5, 8]) {
        await system.setModuleEnabled('neomusic', true);
        await system.setModuleEnabled('neomusic', false);
        await system.removeModule('neomusic');
      }
      expect(opcodes, [3, 4, 5, 3, 4, 5]);
    },
  );

  test('CPC2 lifecycle mutation failures remain errors', () async {
    component.onSend = (channel, frame) {
      final response = _makeCpcResponse(
        frame,
        result: 6,
        payload: Uint8List(0),
      );
      scheduleMicrotask(() {
        system.onLayer2Packet(channel, L2OpCode.writeEnc, response);
      });
    };
    for (final action in <Future<void> Function()>[
      () => system.setModuleEnabled('neomusic', true),
      () => system.setModuleEnabled('neomusic', false),
      () => system.removeModule('neomusic'),
    ]) {
      await expectLater(action(), throwsA(isA<CanopusException>()));
    }
  });

  test('CPC2 lifecycle query still requires completed', () async {
    component.onSend = (channel, frame) {
      final response = _makeCpcResponse(
        frame,
        result: 8,
        payload: Uint8List(0),
      );
      scheduleMicrotask(() {
        system.onLayer2Packet(channel, L2OpCode.writeEnc, response);
      });
    };
    await expectLater(
      system.queryDeviceInfo(),
      throwsA(isA<CanopusException>()),
    );
  });

  test('reports a mismatched CPC2 response without accepting it', () async {
    final event = entity.on<CanopusCommandResponse>().first;
    component.onSend = (channel, frame) {
      system.onLayer2Packet(
        channel,
        L2OpCode.writeEnc,
        _makeCpcResponse(frame, opcode: 4, result: 5, payload: Uint8List(0)),
      );
    };
    await expectLater(
      system.setModuleEnabled('demo', true),
      throwsA(
        isA<CanopusException>().having(
          (error) => error.code,
          'code',
          'canopus_invalid_response',
        ),
      ),
    );
    expect((await event).opcode, 4);
  });

  test(
    'retries a failed Connect restoration before sending to the module',
    () async {
      final opcodes = <int>[];
      component.onSend = (channel, frame) {
        final opcode = ByteData.sublistView(frame).getUint32(16, Endian.little);
        opcodes.add(opcode);
        final refused = opcodes.length == 1;
        system.onLayer2Packet(
          channel,
          L2OpCode.writeEnc,
          _makeCpcResponse(
            frame,
            result: refused ? 7 : 5,
            payload: Uint8List.fromList(refused ? [3] : []),
          ),
        );
      };
      await expectLater(
        system.listenConnect('demo', true, restoring: true),
        throwsA(
          isA<CanopusException>().having(
            (error) => error.code,
            'code',
            'canopus_listener_limit',
          ),
        ),
      );
      await system.sendConnect('demo', Uint8List(0), isText: true);
      expect(opcodes, [20, 20, 19]);
    },
  );

  test('parses standard little-endian CQD1 device info (0x43514431) with target_id', () async {
    component.onSend = (channel, frame) {
      final cqd1 = _makeCqd1Payload(
        magic: 0x43514431, // "1DQC" on wire
        size: 84,
        targetId: 'xiaomi-band-10-3.1.28',
      );
      final resp = _makeCpcResponse(frame, result: 5, payload: cqd1);
      scheduleMicrotask(() {
        system.onLayer2Packet(L2Channel.canopus, L2OpCode.writeEnc, resp);
      });
    };

    // Calling install with dummy invalid tar will reach _queryTargetId first
    // and pass device query, then report an invalid package
    expect(
      () => system.install(Uint8List(0)),
      throwsA(
        isA<CanopusException>().having(
          (e) => e.code,
          'code',
          'canopus_invalid_package',
        ),
      ),
    );
  });

  test('supports 88-byte CQD1 response with request_slots', () async {
    component.onSend = (channel, frame) {
      final cqd1 = _makeCqd1Payload(
        magic: 0x43514431,
        size: 88,
        targetId: 'xiaomi-band-11-1.1.139',
      );
      // bytes 84..88 is request_slots = 16
      ByteData.sublistView(cqd1).setUint32(84, 16, Endian.little);
      final resp = _makeCpcResponse(frame, result: 5, payload: cqd1);
      scheduleMicrotask(() {
        system.onLayer2Packet(L2Channel.canopus, L2OpCode.writeEnc, resp);
      });
    };

    expect(
      () => system.install(Uint8List(0)),
      throwsA(
        isA<CanopusException>().having(
          (e) => e.code,
          'code',
          'canopus_invalid_package',
        ),
      ),
    );
  });

  test('rejects CQD1 when supervisor has no target_id (< 84 bytes)', () async {
    component.onSend = (channel, frame) {
      final cqd1 = _makeCqd1Payload(magic: 0x43514431, size: 36);
      final resp = _makeCpcResponse(frame, result: 5, payload: cqd1);
      scheduleMicrotask(() {
        system.onLayer2Packet(L2Channel.canopus, L2OpCode.writeEnc, resp);
      });
    };

    expect(
      () => system.install(Uint8List(0)),
      throwsA(
        isA<CanopusException>().having(
          (e) => e.code,
          'code',
          'canopus_target_missing',
        ),
      ),
    );
  });

  test('rejects CQD1 with invalid magic', () async {
    component.onSend = (channel, frame) {
      final cqd1 = _makeCqd1Payload(
        magic: 0x12345678,
        size: 84,
        targetId: 'dummy',
      );
      final resp = _makeCpcResponse(frame, result: 5, payload: cqd1);
      scheduleMicrotask(() {
        system.onLayer2Packet(L2Channel.canopus, L2OpCode.writeEnc, resp);
      });
    };

    expect(
      () => system.install(Uint8List(0)),
      throwsA(
        isA<CanopusException>().having(
          (e) => e.code,
          'code',
          'canopus_invalid_response',
        ),
      ),
    );
  });

  test(
    'successfully executes end-to-end install for valid Canopus package',
    () async {
      final elfBytes = Uint8List(512);
      final receiptBytes = Uint8List(176);
      final archive = Archive()
        ..addFile(
          ArchiveFile(
            'artifacts/xiaomi-band-10-3.1.28/module.elf',
            elfBytes.length,
            elfBytes,
          ),
        )
        ..addFile(
          ArchiveFile(
            'receipts/xiaomi-band-10-3.1.28.cmi',
            receiptBytes.length,
            receiptBytes,
          ),
        )
        ..addFile(
          ArchiveFile.string(
            'manifest.json',
            jsonEncode({
              'schema': 1,
              'module_id': 'demo_mod',
              'canopus_abi': '2',
              'lifecycle': 'removable',
              'artifacts': [
                {
                  'target_id': 'xiaomi-band-10-3.1.28',
                  'path': 'artifacts/xiaomi-band-10-3.1.28/module.elf',
                  'receipt_path': 'receipts/xiaomi-band-10-3.1.28.cmi',
                },
              ],
            }),
          ),
        );
      final tarBytes = Uint8List.fromList(TarEncoder().encode(archive));

      component.onSend = (channel, frame) {
        final reqData = ByteData.sublistView(frame);
        final opcode = reqData.getUint32(16, Endian.little);
        Uint8List respPayload = Uint8List(0);
        if (opcode == 9) {
          // QueryDevice
          respPayload = _makeCqd1Payload(
            magic: 0x43514431,
            size: 84,
            targetId: 'xiaomi-band-10-3.1.28',
          );
        }
        final resp = _makeCpcResponse(
          frame,
          result: 5, // completed
          payload: respPayload,
        );
        scheduleMicrotask(() {
          system.onLayer2Packet(L2Channel.canopus, L2OpCode.writeEnc, resp);
        });
      };

      final progressValues = <double>[];
      await system.install(tarBytes, onProgress: progressValues.add);

      expect(progressValues, isNotEmpty);
      expect(progressValues.last, 1.0);
    },
  );

  test('queryDeviceInfo queries device and parses CanopusDeviceInfo', () async {
    component.onSend = (channel, frame) {
      final reqData = ByteData.sublistView(frame);
      final opcode = reqData.getUint32(16, Endian.little);
      expect(opcode, 9);
      final resp = _makeCpcResponse(
        frame,
        result: 5,
        payload: _makeCqd1Payload(
          magic: 0x43514431,
          size: 84,
          targetId: 'xiaomi-band-10-3.1.28',
          moduleCount: 2,
        ),
      );
      scheduleMicrotask(() {
        system.onLayer2Packet(L2Channel.canopus, L2OpCode.writeEnc, resp);
      });
    };

    final info = await system.queryDeviceInfo();
    expect(info, isNotNull);
    expect(info.moduleCount, 2);
    expect(info.targetId, 'xiaomi-band-10-3.1.28');
    expect(info.safeMode, false);
  });

  test(
    'queryModule parses occupied slot and handles disallowed empty slot',
    () async {
      component.onSend = (channel, frame) {
        final reqData = ByteData.sublistView(frame);
        final opcode = reqData.getUint32(16, Endian.little);
        expect(opcode, 8);
        final slot = ByteData.sublistView(
          frame,
          36,
        ).getUint32(0, Endian.little);
        final resp = slot == 0
            ? _makeCpcResponse(
                frame,
                result: 5,
                payload: _makeCqm1Payload(
                  slot: 0,
                  moduleId: 'neo_music',
                  state: 13,
                ),
              )
            : _makeCpcResponse(
                frame,
                result: 7, // disallowed
                payload: Uint8List(0),
              );
        scheduleMicrotask(() {
          system.onLayer2Packet(L2Channel.canopus, L2OpCode.writeEnc, resp);
        });
      };

      final mod0 = await system.queryModule(0);
      expect(mod0, isNotNull);
      expect(mod0!.moduleId, 'neo_music');
      expect(mod0.isEnabled, isTrue);

      final mod1 = await system.queryModule(1);
      expect(mod1, isNull);
    },
  );

  test(
    'listModules queries device info then fetches all active slots',
    () async {
      var reportedCount = 1;
      component.onSend = (channel, frame) {
        final reqData = ByteData.sublistView(frame);
        final opcode = reqData.getUint32(16, Endian.little);
        if (opcode == 9) {
          final resp = _makeCpcResponse(
            frame,
            result: 5,
            payload: _makeCqd1Payload(
              magic: 0x43514431,
              size: 84,
              targetId: 'xiaomi-band-10-3.1.28',
              moduleCount: reportedCount,
            ),
          );
          scheduleMicrotask(() {
            system.onLayer2Packet(L2Channel.canopus, L2OpCode.writeEnc, resp);
          });
        } else if (opcode == 8) {
          final slot = ByteData.sublistView(
            frame,
            36,
          ).getUint32(0, Endian.little);
          final resp = slot == 0
              ? _makeCpcResponse(
                  frame,
                  result: 5,
                  payload: _makeCqm1Payload(
                    slot: 0,
                    moduleId: 'neo_music',
                    state: 2,
                  ),
                )
              : _makeCpcResponse(frame, result: 7, payload: Uint8List(0));
          scheduleMicrotask(() {
            system.onLayer2Packet(L2Channel.canopus, L2OpCode.writeEnc, resp);
          });
        }
      };

      final list = await system.listModules();
      expect(list.length, 1);
      expect(list.first.moduleId, 'neo_music');
      expect(list.first.isEnabled, isFalse);

      reportedCount = 2;
      await expectLater(
        system.listModules(),
        throwsA(
          isA<CanopusException>().having(
            (error) => error.code,
            'code',
            'canopus_module_list_incomplete',
          ),
        ),
      );
    },
  );

  test(
    'module discovery distinguishes silence, rejection and malformed replies',
    () async {
      const timeout = Duration(milliseconds: 50);
      Future<void> expectCode(String code) => expectLater(
        system.listModules(timeout: timeout),
        throwsA(
          isA<CanopusException>().having((error) => error.code, 'code', code),
        ),
      );
      component.onSend = (_, _) {};
      await expectCode('canopus_timeout');

      for (final (result, code) in [
        (7, 'canopus_command_rejected'),
        (5, 'canopus_invalid_response'),
      ]) {
        component.onSend = (_, frame) {
          final response = _makeCpcResponse(
            frame,
            result: result,
            payload: Uint8List(0),
          );
          scheduleMicrotask(() {
            system.onLayer2Packet(
              L2Channel.canopus,
              L2OpCode.writeEnc,
              response,
            );
          });
        };
        await expectCode(code);
      }
    },
  );

  test('setModuleEnabled and removeModule invoke correct opcodes', () async {
    final opcodesCalled = <int>[];
    component.onSend = (channel, frame) {
      final reqData = ByteData.sublistView(frame);
      final opcode = reqData.getUint32(16, Endian.little);
      opcodesCalled.add(opcode);
      final resp = _makeCpcResponse(frame, result: 5, payload: Uint8List(0));
      scheduleMicrotask(() {
        system.onLayer2Packet(L2Channel.canopus, L2OpCode.writeEnc, resp);
      });
    };

    await system.setModuleEnabled('neo_music', true);
    expect(opcodesCalled.last, 3); // Enable

    await system.setModuleEnabled('neo_music', false);
    expect(opcodesCalled.last, 4); // Disable

    await system.removeModule('neo_music');
    expect(opcodesCalled.last, 5); // Remove
  });

  for (final stalled in [false, true]) {
    test(
      stalled
          ? 'staging aborts when the device never advances its write offset'
          : 'windowed staging sends chunks with position feedback and completes',
      () async {
        final elfBytes = Uint8List(2048);
        final receiptBytes = Uint8List(176);
        final archive = Archive()
          ..addFile(
            ArchiveFile(
              'artifacts/xiaomi-band-10-3.1.28/module.elf',
              elfBytes.length,
              elfBytes,
            ),
          )
          ..addFile(
            ArchiveFile(
              'receipts/xiaomi-band-10-3.1.28.cmi',
              receiptBytes.length,
              receiptBytes,
            ),
          )
          ..addFile(
            ArchiveFile.string(
              'manifest.json',
              jsonEncode({
                'schema': 1,
                'module_id': 'window_mod',
                'canopus_abi': '2',
                'lifecycle': 'removable',
                'artifacts': [
                  {
                    'target_id': 'xiaomi-band-10-3.1.28',
                    'path': 'artifacts/xiaomi-band-10-3.1.28/module.elf',
                    'receipt_path': 'receipts/xiaomi-band-10-3.1.28.cmi',
                  },
                ],
              }),
            ),
          );
        final tarBytes = Uint8List.fromList(TarEncoder().encode(archive));

        var currentWritten = 0;
        var aborted = false;
        component.onSend = (channel, frame) {
          final reqData = ByteData.sublistView(frame);
          final opcode = reqData.getUint32(16, Endian.little);
          Uint8List respPayload = Uint8List(0);
          if (opcode == 9) {
            respPayload = _makeCqd1Payload(
              magic: 0x43514431,
              size: 88,
              targetId: 'xiaomi-band-10-3.1.28',
            );
          } else if (opcode == 16) {
            final offset = reqData.getUint32(36, Endian.little);
            final chunkLen = reqData.getUint32(32, Endian.little) - 4;
            if (!stalled) currentWritten = offset + chunkLen;
            respPayload = Uint8List(4);
            ByteData.sublistView(respPayload)
                .setUint32(0, currentWritten, Endian.little);
          } else if (opcode == 18) {
            aborted = true;
          }
          final resp = _makeCpcResponse(
            frame,
            result: stalled && opcode == 16 ? 7 : 5,
            payload: respPayload,
          );
          scheduleMicrotask(() {
            system.onLayer2Packet(L2Channel.canopus, L2OpCode.writeEnc, resp);
          });
        };

        final progressValues = <double>[];
        if (stalled) {
          await expectLater(
            system.install(tarBytes).timeout(const Duration(seconds: 2)),
            throwsA(
              isA<CanopusException>().having(
                (error) => error.message,
                'message',
                contains('no progress'),
              ),
            ),
          );
          expect(aborted, isTrue);
          return;
        }
        await system.install(tarBytes, onProgress: progressValues.add);

        expect(progressValues, isNotEmpty);
        expect(progressValues.last, 1.0);
        expect(currentWritten, 2048);
      },
    );
  }
}
