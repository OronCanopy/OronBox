import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oronbox/src/app/widgets/app_scaffold_messenger.dart';
import 'package:oronbox/src/app/widgets/dialog_helper.dart';

void main() {
  testWidgets('toasts from a covered page follow navigation and dismiss', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    late BuildContext sourceContext;
    var actionCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: OronBoxScaffoldMessenger(
          child: Scaffold(
            body: Builder(
              builder: (context) {
                sourceContext = context;
                return const Text('Source');
              },
            ),
          ),
        ),
      ),
    );
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const OronBoxScaffoldMessenger(
          child: Scaffold(body: Text('Detail')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    OronBoxDialog.showToast(
      context: sourceContext,
      message: 'Detail notice',
      showActionButton: true,
      actionLabel: 'Done',
      onActionPressed: () => actionCount++,
    );
    await tester.pumpAndSettle();
    expect(find.text('Detail notice'), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(actionCount, 1);
    expect(find.byType(SnackBar), findsNothing);

    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    OronBoxDialog.showToast(context: sourceContext, message: 'Source notice');
    await tester.pumpAndSettle();
    expect(find.text('Source notice'), findsOneWidget);
    appScaffoldMessengerOf(sourceContext).removeCurrentSnackBar();
    await tester.pumpAndSettle();
  });

  testWidgets(
    'OronBoxScaffoldMessenger deduplicates rapid identical snackbars',
    (tester) async {
      BuildContext? innerContext;

      await tester.pumpWidget(
        MaterialApp(
          home: OronBoxScaffoldMessenger(
            child: Scaffold(
              body: Builder(
                builder: (context) {
                  innerContext = context;
                  return const Center(child: Text('Body'));
                },
              ),
            ),
          ),
        ),
      );

      expect(innerContext, isNotNull);
      final messenger = ScaffoldMessenger.of(innerContext!);

      // Rapidly trigger 3 identical snackbars
      messenger.showSnackBar(const SnackBar(content: Text('Duplicate Error')));
      messenger.showSnackBar(const SnackBar(content: Text('Duplicate Error')));
      messenger.showSnackBar(const SnackBar(content: Text('Duplicate Error')));

      await tester.pump();

      // Verify only 1 SnackBar widget is in the tree
      expect(find.text('Duplicate Error'), findsOneWidget);
    },
  );
  testWidgets('removed identical notices can be shown immediately', (
    tester,
  ) async {
    final key = GlobalKey<ScaffoldMessengerState>();
    await tester.pumpWidget(
      MaterialApp(
        home: OronBoxScaffoldMessenger(key: key, child: const Scaffold()),
      ),
    );
    final messenger = key.currentState!;
    final first = messenger.showSnackBar(
      const SnackBar(content: Text('Failure')),
    );
    await tester.pumpAndSettle();
    messenger.removeCurrentSnackBar();
    final retry = messenger.showSnackBar(
      const SnackBar(content: Text('Failure')),
    );
    expect(retry, isNot(same(first)));
    await tester.pumpAndSettle();
    expect(find.text('Failure'), findsOneWidget);
    messenger.hideCurrentSnackBar();
    final again = messenger.showSnackBar(
      const SnackBar(content: Text('Failure')),
    );
    expect(again, isNot(same(retry)));
    await tester.pumpAndSettle();
    expect(find.text('Failure'), findsOneWidget);
  });
  testWidgets(
    'global callbacks use the page messenger and custom root fallback',
    (tester) async {
      late BuildContext callbackContext;
      late BuildContext pageContext;
      var hasShell = true;
      Widget app() => MaterialApp(
        builder: (context, child) => OronBoxScaffoldMessenger(
          child: Builder(
            builder: (context) {
              callbackContext = context;
              return child!;
            },
          ),
        ),
        home: hasShell
            ? Scaffold(
                body: OronBoxScaffoldMessenger(
                  key: appScaffoldMessengerKey,
                  child: Scaffold(
                    body: Builder(
                      builder: (context) {
                        pageContext = context;
                        return const SizedBox.shrink();
                      },
                    ),
                  ),
                ),
              )
            : const Scaffold(body: SizedBox.shrink()),
      );
      await tester.pumpWidget(app());
      expect(
        appScaffoldMessengerOf(callbackContext),
        same(ScaffoldMessenger.of(pageContext)),
      );
      final messenger = appScaffoldMessengerOf(callbackContext);
      final first = messenger.showSnackBar(
        const SnackBar(content: Text('Signed in')),
      );
      final duplicate = messenger.showSnackBar(
        const SnackBar(content: Text('Signed in')),
      );
      expect(duplicate, same(first));
      await tester.pumpAndSettle();
      expect(
        tester.widget<SnackBar>(find.byType(SnackBar)).duration,
        appSnackBarDuration,
      );
      messenger.removeCurrentSnackBar();
      await tester.pumpAndSettle();
      hasShell = false;
      await tester.pumpWidget(app());
      final fallback = appScaffoldMessengerOf(callbackContext);
      expect(fallback.widget, isA<OronBoxScaffoldMessenger>());
      fallback.showSnackBar(const SnackBar(content: Text('First run')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<SnackBar>(find.byType(SnackBar)).duration,
        appSnackBarDuration,
      );
      fallback.removeCurrentSnackBar();
      await tester.pumpAndSettle();
    },
  );
}
