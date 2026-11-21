import 'dart:convert';

import 'package:oronbox/src/app/widgets/app_state_view.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:material_ui/material_ui.dart';
import 'package:oronbox/src/app/generated/app_localizations.dart';
import 'package:oronbox/src/app/widgets/app_checkbox_tile.dart';
import 'package:oronbox/src/app/widgets/page_container.dart';
import 'package:oronbox/src/features/resources/widgets/community_html_content.dart';

part 'plugin_ui_layout.dart';
part 'plugin_ui_controls.dart';
part 'plugin_ui_overlays.dart';
part 'plugin_ui_content.dart';

final pluginViewportKeyProvider = Provider.autoDispose
    .family<GlobalKey, String>((ref, pluginId) => GlobalKey());

class PluginViewport extends ConsumerWidget {
  const PluginViewport({
    super.key,
    required this.pluginId,
    required this.child,
  });

  final String pluginId;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) => SizedBox.expand(
    key: ref.watch(pluginViewportKeyProvider(pluginId)),
    child: child,
  );
}

/// Renders AstroBox component UI using the application theme.
class PluginUITree extends StatelessWidget {
  const PluginUITree({
    super.key,
    required this.root,
    required this.onInvoke,
    this.contentPadding,
  });

  final Object? root;
  final Future<void> Function(String callback, [Object? value]) onInvoke;
  final EdgeInsetsGeometry? contentPadding;

  @override
  Widget build(BuildContext context) {
    final tree = _unwrap(root);
    if (tree == null) {
      return EmptyStateView(
        icon: Icons.extension_outlined,
        title: AppLocalizations.of(context)!.pluginNoFeatures,
      );
    }
    final content = _buildNode(context, tree);
    return SingleChildScrollView(
      child: contentPadding == null
          ? content
          : PageContainer(padding: contentPadding!, child: content),
    );
  }

  Map<String, Object?>? _unwrap(Object? value) {
    if (value is List) {
      if (value.isEmpty) return null;
      final first = value.firstOrNull;
      if (first is Map) return _unwrap(first);
      return null;
    }
    if (value is Map) {
      final map = value.cast<String, Object?>();
      if (map['root'] is Map) {
        return _unwrap(map['root']);
      }
      return map;
    }
    return null;
  }

  Widget _buildNode(BuildContext context, Map<String, Object?> node) {
    final props = (node['props'] as Map?) ?? const {};
    final semanticKey = node['key'] ?? props['key'] ?? props['id'];
    final child = _buildNodeContent(context, node);
    return semanticKey == null
        ? child
        : KeyedSubtree(key: ValueKey(semanticKey), child: child);
  }

