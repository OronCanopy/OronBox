import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:oronbox/src/app/theme/app_theme.dart';

Future<void> _gesture(WidgetTester tester, {bool cancel = false}) async {
  Future<void> send(MethodCall call) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'flutter/backgesture',
      const StandardMethodCodec().encodeMethodCall(call),
      (_) {},
    );
  }

  await send(
    const MethodCall('startBackGesture', {
      'touchOffset': <double>[0.0, 250.0],
      'progress': 0.0,
      'swipeEdge': 0,
    }),
  );
  await tester.pump();
  await send(MethodCall(cancel ? 'cancelBackGesture' : 'commitBackGesture'));
  await tester.pumpAndSettle();
}

void main() {
  for (final custom in [false, true]) {
    testWidgets(
      'Android page return continues the slide after release (custom $custom)',
      (tester) async {
        const pageKey = ValueKey('returning-page');
        final router = GoRouter(
          routes: [
            GoRoute(
              path: '/',
              builder: (_, _) => const Scaffold(
                key: ValueKey('home-page'),
                body: Text('home'),
              ),
              routes: [
                GoRoute(
                  path: 'detail',
                  builder: custom
                      ? null
                      : (_, _) =>
                            const Scaffold(key: pageKey, body: Text('detail')),
                  pageBuilder: !custom
                      ? null
                      : (_, state) => CustomTransitionPage<void>(
                          key: state.pageKey,
                          transitionsBuilder:
                              AppTheme.buildPlatformPageTransition,
                          child: const Scaffold(
                            key: pageKey,
                            body: Text('detail'),
                          ),
                        ),
                ),
              ],
            ),
          ],
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(
          MaterialApp.router(
            theme: AppTheme.light.copyWith(platform: TargetPlatform.android),
            routerConfig: router,
          ),
        );
        await tester.pumpAndSettle();
        router.push('/detail');
        await tester.pumpAndSettle();
        Future<void> event(String method, [double? progress]) async {
          await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
            'flutter/backgesture',
            const StandardMethodCodec().encodeMethodCall(
              MethodCall(
                method,
                progress == null
                    ? null
                    : {
                        'touchOffset': <double>[0, 250],
                        'progress': progress,
                        'swipeEdge': 0,
                      },
              ),
            ),
            (_) {},
          );
          await tester.pump();
        }

        await event('startBackGesture', 0);
        await event('updateBackGestureProgress', .45);
        expect(
          tester.getTopLeft(find.byKey(pageKey)).dx,
          greaterThan(
            tester.view.physicalSize.width / tester.view.devicePixelRatio * .25,
          ),
        );
        await event('cancelBackGesture');
        await tester.pumpAndSettle();
        expect(tester.getTopLeft(find.byKey(pageKey)).dx, closeTo(0, .001));
        await event('startBackGesture', 0);
        await event('updateBackGestureProgress', .45);
        final beforeRelease = tester.getTopLeft(find.byKey(pageKey));
        final homeFinder = find.byKey(
          const ValueKey('home-page'),
          skipOffstage: false,
        );
        final homeBeforeRelease = tester.getTopLeft(homeFinder);
        await event('commitBackGesture');
        expect(tester.getTopLeft(find.byKey(pageKey)), beforeRelease);
        expect(tester.getTopLeft(homeFinder), homeBeforeRelease);
        var previousPageX = beforeRelease.dx;
        var previousHomeX = homeBeforeRelease.dx;
        for (var frame = 0; frame < 8; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          final pageX = tester.getTopLeft(find.byKey(pageKey)).dx;
          final homeX = tester.getTopLeft(homeFinder).dx;
          expect(pageX, greaterThanOrEqualTo(previousPageX));
          expect(homeX, greaterThanOrEqualTo(previousHomeX));
          previousPageX = pageX;
          previousHomeX = homeX;
        }
        await tester.pumpAndSettle();
        expect(find.byKey(pageKey), findsNothing);
        expect(router.routeInformationProvider.value.uri.path, '/');
      },
    );
  }
  for (final mode in [
    'gesture',
    'cancel then gesture',
    'arrow',
    'system back',
  ]) {
    testWidgets(
      'root DevTools returns once and preserves secondary route: $mode',
      (tester) async {
        final router = GoRouter(
          initialLocation: '/settings/voice',
          routes: [
            GoRoute(
              path: '/debug',
              builder: (_, _) =>
                  Scaffold(appBar: AppBar(), body: const Text('DevTools')),
            ),
            StatefulShellRoute.indexedStack(
              builder: (_, _, shell) => shell,
              branches: [
                StatefulShellBranch(
                  routes: [
                    GoRoute(
                      path: '/settings',
                      builder: (_, _) => const Scaffold(body: Text('settings')),
                      routes: [
                        GoRoute(
                          path: 'voice',
                          builder: (context, _) => Scaffold(
                            body: TextButton(
                              onPressed: () => context.push('/debug'),
                              child: const Text('voice'),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ],
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(
          MaterialApp.router(
            theme: AppTheme.buildLightTheme(),
            routerConfig: router,
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('voice'));
        await tester.pumpAndSettle();
        if (mode == 'cancel then gesture') {
          await _gesture(tester, cancel: true);
          expect(find.text('DevTools'), findsOneWidget);
          expect(find.text('voice'), findsNothing);
        }
        if (mode == 'system back') {
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
        } else if (mode == 'arrow') {
          await tester.tap(find.byType(BackButton));
          await tester.pumpAndSettle();
        } else {
          await _gesture(tester);
        }
        expect(find.text('voice'), findsOneWidget);
        expect(find.text('settings'), findsNothing);
        expect(
          router.routeInformationProvider.value.uri.path,
          '/settings/voice',
        );
        await _gesture(tester);
        expect(find.text('settings'), findsOneWidget);
        expect(router.routeInformationProvider.value.uri.path, '/settings');
      },
    );
  }
}
