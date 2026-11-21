import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:oronbox/src/app/generated/app_localizations.dart';
import 'package:oronbox/src/app/widgets/app_scaffold_messenger.dart';
import 'package:oronbox/src/app/utils/error_localization.dart';
import 'package:oronbox/src/features/accounts/application/host_accounts.dart';
import 'package:oronbox/src/commands/command_protocol.dart';
import 'package:oronbox/src/host/application_host_provider.dart';
import 'package:oronbox/src/features/resources/services/install_queue_notifier.dart';

final _engineeringInstallNotices = StreamProvider.autoDispose((ref) {
  return ref
      .watch(applicationHostProvider)
      .events
      .where((event) => event.event == 'miwear.engineering.install.finished');
});

/// Presents account notices and new installation failures on the visible page.
class AppErrorGate extends ConsumerWidget {
  const AppErrorGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(
      hostAccountsProvider.select(
        (state) => (state.noticeRevision, state.noticeCode),
      ),
      (previous, next) {
        if (next.$1 == 0 || previous?.$1 == next.$1 || next.$2 == null) return;
        _showError(context, '${next.$2}: application state');
      },
    );
    ref.listen(installQueueProvider, (previous, next) {
      if (previous == null || !previous.loaded) return;
      for (final task in next.tasks) {
        if (task.status != ResourceTaskStatus.failed) continue;
        final old = previous.tasks
            .where((old) => old.id == task.id)
            .firstOrNull;
        if (old?.status == ResourceTaskStatus.failed) continue;
        _showError(context, task.error ?? task.errorCode);
      }
    });
    ref.listen(_engineeringInstallNotices, (_, next) {
      final event = next.asData?.value;
      if (event == null) return;
      final data = event.data;
      final l10n = AppLocalizations.of(context)!;
      final code = data['code'] as String?;
      _showNotice(
        context,
        code == null
            ? l10n.engineeringWaiting
            : localizedErrorMessage(
                l10n,
                CommandError(code, data['message']?.toString() ?? code),
              ),
      );
    });
    return child;
  }

  void _showError(BuildContext context, Object? error) => _showNotice(
    context,
    localizedErrorMessage(AppLocalizations.of(context)!, error),
  );

  void _showNotice(BuildContext context, String message) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!context.mounted) return;
      final messenger = appScaffoldMessengerOf(context);
      messenger
        ..removeCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }
}
