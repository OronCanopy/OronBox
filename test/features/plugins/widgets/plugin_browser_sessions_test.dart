import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oronbox/src/core/services/shared_prefs_service.dart';
import 'package:oronbox/src/app/widgets/sys_app_bar.dart';
import 'package:oronbox/src/app/router/app_router.dart';
import 'package:oronbox/src/app/generated/app_localizations.dart';
import 'package:oronbox/src/app/app_localizations_delegates.dart';
import 'package:oronbox/src/features/plugins/widgets/plugin_browser_sessions.dart';
import 'package:oronbox/src/features/plugins/pages/plugin_window_app.dart';
import 'package:oronbox/src/features/plugins/pages/plugin_management_page.dart';
import 'package:oronbox/src/commands/command_protocol.dart';
import 'package:oronbox/src/host/application_host_provider.dart';
import 'package:webview_all/webview_all.dart';

import '../../../support/test_webview_platform.dart';

void main() {
  late TestWebViewPlatform platform;
  GoRouter? router;
  setUp(() async {
    router = null;
    SharedPreferences.setMockInitialValues({});
    await SharedPrefsService.instance.init();
    platform = TestWebViewPlatform();
    platform.cookies.values = const [
      WebViewCookie(name: 'session', value: 'test', domain: 'example.test'),
    ];
    WebViewPlatform.instance = platform;
  });

  tearDown(() => router?.dispose());

  Future<void> mount(WidgetTester tester) async {
    router = GoRouter(
      navigatorKey: rootNavigatorKey,
      routes: [
        GoRoute(path: '/', builder: (_, _) => const Scaffold()),
        GoRoute(
          path: '/other',
          builder: (_, _) => const Scaffold(body: Text('Other page')),
        ),
        pluginBrowserRoute(),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('closing removes the page before releasing its native WebView', (
    tester,
  ) async {
    await mount(tester);
    final browser = PluginBrowserSessions(pluginId: 'fixture');
    final id = await browser.handle('browser.open', [
      {'url': 'https://example.test'},
    ]);
    await tester.pumpAndSettle();
    final controller = platform.controllers.single;
    expect(find.byType(WebViewWidget), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
    expect(find.byType(SysAppBar), findsOneWidget);
    var widgetRemovedBeforeClose = false;
    controller.onClose = () => widgetRemovedBeforeClose = find
        .byType(WebViewWidget)
        .evaluate()
        .isEmpty;
    final closing = browser.handle('browser.close', [id]);
    await tester.pumpAndSettle();
    await closing;
    expect(widgetRemovedBeforeClose, isTrue);
    expect(controller.closes, 1);
    await browser.close();
    expect(controller.closes, 1);
  });

  testWidgets('stopping during WebView preparation waits for native release', (
    tester,
  ) async {
    await mount(tester);
    platform.preparation = Completer<void>();
    final browser = PluginBrowserSessions(pluginId: 'fixture');
    final opening = browser.handle('browser.open', [
      {'url': 'https://example.test'},
    ]);
    final rejected = expectLater(opening, throwsStateError);
    await tester.pump();
    var closed = false;
    final closing = browser.close().then((_) => closed = true);
    await tester.pump();
    expect(closed, isFalse);
    platform.preparation!.complete();
    await tester.pumpAndSettle();
    await closing;
    await rejected;
    expect(platform.controllers.single.closes, 1);
    expect(find.byType(WebViewWidget), findsNothing);
  });

  testWidgets(
    'initial intercept releases WebView and retains the requested result',
    (tester) async {
      await mount(tester);
      platform.interceptOnLoad = 'oronbox-login://complete?code=test';
      final browser = PluginBrowserSessions(pluginId: 'fixture');
      final id = await browser.handle('browser.open', [
        {
          'url': 'https://example.test',
          'intercept-prefixes': ['oronbox-login://complete'],
          'close-on-intercept': true,
          'ephemeral': true,
        },
      ]);
      expect(
        await browser.handle('browser.wait-for-intercept', [id]),
        platform.interceptOnLoad,
      );
      expect(platform.controllers.single.closes, 1);
      expect(
        platform.controllers.single.params.sessionMode,
        WebViewSessionMode.incognito,
      );
      await browser.close();
    },
  );

  testWidgets('creation failure still releases the allocated controller', (
    tester,
  ) async {
    await mount(tester);
    platform.failPreparation = true;
    final browser = PluginBrowserSessions(pluginId: 'fixture');
    await expectLater(
      browser.handle('browser.open', [
        {'url': 'https://example.test'},
      ]),
      throwsStateError,
    );
    expect(platform.controllers.single.closes, 1);
    await browser.close();
  });
  testWidgets('back cancels interception and releases the owned session', (
    tester,
  ) async {
    await mount(tester);
    final browser = PluginBrowserSessions(pluginId: 'fixture');
    final id = await browser.handle('browser.open', [
      {'url': 'https://example.test'},
    ]);
    await tester.pumpAndSettle();
    final waiting = expectLater(
      browser.handle('browser.wait-for-intercept', [id]),
      throwsStateError,
    );
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    await waiting;
    expect(platform.controllers.single.closes, 1);
    expect(router!.routerDelegate.currentConfiguration.matches.length, 1);
    await browser.close();
  });

  testWidgets('plugin close preserves a page opened above the browser', (
    tester,
  ) async {
    await mount(tester);
    final browser = PluginBrowserSessions(pluginId: 'fixture');
    final id = await browser.handle('browser.open', [
      {'url': 'https://example.test'},
    ]);
    await tester.pumpAndSettle();
    unawaited(router!.push<void>('/other'));
    await tester.pumpAndSettle();
    final closing = browser.handle('browser.close', [id]);
    await tester.pumpAndSettle();
    await closing;
    expect(find.text('Other page'), findsOneWidget);
    expect(platform.controllers.single.closes, 1);
    router!.pop();
    await tester.pumpAndSettle();
    expect(find.byType(WebViewWidget), findsNothing);
    expect(router!.routerDelegate.currentConfiguration.matches.length, 1);
    await browser.close();
  });

  testWidgets('immediate stop before the route builds releases it', (
    tester,
  ) async {
    await mount(tester);
    final browser = PluginBrowserSessions(pluginId: 'fixture');
    await browser.handle('browser.open', [
      {'url': 'https://example.test'},
    ]);
    final closing = browser.close();
    await tester.pumpAndSettle();
    await closing;
    expect(platform.controllers.single.closes, 1);
    expect(find.byType(WebViewWidget), findsNothing);
    expect(router!.routerDelegate.currentConfiguration.matches.length, 1);
  });

  testWidgets('stopping and a concurrent browser close release every session', (
    tester,
  ) async {
    await mount(tester);
    final browser = PluginBrowserSessions(pluginId: 'fixture');
    final first = await browser.handle('browser.open', [
      'https://example.test',
    ]);
    await tester.pumpAndSettle();
    await browser.handle('browser.open', ['https://example.test/second']);
    await tester.pumpAndSettle();
    final closing = browser.handle('browser.close', [first]);
    final stopping = browser.close();
    await tester.pumpAndSettle();
    await Future.wait([closing, stopping]);
    expect(platform.controllers.map((controller) => controller.closes), [1, 1]);
    expect(find.byType(WebViewWidget), findsNothing);
    expect(router!.routerDelegate.currentConfiguration.matches.length, 1);
  });

  testWidgets(
    'navigation, scripts, cookies and later interception keep working',
    (tester) async {
      await mount(tester);
      final browser = PluginBrowserSessions(
        pluginId: 'fixture',
        router: router,
      );
      final id = await browser.handle('browser.open', [
        {
          'url': 'https://example.test',
          'title': 'Plugin login',
          'width': 240,
          'height': 160,
          'user-agent': 'Test browser',
          'intercept-prefixes': ['plugin-auth://complete'],
          'close-on-intercept': true,
        },
      ]);
      await tester.pumpAndSettle();
      final controller = platform.controllers.single;
      expect(controller.agent, 'Test browser');
      expect(controller.params.customSchemes, ['plugin-auth']);
      expect(find.text('Plugin login'), findsOneWidget);
      expect(tester.getSize(find.byType(WebViewWidget)).width, 800);
      await browser.handle('browser.navigate', [
        id,
        'https://example.test/next',
      ]);
      expect(
        await browser.handle('browser.current-url', [id]),
        'https://example.test/next',
      );
      expect(await browser.handle('browser.eval', [id, '1 + 1']), '2');
      expect(
        await browser.handle('browser.get-cookies', [
          id,
          'https://example.test',
        ]),
        [
          {
            'name': 'session',
            'value': 'test',
            'domain': 'example.test',
            'path': '/',
          },
        ],
      );
      expect(
        await controller.navigation!.request!(
          const NavigationRequest(
            url: 'plugin-auth://complete?code=123',
            isMainFrame: true,
          ),
        ),
        NavigationDecision.prevent,
      );
      await tester.pumpAndSettle();
      expect(
        await browser.handle('browser.wait-for-intercept', [id]),
        'plugin-auth://complete?code=123',
      );
      expect(controller.closes, 1);
      await browser.close();
    },
  );

  testWidgets(
    'a detached plugin window owns its browser and management routes',
    (tester) async {
      const channel = MethodChannel('window_manager');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (_) async => null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      final host = _WindowHost();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [applicationHostProvider.overrideWithValue(host)],
          child: const PluginWindowApp(pluginId: 'fixture'),
        ),
      );
      await tester.pumpAndSettle();
      final browser = PluginBrowserSessions(pluginId: 'fixture');
      final id = await browser.handle('browser.open', [
        {'url': 'https://example.test'},
      ]);
      await tester.pumpAndSettle();
      expect(find.byType(WebViewWidget), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(platform.controllers.single.closes, 1);
      final context = rootNavigatorKey.currentContext!;
      final l10n = AppLocalizations.of(context)!;
      await tester.tap(find.byTooltip(l10n.pluginDetails));
      await tester.pumpAndSettle();
      expect(find.byType(PluginManagementPage), findsOneWidget);
      expect(
        host.commands.where(
          (command) =>
              command.method == 'plugin.view.visibility' &&
              command.params['visible'] == false,
        ),
        isEmpty,
      );
      await browser.handle('browser.close', [id]);
      await browser.close();
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );
}

class _WindowHost implements OronBoxCommandBus {
  final commands = <OronBoxCommand>[];
  @override
  Stream<CommandEvent> get events => const Stream.empty();

  @override
  Future<void> close() async {}

  @override
  Future<CommandResult> execute(OronBoxCommand command) async {
    commands.add(command);
    return CommandResult.success(switch (command.method) {
      'plugin.get' => {
        'id': 'fixture',
        'name': 'Fixture',
        'enabled': true,
        'running': true,
        'permissions': <Object?>[],
      },
      'plugin.view.attach' => {'type': 'TEXT', 'content': 'Ready'},
      _ => null,
    });
  }
}
