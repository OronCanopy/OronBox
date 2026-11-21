part of 'plugin_ui_tree.dart';

class _Modal extends StatelessWidget {
  const _Modal({
    required this.props,
    required this.onInvoke,
    required this.child,
  });
  final Map<String, Object?> props;
  final Future<void> Function(String, [Object?]) onInvoke;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final title = props['title']?.toString();
    final onDismiss = props['onDismiss']?.toString() ?? '';
    return Padding(
      padding: _parseEdgeInsets(props),
      child: Center(
        child: OutlinedButton(
          onPressed: () async {
            await showDialog(
              context: context,
              builder: (ctx) => AlertDialog(
                title: title != null ? Text(title) : null,
                content: child,
                actions: [
                  TextButton(
                    onPressed: () {
                      Navigator.pop(ctx);
                      if (onDismiss.isNotEmpty) onInvoke(onDismiss);
                    },
                    child: Text(AppLocalizations.of(context)!.close),
                  ),
                ],
              ),
            );
          },
          child: Text(title ?? AppLocalizations.of(context)!.open),
        ),
      ),
    );
  }
}

class _Tooltip extends StatelessWidget {
  const _Tooltip({required this.props, required this.child});
  final Map<String, Object?> props;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final text =
        props['message']?.toString() ?? props['text']?.toString() ?? '';
    return Padding(
      padding: _parseEdgeInsets(props),
      child: Tooltip(message: text, child: child),
    );
  }
}

class _TabSelection extends StatefulWidget {
  const _TabSelection({required this.index, required this.child});
  final int index;
  final Widget child;

  @override
  State<_TabSelection> createState() => _TabSelectionState();
}

class _TabSelectionState extends State<_TabSelection> {
  @override
  void didUpdateWidget(covariant _TabSelection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.index != oldWidget.index) {
      DefaultTabController.of(context).index = widget.index;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _Tabs extends StatefulWidget {
  const _Tabs({
    required this.props,
    required this.onInvoke,
    required this.children,
  });
  final Map<String, Object?> props;
  final Future<void> Function(String, [Object?]) onInvoke;
  final List<Widget> children;

  @override
  State<_Tabs> createState() => _TabsState();
}

class _TabsState extends State<_Tabs> with SingleTickerProviderStateMixin {
  late TabController _controller;

  @override
  void initState() {
    super.initState();
    final tabs =
        (widget.props['tabs'] as List?)
            ?.whereType<Map>()
            .map((t) => t.cast<String, Object?>())
            .toList() ??
        const [];
    _controller = TabController(length: tabs.length, vsync: this);
  }

  @override
  void didUpdateWidget(covariant _Tabs oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldLength = (oldWidget.props['tabs'] as List?)?.length ?? 0;
    final newLength = (widget.props['tabs'] as List?)?.length ?? 0;
    if (oldLength == newLength) return;
    _controller.dispose();
    _controller = TabController(length: newLength, vsync: this);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tabs =
        (widget.props['tabs'] as List?)
            ?.whereType<Map>()
            .map((t) => t.cast<String, Object?>())
            .toList() ??
        const [];
    final onChange = widget.props['onChange']?.toString() ?? '';
    return TabBar(
      controller: _controller,
      isScrollable: widget.props['scrollable'] == true,
      tabAlignment: widget.props['scrollable'] == true
          ? TabAlignment.start
          : TabAlignment.fill,
      onTap: (i) {
        final id = tabs[i]['id']?.toString() ?? '';
        if (onChange.isNotEmpty) {
          widget.onInvoke(onChange, _uiEvent('CHANGE', id));
        }
      },
      tabs: tabs.map((t) => Tab(text: t['label']?.toString() ?? '')).toList(),
    );
  }
}

class _TabContent extends StatelessWidget {
  const _TabContent({required this.props, required this.child});
  final Map<String, Object?> props;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tabId = props['tabId']?.toString() ?? '';
    final activeId = props['activeId']?.toString() ?? '';
    return tabId == activeId ? child : const SizedBox.shrink();
  }
}
