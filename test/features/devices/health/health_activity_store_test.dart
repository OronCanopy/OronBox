import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:oronbox/src/core/storage/app_data_directory_io.dart';
import 'package:oronbox/src/device/xiaomi/systems/health_system.dart';
import 'package:oronbox/src/features/devices/health/health_models.dart';
import 'package:oronbox/src/features/devices/health/health_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late IoAppDataDirectory storage;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('oronbox-activity-test-');
    storage = IoAppDataDirectory(root);
    HealthStore.activityStorageForTesting = storage;
    HealthStore.clearCache();
  });

  tearDown(() async {
    HealthStore.activityStorageForTesting = null;
    HealthStore.clearCache();
    await root.delete(recursive: true);
  });

  test('saves activity files in flat readable paths', () async {
    final file = XiaomiActivityRawFile(
      id: '8101af6a1006d9',
      data: Uint8List.fromList(const [1, 2, 3, 4]),
    );

    await HealthStore().saveActivityFiles(
      deviceId: 'AA:BB:CC:DD:EE:FF',
      deviceCode: 'o66',
      files: [file],
    );

    final batches = await HealthStore.listActivityBatches();
    expect(batches, hasLength(1));
    expect(batches.single.deviceId, 'AA:BB:CC:DD:EE:FF');
    expect(batches.single.deviceCode, 'o66');
    expect(batches.single.files.single.id, '8101af6a1006d9');
    // Verify flat path pattern: {deviceId}/{fileId}.bin
    expect(batches.single.files.single.path, 'aabbccddeeff/8101af6a1006d9.bin');
  });

  test('exports and imports activity batch archive', () async {
    final file = XiaomiActivityRawFile(
      id: '8101af6a1006d9',
      data: Uint8List.fromList(const [5, 6, 7]),
    );

    await HealthStore().saveActivityFiles(
      deviceId: 'device-export-test',
      deviceCode: 'o66nfc',
      files: [file],
    );

    final batches = await HealthStore.listActivityBatches();
    final batchId = batches.single.id;
    final exportedBytes = await HealthStore.exportActivityBatch(batchId);
    expect(exportedBytes, isNotEmpty);

    final imported = await HealthStore.importActivityBatch(exportedBytes);
    expect(imported.files, isNotEmpty);
    expect(imported.deviceId, 'device-export-test');
    expect(imported.deviceCode, 'o66nfc');

    final allBytes = await HealthStore.exportAllActivityBatches();
    await HealthStore.clearActivityFiles();
    final importedAll = await HealthStore.importActivityBatch(allBytes);
    expect(importedAll.deviceId, 'device-export-test');
    expect(importedAll.files, isNotEmpty);
  });

  test('smoothly migrates legacy nested sha256 paths to flat paths', () async {
    const legacyPath = 'legacy_sha256_dir/sub_sha256_dir/digest123.bin';
    final legacyData = Uint8List.fromList(const [10, 20, 30]);
    final digest =
        '6951bbd9c2178b2a9d01714687307afda1eb6161ff8c398486a76683e7b42925';

    // Pre-populate legacy index and file
    await storage.write(legacyPath, legacyData);
    final legacyIndex = jsonEncode({
      'version': 1,
      'snapshots': [
        {
          'id': 'batch-legacy',
          'deviceId': 'device-legacy',
          'capturedAt': DateTime.now().toIso8601String(),
          'files': [
            {
              'id': '8101af6a1007da',
              'path': legacyPath,
              'bytes': legacyData.length,
              'sha256': digest,
            },
          ],
        },
      ],
    });
    await storage.write(
      'index.json',
      Uint8List.fromList(utf8.encode(legacyIndex)),
    );

    // Load batches should automatically trigger flat path migration
    final batches = await HealthStore.listActivityBatches();
    expect(batches, hasLength(1));
    expect(
      batches.single.files.single.path,
      'device-legacy/8101af6a1007da.bin',
    );

    // Confirm new file exists and old file is removed
    final migratedBytes = await storage.read(
      'device-legacy/8101af6a1007da.bin',
    );
    expect(migratedBytes, legacyData);
    final oldBytes = await storage.read(legacyPath);
    expect(oldBytes, isNull);
  });

  test('failed operation does not poison the serialization queue', () async {
    await expectLater(
      storage.exclusive(() async => throw StateError('fail')),
      throwsStateError,
    );
    expect(await storage.exclusive(() async => 42), 42);
  });

  test('overview finds a workout older than its recent window', () async {
    final bytes = await File(
      '${Directory.current.path}/test/device/xiaomi/fixtures/8101af6a1006d9.bin',
    ).readAsBytes();
    await HealthStore().saveActivityFiles(
      deviceId: 'old-workout',
      files: [
        XiaomiActivityRawFile(
          id: '8101af6a1006d9',
          data: Uint8List.fromList(bytes),
        ),
      ],
    );

    final overview = await HealthStore().overview('old-workout');
    expect(overview.workouts, isNotEmpty);

    final historical = await HealthStore().query(
      'old-workout',
      start: DateTime(2026, 9, 19),
      end: DateTime(2026, 9, 21),
      kinds: const ['workouts'],
    );
    expect(historical.workouts, isNotEmpty);
  });

  test(
    'historical workout overview settles without changing stored data',
    () async {
      const deviceId = 'overview-reload';
      final store = HealthStore();
      final bytes = await File('test/device/xiaomi/fixtures/8101af6a1006d9.bin')
          .readAsBytes();
      await store.saveActivityFiles(
        deviceId: deviceId,
        files: [XiaomiActivityRawFile(id: '8101af6a1006d9', data: bytes)],
      );
      final now = DateTime.now();
      final recentDay = DateTime(now.year, now.month, now.day);
      final oldDay = recentDay.subtract(const Duration(days: 30));
      await store.write(
        deviceId,
        XiaomiHealthData(
          daily: [
            HealthDailySummary(date: recentDay, steps: 1234),
            HealthDailySummary(date: oldDay, steps: 5678),
          ],
        ),
      );
      var notifications = 0;
      final pending = <Future<XiaomiHealthData>>[];
      void onStoredChange() {
        notifications++;
        if (notifications < 6) pending.add(store.overview(deviceId));
      }

      healthDataRevision.addListener(onStoredChange);
      addTearDown(() => healthDataRevision.removeListener(onStoredChange));

      final overview = await store.overview(deviceId);
      while (pending.isNotEmpty) {
        final batch = List.of(pending);
        pending.clear();
        await Future.wait(batch);
      }

      expect(overview.workouts, isNotEmpty);
      expect(overview.capabilities.workouts, isTrue);
      expect(overview.daily.single.steps, 1234);
      expect(HealthStore.getCached(deviceId)!.daily, hasLength(2));
      expect(notifications, 0);
    },
  );

  for (final latestState in [
    'valid',
    'corrupt',
    'missing',
    'truncated',
    'empty',
  ]) {
    test(
      'historical lookup reads only needed summaries, latest=$latestState',
      () async {
        const deviceId = 'indexed-workout';
        final store = HealthStore();
        final bytes = await File(
          'test/device/xiaomi/fixtures/8101af6a1006d9.bin',
        ).readAsBytes();
        final invalidLatest = latestState != 'valid';
        final candidate = Uint8List.fromList(bytes);
        candidate[0] = 0x82;
        if (latestState == 'empty') {
          final empty = Uint8List(11)..setRange(0, 7, candidate);
          ByteData.sublistView(empty).setUint32(
            7,
            crc32(Uint8List.sublistView(empty, 0, 7)),
            Endian.little,
          );
          candidate.setAll(0, empty);
        }
        final latestBytes = latestState == 'empty'
            ? Uint8List.sublistView(candidate, 0, 11)
            : candidate;
        final files = <XiaomiActivityRawFile>[
          XiaomiActivityRawFile(id: '8101af6a1006d9', data: bytes),
          for (var i = 0; i < 100; i++)
            XiaomiActivityRawFile(
              id: '${(0x82 + i).toRadixString(16).padLeft(2, '0')}01af6a100400',
              data: Uint8List.fromList([0]),
            ),
          XiaomiActivityRawFile(
            id: '8201af6a1005d8',
            data: Uint8List.fromList([0]),
          ),
          XiaomiActivityRawFile(
            id: '8201af6a1002da',
            data: Uint8List.fromList([0]),
          ),
          if (invalidLatest)
            XiaomiActivityRawFile(id: '8201af6a1006d9', data: latestBytes),
        ];
        await store.saveActivityFiles(deviceId: deviceId, files: files);
        await store.saveActivityFiles(
          deviceId: 'other-device',
          files: [XiaomiActivityRawFile(id: '8301af6a1006d9', data: bytes)],
        );
        if (latestState == 'missing') {
          await storage.remove('$deviceId/8201af6a1006d9.bin');
        } else if (latestState == 'truncated') {
          await storage.write('$deviceId/8201af6a1006d9.bin', Uint8List(1));
        }
        final counting = _CountingActivityStorage(root);
        HealthStore.activityStorageForTesting = counting;
        final overview = await store.overview(deviceId);
        expect(overview.workouts, hasLength(1));
        expect(counting.fileReads, [
          if (invalidLatest) '$deviceId/8201af6a1006d9.bin',
          '$deviceId/8101af6a1006d9.bin',
        ]);
        counting.fileReads.clear();
        await store.overview(deviceId);
        expect(counting.fileReads, isEmpty);
      },
    );
  }

  test(
    'historical lookup without summaries reads no activity contents',
    () async {
      final bytes = await File('test/device/xiaomi/fixtures/8101af6a1005d8.bin')
          .readAsBytes();
      await HealthStore().saveActivityFiles(
        deviceId: 'no-summary',
        files: [XiaomiActivityRawFile(id: '8101af6a1005d8', data: bytes)],
      );
      final counting = _CountingActivityStorage(root);
      HealthStore.activityStorageForTesting = counting;
      expect((await HealthStore().overview('no-summary')).workouts, isEmpty);
      expect(counting.fileReads, isEmpty);
    },
  );

  test(
    'concurrent queries preserve a synchronization completed during decoding',
    () async {
      const deviceId = 'concurrent-query';
      final store = HealthStore();
      final bytes = await File('test/device/xiaomi/fixtures/8101af6a1005d8.bin')
          .readAsBytes();
      await store.saveActivityFiles(
        deviceId: deviceId,
        files: [XiaomiActivityRawFile(id: '8101af6a1005d8', data: bytes)],
      );
      final today = DateTime.now();
      await store.write(
        deviceId,
        XiaomiHealthData(daily: [HealthDailySummary(date: today, steps: 10)]),
      );
      final blocked = _BlockingActivityStorage(root);
      HealthStore.activityStorageForTesting = blocked;
      final first = store.query(
        deviceId,
        start: DateTime(2020),
        end: DateTime(2030),
      );
      await blocked.started.future;
      final second = store.query(
        deviceId,
        start: DateTime(2020),
        end: DateTime(2030),
      );
      await store.write(
        deviceId,
        XiaomiHealthData(daily: [HealthDailySummary(date: today, steps: 20)]),
      );
      blocked.resume.complete();

      final results = await Future.wait([first, second]);
      expect(results.map((data) => data.daily.single.steps), everyElement(20));
      expect(HealthStore.getCached(deviceId)!.daily.single.steps, 20);
      expect(blocked.fileReads, 1);
    },
  );

  test(
    'saving activity files invalidates an empty historical workout lookup',
    () async {
      const deviceId = 'new-workout';
      final store = HealthStore();
      expect((await store.overview(deviceId)).workouts, isEmpty);
      final bytes = await File('test/device/xiaomi/fixtures/8101af6a1006d9.bin')
          .readAsBytes();
      await store.saveActivityFiles(
        deviceId: deviceId,
        files: [XiaomiActivityRawFile(id: '8101af6a1006d9', data: bytes)],
      );
      expect((await store.overview(deviceId)).workouts, isNotEmpty);
      await HealthStore.clearActivityFiles();
      expect((await store.overview(deviceId)).workouts, isEmpty);
    },
  );
}

class _BlockingActivityStorage extends IoAppDataDirectory {
  _BlockingActivityStorage(super.root);

  final started = Completer<void>();
  final resume = Completer<void>();
  int fileReads = 0;

  @override
  Future<Uint8List?> read(String path) async {
    if (path == 'index.json' && !started.isCompleted) {
      started.complete();
      await resume.future;
    }
    if (path.endsWith('.bin')) fileReads++;
    return super.read(path);
  }
}

class _CountingActivityStorage extends IoAppDataDirectory {
  _CountingActivityStorage(super.root);

  final fileReads = <String>[];

  @override
  Future<Uint8List?> read(String path) async {
    if (path.endsWith('.bin')) fileReads.add(path);
    return super.read(path);
  }
}
