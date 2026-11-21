import 'package:material_ui/material_ui.dart';

final appScaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

ScaffoldMessengerState appScaffoldMessengerOf(BuildContext context) {
  for (final messenger in _pageMessengers.reversed) {
    if (messenger.mounted &&
        ModalRoute.of(messenger.context)?.isCurrent == true &&
        TickerMode.valuesOf(messenger.context).enabled) {
      return messenger;
    }
  }
  return appScaffoldMessengerKey.currentState ?? ScaffoldMessenger.of(context);
}

final _pageMessengers = <_OronBoxScaffoldMessengerState>[];

const appSnackBarDuration = Duration(seconds: 2);

/// Applies the app-wide SnackBar duration without requiring every call site to
/// repeat the same value.
class OronBoxScaffoldMessenger extends ScaffoldMessenger {
  const OronBoxScaffoldMessenger({super.key, required super.child});

  @override
  ScaffoldMessengerState createState() => _OronBoxScaffoldMessengerState();
}

class _OronBoxScaffoldMessengerState extends ScaffoldMessengerState {
  String? _lastMessage;
  DateTime? _lastShownTime;
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _currentController;

  @override
  void initState() {
    super.initState();
    _pageMessengers.add(this);
  }

  @override
  void dispose() {
    _pageMessengers.remove(this);
    super.dispose();
  }

  void _resetNotice() {
    _currentController = null;
    _lastMessage = null;
    _lastShownTime = null;
  }

  @override
  void hideCurrentSnackBar({
    SnackBarClosedReason reason = SnackBarClosedReason.hide,
  }) {
    _resetNotice();
    super.hideCurrentSnackBar(reason: reason);
  }

  @override
  void removeCurrentSnackBar({
    SnackBarClosedReason reason = SnackBarClosedReason.remove,
  }) {
    _resetNotice();
    super.removeCurrentSnackBar(reason: reason);
  }

  @override
  void clearSnackBars() {
    _resetNotice();
    super.clearSnackBars();
  }

  String? _extractText(Widget content) {
    if (content is Text) return content.data ?? content.textSpan?.toPlainText();
    return null;
  }

  @override
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showSnackBar(
    SnackBar snackBar, {
    AnimationStyle? snackBarAnimationStyle,
  }) {
    final text = _extractText(snackBar.content);
    final now = DateTime.now();

    if (text != null &&
        _lastMessage == text &&
        _lastShownTime != null &&
        now.difference(_lastShownTime!) < const Duration(seconds: 2) &&
        _currentController != null) {
      return _currentController!;
    }

    // Clear previous queued SnackBars so errors across multiple concurrent
    // requests don't pile up into a long chain of successive notifications.
    clearSnackBars();

    final duration = snackBar.duration > appSnackBarDuration
        ? appSnackBarDuration
        : snackBar.duration;
    final controller = super.showSnackBar(
      SnackBar(
        key: snackBar.key,
        content: snackBar.content,
        backgroundColor: snackBar.backgroundColor,
        elevation: snackBar.elevation,
        margin: snackBar.margin,
        padding: snackBar.padding,
        width: snackBar.width,
        shape: snackBar.shape,
        hitTestBehavior: snackBar.hitTestBehavior,
        behavior: snackBar.behavior,
        action: snackBar.action,
        actionOverflowThreshold: snackBar.actionOverflowThreshold,
        showCloseIcon: snackBar.showCloseIcon,
        closeIconColor: snackBar.closeIconColor,
        duration: duration,
        persist: snackBar.persist,
        animation: snackBar.animation,
        onVisible: snackBar.onVisible,
        dismissDirection: snackBar.dismissDirection,
        clipBehavior: snackBar.clipBehavior,
      ),
      snackBarAnimationStyle: snackBarAnimationStyle,
    );
    _lastMessage = text;
    _lastShownTime = now;
    _currentController = controller;
    controller.closed.whenComplete(() {
      if (identical(_currentController, controller)) {
        _resetNotice();
      }
    });
    return controller;
  }
}
