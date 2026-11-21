import 'dart:ui' show lerpDouble;

import 'package:material_ui/material_ui.dart';
import 'package:oronbox/src/app/widgets/network_img_layer.dart';

@immutable
class ResourceMediaHeroStyle {
  const ResourceMediaHeroStyle({
    this.opacity = 1,
    this.borderRadius = BorderRadius.zero,
  });

  final double opacity;
  final BorderRadius borderRadius;

  static ResourceMediaHeroStyle lerp(
    ResourceMediaHeroStyle from,
    ResourceMediaHeroStyle to,
    double t,
  ) => ResourceMediaHeroStyle(
    opacity: lerpDouble(from.opacity, to.opacity, t)!,
    borderRadius: BorderRadius.lerp(from.borderRadius, to.borderRadius, t)!,
  );
}

class ResourceMediaHero extends StatelessWidget {
  const ResourceMediaHero({
    super.key,
    required this.tag,
    required this.url,
    required this.width,
    required this.height,
    required this.style,
    this.fit = BoxFit.cover,
  });

  final Object tag;
  final String url;
  final double width;
  final double height;
  final ResourceMediaHeroStyle style;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) => Hero(
    tag: tag,
    transitionOnUserGestures: true,
    flightShuttleBuilder: _flightShuttleBuilder,
    createRectTween: (begin, end) => _ResourceHeroRectTween(
      begin: begin,
      end: end,
      progress: _PredictiveHeroProgress(context),
    ),
    child: _ResourceMediaEndpoint(
      url: url,
      width: width,
      height: height,
      style: style,
      fit: fit,
    ),
  );

  static Widget _flightShuttleBuilder(
    BuildContext flightContext,
    Animation<double> animation,
    HeroFlightDirection flightDirection,
    BuildContext fromHeroContext,
    BuildContext toHeroContext,
  ) {
    final from = (fromHeroContext.widget as Hero).child;
    final to = (toHeroContext.widget as Hero).child;
    if (from is! _ResourceMediaEndpoint || to is! _ResourceMediaEndpoint) {
      return from;
    }
    final progress = flightDirection == HeroFlightDirection.push
        ? animation
        : ReverseAnimation(animation);
    final gestureProgress = _PredictiveHeroProgress(toHeroContext);
    Widget image(_ResourceMediaEndpoint endpoint) => NetworkImgLayer(
      src: endpoint.url,
      width: double.infinity,
      height: double.infinity,
      fit: endpoint.fit,
      fadeInDuration: Duration.zero,
      fadeOutDuration: Duration.zero,
      borderRadius: BorderRadius.zero,
    );
    final fromImage = image(from);
    final toImage = from.url == to.url && from.fit == to.fit ? null : image(to);
    return InheritedTheme.captureAll(
      fromHeroContext,
      AnimatedBuilder(
        animation: progress,
        child: fromImage,
        builder: (context, child) {
          final value = gestureProgress.transform(progress.value);
          final style = ResourceMediaHeroStyle.lerp(
            from.style,
            to.style,
            value,
          );
          return Opacity(
            opacity: style.opacity,
            child: ClipRRect(
              borderRadius: style.borderRadius,
              child: toImage == null
                  ? child
                  : Stack(
                      fit: StackFit.expand,
                      children: [
                        child!,
                        Opacity(opacity: value, child: toImage),
                      ],
                    ),
            ),
          );
        },
      ),
    );
  }
}

// Flutter restarts its page animation at predictive-back commit. Keep the
// Hero's rectangle and appearance progressing from the last dragged position.
class _PredictiveHeroProgress {
  _PredictiveHeroProgress(BuildContext context)
    : _destination = ModalRoute.of(context),
      _enabled =
          Theme.of(context).platform == TargetPlatform.android &&
          Navigator.of(context).userGestureInProgress;

  final ModalRoute<dynamic>? _destination;
  final bool _enabled;
  double _previous = 0;
  double? _committedFrom;

  double transform(double value) {
    if (_enabled &&
        _committedFrom == null &&
        _destination?.isCurrent == true &&
        value < _previous) {
      _committedFrom = _previous;
    }
    _previous = value;
    final start = _committedFrom;
    return start == null ? value : start + (1 - start) * value;
  }
}

class _ResourceHeroRectTween extends MaterialRectCenterArcTween {
  _ResourceHeroRectTween({super.begin, super.end, required this.progress});

  final _PredictiveHeroProgress progress;

  // Tween.transform bypasses lerp at 0 and 1, including the commit reset.
  @override
  Rect? transform(double t) => super.lerp(progress.transform(t));
}

class _ResourceMediaEndpoint extends StatelessWidget {
  const _ResourceMediaEndpoint({
    required this.url,
    required this.width,
    required this.height,
    required this.style,
    required this.fit,
  });

  final String url;
  final double width;
  final double height;
  final ResourceMediaHeroStyle style;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    height: height,
    child: _ResourceMediaSurface(url: url, style: style, fit: fit),
  );
}

class _ResourceMediaSurface extends StatelessWidget {
  const _ResourceMediaSurface({
    required this.url,
    required this.style,
    required this.fit,
  });

  final String url;
  final ResourceMediaHeroStyle style;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) => Opacity(
    opacity: style.opacity,
    child: ClipRRect(
      clipBehavior: Clip.antiAlias,
      borderRadius: style.borderRadius,
      child: NetworkImgLayer(
        src: url,
        width: double.infinity,
        height: double.infinity,
        fit: fit,
        fadeInDuration: Duration.zero,
        fadeOutDuration: Duration.zero,
        borderRadius: BorderRadius.zero,
      ),
    ),
  );
}
