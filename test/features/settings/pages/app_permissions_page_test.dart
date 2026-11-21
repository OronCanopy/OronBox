import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:oronbox/src/app/app_localizations_delegates.dart';
import 'package:oronbox/src/app/generated/app_localizations.dart';
import 'package:oronbox/src/core/services/shared_prefs_service.dart';
import 'package:oronbox/src/features/settings/pages/app_permissions_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _notifications = MethodChannel('org.oroncanopy.oronbox/notifications');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SharedPrefsService.instance.init();
    await SharedPrefsService.instance.reload();
  });

  testWidgets(
    'Android notification permissions refresh on return from settings',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      var display = false;
      var read = false;
      final settingsOpened = <String>[];
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(_notifications, (call) async {
        switch (call.method) {
          case 'hasSendPermission':
            return display;
          case 'hasPhoneAccess':
            return read;
          case 'openSendSettings':
          case 'openPhoneAccess':
            settingsOpened.add(call.method);
            return null;
          default:
            throw MissingPluginException(call.method);
        }
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(_notifications, null);
        debugDefaultTargetPlatformOverride = null;
      });

      await _showPermissions(tester);
      expect(find.text('Notification permissions'), findsOneWidget);
      expect(find.text('Disabled'), findsNWidgets(2));
      await tester.tap(find.text('Show notifications'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Read notifications'));
      await tester.pumpAndSettle();
      expect(settingsOpened, ['openSendSettings', 'openPhoneAccess']);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      display = true;
      read = true;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('Enabled'), findsNWidgets(2));
      expect(find.text('Disabled'), findsNothing);
    },
  );

  for (final platform in [TargetPlatform.iOS, TargetPlatform.macOS]) {
    testWidgets('$platform only offers notification display permission', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = platform;
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(_notifications, (call) async {
        expect(call.method, 'hasSendPermission');
        return true;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(_notifications, null);
        debugDefaultTargetPlatformOverride = null;
      });

      await _showPermissions(tester);
      expect(find.text('Show notifications'), findsOneWidget);
      expect(find.text('Enabled'), findsOneWidget);
      expect(find.text('Read notifications'), findsNothing);
    });
  }
}

Future<void> _showPermissions(WidgetTester tester) async {
  await tester.pumpWidget(
    const ProviderScope(
      child: MaterialApp(
        locale: Locale('en'),
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: AppPermissionsPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
