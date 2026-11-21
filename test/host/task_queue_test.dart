import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:oronbox/src/core/storage/app_data_directory_io.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:oronbox/src/core/storage/managed_temporary_files.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oronbox/src/commands/command_protocol.dart';
import 'package:oronbox/src/core/services/shared_prefs_service.dart';
import 'package:oronbox/src/host/tasks/task_queue.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await SharedPrefsService.instance.init();
  });

  late Directory root;
  late IoAppDataDirectory storage;
  setUp(() async {
    await SharedPrefsService.instance.remove('daemon.tasks');
    root = await Directory.systemTemp.createTemp('oronbox-tasks-test-');
    storage = IoAppDataDirectory(root);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => root.path,
    );
  });
  tearDown(() async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    await root.delete(recursive: true);
  });

  test('runs queued commands strictly one at a time', () async {
    final bus = _DelayedBus();
    final queue = DaemonTaskQueue(bus, storage: storage);
    final first = queue.enqueue(const OronBoxCommand(method: 'first'));
    final second = queue.enqueue(const OronBoxCommand(method: 'second'));

    expect((await queue.wait(first))?.status, 'completed');
    expect((await queue.wait(second))?.status, 'completed');
    expect(bus.maxActive, 1);
    expect(bus.methods, ['first', 'second']);
    await queue.close();
  });

  test('watchface deletion authorization is consumed before execution and ordinary retries', () async {
    final bus = _ReplacementBus();
    final queue = HostTaskQueue(bus, storage: storage);
    final id = queue.enqueue(
      const OronBoxCommand(
        method: 'install.local',
        params: {'replaceWatchfaceId': '123456789', 'device': 'watch'},
      ),
    );
    await bus.started.future;
    expect(bus.commands.single.params['replaceWatchfaceId'], '123456789');
    expect(
      queue.get(id)!.command.params.containsKey('replaceWatchfaceId'),
      isFalse,
    );
    bus.complete.complete();
    expect((await queue.wait(id))?.status, 'failed');
    expect(queue.retry(id), isTrue);
    await queue.wait(id);
    expect(bus.commands.last.params.containsKey('replaceWatchfaceId'), isFalse);
    expect(bus.commands.last.params['device'], 'watch');
    await queue.close();
  });

  test('offline plugin tasks wait without blocking others and pause survives reconnect', () async {
    var connected = false;
    final bus = _DelayedBus();
    final queue = HostTaskQueue(
      bus,
      storage: storage,
      canRun: (task) => task.command.params['pluginId'] == null || connected,
    );
    final waiting = queue.enqueue(
      const OronBoxCommand(
        method: 'install.local',
        params: {'pluginId': 'plugin'},
      ),
    );
    final other = queue.enqueue(const OronBoxCommand(method: 'other'));
    await queue.wait(other);
    expect(queue.get(waiting)?.status, 'waiting_device');
    expect(bus.methods, ['other']);
    expect(queue.holdPending(), 1);
    connected = true;
    queue.resumeWaiting();
    expect(queue.get(waiting)?.status, 'held');
    queue.startHeld();
    expect((await queue.wait(waiting))?.status, 'completed');
    await queue.close();
  });

  test('plugin files survive pending work and are deleted on completion or cancellation', () async {
    final queue = HostTaskQueue(_DelayedBus(), storage: storage);
    Future<String> stage() => ManagedTemporaryFiles.create(
      TemporaryFilePurpose.installs,
      'package.rpk',
      (path) async {
        await File(path).writeAsBytes([1, 2, 3]);
      },
    );
    final path = await stage();
    final id = queue.enqueue(
      OronBoxCommand(
        method: 'install.local',
        params: {'pluginId': 'plugin', 'path': path},
      ),
      held: true,
    );
    expect(await File(path).readAsBytes(), [1, 2, 3]);
    queue.startHeld();
    await queue.wait(id);
    expect(await File(path).exists(), false);
    final cancelledPath = await stage();
    final cancelled = queue.enqueue(
      OronBoxCommand(
        method: 'install.local',
        params: {'pluginId': 'plugin', 'path': cancelledPath},
      ),
      held: true,
    );
    expect(queue.cancel(cancelled), true);
    await queue.close();
    expect(await File(cancelledPath).exists(), false);
    expect(queue.retry(cancelled), false);
  });

  test(
    'closing waits for active cancellation and releases pending plugin files',
    () async {
      final bus = _BlockingBus();
      final queue = HostTaskQueue(
        bus,
        storage: storage,
        onCancelRunning: () async => bus.release(),
      );
      final running = queue.enqueue(
        const OronBoxCommand(method: 'install.local'),
      );
      await bus.started.future;
      final path = await ManagedTemporaryFiles.create(
        TemporaryFilePurpose.installs,
        'package.rpk',
        (path) async {
          await File(path).writeAsBytes([1]);
        },
      );
      final pending = queue.enqueue(
        OronBoxCommand(
          method: 'install.local',
          params: {'pluginId': 'plugin', 'path': path},
        ),
      );
      await queue.close();
      expect(queue.get(running)?.status, 'cancelled');
      expect(queue.get(pending)?.status, 'cancelled');
      expect(await File(path).exists(), false);
      expect(
        () => queue.enqueue(const OronBoxCommand(method: 'other')),
        throwsStateError,
      );
    },
  );

  test('cancelling a running task invokes the cancellation hook', () async {
    final bus = _BlockingBus();
    late final DaemonTaskQueue queue;
    queue = DaemonTaskQueue(
      bus,
      storage: storage,
      onCancelRunning: () async => bus.release(),
    );
    final id = queue.enqueue(const OronBoxCommand(method: 'install.local'));
    await bus.started.future;

    expect(queue.cancel(id), isTrue);
    expect((await queue.wait(id))?.status, 'cancelled');
    expect(bus.cancelled, isTrue);
    await queue.close();
  });

  test('wraps task execution in the configured platform lease', () async {
    final bus = _DelayedBus();
    var activeLeases = 0;
    final queue = DaemonTaskQueue(
      bus,
      storage: storage,
      beginExecution: (_) async {
        activeLeases += 1;
        return () async {
          activeLeases -= 1;
        };
      },
    );

    final id = queue.enqueue(const OronBoxCommand(method: 'install.local'));
    expect((await queue.wait(id))?.status, 'completed');
    expect(activeLeases, 0);
    await queue.close();
  });

  test('preserves actual progress updates below five percent', () async {
    final bus = _ProgressBus([
      const _ProgressEvent(.01, path: '/tmp/resource.bin'),
      const _ProgressEvent(.02, path: '/tmp/resource.bin'),
      const _ProgressEvent(.03, path: '/tmp/resource.bin'),
    ]);
    final queue = DaemonTaskQueue(bus, storage: storage);
    final progress = <double>[];
    final subscription = queue.events.listen((event) {
      if (event.event != 'task') return;
      final value = event.data['progress'];
      if (value is num && value > 0 && value < 1) {
        progress.add(value.toDouble());
      }
    });

    final id = queue.enqueue(
      const OronBoxCommand(
        method: 'install.local',
        params: {'path': '/tmp/resource.bin'},
      ),
    );
    await queue.wait(id);

    expect(progress, [.01, .02, .03]);
    await subscription.cancel();
    await queue.close();
  });

  test('ignores progress from concurrent tasks and backward updates', () async {
    final bus = _ProgressBus([
      const _ProgressEvent(.4, path: '/tmp/current.bin'),
      const _ProgressEvent(
        .9,
        path: '/tmp/other.bin',
        operationId: 'resource.download:other',
      ),
      const _ProgressEvent(.2, path: '/tmp/current.bin'),
      const _ProgressEvent(.7, path: '/tmp/current.bin'),
    ]);
    final queue = DaemonTaskQueue(bus, storage: storage);
    final progress = <double>[];
    final subscription = queue.events.listen((event) {
      if (event.event != 'task') return;
      final value = event.data['progress'];
      if (value is num && value > 0 && value < 1) {
        progress.add(value.toDouble());
      }
    });

    final id = queue.enqueue(
      const OronBoxCommand(
        method: 'install.local',
        params: {'path': '/tmp/current.bin'},
      ),
    );
    await queue.wait(id);

    expect(progress, [.4, .7]);
    await subscription.cancel();
    await queue.close();
  });

  test('resumes a task that was running before host restart', () async {
    final task = DaemonTask(
      id: 'recovered',
      command: const OronBoxCommand(method: 'resource.download'),
      status: 'running',
      createdAt: DateTime(2026),
      startedAt: DateTime(2026, 1, 1, 0, 1),
      progress: .5,
    );
    await SharedPrefsService.instance.setStringList('daemon.tasks', [
      jsonEncode(task.toJson()),
    ]);
    final bus = _DelayedBus();
    final queue = DaemonTaskQueue(bus, storage: storage);

    final recovered = await queue.wait('recovered');
    expect(recovered?.status, 'completed');
    expect(bus.methods, ['resource.download']);
    await queue.close();
  });

  test('drops persisted install tasks on restore, keeps other tasks', () async {
    DaemonTask task(String id, String method, String status) => DaemonTask(
      id: id,
      command: OronBoxCommand(method: method),
      status: status,
      createdAt: DateTime(2026),
    );
    await SharedPrefsService.instance.setStringList('daemon.tasks', [
      jsonEncode(task('install-pending', 'install.local', 'pending').toJson()),
      jsonEncode(task('install-running', 'install.local', 'running').toJson()),
      jsonEncode(task('install-failed', 'install.local', 'failed').toJson()),
      jsonEncode(task('download', 'resource.download', 'held').toJson()),
    ]);
    final bus = _DelayedBus();
    final queue = DaemonTaskQueue(bus, storage: storage);

    await queue.ready;
    expect(queue.get('install-pending'), isNull);
    expect(queue.get('install-running'), isNull);
    expect(queue.get('install-failed'), isNull);
    expect(queue.get('download')?.status, 'held');
    await queue.close();

    // The purge is also written back, so a second restart stays clean.
    final stored = (jsonDecode(
      utf8.decode((await storage.read('state.json'))!),
    ) as List).cast<String>();
    expect(stored, hasLength(1));
    expect(stored.single, contains('resource.download'));
  });
}

