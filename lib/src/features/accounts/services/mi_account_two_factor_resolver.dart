import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:go_router/go_router.dart';
import 'package:oronbox/src/app/webview/app_webview_session.dart';
import 'package:oronbox/src/core/errors/platform_capability_error.dart';
import 'package:oronbox/src/app/generated/app_localizations.dart';

final _verifications =
    <String, ({AppWebViewSession session, Future<String> result})>{};

Future<String> resolveMiAccountTwoFactor(
  BuildContext context,
  Uri notificationUrl,
) async {
  if (kIsWeb) {
    throw const PlatformCapabilityError(
      'Xiaomi 2FA is not available on web because browser cookie access is isolated',
    );
  }
  if (usesDesktopWebViewWindows) {
    final key = notificationUrl.toString();
    final existing = _verifications[key];
    if (existing != null) {
      await existing.session.initialize(detached: true);
      if (!existing.session.closed) await existing.session.invoke('focus');
      return existing.result;
    }
    final session = AppWebViewSession({
      'url': key,
      'ephemeral': true,
      'title': AppLocalizations.of(context)!.settingsMiAccountTwoFactorTitle,
    });
    final result = _verifyInWindow(
      session,
      notificationUrl,
    ).whenComplete(() => _verifications.remove(key));
    _verifications[key] = (session: session, result: result);
    return result;
  }
  final cookieHeader = await context.push<String>(
    '/accounts/xiaomi/verify',
    extra: notificationUrl,
  );
  if (cookieHeader == null || cookieHeader.trim().isEmpty) {
    throw StateError('Xiaomi 2FA was closed or cancelled');
  }
  return cookieHeader;
}

Future<String> _verifyInWindow(AppWebViewSession session, Uri url) async {
  try {
    await session.initialize(detached: true);
    while (!session.closed) {
      final cookies = <String, String>{};
      for (final target in {
        Uri.parse('https://account.xiaomi.com'),
        Uri.parse('https://mi.com'),
        url,
      }) {
        for (final row
            in await session.invoke('cookies', target.toString()) as List) {
          final cookie = row as Map;
          final name = cookie['name'] as String;
          final value = cookie['value'] as String;
          if (name.isNotEmpty && value.isNotEmpty) cookies[name] = value;
        }
      }
      if (['passToken', 'userId', 'cUserId'].any(cookies.containsKey)) {
        return cookies.entries
            .map((entry) => '${entry.key}=${entry.value}')
            .join('; ');
      }
      await Future.any([
        Future<void>.delayed(const Duration(seconds: 1)),
        session.done,
      ]);
    }
    throw StateError('Xiaomi 2FA was closed or cancelled');
  } finally {
    await session.close();
  }
}
