part of 'plugin_ui_tree.dart';

class _Column extends StatelessWidget {
  const _Column({
    required this.props,
    this.styles = const {},
    required this.children,
  });
  final Map<String, Object?> props;
  final Map<String, Object?> styles;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final gap =
        (_toDouble(styles['row_gap'] ?? styles['gap']) ??
                _num(props, 'gap') ??
                0)
            .clamp(0.0, double.infinity);
    final alignStr =
        styles['align_items']?.toString() ?? props['align']?.toString();
    final cross = switch (alignStr) {
      'flex-start' || 'start' => CrossAxisAlignment.start,
      'flex-end' || 'end' => CrossAxisAlignment.end,
      'center' => CrossAxisAlignment.center,
      'stretch' => CrossAxisAlignment.stretch,
      _ => CrossAxisAlignment.stretch,
    };
    final justifyStr = styles['justify_content']?.toString();
    final mainAxis = switch (justifyStr) {
      'flex-start' || 'start' => MainAxisAlignment.start,
      'flex-end' || 'end' => MainAxisAlignment.end,
      'center' => MainAxisAlignment.center,
      'space-between' => MainAxisAlignment.spaceBetween,
      'space-around' => MainAxisAlignment.spaceAround,
      'space-evenly' => MainAxisAlignment.spaceEvenly,
      _ => MainAxisAlignment.start,
    };
    return Padding(
      padding: _parseEdgeInsets(props),
      child: Column(
        crossAxisAlignment: cross,
        mainAxisAlignment: mainAxis,
        mainAxisSize: MainAxisSize.min,
        spacing: gap,
        verticalDirection: styles['flex_direction'] == 'column-reverse'
            ? VerticalDirection.up
            : VerticalDirection.down,
        children: [
          for (final child in children)
            if (child is _PluginSpacer) SizedBox(height: child.size) else child,
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.props,
    this.styles = const {},
    required this.wraps,
    required this.children,
  });
  final Map<String, Object?> props;
  final Map<String, Object?> styles;
  final bool wraps;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final gap =
        (_toDouble(styles['column_gap'] ?? styles['gap']) ??
                _num(props, 'gap') ??
                0)
            .clamp(0.0, double.infinity);
    final alignStr =
        styles['align_items']?.toString() ?? props['align']?.toString();
    final cross = switch (alignStr) {
      'flex-start' || 'start' => CrossAxisAlignment.start,
      'flex-end' || 'end' => CrossAxisAlignment.end,
      'center' => CrossAxisAlignment.center,
      'stretch' => CrossAxisAlignment.stretch,
      _ => CrossAxisAlignment.center,
    };
    final justifyStr = styles['justify_content']?.toString();
    final mainAxis = switch (justifyStr) {
      'flex-start' || 'start' => MainAxisAlignment.start,
      'flex-end' || 'end' => MainAxisAlignment.end,
      'center' => MainAxisAlignment.center,
      'space-between' => MainAxisAlignment.spaceBetween,
      'space-around' => MainAxisAlignment.spaceAround,
      'space-evenly' => MainAxisAlignment.spaceEvenly,
      _ => MainAxisAlignment.center,
    };
    final reverse = styles['flex_direction'] == 'row-reverse';
    final textDirection = Directionality.of(context);
    final direction = !reverse
        ? textDirection
        : textDirection == TextDirection.ltr
        ? TextDirection.rtl
        : TextDirection.ltr;
    return Padding(
      padding: _parseEdgeInsets(props),
      child: wraps
          ? Align(
              alignment: switch (mainAxis) {
                MainAxisAlignment.end => AlignmentDirectional.centerEnd.resolve(
                  direction,
                ),
                MainAxisAlignment.center => Alignment.center,
                _ => AlignmentDirectional.centerStart.resolve(direction),
              },
              child: Wrap(
                spacing: gap,
                runSpacing:
                    (_toDouble(styles['row_gap'] ?? styles['gap']) ??
                            _num(props, 'gap') ??
                            0)
                        .clamp(0.0, double.infinity),
                textDirection: direction,
                verticalDirection: styles['flex_wrap'] == 'wrap-reverse'
                    ? VerticalDirection.up
                    : VerticalDirection.down,
                alignment: switch (mainAxis) {
                  MainAxisAlignment.start => WrapAlignment.start,
                  MainAxisAlignment.end => WrapAlignment.end,
                  MainAxisAlignment.center => WrapAlignment.center,
                  MainAxisAlignment.spaceBetween => WrapAlignment.spaceBetween,
                  MainAxisAlignment.spaceAround => WrapAlignment.spaceAround,
                  MainAxisAlignment.spaceEvenly => WrapAlignment.spaceEvenly,
                },
                crossAxisAlignment: switch (cross) {
                  CrossAxisAlignment.start => WrapCrossAlignment.start,
                  CrossAxisAlignment.end => WrapCrossAlignment.end,
                  _ => WrapCrossAlignment.center,
                },
                children: children,
              ),
            )
          : Row(
              textDirection: direction,
              crossAxisAlignment: cross,
              mainAxisAlignment: mainAxis,
              spacing: gap,
              children: children,
            ),
    );
  }
}

class _PluginSpacer extends StatelessWidget {
  const _PluginSpacer();

  double get size => 16;

  @override
  Widget build(BuildContext context) => SizedBox(width: size, height: size);
}

class _LazyColumn extends StatelessWidget {
  const _LazyColumn({required this.props, required this.children});
  final Map<String, Object?> props;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final gap = _num(props, 'gap') ?? 0;
    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: _parseEdgeInsets(props),
      itemCount: children.length,
      itemBuilder: (_, i) => children[i],
      separatorBuilder: gap > 0
          ? (_, _) => SizedBox(width: gap, height: gap)
          : (_, _) => const SizedBox.shrink(),
    );
  }
}

class _PluginGroup extends StatelessWidget {
  const _PluginGroup({required this.children, this.content});
  final List<Widget> children;
  final String? content;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty && content != null) return Text(content!);
    if (children.length == 1) return children.first;
    return Column(mainAxisSize: MainAxisSize.min, children: children);
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.padding, required this.child});
  final EdgeInsets padding;
  final Widget child;

  @override
  Widget build(BuildContext context) => Card(
    elevation: 0,
    margin: EdgeInsets.zero,
    color: Theme.of(context).colorScheme.surfaceContainerHighest
        .withValues(alpha: .5),
    child: Padding(padding: padding, child: child),
  );
}

class _Divider extends StatelessWidget {
  const _Divider({required this.props});
  final Map<String, Object?> props;

  @override
  Widget build(BuildContext context) {
    final thickness = _num(props, 'thickness');
    return Padding(
      padding: _parseEdgeInsets(props),
      child: Divider(thickness: thickness),
    );
  }
}

class _Grid extends StatelessWidget {
  const _Grid({
    required this.props,
    required this.styles,
    required this.children,
  });
  final Map<String, Object?> props;
  final Map<String, Object?> styles;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final gap = _toDouble(styles['gap']) ?? _toDouble(props['gap']) ?? 8.0;
    return Wrap(spacing: gap, runSpacing: gap, children: children);
  }
}

class _ScrollArea extends StatelessWidget {
  const _ScrollArea({
    required this.props,
    required this.styles,
    required this.children,
  });
  final Map<String, Object?> props;
  final Map<String, Object?> styles;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: _Column(props: props, styles: styles, children: children),
    );
  }
}
