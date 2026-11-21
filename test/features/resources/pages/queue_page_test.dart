import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:oronbox/src/app/app_localizations_delegates.dart';
import 'package:oronbox/src/app/generated/app_localizations.dart';
import 'package:oronbox/src/features/resources/pages/queue_page.dart';
import 'package:oronbox/src/features/resources/services/download_queue_notifier.dart';
import 'package:oronbox/src/features/resources/services/install_queue_notifier.dart';
import 'package:oronbox/src/host/tasks/task_models.dart';
import 'package:oronbox/src/host/tasks/task_monitor.dart';
import 'package:oronbox/src/core/services/shared_prefs_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oronbox/src/commands/command_protocol.dart';
import 'package:oronbox/src/host/application_host_provider.dart';

class _Installs extends InstallQueueNotifier {
  _Installs({
    this.tasks = const [
      InstallTask(
        id: 'failed',
        name: 'Face',
        description: 'Watchface',
        type: LocalDeviceInstallType.watchface,
        filePath: '/face.bin',
        status: ResourceTaskStatus.failed,
        error: 'watchface_downgrade',
        conflictingWatchfaceId: '123456789',
        deviceId: 'watch',
      ),
    ],
  });

  final List<InstallTask> tasks;
  final replacements = <String>[];
  final retries = <String>[];

  @override
  InstallQueueState build() => InstallQueueState(loaded: true, tasks: tasks);

  @override
  void retry(String taskId) => retries.add(taskId);

  @override
  Future<void> reinstallWatchface(
    String taskId, {
    required String identifier,
    bool startImmediately = true,
    bool removeExisting = false,
  }) async {
    if (removeExisting) replacements.add('$taskId/$identifier');
  }
}

class _Downloads extends DownloadQueueNotifier {
  @override
  List<ResourceTask> build() => [];
}

