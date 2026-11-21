import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:oronbox/src/app/app_localizations_delegates.dart';
import 'package:oronbox/src/app/generated/app_localizations.dart';
import 'package:oronbox/src/app/theme/app_theme.dart';
import 'package:oronbox/src/data/community/community_source.dart';
import 'package:oronbox/src/features/resources/domain/community_resource.dart';
import 'package:oronbox/src/features/resources/services/download_queue_notifier.dart';
import 'package:oronbox/src/features/resources/services/install_queue_notifier.dart';
import 'package:oronbox/src/features/resources/widgets/resource_detail_actions.dart';

const _first = CommunityResourceFile(
  id: 'first',
  fileName: 'first.bin',
  version: '1.2',
  size: 2048,
  supportedDevices: {'n66'},
);
const _second = CommunityResourceFile(
  id: 'second',
  fileName: 'second.bin',
  version: '2.3',
  size: 4096,
  supportedDevices: {'n67'},
);
CommunityResourceDetail _detail(List<CommunityResourceFile> files) =>
    CommunityResourceDetail(
      ref: const ResourceRef(
        source: CommunitySourceId.astroboxRepo,
        id: 'test',
      ),
      name: 'Test',
      type: CommunityResourceType.watchface,
      paidType: CommunityPaidType.free,
      authors: const [],
      supportedDevices: const {'n66', 'n67'},
      content: const CommunityResourceContent(
        format: ResourceContentFormat.plainText,
        value: '',
      ),
      files: files,
    );

class _Downloads extends DownloadQueueNotifier {
  _Downloads([this.initial = const []]);
  final List<ResourceTask> initial;
  final enqueued = <({String file, String target})>[];
  void update(List<ResourceTask> tasks) => state = tasks;
  @override
  List<ResourceTask> build() => initial;
  @override
  bool enqueue({
    required CommunityResourceDetail resource,
    required CommunityResourceFile file,
    required String codename,
    String? deviceId,
  }) {
    enqueued.add((file: file.id, target: codename));
    return true;
  }
}

class _Installs extends InstallQueueNotifier {
  _Installs([this.initial = const []]);
  final List<InstallTask> initial;
  final retries = <String>[];
  void update(List<InstallTask> tasks) =>
      state = InstallQueueState(tasks: tasks);
  @override
  InstallQueueState build() => InstallQueueState(tasks: initial);
  @override
  void retry(String taskId) => retries.add(taskId);
}

