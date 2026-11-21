import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:cross_file/cross_file.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oronbox/src/app/app_localizations_delegates.dart';
import 'package:oronbox/src/app/generated/app_localizations.dart';
import 'package:oronbox/src/core/models/bt_models.dart';
import 'package:oronbox/src/features/devices/controllers/device_manager.dart';
import 'package:oronbox/src/features/resources/services/install_queue_notifier.dart';
import 'package:oronbox/src/features/resources/services/resource_payload_analyzer.dart';
import 'package:oronbox/src/features/resources/widgets/resource_install_confirmation.dart';

class _FakeInstallQueueNotifier extends InstallQueueNotifier {
  final List<
    ({
      LocalDeviceInstallType type,
      ResourceInstallMode mode,
      String? identifier,
      String? deviceId,
    })
  >
  enqueued = [];

  @override
  InstallQueueState build() => const InstallQueueState();

  @override
  Future<void> enqueueConfirmedLocalFile(
    XFile file, {
    required LocalDeviceInstallType type,
    required ResourceInstallMode installMode,
    String? identifier,
    String? deviceId,
  }) async {
    enqueued.add((
      type: type,
      mode: installMode,
      identifier: identifier,
      deviceId: deviceId,
    ));
  }
}

class _TestDeviceManager extends LocalDeviceManager {
  _TestDeviceManager({this.device});
  final MiWearState? device;

  @override
  DeviceManagerState build() => DeviceManagerState(currentDevice: device);
}

