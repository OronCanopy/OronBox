import 'package:cupertino_ui/cupertino_ui.dart'
    show CupertinoPageTransitionsBuilder;
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

class AppSlidePageTransitionsBuilder extends PageTransitionsBuilder {
  const AppSlidePageTransitionsBuilder();

  @override
  Duration get transitionDuration => const Duration(milliseconds: 350);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 250);

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => _AppSlideTransition(
    route: route,
    animation: animation,
    secondaryAnimation: secondaryAnimation,
    child: child,
  );
}

class _AppSlideTransition extends StatefulWidget {
  const _AppSlideTransition({
    required this.route,
    required this.animation,
    required this.secondaryAnimation,
    required this.child,
  });

  final PageRoute<dynamic> route;
  final Animation<double> animation;
  final Animation<double> secondaryAnimation;
  final Widget child;

  @override
  State<_AppSlideTransition> createState() => _AppSlideTransitionState();
}

class _AppSlideTransitionState extends State<_AppSlideTransition>
    with WidgetsBindingObserver {
  static final Tween<double> _lightScrimTween = Tween<double>(
    begin: 0.0,
    end: 0.14,
  );
  static final Tween<double> _darkScrimTween = Tween<double>(
    begin: 0.0,
    end: 0.22,
  );

  bool _handlingGesture = false;
  late Animation<double> _lightScrimOpacity;
  late Animation<double> _darkScrimOpacity;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _setupScrimAnimation();
  }

  void _setupScrimAnimation() {
    _lightScrimOpacity = widget.secondaryAnimation.drive(_lightScrimTween);
    _darkScrimOpacity = widget.secondaryAnimation.drive(_darkScrimTween);
  }

  @override
  void didUpdateWidget(covariant _AppSlideTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.secondaryAnimation != widget.secondaryAnimation) {
      _setupScrimAnimation();
    }
  }

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) {
    if (backEvent.isButtonEvent ||
        !widget.route.isCurrent ||
        !widget.route.popGestureEnabled ||
        !TickerMode.valuesOf(context).enabled) {
      return false;
    }
    var navigator = widget.route.navigator;
    while (navigator != null) {
      final parentRoute = ModalRoute.of(navigator.context);
      if (parentRoute == null) break;
      if (!parentRoute.isCurrent) return false;
      navigator = parentRoute.navigator;
    }
    _handlingGesture = true;
    widget.route.handleStartBackGesture(progress: 1 - backEvent.progress);
    return true;
  }

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) {
    if (!_handlingGesture) return;
    widget.route.handleUpdateBackGestureProgress(
      progress: 1 - backEvent.progress,
    );
  }

  @override
  void handleCancelBackGesture() {
    if (!_handlingGesture) return;
    _handlingGesture = false;
    widget.route.handleCancelBackGesture();
  }

  @override
  void handleCommitBackGesture() {
    if (!_handlingGesture) return;
    _handlingGesture = false;
    final navigator = widget.route.navigator!;
    // Keep the route's primary, secondary and Hero animations on the same
    // controller progress instead of resetting it on gesture commit.
    var stopped = false;
    void stopGesture(AnimationStatus status) {
      if (stopped ||
          (status != AnimationStatus.dismissed &&
              status != AnimationStatus.completed)) {
        return;
      }
      stopped = true;
      widget.animation.removeStatusListener(stopGesture);
      navigator.didStopUserGesture();
    }

    widget.animation.addStatusListener(stopGesture);
    navigator.pop();
    if (!widget.animation.isAnimating) {
      stopGesture(AnimationStatus.dismissed);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final scrimOpacity = isDark ? _darkScrimOpacity : _lightScrimOpacity;
    return ListenableBuilder(
      listenable: widget.route.navigator!.userGestureInProgressNotifier,
      builder: (context, _) =>
          const CupertinoPageTransitionsBuilder().buildTransitions(
            widget.route,
            context,
            widget.animation,
            widget.secondaryAnimation,
            Stack(
              fit: StackFit.passthrough,
              children: [
                widget.child,
                Positioned.fill(
                  child: IgnorePointer(
                    child: FadeTransition(
                      opacity: scrimOpacity,
                      child: const ColoredBox(color: Colors.black),
                    ),
                  ),
                ),
              ],
            ),
          ),
    );
  }
}
