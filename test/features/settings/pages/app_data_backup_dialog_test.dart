import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:oronbox/src/app/app_localizations_delegates.dart';
import 'package:oronbox/src/app/generated/app_localizations.dart';
import 'package:oronbox/src/app/widgets/app_checkbox_tile.dart';
import 'package:oronbox/src/features/settings/application/app_data_backup.dart';
import 'package:oronbox/src/features/settings/pages/app_data_backup_dialog.dart';

void main() {
  testWidgets(
    'device pairing is selected while account credentials stay opt-in',
    (tester) async {
      BackupSelection? selected;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  selected = await showBackupSelectionDialog(context);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final devices = find.widgetWithText(
        AppCheckboxTile,
        'Device pairing and keys',
      );
      final accounts = find.widgetWithText(
        AppCheckboxTile,
        'Xiaomi and Amazfit credentials',
      );
      expect(tester.widget<AppCheckboxTile>(devices).value, isTrue);
      expect(tester.widget<AppCheckboxTile>(accounts).value, isFalse);
      expect(
        find.textContaining('unencrypted account credentials'),
        findsNothing,
      );
      await tester.ensureVisible(accounts);
      await tester.tap(find.text('Xiaomi and Amazfit credentials'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('unencrypted account credentials'),
        findsOneWidget,
      );
      await tester.tap(find.text('Xiaomi and Amazfit credentials'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Device pairing and keys'));
      await tester.tap(find.widgetWithText(FilledButton, 'Export backup'));
      await tester.pumpAndSettle();
      expect(selected!.devices, true);
      expect(selected!.accountCredentials, isFalse);
      expect((selected as BackupExportSelection).saveToDocuments, true);
    },
  );

  testWidgets(
    'restore picker labels backups and accepts an existing or external file',
    (tester) async {
      RestoreSourceSelection? result;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await showPublicBackupPickerDialog(context, [
                    'OronBox-AutoBackup-20261103-120000.zip',
                    'OronBox-ManualBackup-20261103-130000.zip',
                    'OronBox-Backup-1700000000000.zip',
                  ]);
                },
                child: const Text('pick'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('pick'));
      await tester.pumpAndSettle();

      expect(find.text('Auto Backup'), findsOneWidget);
      expect(find.text('2026-11-03 12:00:00'), findsOneWidget);
      expect(find.text('Manual Backup'), findsNWidgets(2));
      expect(find.text('Choose another external file...'), findsOneWidget);

      await tester.tap(find.text('2026-11-03 12:00:00'));
      await tester.pumpAndSettle();
      expect(result?.fileName, 'OronBox-AutoBackup-20261103-120000.zip');
      expect(result?.pickExternal, isFalse);

      await tester.tap(find.text('pick'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose another external file...'));
      await tester.pumpAndSettle();
      expect(result, isNotNull);
      expect(result!.pickExternal, true);
      expect(result!.fileName, isNull);
    },
  );
}
