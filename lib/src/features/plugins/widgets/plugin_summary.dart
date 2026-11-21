import 'package:material_ui/material_ui.dart';

import 'plugin_type_badge.dart';

class PluginSummary extends StatelessWidget {
  const PluginSummary({
    super.key,
    required this.name,
    required this.icon,
    this.author = '',
    this.version = '',
    this.runtime,
    this.compact = false,
  });

  final String name;
  final Widget icon;
  final String author;
  final String version;
  final String? runtime;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final metadata = [
      author.trim(),
      version.trim(),
    ].where((value) => value.isNotEmpty).join(' · ');
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        icon,
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                maxLines: compact ? 1 : 2,
                overflow: TextOverflow.ellipsis,
                style: compact
                    ? theme.textTheme.titleSmall
                    : theme.textTheme.titleLarge,
              ),
              if (metadata.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  metadata,
                  maxLines: compact ? 1 : 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              if (runtime == 'wasm' ||
                  runtime == 'js' ||
                  runtime == 'hybrid') ...[
                const SizedBox(height: 4),
                PluginTypeBadge(runtime: runtime),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
