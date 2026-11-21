import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:oronbox/src/app/app_localizations_delegates.dart';
import 'package:oronbox/src/app/generated/app_localizations.dart';
import 'package:oronbox/src/commands/command_protocol.dart';
import 'package:oronbox/src/core/services/shared_prefs_service.dart';
import 'package:oronbox/src/features/accounts/widgets/mi_account_login_dialog.dart';
import 'package:oronbox/src/features/accounts/pages/mi_account_two_factor_page.dart';
import 'package:oronbox/src/features/accounts/services/mi_account_two_factor_resolver.dart';
import 'package:oronbox/src/host/application_host_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_all/webview_all.dart';

import '../../../support/test_webview_platform.dart';

void main() {
  late TestWebViewPlatform platform;
  late _AccountHost host;
  GoRouter? router;
  late BuildContext homeContext;
  final initialUrl = Uri.parse('https://account.xiaomi.com/verify');

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SharedPrefsService.instance.init();
    platform = TestWebViewPlatform();
    WebViewPlatform.instance = platform;
    host = _AccountHost();
  });
  tearDown(() => router?.dispose());

  Future<void> mount(WidgetTester tester) async {
    router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) {
            homeContext = context;
            return const Scaffold(body: Text('Home'));
          },
        ),
        GoRoute(
          path: '/other',
          builder: (_, _) => const Scaffold(body: Text('Other page')),
        ),
        GoRoute(
          path: '/accounts/xiaomi/verify',
          builder: (_, state) =>
              MiAccountTwoFactorPage(initialUrl: state.extra as Uri),
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [applicationHostProvider.overrideWithValue(host)],
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<String> verify() => resolveMiAccountTwoFactor(homeContext, initialUrl);

  testWidgets('credentials open in a dialog without changing the page', (
    tester,
  ) async {
    await mount(tester);
    unawaited(showMiAccountLoginDialog(homeContext));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(router!.routeInformationProvider.value.uri.path, '/');
    expect(find.byType(TextField), findsNWidgets(2));
    final context = tester.element(find.byType(MiAccountLoginDialog));
    final l10n = AppLocalizations.of(context)!;
    final label = tester.element(
      find.text(l10n.settingsMiAccountRememberCredentials),
    );
    final titleStyle =
        Theme.of(context).listTileTheme.titleTextStyle ??
        Theme.of(context).textTheme.bodyLarge!;
    expect(DefaultTextStyle.of(label).style.fontSize, titleStyle.fontSize);
    expect(platform.controllers, isEmpty);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Home'), findsOneWidget);
  });

  testWidgets('login dialog fits a narrow screen with the keyboard open', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    await mount(tester);
    unawaited(showMiAccountLoginDialog(homeContext));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(TextField).last);
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('successful password login closes the dialog and reports sync', (
    tester,
  ) async {
    await mount(tester);
    host.requiresVerification = false;
    final completed = showMiAccountLoginDialog(homeContext);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'user');
    await tester.enterText(find.byType(TextField).last, 'password');
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    await completed;
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(SnackBar), findsOneWidget);
    expect(router!.routeInformationProvider.value.uri.path, '/');
    expect(platform.controllers, isEmpty);
    expect(
      host.commands.where(
        (command) => command.method == 'account.credentials.set',
      ),
      hasLength(1),
    );
  });

  testWidgets(
    'verification is a full page and back cancels its owned session',
    (tester) async {
      await mount(tester);
      final cancelled = expectLater(verify(), throwsStateError);
      await tester.pumpAndSettle();
      expect(find.byType(WebViewWidget), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
      final controller = platform.controllers.single;
      expect(controller.params.sessionMode, WebViewSessionMode.incognito);
      var removedBeforeClose = false;
      controller.onClose = () {
        removedBeforeClose = find.byType(WebViewWidget).evaluate().isEmpty;
      };
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await cancelled;
      expect(controller.closes, 1);
      expect(removedBeforeClose, isTrue);
      final reads = platform.cookies.reads;
      await tester.pump(const Duration(seconds: 3));
      expect(platform.cookies.reads, reads);
    },
  );

  testWidgets(
    'completion reads the session cookie store and returns its header',
    (tester) async {
      await mount(tester);
      final result = verify();
      await tester.pumpAndSettle();
      platform.cookies.values = const [
        WebViewCookie(
          name: 'passToken',
          value: 'test-token',
          domain: 'xiaomi.com',
        ),
        WebViewCookie(name: 'userId', value: '123', domain: 'xiaomi.com'),
      ];
      platform.controllers.single.navigation!.finished!(initialUrl.toString());
      await tester.pumpAndSettle();
      expect(await result, 'passToken=test-token; userId=123');
      expect(platform.controllers.single.closes, 1);
      expect(find.text('Home'), findsOneWidget);
    },
  );

  testWidgets(
    'cookie polling never overlaps and close waits for an active read',
    (tester) async {
      await mount(tester);
      final cancelled = expectLater(verify(), throwsStateError);
      await tester.pumpAndSettle();
      platform.cookies.pending = Completer<List<WebViewCookie>>();
      final navigation = platform.controllers.single.navigation!;
      navigation.finished!(initialUrl.toString());
      navigation.finished!(initialUrl.toString());
      await tester.pump(const Duration(seconds: 3));
      expect(platform.cookies.reads, 1);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await cancelled;
      expect(platform.controllers.single.closes, 0);
      platform.cookies.pending!.complete([]);
      await tester.pump();
      expect(platform.cookies.reads, 1);
      expect(platform.controllers.single.closes, 1);
    },
  );

  testWidgets('returning during initialization releases the late session', (
    tester,
  ) async {
    await mount(tester);
    platform.preparation = Completer<void>();
    final cancelled = expectLater(verify(), throwsStateError);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    router!.pop();
    await tester.pumpAndSettle();
    await cancelled;
    expect(platform.controllers.single.closes, 0);
    platform.preparation!.complete();
    await tester.pump();
    expect(platform.controllers.single.closes, 1);
    expect(platform.controllers.single.loads, isEmpty);
  });

  testWidgets('verification completion preserves a newer page above it', (
    tester,
  ) async {
    await mount(tester);
    final result = verify();
    await tester.pumpAndSettle();
    unawaited(router!.push<void>('/other'));
    await tester.pumpAndSettle();
    platform.cookies.values = const [
      WebViewCookie(name: 'passToken', value: 'token', domain: 'xiaomi.com'),
    ];
    platform.controllers.single.navigation!.finished!(initialUrl.toString());
    await tester.pumpAndSettle();
    expect(await result, 'passToken=token');
    expect(find.text('Other page'), findsOneWidget);
    expect(platform.controllers.single.closes, 1);
    router!.pop();
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
  });

  testWidgets('failed initialization releases the session and can be retried', (
    tester,
  ) async {
    await mount(tester);
    platform.failPreparation = true;
    final cancelled = expectLater(verify(), throwsStateError);
    await tester.pumpAndSettle();
    expect(platform.controllers.single.closes, 1);
    expect(find.byType(WebViewWidget), findsNothing);
    platform.failPreparation = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(platform.controllers, hasLength(2));
    expect(find.byType(WebViewWidget), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await cancelled;
    expect(platform.controllers.last.closes, 1);
  });

  testWidgets(
    'login dialog opens a verification page and closes on completion',
    (tester) async {
      await mount(tester);
      unawaited(showMiAccountLoginDialog(homeContext));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(router!.routeInformationProvider.value.uri.path, '/');
      await tester.enterText(find.byType(TextField).first, 'user');
      await tester.enterText(find.byType(TextField).last, 'password');
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();
      expect(find.byType(MiAccountTwoFactorPage), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      platform.cookies.values = const [
        WebViewCookie(name: 'passToken', value: 'token', domain: 'xiaomi.com'),
      ];
      platform.controllers.single.navigation!.finished!(initialUrl.toString());
      await tester.pumpAndSettle();
      expect(find.byType(MiAccountLoginDialog), findsNothing);
      expect(
        host.commands
            .where((command) => command.method == 'account.xiaomi.complete')
            .single
            .params['cookieHeader'],
        'passToken=token',
      );
      expect(
        host.commands.where(
          (command) => command.method == 'account.credentials.set',
        ),
        hasLength(1),
      );
      expect(platform.controllers.single.closes, 1);
      expect(find.text('Home'), findsOneWidget);
    },
  );

  testWidgets('cancelled verification returns to the editable login dialog', (
    tester,
  ) async {
    await mount(tester);
    unawaited(showMiAccountLoginDialog(homeContext));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'user');
    await tester.enterText(find.byType(TextField).last, 'password');
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(MiAccountLoginDialog), findsOneWidget);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(router!.routeInformationProvider.value.uri.path, '/');
    expect(find.byType(TextField).first, findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller!.text,
      'user',
    );
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNotNull,
    );
    expect(
      host.commands.any(
        (command) => command.method == 'account.xiaomi.complete',
      ),
      isFalse,
    );
    expect(platform.controllers.single.closes, 1);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });
}

class _AccountHost implements OronBoxCommandBus {
  final commands = <OronBoxCommand>[];
  bool requiresVerification = true;

  @override
  Stream<CommandEvent> get events => const Stream.empty();

  @override
  Future<void> close() async {}

  @override
  Future<CommandResult> execute(OronBoxCommand command) async {
    commands.add(command);
    return switch (command.method) {
      'account.list' => const CommandResult.success([]),
      'account.credentials.get' => const CommandResult.success({}),
      'account.login' when !requiresVerification => const CommandResult.success(
        {
          'provider': 'xiaomi',
          'signedIn': true,
          'userId': '123',
          'syncedDevices': 2,
        },
      ),
      'account.login' => const CommandResult.failure(
        CommandError(
          'two_factor_required',
          'Verification required',
          details: {
            'url': 'https://account.xiaomi.com/verify',
            'deviceId': 'test-device',
          },
        ),
      ),
      'account.xiaomi.complete' => const CommandResult.success({
        'provider': 'xiaomi',
        'signedIn': true,
        'userId': '123',
        'syncedDevices': 2,
      }),
      'account.credentials.set' => const CommandResult.success(),
      _ => CommandResult.failure(CommandError('unknown', command.method)),
    };
  }
}
