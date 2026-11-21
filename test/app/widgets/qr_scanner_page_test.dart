import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:oronbox/src/app/app_localizations_delegates.dart';
import 'package:oronbox/src/app/generated/app_localizations.dart';
import 'package:oronbox/src/app/widgets/qr_scanner_page.dart';
import 'package:oronbox/src/core/services/shared_prefs_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('desktop scanner fallback keeps image selection available', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await SharedPrefsService.instance.init();
    await tester.binding.setSurfaceSize(const Size(1024, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: QrScannerPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(
      tester.element(find.byType(QrScannerPage)),
    )!;
    expect(find.text(l10n.qrScanCameraUnavailable), findsOneWidget);
    expect(find.text(l10n.qrScanCameraUnavailableMessage), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, l10n.qrScanFromImage),
          )
          .onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
