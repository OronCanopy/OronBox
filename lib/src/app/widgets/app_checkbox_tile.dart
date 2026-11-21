import 'package:material_ui/material_ui.dart';

/// A full-row checkbox control with ink feedback confined to its checkbox.
class AppCheckboxTile extends StatelessWidget {
  const AppCheckboxTile({
    super.key,
    required this.value,
    required this.onChanged,
    required this.title,
    this.subtitle,
    this.contentPadding,
    this.controlAffinity = ListTileControlAffinity.platform,
    this.dense,
    this.visualDensity,
  });

  final bool value;
  final ValueChanged<bool?>? onChanged;
  final Widget title;
  final Widget? subtitle;
  final EdgeInsetsGeometry? contentPadding;
  final ListTileControlAffinity controlAffinity;
  final bool? dense;
  final VisualDensity? visualDensity;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final affinity = controlAffinity == ListTileControlAffinity.platform
        ? ListTileTheme.of(context).controlAffinity
        : controlAffinity;
    final checkbox = Theme(
      data: theme,
      child: ExcludeFocus(
        child: Checkbox(
          value: value,
          onChanged: onChanged,
          visualDensity: visualDensity,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
    );
    return MergeSemantics(
      child: Theme(
        data: theme.copyWith(
          splashFactory: NoSplash.splashFactory,
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
          hoverColor: Colors.transparent,
        ),
        child: ListTile(
          leading: affinity == ListTileControlAffinity.leading
              ? checkbox
              : null,
          trailing: affinity == ListTileControlAffinity.leading
              ? null
              : checkbox,
          title: title,
          subtitle: subtitle,
          dense: dense,
          visualDensity: visualDensity,
          contentPadding: contentPadding,
          enabled: onChanged != null,
          onTap: onChanged == null ? null : () => onChanged!(!value),
        ),
      ),
    );
  }
}

/// An inline checkbox and label sharing one hit area.
class AppCheckboxRow extends StatelessWidget {
  const AppCheckboxRow({
    super.key,
    required this.value,
    required this.onChanged,
    required this.title,
    this.expanded = false,
  });

  final bool value;
  final ValueChanged<bool?>? onChanged;
  final Widget title;
  final bool expanded;

  @override
  Widget build(BuildContext context) => MergeSemantics(
    child: MouseRegion(
      cursor: onChanged == null
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onChanged == null ? null : () => onChanged!(!value),
        child: Row(
          mainAxisSize: expanded ? MainAxisSize.max : MainAxisSize.min,
          children: [
            Checkbox(value: value, onChanged: onChanged),
            if (expanded) Expanded(child: title) else Flexible(child: title),
          ],
        ),
      ),
    ),
  );
}
