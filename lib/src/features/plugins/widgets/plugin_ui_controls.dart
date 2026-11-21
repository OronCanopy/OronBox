part of 'plugin_ui_tree.dart';

const _pluginInputPadding = EdgeInsets.symmetric(horizontal: 12, vertical: 9);

class _Button extends StatelessWidget {
  const _Button({
    required this.props,
    required this.onInvoke,
    this.children = const [],
    required this.padding,
  });
  final Map<String, Object?> props;
  final Future<void> Function(String, [Object?]) onInvoke;
  final List<Widget> children;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    final label = props['text']?.toString() ?? props['label']?.toString() ?? '';
    final onClick = props['disabled'] == true
        ? ''
        : props['onClick']?.toString() ?? '';
    final primary = props['primary'] == true;
    final caption = Text(label, maxLines: 1, overflow: TextOverflow.ellipsis);
    final buttonContent = children.isEmpty
        ? caption
        : label.isEmpty && children.length == 1
        ? children.single
        : Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 4,
            children: [
              ...children,
              if (label.isNotEmpty) Flexible(child: caption),
            ],
          );
    final iconOnly = props['iconOnly'] == true;
    final style = FilledButton.styleFrom(
      padding:
          padding ??
          (iconOnly
              ? const EdgeInsets.all(6)
              : const EdgeInsets.symmetric(horizontal: 12, vertical: 6)),
      minimumSize: Size(iconOnly ? 36 : 44, 36),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      visualDensity: VisualDensity.standard,
      tapTargetSize: MaterialTapTargetSize.padded,
    );
    final child = primary
        ? FilledButton(
            style: style,
            onPressed: onClick.isEmpty
                ? null
                : () => onInvoke(onClick, _uiEvent('CLICK')),
            child: buttonContent,
          )
        : FilledButton.tonal(
            style: style,
            onPressed: onClick.isEmpty
                ? null
                : () => onInvoke(onClick, _uiEvent('CLICK')),
            child: buttonContent,
          );
    return Center(widthFactor: 1, child: child);
  }
}

class _TextField extends StatefulWidget {
  const _TextField({required this.props, required this.onInvoke});
  final Map<String, Object?> props;
  final Future<void> Function(String, [Object?]) onInvoke;

  @override
  State<_TextField> createState() => _TextFieldState();
}