class _DelayedBus implements OronBoxCommandBus {
  int active = 0;
  int maxActive = 0;
  final methods = <String>[];

  @override
  Stream<CommandEvent> get events => const Stream.empty();

  @override
  Future<CommandResult> execute(OronBoxCommand command) async {
    active += 1;
    maxActive = active > maxActive ? active : maxActive;
    methods.add(command.method);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    active -= 1;
    return const CommandResult.success();
  }

  @override
  Future<void> close() async {}
}

class _BlockingBus implements OronBoxCommandBus {
  final started = Completer<void>();
  final _release = Completer<void>();
  bool cancelled = false;

  void release() {
    cancelled = true;
    if (!_release.isCompleted) _release.complete();
  }

  @override
  Stream<CommandEvent> get events => const Stream.empty();

  @override
  Future<CommandResult> execute(OronBoxCommand command) async {
    if (!started.isCompleted) started.complete();
    await _release.future;
    return const CommandResult.failure(
      CommandError('cancelled', 'Operation was cancelled'),
    );
  }

  @override
  Future<void> close() async {}
}

class _ProgressBus implements OronBoxCommandBus {
  _ProgressBus(this.progress);

  final List<_ProgressEvent> progress;
  final _events = StreamController<CommandEvent>.broadcast(sync: true);

  @override
  Stream<CommandEvent> get events => _events.stream;

  @override
  Future<CommandResult> execute(OronBoxCommand command) async {
    for (final item in progress) {
      _events.add(
        CommandEvent(
          'progress',
          data: {
            'progress': item.value,
            if (item.path != null) 'path': item.path,
            'operationId': item.operationId ?? command.params['operationId'],
          },
        ),
      );
    }
    return const CommandResult.success();
  }

  @override
  Future<void> close() => _events.close();
}

class _ProgressEvent {
  const _ProgressEvent(this.value, {this.path, this.operationId});

  final double value;
  final String? path;
  final String? operationId;
}

class _ReplacementBus implements OronBoxCommandBus {
  final commands = <OronBoxCommand>[];
  final started = Completer<void>();
  final complete = Completer<void>();

  @override
  Stream<CommandEvent> get events => const Stream.empty();

  @override
  Future<CommandResult> execute(OronBoxCommand command) async {
    commands.add(command);
    if (!started.isCompleted) started.complete();
    await complete.future;
    return const CommandResult.failure(
      CommandError('failed', 'Install failed'),
    );
  }

  @override
  Future<void> close() async {}
}
