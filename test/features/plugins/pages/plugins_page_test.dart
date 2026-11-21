import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:oronbox/src/app/app_localizations_delegates.dart';
import 'package:oronbox/src/app/widgets/app_state_view.dart';
import 'package:oronbox/src/app/generated/app_localizations.dart';
import 'package:oronbox/src/commands/command_protocol.dart';
import 'package:oronbox/src/core/services/shared_prefs_service.dart';
import 'package:oronbox/src/features/plugins/pages/plugins_page.dart';
import 'package:oronbox/src/features/plugins/widgets/plugin_install_confirmation.dart';
import 'package:oronbox/src/host/application_host_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SharedPrefsService.instance.init();
  });

  testWidgets('plugin search distinguishes no matches from an empty catalog', (
    tester,
  ) async {
    final host = _MarketHost(update: false, installed: true);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [applicationHostProvider.overrideWithValue(host)],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const PluginsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(tester.element(find.byType(PluginsPage)))!;
    expect(find.text('Installed fixture'), findsOneWidget);
    await tester.enterText(find.byType(SearchBar), 'no-such-plugin');
    await tester.pumpAndSettle();
    expect(find.text(l10n.pluginSearchEmpty), findsOneWidget);
    expect(find.text(l10n.pluginEmpty), findsNothing);
    await tester.tap(find.text(l10n.pluginMarket));
    await tester.pumpAndSettle();
    expect(find.text(l10n.pluginSearchEmpty), findsOneWidget);
    expect(find.text(l10n.pluginMarketEmpty), findsNothing);
    await tester.enterText(find.byType(SearchBar), '');
    await tester.pumpAndSettle();
    expect(find.text('Fixture'), findsOneWidget);
    await tester.tap(find.text(l10n.pluginInstalled));
    await tester.pumpAndSettle();
    expect(find.text('Installed fixture'), findsOneWidget);
  });

  for (final brightness in Brightness.values) {
    testWidgets('empty plugin catalogs share styling ($brightness)', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(320, 740));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            applicationHostProvider.overrideWithValue(
              _MarketHost(update: false, emptyMarket: true),
            ),
          ],
          child: MaterialApp(
            theme: ThemeData(brightness: brightness),
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const PluginsPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final l10n = AppLocalizations.of(
        tester.element(find.byType(PluginsPage)),
      )!;
      expect(find.byType(EmptyStateView), findsOneWidget);
      final installedTitle = tester.widget<Text>(find.text(l10n.pluginEmpty));
      final installedIcon = tester.widget<Icon>(
        find.descendant(
          of: find.byType(EmptyStateView),
          matching: find.byType(Icon),
        ),
      );
      await tester.tap(find.text(l10n.pluginMarket));
      await tester.pumpAndSettle();
      expect(find.byType(EmptyStateView), findsOneWidget);
      final marketTitle = tester.widget<Text>(
        find.text(l10n.pluginMarketEmpty),
      );
      final marketIcon = tester.widget<Icon>(
        find.descendant(
          of: find.byType(EmptyStateView),
          matching: find.byType(Icon),
        ),
      );
      expect(marketTitle.style, installedTitle.style);
      expect(marketIcon.color, installedIcon.color);
      expect(marketIcon.size, installedIcon.size);
      expect(tester.takeException(), isNull);
    });
  }

  for (final update in [false, true]) {
    testWidgets(
      'market card and action share one confirmation (update $update)',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(320, 740));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final host = _MarketHost(update: update);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [applicationHostProvider.overrideWithValue(host)],
            child: MaterialApp(
              localizationsDelegates: appLocalizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: const PluginsPage(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final l10n = AppLocalizations.of(
          tester.element(find.byType(PluginsPage)),
        )!;
        await tester.tap(find.text(l10n.pluginMarket));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Fixture'));
        await tester.pumpAndSettle();
        final firstDialog = tester.widget<AlertDialog>(
          find.byType(AlertDialog),
        );
        expect(find.text('Description'), findsOneWidget);
        expect(find.text('network'), findsNothing);
        await tester.tap(find.widgetWithText(TextButton, l10n.cancel));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byIcon(update ? Icons.upgrade_rounded : Icons.add_rounded),
        );
        await tester.pumpAndSettle();
        final secondDialog = tester.widget<AlertDialog>(
          find.byType(AlertDialog),
        );
        expect(secondDialog.title.runtimeType, firstDialog.title.runtimeType);
        expect(find.text('Description'), findsOneWidget);
        expect(host.installs, 0);
        await tester.tap(
          find.widgetWithText(
            FilledButton,
            update ? l10n.update : l10n.install,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(host.installs, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'long plugin details scroll while installation remains accessible',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      bool? confirmed;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(1.3)),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  confirmed = await confirmPluginInstall(
                    context: context,
                    name: 'Fixture with a long plugin name on a narrow screen',
                    description: List.filled(30, 'Description').join('\n'),
                    runtime: 'wasm',
                    updating: false,
                    permissions: const [
                      'ui',
                      'file',
                      'network',
                      'interconnect',
                    ],
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text('AstroBox-NG'), findsOneWidget);
      expect(find.textContaining(' · '), findsNothing);
      final content = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(SingleChildScrollView),
      );
      await tester.drag(content, const Offset(0, -2000));
      await tester.pumpAndSettle();
      final l10n = AppLocalizations.of(
        tester.element(find.byType(AlertDialog)),
      )!;
      expect(
        tester
            .getRect(find.text('interconnect'))
            .overlaps(tester.getRect(content)),
        isTrue,
      );
      await tester.tap(find.widgetWithText(FilledButton, l10n.install));
      await tester.pumpAndSettle();
      expect(confirmed, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}

class _MarketHost implements OronBoxCommandBus {
  _MarketHost({
    required this.update,
    this.installed = false,
    this.emptyMarket = false,
  });
  final bool emptyMarket;
  final bool installed;
  final bool update;
  int installs = 0;

  @override
  Stream<CommandEvent> get events => const Stream.empty();

  @override
  Future<CommandResult> execute(OronBoxCommand command) async {
    switch (command.method) {
      case 'plugin.list':
        return CommandResult.success(
          installed
              ? [
                  {
                    'id': 'installed-fixture',
                    'name': 'Installed fixture',
                    'description': 'Description',
                    'runtime': 'js',
                    'enabled': true,
                  },
                ]
              : [],
        );
      case 'plugin.safeMode.get':
        return const CommandResult.success({'enabled': false});
      case 'plugin.repositories':
        return const CommandResult.success([
          {'id': 'oronbox', 'name': 'OronBox'},
        ]);
      case 'plugin.repository.catalog':
        if (emptyMarket) return const CommandResult.success([]);
        return CommandResult.success([
          {
            'id': 'fixture',
            'source': 'oronbox',
            'name': 'Fixture',
            'author': 'Author',
            'version': '1.0',
            'runtime': 'js',
            'description': 'Description',
            'permissions': ['network'],
            'installed': update,
            'updateAvailable': update,
          },
        ]);
      case 'plugin.repository.install':
        installs++;
        return const CommandResult.success(null);
      default:
        throw StateError('Unexpected command ${command.method}');
    }
  }

  @override
  Future<void> close() async {}
}
