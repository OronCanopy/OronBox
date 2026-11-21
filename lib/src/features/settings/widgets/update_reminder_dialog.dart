import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:oronbox/src/data/community/community_source.dart';
import 'package:material_ui/material_ui.dart';
import 'package:oronbox/src/app/generated/app_localizations.dart';
import 'package:oronbox/src/app/utils/error_localization.dart';
import 'package:oronbox/src/app/widgets/app_checkbox_tile.dart';
import 'package:oronbox/src/app/widgets/app_scaffold_messenger.dart';
import 'package:oronbox/src/features/resources/widgets/resource_external_link.dart';

import '../services/update_reminder_service.dart';

class UpdateReminderDialog extends ConsumerStatefulWidget {
  const UpdateReminderDialog({
    super.key,
    required this.kind,
    required this.deviceName,
    required this.items,
    required this.onDismiss,
    required this.onHandled,
  });

  final UpdateReminderKind kind;
  final String? deviceName;
  final List<UpdateReminderItem> items;
  final void Function(List<UpdateReminderItem>, bool) onDismiss;
  final VoidCallback onHandled;

  @override
  ConsumerState<UpdateReminderDialog> createState() =>
      _UpdateReminderDialogState();
}

class _UpdateReminderDialogState extends ConsumerState<UpdateReminderDialog> {
  late final _remaining = widget.items.toList();
  bool _silence = false;
  bool _running = false;

  void _close() {
    widget.onDismiss(_remaining, _silence);
    widget.onHandled();
    Navigator.pop(context);
  }

  Future<void> _install(List<UpdateReminderItem> items) async {
    setState(() => _running = true);
    final l10n = AppLocalizations.of(context)!;
    try {
      for (final item in items) {
        if (!mounted) return;
        try {
          if (item.available?.call() == false) {
            setState(() => _remaining.remove(item));
            continue;
          }
          if (item.purchaseRequired && item.resource != null) {
            final resource = item.resource!;
            if (resource.source == CommunitySourceId.astroboxRepo) {
              await showAstroBoxResourcePurchaseDialog(context, resource);
            } else {
              final router = GoRouter.of(context);
              _close();
              router.push(
                '/resources/detail/${Uri.encodeComponent(resource.id)}?source=${resource.source.storageKey}',
              );
              return;
            }
          } else if (await item.install?.call() == true) {
            if (!mounted) return;
            setState(
              () => _remaining.removeWhere(
                (other) =>
                    other.id == item.id ||
                    (item.group != null && other.group == item.group),
              ),
            );
          } else if (mounted) {
            appScaffoldMessengerOf(
              context,
            ).showSnackBar(SnackBar(content: Text(l10n.updateReminderChanged)));
          }
        } catch (error) {
          if (mounted) {
            appScaffoldMessengerOf(context).showSnackBar(
              SnackBar(content: Text(localizedErrorMessage(l10n, error))),
            );
          }
        }
      }
    } finally {
      if (mounted) {
        setState(() => _running = false);
        if (_remaining.isEmpty) _close();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final isFirmware = widget.kind == UpdateReminderKind.firmware;
    final batch = _remaining.where((item) => item.batch).toList();
    final firmware = isFirmware ? _remaining.firstOrNull : null;
    return PopScope(
      canPop: !_running,
      child: AlertDialog(
        scrollable: true,
        title: Text(updateReminderTitle(l10n, widget.kind)),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.deviceName case final name?)
              Text(name, style: Theme.of(context).textTheme.titleSmall),
            if (isFirmware) ...[
              Text(l10n.updateReminderFirmwareMessage),
              const SizedBox(height: 12),
              if (firmware != null) ...[
                Text(
                  l10n.updateReminderCurrentVersion(
                    firmware.currentVersion ?? '',
                  ),
                ),
                Text(l10n.updateReminderLatestFirmware(firmware.version)),
              ],
            ] else ...[
              if (widget.kind == UpdateReminderKind.resources)
                Text(l10n.updateReminderResourcesMessage),
              for (final item in _remaining)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(item.name),
                  subtitle: Text([item.version, ?item.source].join(' · ')),
                  trailing: TextButton(
                    onPressed: _running ? null : () => _install([item]),
                    child: Text(l10n.updateReminderInstall),
                  ),
                ),
            ],
            AppCheckboxRow(
              expanded: true,
              value: _silence,
              onChanged: _running
                  ? null
                  : (value) => setState(() => _silence = value ?? false),
              title: Text(l10n.updateReminderSilence),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: _running ? null : _close,
            child: Text(l10n.updateLater),
          ),
          FilledButton(
            onPressed: _running || batch.isEmpty ? null : () => _install(batch),
            child: Text(
              isFirmware
                  ? l10n.updateReminderInstall
                  : l10n.updateReminderInstallAll,
            ),
          ),
        ],
      ),
    );
  }
}

String updateReminderTitle(AppLocalizations l10n, UpdateReminderKind kind) =>
    switch (kind) {
      UpdateReminderKind.firmware => l10n.updateReminderFirmwareTitle,
      UpdateReminderKind.resources => l10n.updateReminderResourcesTitle,
      UpdateReminderKind.plugins => l10n.updateReminderPluginsTitle,
      UpdateReminderKind.inbox => l10n.updateReminderInbox,
    };