  Widget _buildNodeContent(BuildContext context, Map<String, Object?> node) {
    final rawType = node['type']?.toString() ?? 'SizedBox';
    final typeUpper = rawType.toUpperCase().replaceAll('_', '-');
    final rawProps =
        (node['props'] as Map?)?.cast<String, Object?>() ?? const {};
    final rawStyles = <String, Object?>{
      for (final entry in ((node['styles'] as Map?) ?? {}).entries)
        entry.key.toString().replaceAll('-', '_'): entry.value,
    };
    final rawEvents =
        (node['events'] as Map?)?.cast<String, Object?>() ?? const {};
    final content = node['content']?.toString();

    final props = <String, Object?>{
      ...rawProps,
      for (final key in [
        'checked',
        'default-checked',
        'disabled',
        'visible',
        'multiline',
        'primary',
      ])
        if (rawProps[key] == 'true' || rawProps[key] == 'false')
          key: rawProps[key] == 'true',
      if (content != null &&
          !rawProps.containsKey('value') &&
          !rawProps.containsKey('text') &&
          !rawProps.containsKey('label'))
        'value': content,
    };

    if (_isHidden(node)) {
      return const SizedBox.shrink();
    }

    final rawChildren = node['children'];
    final childNodes = rawChildren is List
        ? rawChildren
              .whereType<Map>()
              .map((c) => c.cast<String, Object?>())
              .where((child) => !_isHidden(child))
              .toList()
        : <Map<String, Object?>>[];
    if (typeUpper == 'TABS-ROOT') {
      final list = childNodes
          .where(
            (n) => n['type'].toString().replaceAll('_', '-') == 'TABS-LIST',
          )
          .firstOrNull;
      final triggers =
          (list?['children'] as List?)?.whereType<Map>().toList() ?? [];
      final panels = childNodes
          .where(
            (n) => n['type'].toString().replaceAll('_', '-') == 'TABS-CONTENT',
          )
          .toList();
      if (triggers.isEmpty) return const SizedBox.shrink();
      final selectedIndex = triggers
          .indexWhere(
            (trigger) => (trigger['props'] as Map?)?['value'] == props['value'],
          )
          .clamp(0, triggers.length - 1);
      return DefaultTabController(
        length: triggers.length,
        initialIndex: selectedIndex,
        child: _TabSelection(
          index: selectedIndex,
          child: Builder(
            builder: (tabContext) {
              final controller = DefaultTabController.of(tabContext);
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TabBar(
                    isScrollable: true,
                    tabs: [
                      for (final trigger in triggers)
                        Tab(
                          child: _buildNode(tabContext, {
                            ...trigger.cast<String, Object?>(),
                            'events': const <String, Object?>{},
                          }),
                        ),
                    ],
                    onTap: (index) {
                      final disabled =
                          (triggers[index]['props'] as Map?)?['disabled'];
                      if (disabled == true || disabled == 'true') {
                        controller.index = controller.previousIndex;
                        return;
                      }
                      final callback =
                          (triggers[index]['events'] as Map?)?['CLICK']
                              ?.toString();
                      if (callback != null) {
                        onInvoke(callback, _uiEvent('CLICK'));
                      }
                    },
                  ),
                  AnimatedBuilder(
                    animation: controller,
                    builder: (context, _) {
                      final value =
                          props['value'] ??
                          (triggers[controller.index]['props']
                              as Map?)?['value'];
                      final panel = panels
                          .where((n) => (n['props'] as Map?)?['value'] == value)
                          .firstOrNull;
                      return panel == null
                          ? const SizedBox.shrink()
                          : _PluginGroup(
                              children: [
                                for (final node
                                    in (panel['children'] as List?)
                                            ?.whereType<Map>() ??
                                        const <Map>[])
                                  _buildNode(
                                    context,
                                    node.cast<String, Object?>(),
                                  ),
                              ],
                            );
                    },
                  ),
                ],
              );
            },
          ),
        ),
      );
    }
    if (typeUpper == 'SELECT') {
      final select = _Dropdown(
        props: {
          ...props,
          if (childNodes.isNotEmpty)
            'options': [
              for (final option in childNodes)
                {
                  'value':
                      (option['props'] as Map?)?['value'] ??
                      option['content'] ??
                      '',
                  'label':
                      (option['props'] as Map?)?['label'] ??
                      option['content'] ??
                      (option['props'] as Map?)?['value'] ??
                      '',
                },
            ],
          if (rawEvents['CHANGE'] != null) 'onChange': rawEvents['CHANGE'],
        },
        onInvoke: onInvoke,
      );
      return _wrapStyles(context, select, props, rawStyles, rawEvents);
    }
    if (typeUpper == 'DIALOG-ROOT' ||
        typeUpper == 'DROPDOWN-MENU-ROOT' ||
        typeUpper == 'CONTEXT-MENU-ROOT') {
      return _buildOverlay(context, typeUpper, childNodes);
    }

    final direction = rawStyles['flex_direction']?.toString().toLowerCase();
    final horizontal = switch (typeUpper) {
      'ROW' => true,
      'DIV' =>
        direction == 'row' ||
            direction == 'row-reverse' ||
            (direction == null && rawStyles['display'] == 'flex'),
      _ => false,
    };
    final hasGrowingChild =
        horizontal &&
        childNodes.any((node) {
          final styles = node['styles'] as Map?;
          return (_toDouble(styles?['flex_grow'] ?? styles?['flex-grow']) ??
                  0) >
              0;
        });
    final wrapStyle = rawStyles['flex_wrap'];
    final wraps =
        horizontal &&
        (wrapStyle == 'wrap' ||
            wrapStyle == 'wrap-reverse' ||
            (wrapStyle == null &&
                !hasGrowingChild &&
                childNodes.length > 1 &&
                childNodes.every(
                  (node) => node['type']?.toString().toUpperCase() == 'BUTTON',
                )));
    final hasTextChild =
        horizontal &&
        childNodes.any((node) {
          final type = node['type']?.toString().toUpperCase();
          return type == 'TEXT' || type == 'SPAN' || type == 'P';
        });
    final children = <Widget>[
      for (final node in childNodes)
        if (horizontal && !wraps)
          _buildRowChild(
            context,
            node,
            reserveIntrinsicWidth: hasGrowingChild,
            hasTextSibling: hasTextChild,
          )
        else
          _buildNode(context, node),
    ];

    Widget child = switch (typeUpper) {
      'COLUMN' => _Column(props: props, styles: rawStyles, children: children),
      'ROW' => _Row(
        props: props,
        styles: rawStyles,
        wraps: wraps,
        children: children,
      ),
      'LAZYCOLUMN' => _LazyColumn(props: props, children: children),
      'SCROLL-AREA' => _ScrollArea(
        props: props,
        styles: rawStyles,
        children: children,
      ),
      'GRID' => _Grid(props: props, styles: rawStyles, children: children),
      'SPACER' => const _PluginSpacer(),
      'TEXT' ||
      'SPAN' ||
      'P' => _Text(props: {...props, if (content != null) 'value': content}),
      'CODE' => _Code(props: props, content: content, styles: rawStyles),
      'HTMLDOCUMENT' => _Html(props: props),
      'BUTTON' => _Button(
        props: {
          ...props,
          if (content != null) 'text': content,
          'iconOnly':
              content == null &&
              childNodes.length == 1 &&
              childNodes.single['type']?.toString().toUpperCase() == 'SVG',
          if (rawEvents['CLICK'] != null) 'onClick': rawEvents['CLICK'],
        },
        onInvoke: onInvoke,
        padding: _controlPadding({...props, ...rawStyles}),
        children: children,
      ),
      'TEXTFIELD' || 'INPUT' || 'TEXTAREA' => _TextField(
        props: {
          ...props,
          if (content != null) 'value': content,
          if (rawEvents['CHANGE'] != null) 'onChange': rawEvents['CHANGE'],
          if (rawEvents['INPUT'] != null) 'onInput': rawEvents['INPUT'],
          if (rawEvents['KEY-DOWN'] != null) 'onKeyDown': rawEvents['KEY-DOWN'],
          if (typeUpper == 'TEXTAREA') 'multiline': true,
        },
        onInvoke: onInvoke,
      ),
      'SWITCH' => _Switch(
        props: {
          ...props,
          if (rawEvents['CHANGE'] != null) 'onChange': rawEvents['CHANGE'],
        },
        onInvoke: onInvoke,
      ),
      'CHECKBOX' => _Checkbox(
        props: {
          ...props,
          if (content != null) 'label': content,
          if (rawEvents['CHANGE'] != null) 'onChange': rawEvents['CHANGE'],
        },
        onInvoke: onInvoke,
      ),
      'SLIDER' => _Slider(
        props: {
          ...props,
          if (rawEvents['CHANGE'] != null) 'onChange': rawEvents['CHANGE'],
        },
        onInvoke: onInvoke,
      ),
      'DROPDOWN' => _Dropdown(props: props, onInvoke: onInvoke),
      'IMAGE' => _Image(props: props, styles: rawStyles),
      'SVG' => _Svg(props: props, content: content),
      'VIDEO' || 'AUDIO' => _MediaPlaceholder(type: typeUpper),
      'OPTION' => _Option(props: props, content: content),
      'CONTEXT-MENU-TRIGGER' ||
      'CONTEXT-MENU-CONTENT' ||
      'CONTEXT-MENU-ITEM' ||
      'CONTEXT-MENU-SEPARATOR' ||
      'DIALOG-TRIGGER' ||
      'DIALOG-CONTENT' ||
      'DIALOG-DESCRIPTION' ||
      'DROPDOWN-MENU-TRIGGER' ||
      'DROPDOWN-MENU-CONTENT' ||
      'DROPDOWN-MENU-SEPARATOR' => _PluginGroup(
        content: content,
        children: children,
      ),
      'TABS-TRIGGER' => Row(
        mainAxisSize: MainAxisSize.min,
        children: [if (content != null) Text(content), ...children],
      ),
      'DIALOG-TITLE' => _Text(
        props: {...props, if (content != null) 'value': content},
      ),
      'DIALOG-CLOSE' => TextButton(
        onPressed: () {
          Navigator.of(context).pop();
          final callback = rawEvents['CLICK']?.toString();
          if (callback != null) onInvoke(callback, _uiEvent('CLICK'));
        },
        child: Text(content ?? AppLocalizations.of(context)!.close),
      ),
      'DROPDOWN-MENU-ITEM' => _Text(
        props: {...props, if (content != null) 'value': content},
      ),
      'CARD' => _Card(
        padding:
            _controlPadding({...props, ...rawStyles}) ??
            const EdgeInsets.all(12),
        child: children.isNotEmpty
            ? (children.length == 1
                  ? children.first
                  : Column(mainAxisSize: MainAxisSize.min, children: children))
            : (content != null ? Text(content) : const SizedBox.shrink()),
      ),
      'DIVIDER' || 'SEPARATOR' => _Divider(props: props),
      'BADGE' => _Badge(
        props: {...props, if (content != null) 'text': content},
        child: children.firstOrNull ?? const SizedBox.shrink(),
      ),
      'CIRCULARPROGRESS' => _CircularProgress(props: props),
      'LINEARPROGRESS' || 'PROGRESS' => _LinearProgress(props: props),
      'MODAL' => _Modal(
        props: props,
        onInvoke: onInvoke,
        child: children.isNotEmpty
            ? (children.length == 1
                  ? children.first
                  : Column(mainAxisSize: MainAxisSize.min, children: children))
            : (content != null ? Text(content) : const SizedBox.shrink()),
      ),
      'TOOLTIP' => _Tooltip(
        props: {...props, if (content != null) 'message': content},
        child: children.firstOrNull ?? const SizedBox.shrink(),
      ),
      'TABS' || 'TABS-ROOT' => _Tabs(
        props: props,
        onInvoke: onInvoke,
        children: children,
      ),
      'TABCONTENT' || 'TABS-CONTENT' => _TabContent(
        props: props,
        child: children.isNotEmpty
            ? (children.length == 1
                  ? children.first
                  : Column(mainAxisSize: MainAxisSize.min, children: children))
            : const SizedBox.shrink(),
      ),
      'DIV' =>
        horizontal
            ? _Row(
                props: props,
                styles: {'justify_content': 'start', ...rawStyles},
                wraps: wraps,
                children: children,
              )
            : children.isEmpty && content != null
            ? Text(content)
            : _Column(props: props, styles: rawStyles, children: children),
      _ =>
        children.isNotEmpty
            ? (children.length == 1
                  ? children.first
                  : Column(mainAxisSize: MainAxisSize.min, children: children))
            : (content != null ? Text(content) : const SizedBox.shrink()),
    };

    final layoutStyles = {...rawStyles};
    if (typeUpper == 'BUTTON' || typeUpper == 'CARD') {
      layoutStyles.removeWhere(
        (key, _) => key == 'padding' || key.startsWith('padding_'),
      );
    }
    if ([
      'BUTTON',
      'INPUT',
      'TEXTAREA',
      'P',
      'SPAN',
      'TEXT',
    ].contains(typeUpper)) {
      layoutStyles.remove('height');
    }
    return _wrapStyles(context, child, props, layoutStyles, {
      ...rawEvents,
      if (typeUpper == 'BUTTON' || typeUpper == 'DIALOG-CLOSE') 'CLICK': null,
    });
  }

  Widget _buildRowChild(
    BuildContext context,
    Map<String, Object?> node, {
    required bool reserveIntrinsicWidth,
    required bool hasTextSibling,
  }) {
    final child = _buildNode(context, node);
    final key = child.key;
    final type = node['type']?.toString().toUpperCase();
    if (type == 'SPACER') {
      return Expanded(key: key, child: child);
    }
    final styles = <String, Object?>{
      for (final entry in ((node['styles'] as Map?) ?? {}).entries)
        entry.key.toString().replaceAll('-', '_'): entry.value,
    };
    final grow = _toDouble(styles['flex_grow']) ?? 0;
    if (grow > 0) {
      return Expanded(
        key: key,
        flex: (grow * 1000).round().clamp(1, 1000000),
        child: child,
      );
    }
    if (_toDouble(styles['flex_shrink']) == 0 ||
        _toDouble(styles['width']) != null) {
      return child;
    }
    final isInlineBadge =
        type == 'BADGE' &&
        (node['children'] as List?)?.isNotEmpty != true &&
        styles['width'] == null &&
        styles['flex_shrink'] == null;
    final canMeasureContent =
        isInlineBadge ||
        switch (type) {
          'TEXT' ||
          'SPAN' ||
          'P' ||
          'BUTTON' ||
          'IMAGE' ||
          'IMG' ||
          'SVG' => true,
          _ => false,
        };
    if ((reserveIntrinsicWidth && canMeasureContent) ||
        (hasTextSibling && isInlineBadge)) {
      return IntrinsicWidth(key: key, child: child);
    }
    return Flexible(
      key: key,
      flex: reserveIntrinsicWidth ? 1000 : 1,
      child: child,
    );
  }

  Widget _buildOverlay(
    BuildContext context,
    String type,
    List<Map<String, Object?>> nodes,
  ) {
    final trigger = nodes
        .where(
          (n) => n['type'].toString().replaceAll('_', '-').endsWith('TRIGGER'),
        )
        .firstOrNull;
    final content = nodes
        .where(
          (n) => n['type'].toString().replaceAll('_', '-').endsWith('CONTENT'),
        )
        .firstOrNull;
    final label = trigger == null
        ? Text(AppLocalizations.of(context)!.open)
        : _buildNode(context, trigger);
    if (type == 'DIALOG-ROOT') {
      return TextButton(
        onPressed: () => showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            content: SingleChildScrollView(
              child: content == null
                  ? const SizedBox.shrink()
                  : _buildNode(dialogContext, content),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: Text(AppLocalizations.of(context)!.close),
              ),
            ],
          ),
        ),
        child: IgnorePointer(child: label),
      );
    }
    final items =
        (content?['children'] as List?)?.whereType<Map>().toList() ?? [];
    final menuKey = GlobalKey<PopupMenuButtonState<int>>();
    final menu = PopupMenuButton<int>(
      key: menuKey,
      onSelected: (index) {
        final events = items[index]['events'] as Map?;
        final callback = events?['CLICK']?.toString();
        if (callback != null && callback.isNotEmpty) {
          onInvoke(callback, _uiEvent('CLICK'));
        }
      },
      itemBuilder: (_) => [
        for (var i = 0; i < items.length; i++)
          if (items[i]['type'].toString().endsWith('SEPARATOR'))
            const PopupMenuDivider()
          else
            PopupMenuItem(
              value: i,
              enabled:
                  (items[i]['props'] as Map?)?['disabled'] != true &&
                  (items[i]['props'] as Map?)?['disabled'] != 'true',
              child: IgnorePointer(
                child: _buildNode(context, items[i].cast<String, Object?>()),
              ),
            ),
      ],
      child: IgnorePointer(child: label),
    );
    return GestureDetector(
      onSecondaryTap: type == 'CONTEXT-MENU-ROOT'
          ? () => menuKey.currentState?.showButtonMenu()
          : null,
      onLongPress: type == 'CONTEXT-MENU-ROOT'
          ? () => menuKey.currentState?.showButtonMenu()
          : null,
      child: menu,
    );
  }

  Widget _wrapStyles(
    BuildContext context,
    Widget child,
    Map<String, Object?> props,
    Map<String, Object?> styles,
    Map<String, Object?> events,
  ) {
    var result = child;

    // 1. Padding 内部留白
    final padding = _parseEdgeInsets(styles);
    if (padding != EdgeInsets.zero) {
      result = Padding(padding: padding, child: result);
    }

    // 2. Margin 外部间距
    final mgAll = _toDouble(styles['margin']);
    final mgTop = _toDouble(styles['margin_top']) ?? mgAll ?? 0;
    final mgBottom = _toDouble(styles['margin_bottom']) ?? mgAll ?? 0;
    final mgLeft = _toDouble(styles['margin_left']) ?? mgAll ?? 0;
    final mgRight = _toDouble(styles['margin_right']) ?? mgAll ?? 0;
    if (mgTop > 0 || mgBottom > 0 || mgLeft > 0 || mgRight > 0) {
      result = Padding(
        padding: EdgeInsets.only(
          top: mgTop,
          bottom: mgBottom,
          left: mgLeft,
          right: mgRight,
        ),
        child: result,
      );
    }

    // 3. 尺寸约束 (Width, Height)
    final wVal = styles['width'];
    final hVal = styles['height'];
    final width = wVal == '100%' ? double.infinity : _toDouble(wVal);
    final height = hVal == '100%' ? null : _toDouble(hVal);
    if (width != null || height != null) {
      result = SizedBox(width: width, height: height, child: result);
    }

    final minWidth = (_toDouble(styles['min_width']) ?? 0).clamp(
      0.0,
      double.infinity,
    );
    final minHeight = (_toDouble(styles['min_height']) ?? 0).clamp(
      0.0,
      double.infinity,
    );
    final maxWidth = (_toDouble(styles['max_width']) ?? double.infinity).clamp(
      minWidth,
      double.infinity,
    );
    final maxHeight = (_toDouble(styles['max_height']) ?? double.infinity)
        .clamp(minHeight, double.infinity);
    if (minWidth > 0 ||
        minHeight > 0 ||
        maxWidth.isFinite ||
        maxHeight.isFinite) {
      result = ConstrainedBox(
        constraints: BoxConstraints(
          minWidth: minWidth,
          minHeight: minHeight,
          maxWidth: maxWidth,
          maxHeight: maxHeight,
        ),
        child: result,
      );
    }

    // 4. 点击交互事件（若元素自身未消费点击且绑定了 CLICK 事件）
    final clickCallback = events['CLICK']?.toString();
    if (clickCallback != null && clickCallback.isNotEmpty) {
      result = InkWell(
        onTap: () => onInvoke(clickCallback, _uiEvent('CLICK')),
        child: result,
      );
    }

    void emit(String event, [Object? payload]) {
      final callback = events[event]?.toString();
      if (callback != null && callback.isNotEmpty) {
        onInvoke(callback, {'eventType': event, 'payload': payload ?? {}});
      }
    }

    if (events.containsKey('KEY-DOWN') ||
        events.containsKey('KEY-UP') ||
        events.containsKey('FOCUS') ||
        events.containsKey('BLUR')) {
      result = Focus(
        canRequestFocus: props['disabled'] != true,
        onFocusChange: (focused) => emit(focused ? 'FOCUS' : 'BLUR'),
        onKeyEvent: (_, event) {
          final type = event is KeyUpEvent ? 'KEY-UP' : 'KEY-DOWN';
          final key = event.logicalKey;
          emit(type, {
            'key':
                key == LogicalKeyboardKey.enter ||
                    key == LogicalKeyboardKey.numpadEnter
                ? 'Enter'
                : key.keyLabel,
            'repeat': event is KeyRepeatEvent,
            'altKey': HardwareKeyboard.instance.isAltPressed,
            'ctrlKey': HardwareKeyboard.instance.isControlPressed,
            'shiftKey': HardwareKeyboard.instance.isShiftPressed,
            'metaKey': HardwareKeyboard.instance.isMetaPressed,
          });
          return KeyEventResult.ignored;
        },
        child: result,
      );
    }
    if (events.containsKey('MOUSE-ENTER') ||
        events.containsKey('MOUSE-LEAVE') ||
        events.containsKey('HOVER')) {
      result = MouseRegion(
        onEnter: (_) => emit('MOUSE-ENTER'),
        onExit: (_) => emit('MOUSE-LEAVE'),
        onHover: (_) => emit('HOVER'),
        child: result,
      );
    }
    if (events.containsKey('POINTER-DOWN') ||
        events.containsKey('POINTER-UP') ||
        events.containsKey('POINTER-MOVE')) {
      result = Listener(
        onPointerDown: (event) => emit('POINTER-DOWN', {
          'clientX': event.localPosition.dx,
          'clientY': event.localPosition.dy,
          'buttons': event.buttons,
        }),
        onPointerUp: (event) => emit('POINTER-UP', {
          'clientX': event.localPosition.dx,
          'clientY': event.localPosition.dy,
          'buttons': event.buttons,
        }),
        onPointerMove: (event) => emit('POINTER-MOVE', {
          'clientX': event.localPosition.dx,
          'clientY': event.localPosition.dy,
          'buttons': event.buttons,
        }),
        child: result,
      );
    }
    if (events.containsKey('LONG-PRESS')) {
      result = GestureDetector(
        onLongPress: () => emit('LONG-PRESS'),
        child: result,
      );
    }

    // 5. 禁用
    if (props['disabled'] == true || props['disabled'] == 'true') {
      result = AbsorbPointer(child: result);
    }

    return result;
  }
}

