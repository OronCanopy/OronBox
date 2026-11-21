import 'dart:async';
import 'dart:js_interop';

import 'package:material_ui/material_ui.dart';
import 'package:web/web.dart' as web;
import 'package:oronbox/src/app/generated/app_localizations.dart';
import 'package:oronbox/src/app/widgets/auxiliary_app.dart';

import '../services/bandbbs_browser_authorization.dart';
import '../services/bandbbs_oauth_callback.dart';

class BandBbsBrowserCallbackApp extends StatelessWidget {
  const BandBbsBrowserCallbackApp({super.key});
  @override
  Widget build(BuildContext context) =>
      const AuxiliaryApp(child: _CallbackPage());
}

class _CallbackPage extends StatefulWidget {
  const _CallbackPage();
  @override
  State<_CallbackPage> createState() => _CallbackPageState();
}

class _CallbackPageState extends State<_CallbackPage> {
  late final Uri _uri;
  web.BroadcastChannel? _channel;
  Timer? _retry;
  Timer? _fallback;
  bool _canContinue = false;
  bool? _success;
  DateTime? _lastResponse;

  @override
  void initState() {
    super.initState();
    final initial = Uri.base;
    final id = initial.queryParameters['flow'];
    final key = 'oronbox.oauth.callback.${id ?? 'direct'}';
    final saved = web.window.sessionStorage.getItem(key);
    _uri =
        initial.queryParameters.containsKey('ticket') ||
            initial.queryParameters.containsKey('error')
        ? initial
        : Uri.tryParse(saved ?? '') ?? initial;
    web.window.sessionStorage.setItem(key, _uri.toString());
    final clean = Uri.base.replace(
      queryParameters: Map<String, String>.from(Uri.base.queryParameters)
        ..remove('ticket')
        ..remove('error'),
    );
    web.window.history.replaceState(null, '', clean.toString());
    if (id == null) {
      _canContinue = true;
      return;
    }
    final channel = web.BroadcastChannel('oronbox.oauth.$id');
    _channel = channel;
    channel.onmessage = ((web.MessageEvent event) {
      final raw = event.data.dartify();
      if (raw is! Map || !mounted) return;
      if (raw['type'] == 'accepted') {
        _lastResponse = DateTime.now();
        setState(() {
          _canContinue = false;
        });
      }
      if (raw['type'] == 'completed' && raw['success'] is bool) {
        setState(() {
          _success = raw['success'] as bool;
          _canContinue = false;
        });
        _retry?.cancel();
        _fallback?.cancel();
        channel.postMessage({'type': 'received'}.jsify());
        web.window.sessionStorage.removeItem(key);
        clearBandBbsBrowserCallback();
        if (_success == true) web.window.close();
      }
    }).toJS;
    _send();
    _retry = Timer.periodic(const Duration(milliseconds: 500), (_) => _send());
    _fallback = Timer.periodic(const Duration(seconds: 3), (_) {
      final last = _lastResponse;
      if (mounted &&
          (last == null ||
              DateTime.now().difference(last) >= const Duration(seconds: 3))) {
        setState(() => _canContinue = true);
      }
    });
  }

  void _send() => _channel?.postMessage(
    {'type': 'callback', 'uri': _uri.toString()}.jsify(),
  );

  void _continue() {
    _channel?.postMessage({'type': 'takeover'}.jsify());
    final original = Uri.tryParse(
      web.window.sessionStorage.getItem('oronbox.oauth.return') ?? '',
    );
    final target =
        original != null &&
            (original.scheme == 'http' || original.scheme == 'https') &&
            original.origin == Uri.base.origin
        ? original
        : withoutBandBbsOAuthParameters(Uri.base);
    web.window.sessionStorage.removeItem(
      'oronbox.oauth.callback.${_uri.queryParameters['flow'] ?? 'direct'}',
    );
    web.window.location.replace(
      target
          .replace(
            queryParameters: {
              ...target.queryParameters,
              'oauth': 'bandbbs',
              'oauth_continue': '1',
              if (_uri.queryParameters['ticket'] case final ticket?)
                'ticket': ticket,
              if (_uri.queryParameters['error'] case final error?)
                'error': error,
            },
          )
          .toString(),
    );
  }

  @override
  void dispose() {
    _retry?.cancel();
    _fallback?.cancel();
    _channel?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_success == null && !_canContinue)
                const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(
                _success == true
                    ? l10n.oauthBrowserCompleted
                    : _success == false
                    ? l10n.settingsAccountBandBbsLoginFailed
                    : _canContinue
                    ? l10n.oauthBrowserOriginalClosed
                    : l10n.oauthBrowserCompleting,
              ),
              if (_canContinue)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: FilledButton(
                    onPressed: _continue,
                    child: Text(l10n.oauthBrowserContinue),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