Future<void> _pump(
  WidgetTester tester,
  CommunityResourceDetail detail,
  _Downloads downloads, {
  String target = 'n66',
  _Installs? installs,
  Widget? secondaryActions,
  double width = 260,
  double top = 0,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        downloadQueueProvider.overrideWith(() => downloads),
        installQueueProvider.overrideWith(() => installs ?? _Installs()),
      ],
      child: MaterialApp(
        theme: AppTheme.light,
        locale: const Locale('zh'),
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Padding(
            padding: EdgeInsets.only(top: top),
            child: SizedBox(
              width: width,
              child: ResourceDetailActions(
                detail: detail,
                currentCodename: target,
                secondaryActions: secondaryActions,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final nearBottom in [false, true]) {
    final small = nearBottom;
    testWidgets(
      'menu avoids the ${small ? "small" : "large"} trigger nearBottom=$nearBottom',
      (tester) async {
        await _pump(
          tester,
          _detail(small ? [_first, _second] : [_second]),
          _Downloads(),
          top: nearBottom ? (small ? 490 : 500) : 80,
        );
        final trigger = small
            ? find.byType(TextButton)
            : find.byType(FilledButton);
        final button = tester.getRect(trigger);
        await tester.tap(trigger);
        await tester.pumpAndSettle();
        final items = find.byType(MenuItemButton);
        expect(items, findsWidgets);
        final first = tester.getRect(items.first);
        final last = tester.getRect(items.last);
        if (nearBottom) {
          expect(last.bottom, lessThanOrEqualTo(button.top));
        } else {
          expect(first.top, greaterThanOrEqualTo(button.bottom));
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('long device menu scrolls within available space', (
    tester,
  ) async {
    final downloads = _Downloads();
    final files = List.generate(
      12,
      (index) => CommunityResourceFile(
        id: 'file-$index',
        fileName: 'file-$index.bin',
        version: '1.$index',
        supportedDevices: const {'n67'},
      ),
    );
    await _pump(tester, _detail(files), downloads, top: 280);
    final button = tester.getRect(find.byType(FilledButton));
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    final scroll = find
        .ancestor(
          of: find.byType(MenuItemButton).first,
          matching: find.byType(SingleChildScrollView),
        )
        .first;
    final bounds = tester.getRect(scroll);
    expect(bounds.top, greaterThanOrEqualTo(0));
    expect(bounds.bottom, lessThanOrEqualTo(600));
    expect(bounds.top >= button.bottom || bounds.bottom <= button.top, isTrue);
    await tester.drag(scroll, const Offset(0, -1000));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(MenuItemButton).last);
    await tester.pumpAndSettle();
    expect(downloads.enqueued.single.file, 'file-11');
    expect(tester.takeException(), isNull);
  });
  testWidgets('metadata stays beside the action in a single-height button', (
    tester,
  ) async {
    await _pump(tester, _detail([_first]), _Downloads());
    final label = tester.getCenter(find.text('安装'));
    final metadata = tester.getCenter(find.text('1.2 · 2.0 KB'));
    expect(metadata.dy, closeTo(label.dy, 1));
    expect(metadata.dx, greaterThan(label.dx));
    expect(tester.getSize(find.byType(FilledButton)).height, 48);
  });
  const width = 320.0;
  testWidgets(
    'full-width install above left download and right actions at $width',
    (tester) async {
      await _pump(
        tester,
        _detail([_first, _second]),
        _Downloads(),
        width: width,
        secondaryActions: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton(onPressed: () {}, child: const Text('投币')),
            TextButton(onPressed: () {}, child: const Text('举报')),
          ],
        ),
      );
      final install = tester.getRect(find.byType(FilledButton));
      final more = tester.getRect(
        find.ancestor(
          of: find.text('更多设备下载'),
          matching: find.byType(TextButton),
        ),
      );
      final coin = tester.getRect(
        find.ancestor(of: find.text('投币'), matching: find.byType(TextButton)),
      );
      final report = tester.getRect(
        find.ancestor(of: find.text('举报'), matching: find.byType(TextButton)),
      );
      expect(install.width, width);
      expect(more.left, install.left);
      expect(more.top, greaterThanOrEqualTo(install.bottom));
      expect(coin.center.dy, more.center.dy);
      expect(report.center.dy, more.center.dy);
      expect(report.right, install.right);
      expect(more.right, lessThanOrEqualTo(coin.left));
      final arrow = tester.getCenter(find.byIcon(Icons.chevron_right));
      expect(arrow.dx, greaterThan(tester.getCenter(find.text('更多设备下载')).dx));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('install success survives queue cleanup for two seconds', (
    tester,
  ) async {
    final detail = _detail([_first]);
    InstallTask task(ResourceTaskStatus status) => InstallTask(
      id: 'current',
      name: 'Test',
      description: 'n66',
      type: LocalDeviceInstallType.watchface,
      filePath: '/test.bin',
      resource: detail,
      file: _first,
      status: status,
      progress: .5,
    );
    final installs = _Installs([task(ResourceTaskStatus.installing)]);
    await _pump(tester, detail, _Downloads(), installs: installs);
    expect(find.textContaining('50'), findsOneWidget);
    installs.update([task(ResourceTaskStatus.completed)]);
    await tester.pump();
    expect(find.text('安装成功'), findsOneWidget);
    installs.update([]);
    await tester.pump(const Duration(milliseconds: 1999));
    expect(find.text('安装成功'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.text('安装'), findsOneWidget);
  });

  testWidgets('download hands over to install without returning to idle', (
    tester,
  ) async {
    final detail = _detail([_first]);
    final downloads = _Downloads([
      ResourceTask(
        id: 'download',
        resource: detail,
        file: _first,
        codename: 'n66',
        status: ResourceTaskStatus.downloading,
        progress: 1,
      ),
    ]);
    final installs = _Installs();
    await _pump(tester, detail, downloads, installs: installs);
    expect(find.textContaining('100'), findsOneWidget);
    installs.update([
      InstallTask(
        id: 'install',
        name: 'Test',
        description: 'n66',
        type: LocalDeviceInstallType.watchface,
        filePath: '/test.bin',
        resource: detail,
        file: _first,
        status: ResourceTaskStatus.installing,
        progress: .3,
      ),
    ]);
    await tester.pump();
    expect(find.textContaining('30'), findsOneWidget);
    downloads.update([]);
    await tester.pump();
    expect(find.textContaining('30'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
  });
  testWidgets('historical completion does not show a new success', (
    tester,
  ) async {
    final detail = _detail([_first]);
    final installs = _Installs([
      InstallTask(
        id: 'old',
        name: 'Test',
        description: 'n66',
        type: LocalDeviceInstallType.watchface,
        filePath: '/test.bin',
        resource: detail,
        file: _first,
        status: ResourceTaskStatus.completed,
      ),
    ]);
    await _pump(tester, detail, _Downloads(), installs: installs);
    expect(find.text('安装成功'), findsNothing);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNotNull,
    );
  });
  testWidgets(
    'same file installing for another device keeps current action available',
    (tester) async {
      const shared = CommunityResourceFile(
        id: 'shared',
        fileName: 'shared.bin',
        version: '1',
        size: 1024,
        supportedDevices: {'n66', 'n67'},
      );
      final detail = _detail([shared]);
      final installs = _Installs([
        InstallTask(
          id: 'other',
          name: 'Test',
          description: 'n67',
          type: LocalDeviceInstallType.watchface,
          filePath: '/test.bin',
          resource: detail,
          file: shared,
          status: ResourceTaskStatus.installing,
        ),
      ]);
      final downloads = _Downloads();
      await _pump(tester, detail, downloads, installs: installs);
      await tester.tap(find.text('安装'));
      expect(downloads.enqueued.single.target, 'n66');
    },
  );
  testWidgets('single incompatible choice opens the device menu', (
    tester,
  ) async {
    final downloads = _Downloads();
    await _pump(tester, _detail([_first]), downloads, target: 'n67');
    expect(find.text('安装'), findsNothing);
    await tester.tap(find.text('更多设备下载'));
    await tester.pumpAndSettle();
    expect(downloads.enqueued, isEmpty);
    expect(find.byType(MenuItemButton), findsOneWidget);
    await tester.tap(find.byType(MenuItemButton));
    await tester.pumpAndSettle();
    expect(downloads.enqueued, [(file: 'first', target: 'n66')]);
  });
  testWidgets('single artifact retains one choice per supported device', (
    tester,
  ) async {
    const shared = CommunityResourceFile(
      id: 'shared',
      fileName: 'shared.bin',
      version: '1',
      size: 1024,
      supportedDevices: {'n66', 'n67'},
    );
    final downloads = _Downloads();
    await _pump(tester, _detail([shared]), downloads);
    expect(find.byIcon(Icons.arrow_drop_down), findsNothing);
    expect(find.text('更多设备下载'), findsOneWidget);
    final moreButton = find.ancestor(
      of: find.text('更多设备下载'),
      matching: find.byType(TextButton),
    );
    expect(
      tester.getTopLeft(moreButton).dx,
      tester.getTopLeft(find.byType(FilledButton)).dx,
    );
    expect(
      tester.getSize(moreButton).width,
      lessThan(tester.getSize(find.byType(FilledButton)).width),
    );
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);
    await tester.tap(find.text('更多设备下载'));
    await tester.pumpAndSettle();
    final items = find.byType(MenuItemButton);
    expect(items, findsNWidgets(2));
    await tester.tap(items.last);
    await tester.pumpAndSettle();
    expect(downloads.enqueued, [(file: 'shared', target: 'n67')]);
  });
  testWidgets(
    'matching file is direct and other device selection keeps the queue path',
    (tester) async {
      final downloads = _Downloads();
      await _pump(tester, _detail([_first, _second]), downloads);
      expect(find.text('1.2 · 2.0 KB'), findsOneWidget);
      await tester.tap(find.text('更多设备下载'));
      await tester.pumpAndSettle();
      expect(find.text('2.3 · 4.0 KB'), findsOneWidget);
      await tester.tap(find.text('2.3 · 4.0 KB'));
      await tester.pumpAndSettle();
      expect(downloads.enqueued, [(file: 'second', target: 'n67')]);
    },
  );
  testWidgets('unmatched multi-file resource opens the device choices', (
    tester,
  ) async {
    final downloads = _Downloads();
    await _pump(
      tester,
      _detail([_first, _second]),
      downloads,
      target: 'unknown',
    );
    expect(find.text('安装'), findsNothing);
    await tester.tap(find.text('更多设备下载'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1.2 · 2.0 KB'));
    await tester.pumpAndSettle();
    expect(downloads.enqueued.single.file, 'first');
  });
  testWidgets('another file downloading does not disable the current file', (
    tester,
  ) async {
    final detail = _detail([_first, _second]);
    final downloads = _Downloads([
      ResourceTask(
        id: 'other',
        resource: detail,
        file: _second,
        codename: 'n67',
        status: ResourceTaskStatus.downloading,
      ),
    ]);
    await _pump(tester, detail, downloads);
    await tester.tap(find.text('安装'));
    expect(downloads.enqueued.single.file, 'first');
  });
  testWidgets(
    'current download shows its progress and prevents duplicate enqueue',
    (tester) async {
      final detail = _detail([_first]);
      final downloads = _Downloads([
        ResourceTask(
          id: 'current',
          resource: detail,
          file: _first,
          codename: 'n66',
          status: ResourceTaskStatus.downloading,
          progress: .42,
        ),
      ]);
      await _pump(tester, detail, downloads);
      expect(find.textContaining('42'), findsOneWidget);
      final button = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(button.onPressed, isNull);
    },
  );
  testWidgets('failed install retries the existing task', (tester) async {
    final detail = _detail([_first]);
    final downloads = _Downloads();
    final installs = _Installs([
      InstallTask(
        id: 'failed',
        name: 'Test',
        description: '',
        type: LocalDeviceInstallType.watchface,
        filePath: '/test.bin',
        resource: detail,
        file: _first,
        status: ResourceTaskStatus.failed,
      ),
    ]);
    await _pump(tester, detail, downloads, installs: installs);
    await tester.tap(find.text('重试'));
    expect(installs.retries, ['failed']);
    expect(downloads.enqueued, isEmpty);
  });
}
