import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:oronbox/src/app/app_localizations_delegates.dart';
import 'package:oronbox/src/app/generated/app_localizations.dart';
import 'package:oronbox/src/app/widgets/app_error_gate.dart';
import 'package:oronbox/src/app/widgets/app_scaffold_messenger.dart';
import 'package:oronbox/src/features/accounts/application/host_accounts.dart';
import 'package:oronbox/src/features/resources/services/install_queue_notifier.dart';

class _Accounts extends HostAccountsNotifier {
  @override
  HostAccountsState build() => const HostAccountsState();
}

class _Installs extends InstallQueueNotifier {
  @override
  InstallQueueState build() => const InstallQueueState();

  void update(ResourceTaskStatus status, {bool loaded = true}) {
    state = InstallQueueState(
      loaded: loaded,
      tasks: [
        InstallTask(
          id: 'task',
          name: 'Resource',
          description: '',
          type: LocalDeviceInstallType.app,
          filePath: '/resource.bin',
          status: status,
          error: status == ResourceTaskStatus.failed
              ? 'install_quantity_limit'
              : null,
        ),
      ],
    );
  }
}

void main() {
  testWidgets(
    'failures follow the visible custom messenger and repeat after retry',
    (tester) async {
      final installs = _Installs();
      final navigator = GlobalKey<NavigatorState>();
      late BuildContext callbackContext;
      late BuildContext shellContext;
      late BuildContext detailContext;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            hostAccountsProvider.overrideWith(_Accounts.new),
            installQueueProvider.overrideWith(() => installs),
          ],
          child: MaterialApp(
            navigatorKey: navigator,
            locale: const Locale('zh'),
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => OronBoxScaffoldMessenger(
              child: Builder(
                builder: (context) {
                  callbackContext = context;
                  return AppErrorGate(child: child!);
                },
              ),
            ),
            home: Scaffold(
              bottomNavigationBar: const SizedBox(
                height: 80,
                child: Text('Navigation'),
              ),
              body: OronBoxScaffoldMessenger(
                key: appScaffoldMessengerKey,
                child: Scaffold(
                  body: Builder(
                    builder: (context) {
                      shellContext = context;
                      return const Text('Queue');
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      installs.update(ResourceTaskStatus.failed);
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);

      installs.update(ResourceTaskStatus.pending);
      installs.update(ResourceTaskStatus.failed);
      await tester.pumpAndSettle();
      expect(find.text('达到安装数量限制'), findsOneWidget);
      final notice = tester.getRect(find.byType(SnackBar));
      final bottomBar = tester.getRect(find.text('Navigation'));
      expect(notice.bottom, lessThanOrEqualTo(bottomBar.top));
      expect(
        appScaffoldMessengerOf(callbackContext),
        same(ScaffoldMessenger.of(shellContext)),
      );

      appScaffoldMessengerOf(callbackContext).removeCurrentSnackBar();
      await tester.pumpAndSettle();
      installs.update(ResourceTaskStatus.failed);
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);

      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => OronBoxScaffoldMessenger(
            child: Scaffold(
              body: Builder(
                builder: (context) {
                  detailContext = context;
                  return const Text('Detail');
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        appScaffoldMessengerOf(callbackContext),
        same(ScaffoldMessenger.of(detailContext)),
      );
      installs.update(ResourceTaskStatus.installing);
      installs.update(ResourceTaskStatus.failed);
      await tester.pumpAndSettle();
      expect(find.text('达到安装数量限制'), findsOneWidget);
      final firstNotice = tester.widget<SnackBar>(find.byType(SnackBar));
      installs.update(ResourceTaskStatus.installing);
      installs.update(ResourceTaskStatus.failed);
      await tester.pumpAndSettle();
      expect(find.text('达到安装数量限制'), findsOneWidget);
      expect(
        tester.widget<SnackBar>(find.byType(SnackBar)),
        isNot(same(firstNotice)),
      );

      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(
        appScaffoldMessengerOf(callbackContext),
        same(ScaffoldMessenger.of(shellContext)),
      );
    },
  );
}
