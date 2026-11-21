import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:oronbox/src/app/app_localizations_delegates.dart';
import 'package:oronbox/src/app/generated/app_localizations.dart';
import 'package:oronbox/src/data/community/community_source.dart';
import 'package:oronbox/src/features/resources/domain/community_resource.dart';
import 'package:oronbox/src/features/resources/widgets/resource_external_link.dart';

void main() {
  testWidgets(
    'paid file notice preserves dismissal and external browser actions',
    (tester) async {
      final launches = <Map<Object?, Object?>>[];
      var browserAvailable = true;
      const channel = MethodChannel('plugins.flutter.io/url_launcher');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'launch') {
          launches.add(Map<Object?, Object?>.from(call.arguments as Map));
          return browserAvailable;
        }
        return true;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showAstroBoxResourcePurchaseDialog(
                  context,
                  const ResourceRef(
                    source: CommunitySourceId.astroboxRepo,
                    id: 'sample',
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text('此文件需要购买或授权'), findsOneWidget);
      expect(
        find.text(
          '此资源通过 AstroBox Creator Console 加密上传\n需购买或获得授权后才能解密\n请改用 AstroBox 打开',
        ),
        findsOneWidget,
      );
      expect(find.text('知道了'), findsOneWidget);
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();
      expect(find.text('此文件需要购买或授权'), findsNothing);
      expect(launches, isEmpty);
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('外部打开'));
      await tester.pumpAndSettle();
      expect(
        launches.single['url'],
        'https://astrobox.online/open?source=resv2&id=sample&provider=OfficialV2',
      );
      expect(launches.single['useWebView'], isFalse);
      expect(launches.single['useSafariVC'], isFalse);
      browserAvailable = false;
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('外部打开'));
      await tester.pumpAndSettle();
      expect(find.text('无法打开浏览器'), findsOneWidget);
    },
  );
}
