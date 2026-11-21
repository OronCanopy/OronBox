import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:oronbox/src/app/app_localizations_delegates.dart';
import 'package:oronbox/src/app/generated/app_localizations.dart';
import 'package:oronbox/src/core/models/bt_models.dart';
import 'package:oronbox/src/core/services/shared_prefs_service.dart';
import 'package:oronbox/src/device/core/device_state.dart';
import 'package:oronbox/src/features/devices/controllers/device_manager.dart';
import 'package:oronbox/src/features/devices/pages/apps/device_apps_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('hidden system apps are distinguished from no installed apps', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await SharedPrefsService.instance.init();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [deviceManagerProvider.overrideWith(_Devices.new)],
        child: MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const DeviceAppsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(
      tester.element(find.byType(DeviceAppsPage)),
    )!;
    expect(find.text(l10n.appManagementNoVisibleApps), findsOneWidget);
    expect(find.text(l10n.appManagementNone), findsNothing);
    await tester.tap(
      find.widgetWithText(TextButton, l10n.appManagementShowSystemApps),
    );
    await tester.pumpAndSettle();
    expect(find.text('System fixture'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _Devices extends LocalDeviceManager {
  @override
  DeviceManagerState build() => const DeviceManagerState(
    protocolState: ProtocolState.ready,
    apps: [
      AppInfo(
        packageName: 'com.xiaomi.miwear.fixture',
        appName: 'System fixture',
      ),
    ],
  );
  @override
  Future<void> fetchApps() async {}
}
