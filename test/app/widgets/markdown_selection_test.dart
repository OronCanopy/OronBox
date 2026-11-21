import 'package:flutter/foundation.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:oronbox/src/app/app_localizations_delegates.dart';
import 'package:oronbox/src/app/generated/app_localizations.dart';
import 'package:oronbox/src/app/theme/app_theme.dart';
import 'package:oronbox/src/app/widgets/markdown_style_sheet.dart';

void main() {
  testWidgets(
    'selectable MarkdownBody long-press selection works across platforms without crash',
    (tester) async {
      for (final platform in [
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.macOS,
        TargetPlatform.windows,
      ]) {
        debugDefaultTargetPlatformOverride = platform;
        final theme = AppTheme.buildLightTheme();

        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: MarkdownBody(
                data: '''
# Header
Selectable Markdown text that previously crashed on long press selection.
''',
                selectable: true,
                styleSheet: markdownStyleSheetFromTheme(theme),
              ),
            ),
          ),
        );

        expect(find.byType(MarkdownBody), findsOneWidget);

        await tester.longPress(find.textContaining('Selectable Markdown text'));
        await tester.pumpAndSettle();

        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
}
