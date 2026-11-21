import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:segmented_list/segmented_list.dart';
import 'package:oronbox/src/app/app_localizations_delegates.dart';
import 'package:oronbox/src/app/generated/app_localizations.dart';
import 'package:oronbox/src/commands/command_protocol.dart';
import 'package:oronbox/src/core/services/shared_prefs_service.dart';
import 'package:oronbox/src/features/plugins/pages/plugin_management_page.dart';
import 'package:oronbox/src/host/application_host_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late _Host host;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SharedPrefsService.instance.init();
    host = _Host();
  });

  Future<void> render(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [applicationHostProvider.overrideWithValue(host)],
        child: MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const PluginManagementPage(pluginId: 'fixture'),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('header actions stay side by side and toggle plugin activation', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 740));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await render(tester);
    final l10n = AppLocalizations.of(
      tester.element(find.byType(PluginManagementPage)),
    )!;
    final disable = find.widgetWithText(FilledButton, l10n.pluginDisable);
    final uninstall = find.widgetWithText(FilledButton, l10n.uninstall);
    final disableRect = tester.getRect(disable);
    final uninstallRect = tester.getRect(uninstall);
    expect(
      disableRect.top,
      greaterThan(tester.getRect(find.text('Description')).bottom),
    );
    expect(disableRect.top, uninstallRect.top);
    expect(disableRect.right, lessThan(uninstallRect.left));
    expect(
      uninstallRect.bottom,
      lessThan(tester.getRect(find.text(l10n.pluginAutoStart)).top),
    );
    expect(find.byIcon(Icons.rocket_launch_outlined), findsOneWidget);
    await tester.tap(disable);
    await tester.pumpAndSettle();
    expect(host.settings['enabled'], false);
    await tester.tap(find.widgetWithText(FilledButton, l10n.pluginEnable));
    await tester.pumpAndSettle();
    expect(host.settings['enabled'], true);
    expect(host.settings['autoStart'], false);
    expect(host.settings['background'], 'active');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'background and automatic startup remain independent through user changes',
    (tester) async {
      await render(tester);
      final l10n = AppLocalizations.of(
        tester.element(find.byType(PluginManagementPage)),
      )!;
      expect(find.byType(SegmentedList), findsOneWidget);
      final name = tester.getRect(find.text('Fixture'));
      final description = tester.getRect(find.text('Description'));
      expect(description.top, greaterThan(name.bottom));
      expect(description.left, lessThan(name.left));
      await tester.tap(find.text(l10n.pluginAutoStart));
      await tester.pumpAndSettle();
      expect(host.settings['autoStart'], true);
      expect(host.settings['background'], 'active');
      await tester.tap(find.text(l10n.pluginBackground));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.pluginBackgroundContinuous));
      await tester.pumpAndSettle();
      expect(host.settings, {
        'enabled': true,
        'autoStart': true,
        'background': 'continuous',
      });
      await tester.tap(find.text(l10n.pluginAutoStart));
      await tester.pumpAndSettle();
      expect(host.settings, {
        'enabled': true,
        'autoStart': false,
        'background': 'continuous',
      });
    },
  );

  testWidgets(
    'target permission changes address the exact device and application rule on a narrow screen',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 740));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await render(tester);
      final l10n = AppLocalizations.of(
        tester.element(find.byType(PluginManagementPage)),
      )!;
      final targetTile = find.ancestor(
        of: find.text('Watch / org.example.app'),
        matching: find.byType(SegmentedTile),
      );
      await tester.scrollUntilVisible(
        find.text('Watch / org.example.app'),
        200,
        scrollable: find
            .descendant(
              of: find.byType(SegmentedList),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      expect(find.byType(DropdownButton<String>), findsNothing);
      await tester.tap(targetTile);
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.pluginPermissionDeny).last);
      await tester.pumpAndSettle();
      expect(host.lastPermission?['key'], _Host.targetKey);
      expect(host.lastPermission?['policy'], {'decision': 'deny'});
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'uninstall confirms and returns a removed result to the function page',
    (tester) async {
      bool? removed;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [applicationHostProvider.overrideWithValue(host)],
          child: MaterialApp(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  child: const Text('Open'),
                  onPressed: () async {
                    removed = await Navigator.of(context).push<bool>(
                      MaterialPageRoute(
                        builder: (_) =>
                            const PluginManagementPage(pluginId: 'fixture'),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      final l10n = AppLocalizations.of(
        tester.element(find.byType(PluginManagementPage)),
      )!;
      final button = find.widgetWithText(FilledButton, l10n.uninstall);
      await tester.scrollUntilVisible(
        button,
        250,
        scrollable: find
            .descendant(
              of: find.byType(SegmentedList),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(host.removed, false);
      await tester.tap(find.widgetWithText(FilledButton, l10n.uninstall).last);
      await tester.pumpAndSettle();
      expect(host.removed, true);
      expect(removed, true);
      expect(find.text('Open'), findsOneWidget);
    },
  );
}

class _Host implements OronBoxCommandBus {
  static const targetKey =
      '["interconnect","interconnect.send","[\\"watch\\",\\"org.example.app\\"]"]';
  final settings = <String, Object?>{
    'enabled': true,
    'background': 'active',
    'autoStart': false,
  };
  Map<String, Object?>? lastPermission;
  bool removed = false;
  final policies = <String, Object?>{
    targetKey: {
      'capability': 'interconnect',
      'operation': 'interconnect.send',
      'scope': '["watch","org.example.app"]',
      'resource': 'Watch / org.example.app',
      'decision': 'allow',
    },
  };

  @override
  Stream<CommandEvent> get events => const Stream.empty();

  @override
  Future<CommandResult> execute(OronBoxCommand command) async {
    switch (command.method) {
      case 'plugin.get':
        return CommandResult.success({
          'id': 'fixture',
          'name': 'Fixture',
          'version': '1',
          'apiLevel': 1,
          'description': 'Description',
          'permissions': ['interconnect'],
          'permissionPolicies': policies,
          ...settings,
        });
      case 'plugin.settings.set':
        settings.addAll(Map.of(command.params)..remove('id'));
      case 'plugin.permission.set':
        lastPermission = command.params;
        final key = command.params['key'] as String;
        policies[key] = {
          ...(policies[key] as Map).cast<String, Object?>(),
          ...(command.params['policy'] as Map).cast<String, Object?>(),
        };
      case 'plugin.remove':
        removed = true;
    }
    return const CommandResult.success();
  }

  @override
  Future<void> close() async {}
}