double? _toDouble(Object? val) {
  if (val == null) return null;
  if (val is num) return val.toDouble();
  final s = val.toString().replaceAll('px', '').trim();
  return double.tryParse(s);
}

double? _num(Map<String, Object?> props, String key) {
  final v = props[key];
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}

int? _int(Map<String, Object?> props, String key) {
  final v = props[key];
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}

bool _isHidden(Map<String, Object?> node) {
  final visible = (node['props'] as Map?)?['visible'];
  return visible == false ||
      visible == 'false' ||
      (node['styles'] as Map?)?['display'] == 'none';
}

EdgeInsets _parseEdgeInsets(Map<String, Object?> props) {
  final all = _toDouble(props['padding']) ?? 0;
  return EdgeInsets.only(
    top: (_toDouble(props['padding_top']) ?? all).clamp(0, double.infinity),
    bottom: (_toDouble(props['padding_bottom']) ?? all).clamp(
      0,
      double.infinity,
    ),
    left: (_toDouble(props['padding_left']) ?? all).clamp(0, double.infinity),
    right: (_toDouble(props['padding_right']) ?? all).clamp(0, double.infinity),
  );
}

EdgeInsets? _controlPadding(Map<String, Object?> values) =>
    values.keys.any((key) => key == 'padding' || key.startsWith('padding_'))
    ? _parseEdgeInsets(values)
    : null;

Map<String, Object?> _uiEvent(String type, [Object? value]) => {
  'eventType': type,
  'payload': {
    if (value != null) 'value': value,
    if (value is bool) 'checked': value,
  },
};
