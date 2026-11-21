import 'package:material_ui/material_ui.dart';
import 'package:oronbox/src/app/generated/app_localizations.dart';

/// 页面和列表的空状态，主要提示使用 title，补充说明使用 message
/// 卡片与弹窗内使用 compact，内容超出可用高度时可纵向滚动
class EmptyStateView extends StatelessWidget {
  const EmptyStateView({
    super.key,
    this.icon,
    this.iconWidget,
    this.title,
    this.message,
    this.action,
    this.compact = false,
    this.padding,
  });

  final IconData? icon;
  final Widget? iconWidget;
  final String? title;
  final String? message;
  final Widget? action;
  final bool compact;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final defaultIcon =
        iconWidget ??
        Icon(
          icon ?? Icons.inbox_outlined,
          size: compact ? 36 : 56,
          color: colors.onSurfaceVariant.withValues(alpha: 0.75),
        );

    final resolvedPadding =
        padding ??
        (compact
            ? const EdgeInsets.symmetric(horizontal: 16, vertical: 20)
            : const EdgeInsets.symmetric(horizontal: 24, vertical: 48));

    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          primary: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: constraints.hasBoundedHeight
                  ? constraints.maxHeight
                  : 0,
            ),
            child: Center(
              child: Padding(
                padding: resolvedPadding,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    defaultIcon,
                    if (title != null && title!.isNotEmpty) ...[
                      SizedBox(height: compact ? 8 : 14),
                      Text(
                        title!,
                        textAlign: TextAlign.center,
                        style:
                            (compact
                                    ? textTheme.titleSmall
                                    : textTheme.titleMedium)
                                ?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: colors.onSurface,
                                ),
                      ),
                    ],
                    if (message != null && message!.isNotEmpty) ...[
                      SizedBox(
                        height: (title != null && title!.isNotEmpty)
                            ? 4
                            : (compact ? 8 : 12),
                      ),
                      Text(
                        message!,
                        textAlign: TextAlign.center,
                        style:
                            (compact
                                    ? textTheme.bodySmall
                                    : textTheme.bodyMedium)
                                ?.copyWith(color: colors.onSurfaceVariant),
                      ),
                    ],
                    if (action != null) ...[
                      SizedBox(height: compact ? 12 : 20),
                      action!,
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 加载失败状态，与空状态共用布局，通过 onRetry 提供重试操作
class ErrorStateView extends StatelessWidget {
  const ErrorStateView({
    super.key,
    this.icon,
    this.iconWidget,
    this.title,
    this.message,
    this.onRetry,
    this.retryLabel,
    this.compact = false,
    this.padding,
  });

  final IconData? icon;
  final Widget? iconWidget;
  final String? title;
  final String? message;
  final VoidCallback? onRetry;
  final String? retryLabel;
  final bool compact;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    return EmptyStateView(
      compact: compact,
      padding: padding,
      iconWidget:
          iconWidget ??
          Icon(
            icon ?? Icons.error_outline,
            size: compact ? 36 : 56,
            color: colors.error.withValues(alpha: 0.85),
          ),
      title: title,
      message: message,
      action: onRetry == null
          ? null
          : FilledButton.tonal(
              onPressed: onRetry,
              child: Text(retryLabel ?? l10n?.refresh ?? 'Refresh'),
            ),
    );
  }
}