Future<void> _pumpQueue(
  WidgetTester tester,
  _Installs installs, {
  GoRouter? router,
}) async {
  tester.view.physicalSize = const Size(400, 860);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        installQueueProvider.overrideWith(() => installs),
        downloadQueueProvider.overrideWith(_Downloads.new),
        hostTasksProvider.overrideWith((_) => Stream.value(<HostTaskView>[])),
      ],
      child: router != null
          ? MaterialApp.router(
              routerConfig: router,
              locale: const Locale('zh'),
              localizationsDelegates: appLocalizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
            )
          : const MaterialApp(
              locale: Locale('zh'),
              localizationsDelegates: appLocalizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: QueuePage(),
            ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SharedPrefsService.instance.init();
  });
  test('replacement retains the failed file, exact ID and original target across the host boundary', () async {
    final host = _Host();
    final container = ProviderContainer(
      overrides: [applicationHostProvider.overrideWithValue(host)],
    );
    addTearDown(container.dispose);
    final queue = container.read(installQueueProvider.notifier);
    await Future<void>.delayed(Duration.zero);
    final task = container.read(installQueueProvider).tasks.single;
    expect(task.canReplaceWatchface, isTrue);
    await expectLater(
      queue.reinstallWatchface(
        task.id,
        identifier: 'other',
        removeExisting: true,
      ),
      throwsStateError,
    );
    expect(host.enqueued, isEmpty);
    await queue.reinstallWatchface(
      task.id,
      identifier: '123456789',
      removeExisting: true,
    );
    final params =
        (host.enqueued.single.params['command'] as Map)['params'] as Map;
    expect(params['path'], '/face.bin');
    expect(params['device'], 'original-watch');
    expect(params.containsKey('identifier'), isFalse);
    expect(params['replaceWatchfaceId'], '123456789');
    expect(host.enqueued.single.params['held'], isFalse);
  });
  testWidgets(
    'DOWNGRADE offers an explicit delete confirmation and retains ordinary retry',
    (tester) async {
      final installs = _Installs();
      await _pumpQueue(tester, installs);
      expect(find.text('设备上已有相同 ID 的表盘\n当前版本无法直接安装'), findsOneWidget);
      expect(find.byIcon(Icons.refresh), findsOneWidget);
      expect(find.text('删除后重装'), findsNothing);
      await tester.tap(find.byIcon(Icons.refresh));
      await tester.pumpAndSettle();
      expect(find.text('重新安装表盘'), findsOneWidget);
      expect(find.textContaining('原表盘无法自动恢复'), findsOneWidget);
      expect(installs.replacements, isEmpty);
      expect(installs.retries, isEmpty);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(installs.replacements, isEmpty);
      expect(installs.retries, isEmpty);
      await tester.tap(find.byIcon(Icons.refresh));
      await tester.pumpAndSettle();
      await tester.tap(find.text('直接重试'));
      await tester.pumpAndSettle();
      expect(installs.retries, ['failed']);
      expect(installs.replacements, isEmpty);
      await tester.tap(find.byIcon(Icons.refresh));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '删除后重装'));
      await tester.pumpAndSettle();
      expect(installs.replacements, ['failed/123456789']);
      expect(installs.retries, ['failed']);
      expect(tester.takeException(), isNull);
    },
  );

  for (final code in ['install_low_storage', 'install_quantity_limit']) {
    for (final destination in [null, '/devices/apps', '/devices/watchfaces']) {
      testWidgets('$code retry guides to $destination and retains the task', (
        tester,
      ) async {
        final installs = _Installs(
          tasks: [
            InstallTask(
              id: 'failed',
              name: 'Face',
              description: 'Watchface',
              type: LocalDeviceInstallType.watchface,
              filePath: '/face.bin',
              status: ResourceTaskStatus.failed,
              error: 'Device refused installation',
              errorCode: code,
            ),
          ],
        );
        final router = GoRouter(
          routes: [
            GoRoute(path: '/', builder: (_, _) => const QueuePage()),
            GoRoute(
              path: '/devices/apps',
              builder: (_, _) => const Scaffold(body: Text('Apps page')),
            ),
            GoRoute(
              path: '/devices/watchfaces',
              builder: (_, _) => const Scaffold(body: Text('Faces page')),
            ),
          ],
        );
        addTearDown(router.dispose);
        await _pumpQueue(tester, installs, router: router);
        await tester.tap(find.byIcon(Icons.refresh));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(
          find.text(code == 'install_low_storage' ? '设备存储空间不足' : '已达到安装数量限制'),
          findsOneWidget,
        );
        expect(find.textContaining('请先删除一些资源，再重试安装'), findsOneWidget);
        await tester.tap(
          find.widgetWithText(TextButton, switch (destination) {
            '/devices/apps' => '应用管理',
            '/devices/watchfaces' => '表盘管理',
            _ => '取消',
          }),
        );
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        if (destination != null) {
          expect(
            find.text(
              destination == '/devices/apps' ? 'Apps page' : 'Faces page',
            ),
            findsOneWidget,
          );
          router.pop();
          await tester.pumpAndSettle();
          await tester.tap(find.byIcon(Icons.refresh));
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsNothing);
        }
        expect(find.text('Face'), findsOneWidget);
        expect(installs.retries, destination == null ? isEmpty : ['failed']);
        expect(installs.replacements, isEmpty);
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final failure in {
    'install_low_battery': '设备电量过低',
    'request_timeout': '请求超时，请重试',
  }.entries) {
    testWidgets('${failure.key} retries without a dialog', (tester) async {
      final installs = _Installs(
        tasks: [
          InstallTask(
            id: 'failed',
            name: 'Face',
            description: 'Watchface',
            type: LocalDeviceInstallType.watchface,
            filePath: '/face.bin',
            status: ResourceTaskStatus.failed,
            error: failure.key,
          ),
        ],
      );
      await _pumpQueue(tester, installs);
      expect(find.text(failure.value), findsOneWidget);
      await tester.tap(find.byIcon(Icons.refresh));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(installs.retries, ['failed']);
      expect(installs.replacements, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }
}

class _Host implements OronBoxCommandBus {
  final enqueued = <OronBoxCommand>[];

  @override
  Stream<CommandEvent> get events => const Stream.empty();

  @override
  Future<CommandResult> execute(OronBoxCommand command) async {
    if (command.method == 'task.enqueue') enqueued.add(command);
    if (command.method != 'queue.list') return const CommandResult.success();
    return const CommandResult.success([
      {
        'id': 'failed',
        'status': 'failed',
        'command': {
          'method': 'install.local',
          'params': {'type': 'watchface', 'path': '/face.bin', 'title': 'Face'},
        },
        'result': {
          'ok': false,
          'error': {
            'code': 'watchface_downgrade',
            'message': 'watchface_downgrade',
            'details': {
              'watchfaceId': '123456789',
              'deviceId': 'original-watch',
            },
          },
        },
      },
    ]);
  }

  @override
  Future<void> close() async {}
}
