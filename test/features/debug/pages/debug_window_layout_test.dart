import 'package:flutter_test/flutter_test.dart';
import 'package:oronbox/src/features/debug/widgets/debug_console.dart';
import 'package:oronbox/src/app/app_localizations_delegates.dart';
import 'package:oronbox/src/app/generated/app_localizations.dart';
import 'package:oronbox/src/features/debug/pages/debug_window_app.dart';
import 'package:oronbox/src/features/debug/widgets/debug_inspectors.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('NG string content can be listed and inspected', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: DebugLayoutInspector(
            nodes: debugLayoutNodes({
              'type': 'DIV',
              'id': 1,
              'children': [
                {'type': 'P', 'id': 2, 'content': 'Lyra 音乐导入'},
              ],
            }),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('P'));
    await tester.pump();
    expect(find.textContaining('Lyra 音乐导入'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('console distinguishes filtered results from an empty log', (
    tester,
  ) async {
    for (final filtered in [false, true]) {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: DebugConsole(records: const [], filtered: filtered),
          ),
        ),
      );
      final l10n = AppLocalizations.of(
        tester.element(find.byType(DebugConsole)),
      )!;
      expect(
        find.text(filtered ? l10n.debugNoMatchingLogs : l10n.debugNoLogs),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    }
  });

  test('plugin diagnostics accept the current single-root layout shape', () {
    final nodes = debugLayoutNodes({
      'type': 'Column',
      'props': <String, Object?>{},
    });

    expect(nodes, hasLength(1));
    expect(nodes.single['type'], 'Column');
  });

  test('plugin diagnostics flatten current tree children for inspection', () {
    final nodes = debugLayoutNodes({
      'type': 'Column',
      'children': [
        {
          'type': 'Text',
          'props': {'value': 'hello'},
        },
        {
          'type': 'Button',
          'props': {'text': 'run'},
        },
      ],
    });

    expect(nodes.map((node) => node['type']), ['Column', 'Text', 'Button']);
  });

  test('plugin diagnostics keep accepting the legacy layout list', () {
    final nodes = debugLayoutNodes([
      {'type': 'Text'},
      {'type': 'Button'},
    ]);

    expect(nodes.map((node) => node['type']), ['Text', 'Button']);
  });
}
