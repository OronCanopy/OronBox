import 'package:material_ui/material_ui.dart';
import 'package:oronbox/src/app/generated/app_localizations.dart';

import '../domain/plugin_permission.dart';
import 'plugin_summary.dart';

Future<bool> confirmPluginInstall({
  required BuildContext context,
  required String name,
  required List<String> permissions,
  required bool updating,
  String author = '',
  String version = '',
  String description = '',
  String? runtime,
  Widget? icon,
  bool installed = false,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final declared = permissions
      .where((permission) => !isRetiredPluginPermission(permission))
      .toList(growable: false);
  return await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: SizedBox(
            width: 420,
            child: PluginSummary(
              name: name,
              author: author,
              version: version,
              runtime: runtime,
              icon: icon ?? const Icon(Icons.extension_outlined, size: 56),
            ),
          ),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (description.trim().isNotEmpty) ...[
                    Text(description),
                    const SizedBox(height: 16),
                  ],
                  Text(
                    l10n.pluginDeclaredPermissions,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  if (declared.isEmpty)
                    Text(
                      l10n.pluginNoPermissions,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    )
                  else
                    ...declared.map(
                      (permission) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Text(permission),
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              onPressed: installed && !updating
                  ? null
                  : () => Navigator.pop(context, true),
              child: Text(
                updating
                    ? l10n.update
                    : installed
                    ? l10n.pluginUpToDate
                    : l10n.install,
              ),
            ),
          ],
        ),
      ) ??
      false;
}
