import 'dart:async';
import 'dart:js_interop';

import 'package:uuid/uuid.dart';
import 'package:web/web.dart' as web;
import 'package:oronbox/src/core/errors/coded_error.dart';

import 'bandbbs_oauth_callback.dart';

final _callbacks = StreamController<Uri>.broadcast(sync: true);
_Authorization? _authorization;

Stream<Uri> get bandBbsBrowserCallbacks => _callbacks.stream;
String? get bandBbsBrowserReturnUri => _authorization?.returnUri.toString();
bool get isBandBbsBrowserCallback =>
    isBandBbsOAuthCallback(Uri.base, webLocation: Uri.base) &&
    Uri.base.queryParameters['oauth_continue'] != '1';

class _BrowserAuthorizationError implements CodedError {
  const _BrowserAuthorizationError(this.code);
  @override
  final String code;
  @override
  String get message => code;
  @override
  Object? get details => null;
  @override
  String toString() => code;
}

void reserveBandBbsAuthorization() {
  if (_authorization case final current?) {
    if (!current.window.closed) {
      current.window.focus();
      return;
    }
    current.dispose();
  }
  final id = const Uuid().v4();
  final window = web.window.open('about:blank', 'oronbox-auth-$id');
  if (window == null) {
    throw const _BrowserAuthorizationError('oauth_popup_blocked');
  }
  window.opener = null;
  final original = withoutBandBbsOAuthParameters(Uri.base);
  window.sessionStorage.setItem('oronbox.oauth.return', original.toString());
  _authorization = _Authorization(id, window, original);
}

Future<bool> openBandBbsAuthorization(Uri uri) async {
  if (_authorization == null) reserveBandBbsAuthorization();
  _authorization!.window.location.replace(uri.toString());
  return true;
}

void cancelBandBbsAuthorization() {
  final current = _authorization;
  _authorization = null;
  current?.dispose(closeWindow: true);
}

void completeBandBbsBrowserCallback(Uri uri, {required bool success}) {
  final current = _authorization;
  if (current == null || uri.queryParameters['flow'] != current.id) return;
  current.completed = success;
  current.send({'type': 'completed', 'success': success});
}

void clearBandBbsBrowserCallback() {
  final clean = withoutBandBbsOAuthParameters(Uri.base);
  web.window.history.replaceState(null, '', clean.toString());
}

class _Authorization {
  _Authorization(this.id, this.window, Uri original)
    : returnUri = original.replace(
        queryParameters: {
          ...original.queryParameters,
          'oauth': 'bandbbs',
          'flow': id,
        },
        fragment: '',
      ),
      channel = web.BroadcastChannel('oronbox.oauth.$id') {
    channel.onmessage = ((web.MessageEvent event) {
      final raw = event.data.dartify();
      if (raw is! Map) return;
      if (raw['type'] == 'received' || raw['type'] == 'takeover') {
        if (identical(_authorization, this)) _authorization = null;
        dispose();
        return;
      }
      if (raw['type'] != 'callback') return;
      final uri = Uri.tryParse(raw['uri']?.toString() ?? '');
      if (uri == null ||
          !isBandBbsOAuthCallback(uri, webLocation: Uri.base) ||
          uri.queryParameters['flow'] != id) {
        return;
      }
      send({'type': 'accepted'});
      if (completed case final success?) {
        send({'type': 'completed', 'success': success});
      } else if (!_handling) {
        _handling = true;
        _callbacks.add(uri);
      }
    }).toJS;
  }

  final String id;
  final web.Window window;
  final Uri returnUri;
  final web.BroadcastChannel channel;
  bool _handling = false;
  bool? completed;
  bool _disposed = false;

  void send(Map<String, Object?> message) {
    if (!_disposed) channel.postMessage(message.jsify());
  }

  void dispose({bool closeWindow = false}) {
    if (_disposed) return;
    _disposed = true;
    channel.onmessage = null;
    channel.close();
    if (closeWindow && !window.closed) window.close();
  }
}
