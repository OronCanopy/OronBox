import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:oronbox/src/device/core/entity.dart';
import 'package:oronbox/src/device/core/event_bus.dart';
import 'package:oronbox/src/device/core/transport.dart';
import 'package:oronbox/src/device/xiaomi/protocol/generated/wear.pb.dart'
    as pb;
import 'package:oronbox/src/device/xiaomi/protocol/generated/wear_common.pbenum.dart'
    as common;
import 'package:oronbox/src/device/xiaomi/protocol/generated/wear_notification.pb.dart'
    as notification;
import 'package:oronbox/src/device/xiaomi/protocol/generated/wear_system.pb.dart'
    as system;
import 'package:oronbox/src/device/xiaomi/protocol/generated/wear_thirdparty_app.pb.dart'
    as app;
import 'package:oronbox/src/device/xiaomi/protocol/generated/wear_watch_face.pb.dart'
    as watch;
import 'package:oronbox/src/device/xiaomi/protocol/packet/mass_packet.dart';
import 'package:oronbox/src/device/xiaomi/protocol/transport/mass_transfer.dart';
import 'package:oronbox/src/device/xiaomi/systems/install_system.dart';
import 'package:oronbox/src/device/xiaomi/systems/mass_system.dart';
import 'package:oronbox/src/device/xiaomi/systems/resource_system.dart';
import 'package:oronbox/src/device/xiaomi/systems/watchface_system.dart';
import 'package:oronbox/src/device/xiaomi/systems/xiaomi_device_component.dart';

