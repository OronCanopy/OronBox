import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

/// Removes an owned root page without popping pages opened above it.
Future<void> closeRootPage(
  GoRouter router,
  TransitionRoute<dynamic> route, [
  Object? result,
]) async {
  if (route.isActive) {
    final page = route.settings as Page<Object?>;
    final configuration = router.routerDelegate.currentConfiguration;
    final matches = configuration.matches;
    final owned = matches.where((match) => match.pageKey == page.key);
    if (owned.isNotEmpty) {
      final match = owned.single;
      router.restore(
        RouteMatchList(
          matches: matches.where((item) => item != match).toList(),
          uri: configuration.uri,
          pathParameters: configuration.pathParameters,
          extra: configuration.extra,
          error: configuration.error,
        ),
      );
      if (match is ImperativeRouteMatch) match.complete(result);
    }
  }
  await route.completed;
}