class _TextFieldState extends State<_TextField> {
  late final TextEditingController _ctrl;
  late final FocusNode _focus;
  late String _lastEmittedValue;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(
      text:
          (widget.props['value'] ?? widget.props['default-value'])
              ?.toString() ??
          '',
    );
    _lastEmittedValue = _ctrl.text;
    _focus = FocusNode()..addListener(_onBlur);
  }

  @override
  void didUpdateWidget(covariant _TextField old) {
    super.didUpdateWidget(old);
    if (!_focus.hasFocus && widget.props.containsKey('value')) {
      final newValue = widget.props['value']?.toString() ?? '';
      if (_ctrl.text != newValue) _ctrl.text = newValue;
      _lastEmittedValue = newValue;
    }
  }

  void _emitChange(String value) {
    if (value == _lastEmittedValue) return;
    _lastEmittedValue = value;
    final cb = widget.props['onChange']?.toString() ?? '';
    if (cb.isNotEmpty) widget.onInvoke(cb, _uiEvent('CHANGE', value));
  }

  void _onBlur() {
    if (!_focus.hasFocus) {
      _emitChange(_ctrl.text);
    }
  }

  @override
  void dispose() {
    _focus.removeListener(_onBlur);
    _focus.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final placeholder = widget.props['placeholder']?.toString();
    final multiline = widget.props['multiline'] == true;
    return Padding(
      padding: _parseEdgeInsets(widget.props),
      child: TextField(
        enabled: widget.props['disabled'] != true,
        controller: _ctrl,
        focusNode: _focus,
        onChanged: (value) {
          final input = widget.props['onInput']?.toString() ?? '';
          if (input.isNotEmpty) {
            widget.onInvoke(input, _uiEvent('INPUT', value));
          }
          _emitChange(value);
        },
        onSubmitted: multiline
            ? null
            : (_) {
                final callback = widget.props['onKeyDown']?.toString();
                if (callback != null) {
                  widget.onInvoke(callback, {
                    'eventType': 'KEY-DOWN',
                    'payload': {'key': 'Enter', 'value': _ctrl.text},
                  });
                }
              },
        maxLines: multiline ? null : 1,
        decoration: InputDecoration(
          isDense: true,
          contentPadding: _pluginInputPadding,
          hintText: placeholder,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }
}

class _Switch extends StatefulWidget {
  const _Switch({required this.props, required this.onInvoke});
  final Map<String, Object?> props;
  final Future<void> Function(String, [Object?]) onInvoke;

  @override
  State<_Switch> createState() => _SwitchState();
}

class _SwitchState extends State<_Switch> {
  late bool _checked;

  @override
  void initState() {
    super.initState();
    _checked =
        (widget.props['checked'] ?? widget.props['default-checked']) == true;
  }

  @override
  void didUpdateWidget(covariant _Switch oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.props.containsKey('checked')) {
      _checked = widget.props['checked'] == true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final onChange = widget.props['disabled'] == true
        ? ''
        : widget.props['onChange']?.toString() ?? '';
    return Padding(
      padding: _parseEdgeInsets(widget.props),
      child: Switch(
        value: _checked,
        onChanged: onChange.isEmpty
            ? null
            : (value) {
                if (!widget.props.containsKey('checked')) {
                  setState(() => _checked = value);
                }
                widget.onInvoke(onChange, _uiEvent('CHANGE', value));
              },
      ),
    );
  }
}

class _Checkbox extends StatelessWidget {
  const _Checkbox({required this.props, required this.onInvoke});
  final Map<String, Object?> props;
  final Future<void> Function(String, [Object?]) onInvoke;

  @override
  Widget build(BuildContext context) {
    final checked = props['checked'] == true;
    final label = props['label']?.toString();
    final onChange = props['disabled'] == true
        ? ''
        : props['onChange']?.toString() ?? '';
    final cb = Checkbox(
      value: checked,
      onChanged: onChange.isEmpty
          ? null
          : (v) => onInvoke(onChange, _uiEvent('CHANGE', v)),
    );
    if (label == null) {
      return Padding(padding: _parseEdgeInsets(props), child: cb);
    }
    return Padding(
      padding: _parseEdgeInsets(props),
      child: AppCheckboxRow(
        value: checked,
        onChanged: onChange.isEmpty
            ? null
            : (value) => onInvoke(onChange, _uiEvent('CHANGE', value)),
        title: Text(label),
      ),
    );
  }
}

class _Slider extends StatelessWidget {
  const _Slider({required this.props, required this.onInvoke});
  final Map<String, Object?> props;
  final Future<void> Function(String, [Object?]) onInvoke;

  @override
  Widget build(BuildContext context) {
    final value = double.tryParse(props['value']?.toString() ?? '') ?? 0;
    final min = double.tryParse(props['min']?.toString() ?? '') ?? 0;
    final max = double.tryParse(props['max']?.toString() ?? '') ?? 1;
    final onChange = props['disabled'] == true
        ? ''
        : props['onChange']?.toString() ?? '';
    return Padding(
      padding: _parseEdgeInsets(props),
      child: Slider(
        value: value.clamp(min, max),
        min: min,
        max: max,
        onChanged: onChange.isEmpty
            ? null
            : (v) => onInvoke(onChange, _uiEvent('CHANGE', v)),
      ),
    );
  }
}

class _Dropdown extends StatelessWidget {
  const _Dropdown({required this.props, required this.onInvoke});
  final Map<String, Object?> props;
  final Future<void> Function(String, [Object?]) onInvoke;

  @override
  Widget build(BuildContext context) {
    final value = props['value']?.toString();
    final options = <String, String>{
      for (final option in (props['options'] as List?) ?? const [])
        if (option is Map)
          option['value'].toString(): (option['label'] ?? option['value'])
              .toString()
        else
          option.toString(): option.toString(),
    };
    final onChange = props['disabled'] == true
        ? ''
        : props['onChange']?.toString() ?? '';
    return Padding(
      padding: _parseEdgeInsets(props),
      child: DropdownMenu<String>(
        inputDecorationTheme: Theme.of(context).inputDecorationTheme.copyWith(
          isDense: true,
          contentPadding: _pluginInputPadding,
          suffixIconConstraints: const BoxConstraints(
            minWidth: 32,
            minHeight: 32,
          ),
        ),
        initialSelection: value != null && options.containsKey(value)
            ? value
            : null,
        dropdownMenuEntries: options.entries
            .map((o) => DropdownMenuEntry(value: o.key, label: o.value))
            .toList(),
        enabled: props['disabled'] != true,
        onSelected: onChange.isEmpty
            ? null
            : (v) => onInvoke(onChange, _uiEvent('CHANGE', v)),
      ),
    );
  }
}

class _Option extends StatelessWidget {
  const _Option({required this.props, this.content});
  final Map<String, Object?> props;
  final String? content;

  @override
  Widget build(BuildContext context) => Text(
    content ?? props['label']?.toString() ?? props['value']?.toString() ?? '',
  );
}
