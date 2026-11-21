import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:oronbox/src/app/widgets/app_state_view.dart';
import 'package:oronbox/src/app/app_localizations_delegates.dart';
import 'package:oronbox/src/app/generated/app_localizations.dart';

void main() {
  testWidgets('empty state keeps its action reachable in a short pane', (
    tester,
  ) async {
    var activated = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                width: 240,
                height: 120,
                child: EmptyStateView(
                  icon: Icons.search_off,
                  title: 'No matching entries for this search',
                  message: 'Try a different search or add an entry',
                  action: TextButton(
                    onPressed: () => activated = true,
                    child: const Text('Add entry'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Add entry'));
    await tester.tap(find.text('Add entry'));
    expect(activated, isTrue);
  });
  testWidgets('compact error retry remains reachable with large text', (
    tester,
  ) async {
    var retried = false;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                width: 240,
                height: 100,
                child: ErrorStateView(
                  compact: true,
                  title: 'Unable to load entries',
                  message: 'Please try again',
                  onRetry: () => retried = true,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    final retry = find.byType(FilledButton);
    await tester.ensureVisible(retry);
    await tester.tap(retry);
    expect(retried, isTrue);
  });
  testWidgets('compact empty state also fits an unbounded list section', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: const [
              EmptyStateView(
                compact: true,
                title: 'Empty section',
                message: 'Add an entry',
              ),
              Text('Next section'),
            ],
          ),
        ),
      ),
    );
    expect(find.text('Next section'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
