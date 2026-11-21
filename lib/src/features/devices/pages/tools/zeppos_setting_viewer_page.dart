import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:go_router/go_router.dart';
import 'package:oronbox/src/app/webview/app_webview_session.dart';
import 'package:oronbox/src/app/webview/app_webview_page.dart';
import 'package:oronbox/src/app/widgets/app_state_view.dart';
import 'package:oronbox/src/app/generated/app_localizations.dart';
import 'package:oronbox/src/app/utils/error_localization.dart';
import 'package:oronbox/src/app/widgets/sys_app_bar.dart';
import 'package:oronbox/src/features/devices/services/zeppos_app_settings_session.dart';

final _settingsWindows = <int, ZeppOsAppSettingsSession>{};

Future<void> showZeppOsAppSettings(
  BuildContext context, {
  required int appId,
  required String title,
}) async {
  if (usesDesktopWebViewWindows) {
    final existing = _settingsWindows[appId];
    if (existing != null) {
      await existing.initialize(detached: true, title: title);
      if (existing.browser?.closed == false) {
        await existing.browser!.invoke('focus');
      }
      return;
    }
    final session = ZeppOsAppSettingsSession(appId);
    _settingsWindows[appId] = session;
    try {
      await session.initialize(detached: true, title: title);
      await session.browser!.done;
    } finally {
      await session.close();
      if (identical(_settingsWindows[appId], session)) {
        _settingsWindows.remove(appId);
      }
    }
    return;
  }
  final location = Uri(
    path: '/devices/apps/settings/$appId',
    queryParameters: title.isEmpty ? null : {'title': title},
  ).toString();
  await context.push<void>(location);
}

class ZeppOsSettingViewerPage extends StatefulWidget {
  const ZeppOsSettingViewerPage({
    required this.appId,
    required this.title,
    super.key,
  });

  final int appId;
  final String title;

  @override
  State<ZeppOsSettingViewerPage> createState() =>
      _ZeppOsSettingViewerPageState();
}

class _ZeppOsSettingViewerPageState extends State<ZeppOsSettingViewerPage> {
  Object? _error;
  late ZeppOsAppSettingsSession _session;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _session = ZeppOsAppSettingsSession(widget.appId);
    unawaited(_open());
  }

  Future<void> _open() async {
    try {
      await _session.initialize(
        title: widget.title,
        onLoadError: (error) {
          if (mounted) setState(() => _error = error);
        },
      );
      if (mounted) setState(() => _ready = true);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  @override
  void dispose() {
    unawaited(_session.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _ready && _error == null
      ? AppWebViewPage(session: _session.browser!)
      : Scaffold(
          appBar: SysAppBar(secondary: true, title: Text(widget.title)),
          body: _error != null
              ? ErrorStateView(
                  message: localizedErrorMessage(
                    AppLocalizations.of(context)!,
                    _error,
                  ),
                  retryLabel: AppLocalizations.of(context)!.retry,
                  onRetry: () async {
                    await _session.close();
                    if (!mounted) return;
                    setState(() {
                      _error = null;
                      _ready = false;
                    });
                    _session = ZeppOsAppSettingsSession(widget.appId);
                    await _open();
                  },
                )
              : const Center(child: CircularProgressIndicator()),
        );
}
