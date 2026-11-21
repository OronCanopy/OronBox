import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:oronbox/src/app/app_localizations_delegates.dart';
import 'package:oronbox/src/app/generated/app_localizations.dart';
import 'package:oronbox/src/core/ai/ai_models.dart';
import 'package:oronbox/src/core/ai/ai_settings_store.dart';
import 'package:oronbox/src/core/services/shared_prefs_service.dart';
import 'package:oronbox/src/features/ai/widgets/model_selection_dialog.dart';
import 'package:oronbox/src/features/ai/widgets/provider_management_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SharedPrefsService.instance.init();
    AiSettingsStore.providers = [];
  });
  testWidgets(
    'model selection shows an empty state when providers have no models',
    (tester) async {
      AiSettingsStore.providers = [
        const AiProviderConfig(
          id: 'empty',
          name: 'Empty provider',
          baseUrl: 'https://example.com',
          credentialRef: '',
        ),
      ];
      await tester.binding.setSurfaceSize(const Size(320, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(1.6)),
            child: child!,
          ),
          home: const Scaffold(body: ModelSelectionDialog()),
        ),
      );
      await tester.pumpAndSettle();
      final l10n = AppLocalizations.of(
        tester.element(find.byType(ModelSelectionDialog)),
      )!;
      expect(find.text(l10n.globalAiNoModelsTitle), findsOneWidget);
      expect(find.text(l10n.globalAiNoModelsMessage), findsOneWidget);
      expect(find.text('Empty provider'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('provider settings separate the empty title and guidance', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: ProviderManagementDialog()),
      ),
    );
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(
      tester.element(find.byType(ProviderManagementDialog)),
    )!;
    expect(find.text(l10n.globalAiNoProvidersTitle), findsOneWidget);
    await tester.ensureVisible(find.text(l10n.globalAiNoProvidersMessage));
    expect(tester.takeException(), isNull);
  });
}