void main() {
  late DeviceEntity entity;
  late DeviceEventBus bus;
  late _Component component;

  setUp(() {
    bus = DeviceEventBus();
    final transport = _Transport();
    entity = DeviceEntity(
      id: 'watch',
      kind: 'xiaomi',
      transport: transport,
      eventBus: bus,
    );
    component = _Component(transport);
    entity.set<XiaomiDeviceComponent>(component);
  });
  tearDown(() async {
    await entity.dispose();
    component.requestPool.clear();
    bus.dispose();
  });

  for (final (type, status, errorCode) in [
    ('watchface', common.PrepareStatus.LOW_STORAGE, 'install_low_storage'),
    (
      'app',
      common.PrepareStatus.EXCEED_QUANTITY_LIMIT,
      'install_quantity_limit',
    ),
    ('firmware', common.PrepareStatus.LOW_BATTERY, 'install_low_battery'),
    ('notification', common.PrepareStatus.LOW_STORAGE, 'install_low_storage'),
  ]) {
    test('$type rejects $status before sending file data', () async {
      final mass = _Mass();
      final installer = XiaomiInstallSystem();
      entity.registerSystem(mass);
      entity.registerSystem(installer);
      component.send = (packet) async {
        component.requestPool.onPacket(
          pb.WearPacket(
            type: packet.type,
            id: packet.id,
            watchFace: type == 'watchface'
                ? watch.WatchFace(prepareStatus: status)
                : null,
            thirdpartyApp: type == 'app'
                ? app.ThirdpartyApp(
                    installResponse: app.AppInstaller_Response(
                      prepareStatus: status,
                    ),
                  )
                : null,
            system: type == 'firmware'
                ? system.System(
                    prepareOtaResponse: system.PrepareOta_Response(
                      prepareStatus: status,
                    ),
                  )
                : null,
            notification: type == 'notification'
                ? notification.Notification(
                    appIconResponse: notification.PrepareAppIcon_Response(
                      prepareStatus: status,
                    ),
                  )
                : null,
          ),
        );
      };
      final bytes = Uint8List(128)..setAll(0x28, '123456789'.codeUnits);
      final installing = switch (type) {
        'watchface' => installer.installWatchface(bytes, watchfaceId: ''),
        'app' => installer.installApp(bytes),
        'firmware' => installer.installFirmware(bytes),
        _ => installer.installNotificationIcon(
          bytes,
          packageName: 'org.example.app',
        ),
      };
      await expectLater(
        installing,
        throwsA(
          isA<XiaomiInstallException>().having(
            (error) => error.code,
            'error code',
            errorCode,
          ),
        ),
      );
      expect(mass.payloads, isEmpty);
      expect(component.sent, hasLength(1));
    });
  }

  for (final scenario in ['reboot', 'incomplete transfer', 'rejected']) {
    test('firmware finish handles $scenario', () async {
      final mass = _Mass()..reportResult = false;
      final installer = XiaomiInstallSystem();
      entity.registerSystem(mass);
      entity.registerSystem(installer);
      void reply(common.PrepareStatus status) {
        component.requestPool.onPacket(
          pb.WearPacket(
            type: pb.WearPacket_Type.SYSTEM,
            id: system.System_SystemID.PREPARE_OTA.value,
            system: system.System(
              prepareOtaResponse: system.PrepareOta_Response(
                prepareStatus: status,
              ),
            ),
          ),
        );
      }

      component.send = (_) async => reply(common.PrepareStatus.READY);
      mass.finish = () async {
        if (scenario == 'rejected') reply(common.PrepareStatus.LOW_BATTERY);
        await installer.dispose();
        if (scenario == 'incomplete transfer') {
          throw StateError('MASS transfer interrupted');
        }
      };
      final result = installer.installFirmware(Uint8List(80));
      switch (scenario) {
        case 'reboot':
          await result;
        case 'incomplete transfer':
          await expectLater(
            result,
            throwsA(
              isA<StateError>().having(
                (e) => e.message,
                'message',
                'MASS transfer interrupted',
              ),
            ),
          );
        case 'rejected':
          await expectLater(
            result,
            throwsA(
              isA<XiaomiInstallException>().having(
                (e) => e.code,
                'code',
                'install_low_battery',
              ),
            ),
          );
      }
      expect(mass.payloads, hasLength(1));
    });
  }

  test('MASS watchface preserves bytes without an override and rewrites only an explicit ID', () async {
    final mass = _Mass();
    final installer = XiaomiInstallSystem();
    entity.registerSystem(mass);
    entity.registerSystem(installer);
    final bytes = Uint8List(128)
      ..setRange(0x28, 0x28 + 12, '123456789012'.codeUnits);
    component.send = (packet) async {
      component.requestPool.onPacket(
        pb.WearPacket(
          type: packet.type,
          id: packet.id,
          watchFace: watch.WatchFace(prepareStatus: common.PrepareStatus.READY),
        ),
      );
    };
    await installer.installWatchface(bytes, watchfaceId: '');
    expect(mass.payloads.single, bytes);
    expect(component.sent.single.watchFace.prepareInfo.id, '123456789012');
    await installer.installWatchface(bytes, watchfaceId: '987654321');
    expect(mass.payloads.last.sublist(0x28, 0x28 + 12), [
      ...'987654321'.codeUnits,
      0,
      0,
      0,
    ]);
    expect(bytes.sublist(0x28, 0x28 + 12), '123456789012'.codeUnits);
  });

  test(
    'watchface overrides use the complete ID field without changing the title',
    () async {
      final mass = _Mass();
      entity.registerSystem(mass);
      final installer = XiaomiInstallSystem();
      entity.registerSystem(installer);
      final bytes = Uint8List(128)
        ..setAll(0x28, 'aB3dE6gH9jK2'.codeUnits)
        ..setAll(0x68, 'Test face'.codeUnits);
      final original = Uint8List.fromList(bytes);
      component.send = (packet) async {
        component.requestPool.onPacket(
          pb.WearPacket(
            type: packet.type,
            id: packet.id,
            watchFace: watch.WatchFace(
              prepareStatus: common.PrepareStatus.READY,
            ),
          ),
        );
      };
      final installedId = await installer.installWatchface(
        bytes,
        watchfaceId: 'ABCDEF1234567890',
      );
      expect(installedId, 'ABCDEF1234567890');
      expect(
        component.sent.single.watchFace.prepareInfo.id,
        'ABCDEF1234567890',
      );
      expect(
        mass.payloads.single.sublist(0x28, 0x38),
        'ABCDEF1234567890'.codeUnits,
      );
      expect(mass.payloads.single.sublist(0x38, 0x68), everyElement(0));
      expect(mass.payloads.single.sublist(0x68), original.sublist(0x68));
      expect(bytes, original);
    },
  );

  for (final disposing in [false, true]) {
    test(
      disposing
          ? 'disposing after MASS completes cancels the install result wait'
          : 'reset cancels the install result wait and allows a new install',
      () async {
        final mass = _Mass()..reportResult = false;
        final installer = XiaomiInstallSystem();
        entity.registerSystem(mass);
        entity.registerSystem(installer);
        component.send = (packet) async {
          component.requestPool.onPacket(
            pb.WearPacket(
              type: packet.type,
              id: packet.id,
              watchFace: watch.WatchFace(
                prepareStatus: common.PrepareStatus.READY,
              ),
            ),
          );
        };
        final installing = installer.installWatchface(
          Uint8List(128)..setAll(0x28, '111222333'.codeUnits),
          watchfaceId: '123456789',
        );
        await Future<void>.delayed(Duration.zero);
        expect(mass.payloads, hasLength(1));
        final failed = expectLater(
          installing.timeout(const Duration(milliseconds: 200)),
          throwsStateError,
        );
        if (disposing) {
          await entity.dispose();
        } else {
          installer.abortPending(StateError('L1 session reset'));
        }
        try {
          await failed;
          expect(component.requestPool.onPacketListeners, isEmpty);
        } finally {
          component.requestPool.onPacket(
            pb.WearPacket(
              type: pb.WearPacket_Type.WATCH_FACE,
              id: watch.WatchFace_WatchFaceID.REPORT_INSTALL_RESULT.value,
              watchFace: watch.WatchFace(
                installResult: watch.InstallResult(
                  code: watch.InstallResult_Code.INSTALL_SUCCESS,
                ),
              ),
            ),
          );
          await installing.then<void>((_) {}, onError: (_, _) {});
        }
        if (!disposing) {
          mass.reportResult = true;
          await installer.installWatchface(
            Uint8List(128)..setAll(0x28, '111222333'.codeUnits),
            watchfaceId: '987654321',
          );
          expect(mass.payloads, hasLength(2));
        }
      },
    );
  }

  test(
    'DOWNGRADE retains the installed face until replacement is authorized',
    () async {
      final mass = _Mass();
      final installer = XiaomiInstallSystem();
      entity.registerSystem(mass);
      entity.registerSystem(installer);
      entity.registerSystem(XiaomiWatchfaceSystem());
      final bytes = Uint8List(128)..setAll(0x28, '123456789'.codeUnits);
      component.send = (packet) async {
        component.requestPool.onPacket(
          pb.WearPacket(
            type: packet.type,
            id: packet.id,
            watchFace: watch.WatchFace(
              prepareStatus: common.PrepareStatus.DOWNGRADE,
            ),
          ),
        );
      };
      await expectLater(
        installer.installWatchface(bytes, watchfaceId: ''),
        throwsA(
          isA<WatchfaceDowngradeException>()
              .having((error) => error.watchfaceId, 'ID', '123456789')
              .having((error) => error.deviceId, 'device', 'watch'),
        ),
      );
      expect(component.sent, hasLength(1));
      expect(mass.payloads, isEmpty);
    },
  );

  for (final outcome in [
    'success',
    'rejected',
    'reset',
    'dispose',
    'downgrade',
    'ready',
  ]) {
    test(
      'authorized replacement waits for deletion acknowledgement ($outcome)',
      () async {
        final mass = _Mass();
        final installer = XiaomiInstallSystem();
        entity.registerSystem(mass);
        entity.registerSystem(installer);
        entity.registerSystem(XiaomiWatchfaceSystem());
        final bytes = Uint8List(128)..setAll(0x28, '123456789'.codeUnits);
        final deleteRequested = Completer<void>();
        var prepares = 0;
        component.send = (packet) async {
          if (packet.id ==
              watch.WatchFace_WatchFaceID.REMOVE_WATCH_FACE.value) {
            expect(packet.watchFace.id, '123456789');
            deleteRequested.complete();
            return;
          }
          prepares++;
          component.requestPool.onPacket(
            pb.WearPacket(
              type: packet.type,
              id: packet.id,
              watchFace: watch.WatchFace(
                prepareReply: watch.PrepareReply(
                  id: '123456789',
                  prepareStatus:
                      outcome == 'ready' ||
                          prepares > 1 && outcome != 'downgrade'
                      ? common.PrepareStatus.READY
                      : common.PrepareStatus.DOWNGRADE,
                  expectedSliceLength: 2048,
                ),
              ),
            ),
          );
        };
        final installing = installer.installWatchface(
          bytes,
          watchfaceId: '',
          replaceWatchfaceId: '123456789',
        );
        final completion = expectLater(
          installing,
          outcome == 'success' || outcome == 'ready'
              ? completes
              : throwsA(isA<Exception>()),
        );
        if (outcome != 'ready') {
          await deleteRequested.future.timeout(const Duration(seconds: 1));
          expect(prepares, 1);
          expect(mass.payloads, isEmpty);
          if (outcome == 'reset') {
            component.requestPool.clear();
          } else if (outcome == 'dispose') {
            await entity.dispose();
          } else {
            component.requestPool.onPacket(
              pb.WearPacket(
                type: pb.WearPacket_Type.WATCH_FACE,
                id: watch.WatchFace_WatchFaceID.REMOVE_WATCH_FACE.value,
                watchFace: watch.WatchFace(success: outcome != 'rejected'),
              ),
            );
          }
        }
        await completion;
        if (outcome == 'success' || outcome == 'ready') {
          expect(mass.payloads.single, bytes);
          expect(mass.sliceLengths.single, 2048);
        } else {
          expect(mass.payloads, isEmpty);
        }
        expect(
          prepares,
          outcome == 'success' || outcome == 'downgrade' ? 2 : 1,
        );
        expect(
          component.sent.where((packet) => packet.id == 2),
          hasLength(outcome == 'ready' ? 0 : 1),
        );
      },
    );
  }

  test(
    'resource queries coalesce and abort while the transport is still sending',
    () async {
      final resources = XiaomiResourceSystem();
      entity.registerSystem(resources);
      final sending = Completer<void>();
      component.send = (_) => sending.future;
      final first = resources.fetchInstalledQuickApps();
      final second = resources.fetchInstalledQuickApps();
      expect(identical(first, second), true);
      final cancelled = expectLater(first, throwsStateError);
      resources.abortPending(StateError('connection reset'));
      await cancelled.timeout(const Duration(seconds: 1));
      expect(component.sent, hasLength(1));
      sending.complete();
      component.send = (_) async => throw StateError('new transport failure');
      await expectLater(resources.fetchInstalledQuickApps(), throwsStateError);
      expect(component.sent, hasLength(2));
      await resources.dispose();
      await expectLater(resources.fetchInstalledQuickApps(), throwsStateError);
      expect(component.sent, hasLength(2));
    },
  );
}

