import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:oronbox/src/app/app_localizations_delegates.dart';
import 'package:oronbox/src/app/generated/app_localizations.dart';
import 'package:oronbox/src/features/settings/services/update_reminder_service.dart';
import 'package:oronbox/src/features/settings/widgets/update_reminder_dialog.dart';

void main() {
  testWidgets('small update dialog scrolls and keeps item actions usable', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(340, 450));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final installed = <int>[];
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: UpdateReminderDialog(
              kind: UpdateReminderKind.resources,
              deviceName: 'Device',
              items: [
                for (var index = 0; index < 12; index++)
                  UpdateReminderItem(
                    id: '$index',
                    name: 'Resource $index',
                    version: '2.0',
                    revision: '2',
                    install: () async {
                      installed.add(index);
                      return true;
                    },
                  ),
              ],
              onDismiss: (_, _) {},
              onHandled: () {},
            ),
          ),
        ),
      ),
    );
    final row = find.widgetWithText(ListTile, 'Resource 11');
    await tester.ensureVisible(row);
    await tester.tap(
      find.descendant(of: row, matching: find.byType(TextButton)),
    );
    await tester.pumpAndSettle();
    expect(installed, [11]);
    expect(row, findsNothing);
    expect(find.byType(FilledButton).hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
