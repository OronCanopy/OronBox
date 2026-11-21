import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:oronbox/src/app/app_localizations_delegates.dart';
import 'package:oronbox/src/app/generated/app_localizations.dart';
import 'package:oronbox/src/commands/command_protocol.dart';
import 'package:oronbox/src/core/services/shared_prefs_service.dart';
import 'package:oronbox/src/features/devices/controllers/device_manager.dart';
import 'package:oronbox/src/features/settings/pages/labs/miwear_engineering_page.dart';
import 'package:oronbox/src/host/application_host_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Devices extends LocalDeviceManager {
  @override
  DeviceManagerState build() => const DeviceManagerState();
}

class _Host implements OronBoxCommandBus {
  final eventsController = StreamController<CommandEvent>.broadcast();
  final commands = <String>[];
  @override
  Stream<CommandEvent> get events => eventsController.stream;
  @override
  Future<CommandResult> execute(OronBoxCommand command) async {
    commands.add(command.method);
    return const CommandResult.success({
      'phase': 'waiting',
      'connected': false,
      'logs': <String>[],
    });
  }

  @override
  Future<void> close() => eventsController.close();
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SharedPrefsService.instance.init();
  });
  for (final width in [390.0, 1100.0]) {
    testWidgets(
      'engineering page fits width $width and preserves waiting state',
      (tester) async {
        tester.view.physicalSize = Size(width, 1500);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final host = _Host();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              applicationHostProvider.overrideWithValue(host),
              deviceManagerProvider.overrideWith(_Devices.new),
            ],
            child: MaterialApp(
              locale: const Locale('zh'),
              localizationsDelegates: appLocalizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: const MiWearEngineeringPage(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final l10n = AppLocalizations.of(
          tester.element(find.byType(MiWearEngineeringPage)),
        )!;
        expect(find.text(l10n.engineeringWaiting), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        expect(host.commands.last, 'miwear.engineering.cancel');
        await host.close();
      },
    );
  }
}
