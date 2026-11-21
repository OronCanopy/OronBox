import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:oronbox/src/app/app_localizations_delegates.dart';
import 'package:oronbox/src/app/generated/app_localizations.dart';
import 'package:oronbox/src/commands/command_protocol.dart';
import 'package:oronbox/src/core/services/shared_prefs_service.dart';
import 'package:oronbox/src/features/plugins/pages/plugin_detail_page.dart';
import 'package:oronbox/src/features/plugins/pages/plugin_management_page.dart';
import 'package:oronbox/src/host/application_host_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SharedPrefsService.instance.init();
  });
  Future<void> render(WidgetTester tester, _PluginHost host) =>
      tester.pumpWidget(
        ProviderScope(
          overrides: [applicationHostProvider.overrideWithValue(host)],
          child: MaterialApp(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(
              body: PluginDetailPage(pluginId: 'fixture', embedded: true),
            ),
          ),
        ),
      );

  testWidgets('paints features loading before opening the runtime', (
    tester,
  ) async {
    final host = _PluginHost();
    host.onOpen = () {
      expect(find.text('Fixture'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    };
    await render(tester, host);
    await tester.pump();
    expect(host.methods, ['plugin.get', 'plugin.view.attach']);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    final l10n = AppLocalizations.of(
      tester.element(find.byType(PluginDetailPage)),
    )!;
    expect(find.text(l10n.pluginNoFeatures), findsNothing);

    host.open.complete(
      const CommandResult.success({'type': 'P', 'content': 'Ready'}),
    );
    await tester.pumpAndSettle();
    expect(find.text('Ready'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.drag(find.text('Ready'), const Offset(-600, 0));
    await tester.pumpAndSettle();
    expect(find.text('Ready'), findsOneWidget);
    await tester.tap(find.byTooltip(l10n.pluginDetails));
    await tester.pumpAndSettle();
    expect(find.byType(PluginManagementPage), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(host.methods.last, 'plugin.view.detach');
  });

  testWidgets('only completed empty UI displays the no-features message', (
    tester,
  ) async {
    final host = _PluginHost();
    await render(tester, host);
    await tester.pump();
    host.open.complete(const CommandResult.success(<Object?>[]));
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(
      tester.element(find.byType(PluginDetailPage)),
    )!;
    expect(find.text(l10n.pluginNoFeatures), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('open failures replace loading with an error', (tester) async {
    final host = _PluginHost();
    await render(tester, host);
    await tester.pump();
    host.open.complete(
      const CommandResult.failure(CommandError('fixture', 'Open failed')),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Open failed'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets(
    'retained navigation branches report plugin visibility without disposing its view',
    (tester) async {
      final host = _PluginHost();
      host.open.complete(
        const CommandResult.success({'type': 'TEXT', 'content': 'Ready'}),
      );
      final router = GoRouter(
        initialLocation: '/plugins/fixture',
        routes: [
          StatefulShellRoute.indexedStack(
            builder: (_, _, shell) => shell,
            branches: [
              StatefulShellBranch(
                initialLocation: '/plugins/fixture',
                routes: [
                  GoRoute(
                    path: '/plugins/:id',
                    builder: (_, _) =>
                        const PluginDetailPage(pluginId: 'fixture'),
                  ),
                ],
              ),
              StatefulShellBranch(
                routes: [
                  GoRoute(
                    path: '/elsewhere',
                    builder: (_, _) => const Scaffold(body: Text('Elsewhere')),
                  ),
                ],
              ),
            ],
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [applicationHostProvider.overrideWithValue(host)],
          child: MaterialApp.router(
            routerConfig: router,
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(host.visibility, isEmpty);
      router.go('/elsewhere');
      await tester.pumpAndSettle();
      expect(host.visibility, [false]);
      expect(
        host.methods.where((method) => method == 'plugin.view.detach'),
        isEmpty,
      );
      router.go('/plugins/fixture');
      await tester.pumpAndSettle();
      expect(host.visibility, [false, true]);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      router.dispose();
    },
  );

  testWidgets(
    'independent plugin pages receive updates and pop back to the current root',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await SharedPrefsService.instance.init();
      final host = _RoutingPluginHost();
      final router = GoRouter(
        initialLocation: '/plugins/fixture',
        routes: [
          GoRoute(
            path: '/plugins/:id',
            builder: (_, _) =>
                const PluginDetailPage(pluginId: 'fixture', embedded: true),
            routes: [
              GoRoute(
                path: 'page',
                builder: (_, state) {
                  final args = state.extra as PluginUiRouteArgs;
                  return PluginUiPage(
                    pluginId: 'fixture',
                    preview: args.nodes,
                    title: args.title,
                  );
                },
              ),
            ],
          ),
        ],
      );
      host.open.complete(
        const CommandResult.success({'type': 'TEXT', 'content': 'Root'}),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [applicationHostProvider.overrideWithValue(host)],
          child: MaterialApp.router(
            routerConfig: router,
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
          ),
        ),
      );
      await tester.pumpAndSettle();
      host.controller.add(
        const CommandEvent(
          'plugin.ui',
          data: {
            'id': 'fixture',
            'page': true,
            'nodes': {
              'type': 'BUTTON',
              'content': 'Page action',
              'events': {'CLICK': 'page-action'},
            },
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(PluginUiPage), findsOneWidget);
      await tester.tap(find.text('Page action'));
      await tester.pumpAndSettle();
      expect(host.methods.last, 'plugin.invoke');
      host.controller.add(
        const CommandEvent(
          'plugin.ui',
          data: {
            'id': 'fixture',
            'nodes': {'type': 'TEXT', 'content': 'Updated root'},
          },
        ),
      );
      host.controller.add(
        const CommandEvent(
          'plugin.ui',
          data: {
            'id': 'fixture',
            'page': true,
            'nodes': {'type': 'TEXT', 'content': 'Updated page'},
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Updated page'), findsOneWidget);
      router.pop();
      await tester.pumpAndSettle();
      expect(find.text('Updated root'), findsOneWidget);
      expect(
        host.methods.where((method) => method == 'plugin.view.detach'),
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(host.methods.last, 'plugin.view.detach');
      router.dispose();
      await host.controller.close();
    },
  );
}

class _RoutingPluginHost extends _PluginHost {
  final controller = StreamController<CommandEvent>.broadcast();
  @override
  Stream<CommandEvent> get events => controller.stream;
}

class _PluginHost implements OronBoxCommandBus {
  final open = Completer<CommandResult>();
  final methods = <String>[];
  final visibility = <bool>[];
  VoidCallback? onOpen;

  @override
  Stream<CommandEvent> get events => const Stream.empty();

  @override
  Future<CommandResult> execute(OronBoxCommand command) async {
    methods.add(command.method);
    switch (command.method) {
      case 'plugin.get':
        return const CommandResult.success({
          'id': 'fixture',
          'name': 'Fixture',
        });
      case 'plugin.view.visibility':
        visibility.add(command.params['visible'] == true);
        return const CommandResult.success();
      case 'plugin.view.attach':
        onOpen?.call();
        return open.future;
      default:
        return const CommandResult.success();
    }
  }

  @override
  Future<void> close() async {}
}
