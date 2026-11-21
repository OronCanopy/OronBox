import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oronbox/src/device/core/entity.dart';
import 'package:oronbox/src/device/core/event_bus.dart';
import 'package:oronbox/src/device/core/transport.dart';
import 'package:oronbox/src/device/xiaomi/engineering/miwear_engineering_system.dart';

class _Link implements Transport {
  Future<void> Function(Uint8List)? onSend;
  final sent = <Uint8List>[];
  @override
  String get deviceId => 'engineering-test';
  @override
  String get deviceName => 'N67-FACTEST';
  @override
  Stream<Uint8List> get incomingData => const Stream.empty();
  @override
  Stream<bool> get connectionState => const Stream.empty();
  @override
  Future<void> send(Uint8List bytes) async {
    sent.add(Uint8List.fromList(bytes));
    await onSend?.call(bytes);
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  late _Link link;
  late MiWearEngineeringSystem system;
  late DeviceEntity entity;
  late DeviceEventBus events;
  setUp(() {
    link = _Link();
    events = DeviceEventBus();
    entity = DeviceEntity(
      id: link.deviceId,
      kind: 'miwear-engineering',
      transport: link,
      eventBus: events,
    );
    system = MiWearEngineeringSystem(ble: true, writeLength: 180);
    entity.registerSystem(system);
  });
  tearDown(() async {
    await entity.dispose();
    events.dispose();
  });
  void reply(String text) =>
      system.onData(Uint8List.fromList(ascii.encode(text)));

  test(
    'AT response survives fragmented notifications and uses the factory prefix',
    () async {
      link.onSend = (_) async {
        reply('GETBAT');
        reply('PERCENT=OK,');
        reply('87\r');
        reply('\n');
      };
      expect(
        await system.at('AT^GETBATPERCENT', 'GETBATPERCENT='),
        'GETBATPERCENT=OK,87',
      );
      expect(ascii.decode(link.sent.single), '00AT^GETBATPERCENT');
    },
  );

  test(
    'an unrelated line cannot hide an AT reply in the same notification',
    () async {
      link.onSend = (_) async => reply('notice\r\nGETBATPERCENT=OK,87\r\n');
      expect(
        await system.at('AT^GETBATPERCENT', 'GETBATPERCENT='),
        'GETBATPERCENT=OK,87',
      );
    },
  );

  test('file status is recognized after a diagnostic error prefix', () async {
    link.onSend = (data) async =>
        reply(ascii.decode(data) == '300' ? '300' : 'open error:-1, 331');
    await expectLater(
      system.uploadFirmware(Uint8List(30), (_) {}),
      throwsA(
        isA<MiWearEngineeringException>().having(
          (e) => e.code,
          'code',
          'engineering_response',
        ),
      ),
    );
  });

  test(
    'upload retries the same CRC block and only advances acknowledged bytes',
    () async {
      final payload = Uint8List.fromList(List.generate(9013, (i) => i % 251));
      final uploaded = <int>[];
      final block = <int>[];
      var retried = false;
      var receiving = false;
      final progress = <double>[];
      link.onSend = (data) async {
        if (!receiving) {
          final control = ascii.decode(data);
          if (control == '300') {
            reply('3');
            reply('00');
          } else if (control.startsWith('33')) {
            expect(control, '33OTA,/data/ota/b283_ota.bin,9013');
            receiving = true;
            reply('330');
          } else {
            expect(control, '32');
            reply('320');
          }
          return;
        }
        block.addAll(data);
        final length = (payload.length - uploaded.length).clamp(0, 4480);
        if (block.length < length + 4) return;
        expect(block.length, length + 4);
        expect(
          ByteData.sublistView(Uint8List.fromList(block))
              .getUint32(length, Endian.little),
          getCrc32(block.sublist(0, length)),
        );
        expect(
          block.sublist(0, length),
          payload.sublist(uploaded.length, uploaded.length + length),
        );
        if (!retried) {
          retried = true;
          block.clear();
          reply('311');
          return;
        }
        uploaded.addAll(block.take(length));
        block.clear();
        if (uploaded.length == payload.length) receiving = false;
        reply('310');
      };
      await system.uploadFirmware(payload, progress.add);
      expect(uploaded, payload);
      expect(progress, [4480 / 9013, 8960 / 9013, 1]);
      expect(retried, isTrue);
    },
  );

  test(
    'device rejection stops upload before data or restart commands',
    () async {
      link.onSend = (data) async =>
          reply(ascii.decode(data) == '300' ? '300' : '331');
      await expectLater(
        system.uploadFirmware(Uint8List(30), (_) {}),
        throwsA(isA<MiWearEngineeringException>()),
      );
      expect(link.sent.length, 2);
      expect(
        link.sent.any((d) => ascii.decode(d).contains('OTA_UPDATE')),
        isFalse,
      );
    },
  );

  test(
    'disconnect releases a pending request and rejects further commands',
    () async {
      final pending = system.at('AT^SWVER=APP', 'SWVER=');
      final expectation = expectLater(
        pending,
        throwsA(
          isA<MiWearEngineeringException>().having(
            (e) => e.code,
            'code',
            'cancelled',
          ),
        ),
      );
      await system.dispose();
      await expectation;
      await expectLater(
        system.at('AT^GETBATPERCENT', 'GETBATPERCENT='),
        throwsA(isA<MiWearEngineeringException>()),
      );
    },
  );

  test('a second operation cannot replace a pending AT waiter', () async {
    final first = system.at('AT^SWVER=APP', 'SWVER=');
    await expectLater(
      system.at('AT^GETBATPERCENT', 'GETBATPERCENT='),
      throwsA(
        isA<MiWearEngineeringException>().having(
          (e) => e.code,
          'code',
          'engineering_busy',
        ),
      ),
    );
    reply('SWVER=OK,3.1.190\r\n');
    expect(await first, 'SWVER=OK,3.1.190');
  });
}