class _Component extends XiaomiDeviceComponent {
  _Component(Transport transport) : super(transport: transport, sppV1: false);
  final sent = <pb.WearPacket>[];
  Future<void> Function(pb.WearPacket) send = (_) async {};

  @override
  Future<void> sendPbPacket(pb.WearPacket packet, {bool waitForAck = false}) {
    sent.add(packet);
    return send(packet);
  }
}

class _Mass extends XiaomiMassSystem {
  final payloads = <Uint8List>[];
  final sliceLengths = <int?>[];
  bool reportResult = true;
  Future<void> Function()? finish;

  @override
  Future<void> sendFile({
    required Uint8List fileData,
    required MassDataType dataType,
    int? expectedSliceLength,
    void Function(SendMassCallbackData)? onProgress,
  }) async {
    payloads.add(Uint8List.fromList(fileData));
    sliceLengths.add(expectedSliceLength);
    if (finish case final fn?) await fn();
    if (!reportResult) return;
    component.requestPool.onPacket(
      pb.WearPacket(
        type: pb.WearPacket_Type.WATCH_FACE,
        id: watch.WatchFace_WatchFaceID.REPORT_INSTALL_RESULT.value,
        watchFace: watch.WatchFace(
          installResult: watch.InstallResult(
            code: watch.InstallResult_Code.INSTALL_SUCCESS,
          ),
        ),
      ),
    );
  }
}

class _Transport implements Transport {
  @override
  String get deviceId => 'watch';
  @override
  String get deviceName => 'Watch';
  @override
  Stream<Uint8List> get incomingData => const Stream.empty();
  @override
  Stream<bool> get connectionState => const Stream.empty();
  @override
  Future<void> send(Uint8List data) async {}
  @override
  Future<void> dispose() async {}
}
