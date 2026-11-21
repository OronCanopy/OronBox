import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:webview_all/webview_all.dart';
import 'package:oronbox/src/app/generated/app_localizations.dart';
import 'package:oronbox/src/app/utils/error_localization.dart';
import 'package:oronbox/src/app/widgets/app_state_view.dart';
import 'package:oronbox/src/app/widgets/sys_app_bar.dart';

import 'app_webview_session.dart';

class AppWebViewPage extends StatefulWidget {
  const AppWebViewPage({super.key, required this.session, this.window = false});

  final AppWebViewSession session;
  final bool window;

  @override
  State<AppWebViewPage> createState() => _AppWebViewPageState();
}

class _AppWebViewPageState extends State<AppWebViewPage> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final session = widget.session;
    if (!widget.window) {
      session.router = GoRouter.of(context);
      session.route = ModalRoute.of(context)! as TransitionRoute<dynamic>;
    }
    if (!session.attached.isCompleted) session.attached.complete();
  }

  @override
  void dispose() {
    widget.session.route = null;
    widget.session.markClosed();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.session,
    builder: (context, _) {
      final session = widget.session;
      final l10n = AppLocalizations.of(context)!;
      return Scaffold(
        appBar: SysAppBar(
          secondary: !widget.window,
          fullWindow: true,
          title: Text(session.options['title']?.toString() ?? l10n.pluginsTab),
        ),
        body: session.closed
            ? const SizedBox.shrink()
            : session.error != null
            ? ErrorStateView(
                message: localizedErrorMessage(l10n, session.error),
                retryLabel: l10n.retry,
                onRetry: () async {
                  try {
                    await session.retry();
                  } catch (error) {
                    session.receiveEvent({
                      'type': 'error',
                      'message': error.toString(),
                    });
                  }
                },
              )
            : !session.ready
            ? const Center(child: CircularProgressIndicator())
            : SafeArea(
                top: false,
                child: Column(
                  children: [
                    if (session.progress < 100)
                      LinearProgressIndicator(
                        value: session.progress / 100,
                        minHeight: 2,
                      ),
                    Expanded(
                      child: WebViewWidget(controller: session.controller),
                    ),
                  ],
                ),
              ),
      );
    },
  );
}
