import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:go_router/go_router.dart';
import 'package:oronbox/src/app/generated/app_localizations.dart';
import 'package:oronbox/src/app/router/close_root_page.dart';
import 'package:oronbox/src/app/webview/app_webview_page.dart';
import 'package:oronbox/src/app/webview/app_webview_session.dart';
import 'package:oronbox/src/core/logging/logging_service.dart';

class MiAccountTwoFactorPage extends StatefulWidget {
  const MiAccountTwoFactorPage({super.key, required this.initialUrl});
  final Uri initialUrl;

  @override
  State<MiAccountTwoFactorPage> createState() => _MiAccountTwoFactorPageState();
}

class _MiAccountTwoFactorPageState extends State<MiAccountTwoFactorPage> {
  late AppWebViewSession _session;
  Future<void>? _opening;
  Future<void>? _checking;
  StreamSubscription<Map<String, Object?>>? _events;
  Timer? _pollTimer;
  bool _completed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_opening != null) return;
    _session = AppWebViewSession({
      'url': widget.initialUrl.toString(),
      'title': AppLocalizations.of(context)!.settingsMiAccountTwoFactorTitle,
      'ephemeral': true,
    });
    _events = _session.events.listen((event) {
      if (event['type'] == 'loaded') unawaited(_checkCookies());
    });
    _opening = _session.initialize().catchError((Object _) {});
    _pollTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _checkCookies(),
    );
  }

  Future<void> _checkCookies() {
    if (_completed || !mounted || !_session.ready) return Future.value();
    return _checking ??= _readCookies().whenComplete(() => _checking = null);
  }

  Future<void> _readCookies() async {
    final cookies = <String, String>{};
    try {
      for (final uri in {
        Uri.parse('https://account.xiaomi.com'),
        Uri.parse('https://mi.com'),
        widget.initialUrl,
      }) {
        for (final row
            in await _session.invoke('cookies', uri.toString()) as List) {
          final cookie = row as Map;
          final name = cookie['name'] as String;
          final value = cookie['value'] as String;
          if (name.isNotEmpty && value.isNotEmpty) cookies[name] = value;
        }
        if (!mounted || _completed) return;
      }
    } catch (error, stack) {
      getLogger('MiAccountTwoFactor').fine('Cookie read failed', error, stack);
      return;
    }
    if (!['passToken', 'userId', 'cUserId'].any(cookies.containsKey)) return;
    _completed = true;
    _pollTimer?.cancel();
    final header = cookies.entries
        .map((entry) => '${entry.key}=${entry.value}')
        .join('; ');
    await closeRootPage(
      GoRouter.of(context),
      ModalRoute.of(context)! as TransitionRoute<dynamic>,
      header,
    );
  }

  Future<void> _close() async {
    await _opening;
    await _checking;
    await _session.close();
    await _events?.cancel();
  }

  @override
  void dispose() {
    _completed = true;
    _pollTimer?.cancel();
    unawaited(
      _close().catchError((Object error, StackTrace stack) {
        getLogger('MiAccountTwoFactor')
            .warning('Session close failed', error, stack);
      }),
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppWebViewPage(session: _session);
}
