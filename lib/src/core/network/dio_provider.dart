import 'dart:async';

import 'package:dio/dio.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:oronbox/src/app/generated/app_localizations.dart';
import 'package:oronbox/src/app/widgets/app_scaffold_messenger.dart';
import 'package:oronbox/src/core/network/app_http_transport.dart';
import 'package:oronbox/src/core/network/github_cdn.dart';
import 'package:oronbox/src/core/providers/app_settings_providers.dart';

final appDioProvider = Provider<Dio>((ref) {
  GitHubCdn? sessionFallback;
  GitHubCdn? lastNotifiedFallback;
  DateTime? lastNotifiedAt;

  ref.listen(appSettingsProvider.select((settings) => settings.cdn), (
    previous,
    next,
  ) {
    if (previous != next) {
      sessionFallback = null;
      lastNotifiedFallback = null;
      lastNotifiedAt = null;
    }
  });

  return createAppHttpTransport(
    githubCdn: () {
      final settings = ref.read(appSettingsProvider);
      if (settings.cdn == GitHubCdn.auto) {
        return settings.effectiveCdn;
      }
      return sessionFallback ?? settings.effectiveCdn;
    },
    onGithubCdnFallback: (fallback) {
      final settings = ref.read(appSettingsProvider);
      if (settings.cdn == GitHubCdn.auto && settings.effectiveCdn != fallback) {
        unawaited(
          ref.read(appSettingsProvider.notifier).setEffectiveCdn(fallback),
        );
      }
      sessionFallback = fallback;

      final now = DateTime.now();
      final recentlyNotified =
          lastNotifiedFallback == fallback &&
          lastNotifiedAt != null &&
          now.difference(lastNotifiedAt!) < const Duration(seconds: 5);
      if (recentlyNotified) return;
      lastNotifiedFallback = fallback;
      lastNotifiedAt = now;

      final context = appScaffoldMessengerKey.currentContext;
      if (context == null) return;
      final messenger = appScaffoldMessengerOf(context);
      final l10n = AppLocalizations.of(context);
      if (l10n == null) return;
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.githubCdnFallback(fallback.displayName))),
      );
    },
  );
});