void main() {
  testWidgets(
    'confirmAndEnqueueResourceFile detects Canopus preceded by >4KB data and enqueues cleanly',
    (tester) async {
      final fakeQueue = _FakeInstallQueueNotifier();
      final deviceManager = _TestDeviceManager(
        device: const MiWearState(
          name: 'Xiaomi Smart Band 8 Pro',
          codename: 'm2302b1',
          addr: '00:11:22:33:44:55',
          connectType: 'ble',
        ),
      );

      final elfBytes = Uint8List(8192);
      final archive = Archive()
        ..addFile(
          ArchiveFile(
            'artifacts/cortex-m33/module.elf',
            elfBytes.length,
            elfBytes,
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
              'version': '1.0.0',
              'version_code': 1,
              'artifacts': ['artifacts/cortex-m33/module.elf'],
            }),
          ),
        );
      final tarBytes = Uint8List.fromList(TarEncoder().encode(archive));
      final file = XFile.fromData(
        tarBytes,
        name: 'demo_mod-1.0.0.canopus',
        length: tarBytes.length,
      );

      late BuildContext capturedContext;
      late WidgetRef capturedRef;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            installQueueProvider.overrideWith(() => fakeQueue),
            deviceManagerProvider.overrideWith(() => deviceManager),
          ],
          child: MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Consumer(
              builder: (context, ref, _) {
                capturedContext = context;
                capturedRef = ref;
                return const Scaffold(body: Text('Home'));
              },
            ),
          ),
        ),
      );

      final enqueueFuture = confirmAndEnqueueResourceFile(
        context: capturedContext,
        ref: capturedRef,
        file: file,
        deviceId: '00:11:22:33:44:55',
        selectedType: LocalDeviceInstallType.canopus,
      );

      await tester.pump();
      await tester.pumpAndSettle();

      // Should show install confirmation directly without mismatch
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Install'), findsOneWidget);

      await tester.tap(find.text('Install'));
      await tester.pumpAndSettle();

      final result = await enqueueFuture;
      expect(result, isTrue);
      expect(fakeQueue.enqueued, hasLength(1));
      expect(fakeQueue.enqueued.first.type, LocalDeviceInstallType.canopus);
      expect(fakeQueue.enqueued.first.deviceId, '00:11:22:33:44:55');
      expect(fakeQueue.enqueued.first.identifier, 'demo_mod');
      expect(fakeQueue.enqueued.first.mode, ResourceInstallMode.automatic);
    },
  );

  testWidgets(
    'confirmAndEnqueueResourceFile prompts resource type mismatch when selecting Canopus with app selected',
    (tester) async {
      final fakeQueue = _FakeInstallQueueNotifier();
      final deviceManager = _TestDeviceManager(
        device: const MiWearState(
          name: 'Xiaomi Smart Band 8 Pro',
          codename: 'm2302b1',
          addr: '00:11:22:33:44:55',
          connectType: 'ble',
        ),
      );

      final archive = Archive();
      archive.addFile(
        ArchiveFile(
          'manifest.json',
          utf8
              .encode(
                jsonEncode({
                  'schema': 1,
                  'module_id': 'demo_mod',
                  'canopus_abi': '2',
                }),
              )
              .length,
          utf8.encode(
            jsonEncode({
              'schema': 1,
              'module_id': 'demo_mod',
              'canopus_abi': '2',
            }),
          ),
        ),
      );
      final tarBytes = Uint8List.fromList(TarEncoder().encode(archive));
      final file = XFile.fromData(
        tarBytes,
        name: 'test_module.canopus',
        length: tarBytes.length,
      );

      late BuildContext capturedContext;
      late WidgetRef capturedRef;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            installQueueProvider.overrideWith(() => fakeQueue),
            deviceManagerProvider.overrideWith(() => deviceManager),
          ],
          child: MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Consumer(
              builder: (context, ref, _) {
                capturedContext = context;
                capturedRef = ref;
                return const Scaffold(body: Text('Home'));
              },
            ),
          ),
        ),
      );

      final enqueueFuture = confirmAndEnqueueResourceFile(
        context: capturedContext,
        ref: capturedRef,
        file: file,
        selectedType: LocalDeviceInstallType.app,
      );

      await tester.pump();
      await tester.pumpAndSettle();

      // Should show type mismatch alert
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Incorrect resource type'), findsOneWidget);
      expect(
        find.textContaining(
          'This appears to be a Module resource, but you selected quick app',
        ),
        findsOneWidget,
      );
      expect(find.text('Install as Module'), findsOneWidget);

      await tester.tap(find.text('Install as Module'));
      await tester.pumpAndSettle();

      final result = await enqueueFuture;
      expect(result, isTrue);
      expect(fakeQueue.enqueued, hasLength(1));
      expect(fakeQueue.enqueued.first.type, LocalDeviceInstallType.canopus);
      expect(fakeQueue.enqueued.first.identifier, 'demo_mod');
      expect(fakeQueue.enqueued.first.mode, ResourceInstallMode.automatic);
    },
  );

  testWidgets(
    'confirmAndEnqueueResourceFile does not crash when analysis is null and installs as selected',
    (tester) async {
      final fakeQueue = _FakeInstallQueueNotifier();
      final deviceManager = _TestDeviceManager(
        device: const MiWearState(
          name: 'Xiaomi Smart Band 8 Pro',
          codename: 'm2302b1',
          addr: '00:11:22:33:44:55',
          connectType: 'ble',
        ),
      );

      final plainBytes = Uint8List.fromList(
        utf8.encode('just plain text file'),
      );
      final file = XFile.fromData(
        plainBytes,
        name: 'unknown.txt',
        length: plainBytes.length,
      );

      late BuildContext capturedContext;
      late WidgetRef capturedRef;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            installQueueProvider.overrideWith(() => fakeQueue),
            deviceManagerProvider.overrideWith(() => deviceManager),
          ],
          child: MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Consumer(
              builder: (context, ref, _) {
                capturedContext = context;
                capturedRef = ref;
                return const Scaffold(body: Text('Home'));
              },
            ),
          ),
        ),
      );

      final enqueueFuture = confirmAndEnqueueResourceFile(
        context: capturedContext,
        ref: capturedRef,
        file: file,
        selectedType: LocalDeviceInstallType.app,
      );

      await tester.pump();
      await tester.pumpAndSettle();

      // Shows unknown type dialog
      expect(find.byType(AlertDialog), findsOneWidget);

      // Fast forward the countdown timer (3 seconds)
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();

      final installButton = find.text('Continue as quick app');
      expect(installButton, findsOneWidget);

      await tester.tap(installButton);
      await tester.pumpAndSettle();

      final result = await enqueueFuture;
      expect(result, isTrue);
      expect(fakeQueue.enqueued, hasLength(1));
      expect(fakeQueue.enqueued.first.type, LocalDeviceInstallType.app);
      expect(fakeQueue.enqueued.first.identifier, isNull);
      expect(fakeQueue.enqueued.first.mode, ResourceInstallMode.forceType);
    },
  );
}
