import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:oronbox/src/app/app_localizations_delegates.dart';
import 'package:oronbox/src/app/generated/app_localizations.dart';
import 'package:oronbox/src/commands/command_protocol.dart';
import 'package:oronbox/src/features/plugins/widgets/plugin_host_request_handler.dart';
import 'package:oronbox/src/features/plugins/widgets/plugin_ui_tree.dart';
import 'package:oronbox/src/host/application_host_provider.dart';

void main() {
  late _Host host;

  setUp(() {
    host = _Host();
  });
  tearDown(() async {
    await host.close();
  });

  Future<void> render(WidgetTester tester, {bool duplicate = false}) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [applicationHostProvider.overrideWithValue(host)],
        child: MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: PluginHostRequestHandler(
              child: duplicate
                  ? const PluginHostRequestHandler(child: SizedBox())
                  : const Center(
                      child: SizedBox(
                        width: 280,
                        height: 360,
                        child: PluginViewport(
                          pluginId: 'fixture',
                          child: SizedBox(),
                        ),
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Map<String, Object?> permission(String id) => {
    'requestId': id,
    'pluginId': 'fixture',
    'type': 'permission',
    'pluginName': 'Fixture',
    'operation': 'device.list',
    'capability': 'device',
  };

  testWidgets('background approvals wait for the app to resume', (
    tester,
  ) async {
    await render(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    host.request(permission('approval'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    final l10n = AppLocalizations.of(tester.element(find.byType(AlertDialog)))!;
    await tester.tap(find.text(l10n.pluginPermissionOnce));
    await tester.pumpAndSettle();
    expect(host.responses['approval'], containsPair('decision', 'once'));
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets(
    'platform capability notice shows feedback without an uninstall dialog',
    (tester) async {
      await render(tester);
      host.eventsController.add(
        const CommandEvent(
          'plugin.notice',
          data: {
            'pluginId': 'fixture',
            'code': 'platform_capability_unavailable',
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(
        find.text('This feature is unavailable on this platform or browser'),
        findsOneWidget,
      );
    },
  );

  testWidgets('render size completes while an approval is awaiting input', (
    tester,
  ) async {
    await render(tester);
    host.request(permission('approval'));
    await tester.pumpAndSettle();
    host.request({
      'requestId': 'size',
      'pluginId': 'fixture',
      'type': 'renderSize',
    });
    await tester.pumpAndSettle();
    expect(host.responses['size'], {'width': 280.0, 'height': 360.0});
    expect(find.byType(AlertDialog), findsOneWidget);
    host.cancel('approval');
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('cancelling an old permission dialog preserves a newer route', (
    tester,
  ) async {
    await render(tester);
    host.request(permission('approval'));
    await tester.pumpAndSettle();
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    unawaited(
      navigator.push<void>(
        MaterialPageRoute(
          builder: (_) => const Scaffold(body: Text('New route')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    host.cancel('approval');
    await tester.pumpAndSettle();
    expect(find.text('New route'), findsOneWidget);
    expect(find.byType(AlertDialog, skipOffstage: false), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('two handlers claim a request once and show a single dialog', (
    tester,
  ) async {
    await render(tester, duplicate: true);
    host.request(permission('approval'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(host.claims, hasLength(1));
    host.cancel('approval');
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets(
    'window teardown releases pending approval and removes its dialog',
    (tester) async {
      await render(tester);
      host.request(permission('approval'));
      await tester.pumpAndSettle();
      expect(host.claims, hasLength(1));
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(host.claims, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}

class _Host implements OronBoxCommandBus {
  final eventsController = StreamController<CommandEvent>.broadcast();
  final pending = <String, Map<String, Object?>>{};
  final claims = <String, String>{};
  final responses = <String, Object?>{};

  void request(Map<String, Object?> data) {
    pending[data['requestId'] as String] = data;
    eventsController.add(CommandEvent('plugin.hostRequest', data: data));
  }

  void cancel(String id) {
    pending.remove(id);
    claims.remove(id);
    eventsController.add(
      CommandEvent('plugin.hostCancelled', data: {'requestId': id}),
    );
  }

  @override
  Stream<CommandEvent> get events => eventsController.stream;

  @override
  Future<CommandResult> execute(OronBoxCommand command) async {
    final id = command.params['requestId']?.toString() ?? '';
    final owner = command.params['owner']?.toString() ?? '';
    switch (command.method) {
      case 'plugin.host.pending':
        return CommandResult.success(pending.containsKey(id));
      case 'plugin.host.claim':
        if (!pending.containsKey(id) ||
            (claims[id] != null && claims[id] != owner)) {
          return const CommandResult.success(false);
        }
        claims[id] = owner;
        return const CommandResult.success(true);
      case 'plugin.host.respond':
        if (claims[id] == owner && pending.remove(id) != null) {
          claims.remove(id);
          responses[id] = command.params['response'];
        }
        break;
      case 'plugin.host.release':
        claims.removeWhere(
          (key, value) => value == owner && (id.isEmpty || id == key),
        );
    }
    return const CommandResult.success();
  }

  @override
  Future<void> close() => eventsController.close();
}
