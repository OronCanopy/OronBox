import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:oronbox/src/app/generated/app_localizations.dart';
import 'package:oronbox/src/app/widgets/sys_app_bar.dart';
import 'package:oronbox/src/core/services/shared_prefs_service.dart';
import 'package:oronbox/src/device/zeppos/app_side/zeppos_app_side_storage.dart';
import 'package:oronbox/src/features/devices/pages/tools/zeppos_setting_viewer_page.dart';
import 'package:oronbox/src/features/devices/services/zeppos_app_settings_session.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_all/webview_all.dart';

import '../../../support/test_webview_platform.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const appId = 123;
  final storage = ZeppOsAppSideStorage();
  final coordinator = ZeppOsSettingsCoordinator.instance;
  late Directory root;
  late TestWebViewPlatform platform;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('oronbox-settings-test-');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => root.path,
    );
    SharedPreferences.setMockInitialValues({});
    await SharedPrefsService.instance.init();
    platform = TestWebViewPlatform();
    WebViewPlatform.instance = platform;
    await storage.saveSetting(
      appId,
      Uint8List.fromList(utf8.encode('AppSettingsPage({build: () => View()})')),
    );
  });

  tearDown(() async {
    await coordinator.settle();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    await root.delete(recursive: true);
  });

  test('settings writes reach app-side storage and drain on close', () async {
    final session = ZeppOsAppSettingsSession(appId);
    await session.initialize();
    final controller = platform.controllers.single;
    controller.send({
      'type': 'settings',
      'operation': 'set',
      'key': 'a',
      'value': '1',
    });
    controller.send({
      'type': 'settings',
      'operation': 'set',
      'key': 'b',
      'value': '2',
    });
    controller.send({'type': 'settings', 'operation': 'remove', 'key': 'a'});
    await session.close();
    expect(await coordinator.read(appId), {'b': '2'});
    expect(controller.closes, 1);
    controller.send({'type': 'settings', 'operation': 'clear'});
    await session.close();
    expect(await coordinator.read(appId), {'b': '2'});
    expect(controller.closes, 1);
  });

  test(
    'app-side updates return to the live document and stop on close',
    () async {
      final session = ZeppOsAppSettingsSession(appId);
      await session.initialize();
      final controller = platform.controllers.single;
      final initial = controller.executions.stream.first;
      controller.navigation!.finished!('about:blank');
      await initial;
      final update = controller.executions.stream.first;
      await coordinator.set(appId, 'theme', 'dark');
      expect(await update, contains('"theme":"dark"'));
      await session.close();
      final count = controller.scripts.length;
      await coordinator.set(appId, 'theme', 'light');
      await Future<void>.delayed(Duration.zero);
      expect(controller.scripts, hasLength(count));
    },
  );

  test(
    'malformed messages do not discard later valid settings writes',
    () async {
      final session = ZeppOsAppSettingsSession(appId);
      await session.initialize();
      final controller = platform.controllers.single;
      controller.channel!.onMessageReceived(
        const JavaScriptMessage(message: '{'),
      );
      controller.send({
        'type': 'settings',
        'operation': 'set',
        'key': 'ok',
        'value': 'yes',
      });
      await session.close();
      expect(await coordinator.read(appId), {'ok': 'yes'});
    },
  );

  test(
    'closing during native preparation waits and releases exactly once',
    () async {
      platform.preparation = Completer<void>();
      final session = ZeppOsAppSettingsSession(appId);
      final initializing = session.initialize();
      final rejected = expectLater(initializing, throwsStateError);
      await platform.created.future;
      var closed = false;
      final closing = session.close().then((_) => closed = true);
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      platform.preparation!.complete();
      await rejected;
      await closing;
      expect(platform.controllers.single.closes, 1);
      expect(platform.controllers.single.html, isNull);
    },
  );

  test('initialization failure releases its native session', () async {
    platform.failConfiguration = true;
    final session = ZeppOsAppSettingsSession(appId);
    await expectLater(session.initialize(), throwsStateError);
    await session.close();
    expect(platform.controllers.single.closes, 1);
  });

  test(
    'closing one page leaves another session for the same app usable',
    () async {
      final first = ZeppOsAppSettingsSession(appId);
      final second = ZeppOsAppSettingsSession(appId);
      await first.initialize();
      await second.initialize();
      await first.close();
      final live = platform.controllers.last;
      final initial = live.executions.stream.first;
      live.navigation!.finished!('about:blank');
      await initial;
      final update = live.executions.stream.first;
      await coordinator.set(appId, 'value', 'still live');
      expect(await update, contains('still live'));
      expect(live.closes, 0);
      await second.close();
    },
  );

  testWidgets('settings open as a page and release on return', (tester) async {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, _) => Scaffold(
            body: TextButton(
              onPressed: () => showZeppOsAppSettings(
                context,
                appId: appId,
                title: 'Fixture settings',
              ),
              child: const Text('Open settings'),
            ),
          ),
        ),
        GoRoute(
          path: '/devices/apps/settings/:appId',
          builder: (_, state) => ZeppOsSettingViewerPage(
            appId: int.parse(state.pathParameters['appId']!),
            title: state.uri.queryParameters['title']!,
          ),
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    );
    await tester.tap(find.text('Open settings'));
    await tester.pump();
    for (var frame = 0; frame < 100; frame++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
      if (platform.controllers.isNotEmpty &&
          platform.controllers.single.loaded.isCompleted) {
        break;
      }
    }
    expect(platform.controllers.single.loaded.isCompleted, isTrue);
    await tester.pumpAndSettle();
    expect(find.byType(ZeppOsSettingViewerPage), findsOneWidget);
    expect(find.byType(SysAppBar), findsOneWidget);
    expect(find.byType(WebViewWidget), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
    final controller = platform.controllers.single;
    expect(controller.params.sessionMode, WebViewSessionMode.incognito);
    var removedBeforeRelease = false;
    controller.onClose = () =>
        removedBeforeRelease = find.byType(WebViewWidget).evaluate().isEmpty;
    router.pop();
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
    expect(find.text('Open settings'), findsOneWidget);
    expect(removedBeforeRelease, isTrue);
    expect(controller.closes, 1);
    await tester.pumpWidget(const SizedBox());
    router.dispose();
  });
}
