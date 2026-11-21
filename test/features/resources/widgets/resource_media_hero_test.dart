import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:oronbox/src/app/theme/app_theme.dart';
import 'package:oronbox/src/app/widgets/network_img_layer.dart';
import 'package:oronbox/src/features/resources/widgets/resource_media_hero.dart';

const _detailImage = ValueKey('detail-image');
const _detailPage = ValueKey('detail-page');

Future<void> _backEvent(
  WidgetTester tester,
  String name, [
  double? progress,
]) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/backgesture',
    const StandardMethodCodec().encodeMethodCall(
      MethodCall(
        name,
        progress == null
            ? null
            : {
                'touchOffset': [100.0, 200.0],
                'progress': progress,
                'swipeEdge': 0,
              },
      ),
    ),
    (_) {},
  );
  await tester.pump();
}

Future<GoRouter> _pump(WidgetTester tester, {bool icon = false}) async {
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: Padding(
              padding: const EdgeInsets.only(left: 24, top: 80),
              child: ResourceMediaHero(
                tag: 'cover',
                url: '',
                width: icon ? 56 : 120,
                height: icon ? 56 : 80,
                style: const ResourceMediaHeroStyle(),
              ),
            ),
          ),
        ),
        routes: [
          GoRoute(
            path: 'detail',
            pageBuilder: (_, state) => CustomTransitionPage<void>(
              key: state.pageKey,
              transitionsBuilder: AppTheme.buildPlatformPageTransition,
              child: Scaffold(
                key: _detailPage,
                body: Align(
                  alignment: Alignment.topLeft,
                  child: ResourceMediaHero(
                    key: _detailImage,
                    tag: 'cover',
                    url: '',
                    width: icon ? 76 : 300,
                    height: icon ? 76 : 200,
                    style: ResourceMediaHeroStyle(opacity: icon ? 1 : .16),
                  ),
                ),
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
  return router;
}

void main() {
  testWidgets('square icon keeps its aspect ratio throughout both flights', (
    tester,
  ) async {
    final router = await _pump(tester, icon: true);
    for (final returning in [true, false]) {
      if (returning) {
        router.pop();
      } else {
        router.push('/detail');
      }
      await tester.pump();
      for (var frame = 0; frame < 6; frame++) {
        await tester.pump(const Duration(milliseconds: 40));
        final size = tester.getSize(find.byType(NetworkImgLayer));
        expect(size.width, closeTo(size.height, .00001));
      }
      await tester.pumpAndSettle();
    }
  });
  testWidgets('predictive return keeps the page opaque behind its Hero', (
    tester,
  ) async {
    await _pump(tester);
    await _backEvent(tester, 'startBackGesture', 0);
    await _backEvent(tester, 'updateBackGestureProgress', .45);
    await _backEvent(tester, 'commitBackGesture');
    await tester.pump(const Duration(milliseconds: 80));
    var opacity = 1.0;
    tester.element(find.byKey(_detailPage)).visitAncestorElements((element) {
      final widget = element.widget;
      if (widget is Opacity) opacity *= widget.opacity;
      if (widget is FadeTransition) opacity *= widget.opacity.value;
      return true;
    });
    expect(opacity, 1);
    await tester.pumpAndSettle();
  });
  for (final dragProgress in [.1, .45, .9]) {
    testWidgets('predictive Hero continues at $dragProgress release progress', (
      tester,
    ) async {
      final router = await _pump(tester);
      await _backEvent(tester, 'startBackGesture', 0);
      await _backEvent(tester, 'updateBackGestureProgress', dragProgress);
      final image = find.byType(NetworkImgLayer);
      final draggedRect = tester.getRect(image);
      final draggedPagePosition = tester.getTopLeft(find.byKey(_detailPage));
      final draggedOpacity = tester
          .element(image)
          .findAncestorWidgetOfExactType<Opacity>()!
          .opacity;
      expect(draggedRect.width, allOf(greaterThan(120), lessThan(300)));
      expect(draggedOpacity, allOf(greaterThan(.16), lessThan(1)));
      await _backEvent(tester, 'commitBackGesture');
      expect(tester.getRect(image), draggedRect);
      expect(tester.getTopLeft(find.byKey(_detailPage)), draggedPagePosition);
      expect(
        tester.element(image).findAncestorWidgetOfExactType<Opacity>()!.opacity,
        closeTo(draggedOpacity, .00001),
      );
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.getSize(image).width, lessThan(draggedRect.width));
      expect(
        tester.getTopLeft(find.byKey(_detailPage)).dx,
        greaterThan(draggedPagePosition.dx),
      );
      await tester.pumpAndSettle();
      expect(router.canPop(), isFalse);
      expect(find.byKey(_detailImage), findsNothing);
    });
  }
  testWidgets(
    'cancelled predictive back keeps detail mounted and allows another return',
    (tester) async {
      final router = await _pump(tester);
      final detailElement = tester.element(find.byKey(_detailImage));
      await _backEvent(tester, 'startBackGesture', 0);
      await _backEvent(tester, 'updateBackGestureProgress', .4);
      await _backEvent(tester, 'cancelBackGesture');
      await tester.pumpAndSettle();
      expect(tester.element(find.byKey(_detailImage)), same(detailElement));
      expect(tester.getTopLeft(find.byKey(_detailPage)), Offset.zero);
      expect(router.canPop(), isTrue);
      await _backEvent(tester, 'startBackGesture', 0);
      await _backEvent(tester, 'updateBackGestureProgress', .7);
      await _backEvent(tester, 'updateBackGestureProgress', .2);
      final draggedRect = tester.getRect(find.byType(NetworkImgLayer));
      await _backEvent(tester, 'commitBackGesture');
      expect(tester.getRect(find.byType(NetworkImgLayer)), draggedRect);
      await tester.pumpAndSettle();
      expect(router.canPop(), isFalse);
    },
  );
  testWidgets('normal cover flights interpolate opacity in both directions', (
    tester,
  ) async {
    final router = await _pump(tester);
    router.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final returningOpacity = tester
        .element(find.byType(NetworkImgLayer))
        .findAncestorWidgetOfExactType<Opacity>()!
        .opacity;
    expect(returningOpacity, allOf(greaterThan(.16), lessThan(1)));
    await tester.pumpAndSettle();
    router.push('/detail');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final openingOpacity = tester
        .element(find.byType(NetworkImgLayer))
        .findAncestorWidgetOfExactType<Opacity>()!
        .opacity;
    expect(openingOpacity, allOf(greaterThan(.16), lessThan(1)));
    await tester.pumpAndSettle();
  });
}
