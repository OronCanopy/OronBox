import 'package:material_ui/material_ui.dart';
import 'package:oronbox/src/app/generated/app_localizations.dart';

class PluginTypeBadge extends StatelessWidget {
  const PluginTypeBadge({super.key, required this.runtime});

  final String? runtime;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final label = switch (runtime) {
      'wasm' => l10n.pluginTypeAstroBox,
      'js' || 'hybrid' => l10n.pluginTypeOronBox,
      _ => null,
    };
    if (label == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(label, style: theme.textTheme.labelSmall),
    );
  }
}
