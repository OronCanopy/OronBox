@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web/web.dart' as web;
import 'package:oronbox/src/core/services/shared_prefs_service.dart';
import 'package:oronbox/src/features/accounts/pages/bandbbs_browser_callback_app.dart';
import 'package:oronbox/src/features/accounts/services/bandbbs_browser_authorization.dart';

void main() {
  tearDown(cancelBandBbsAuthorization);

  test(
    'authorization hands a ticket to the original page exactly once',
    () async {
      final original = Uri.base;
      reserveBandBbsAuthorization();
      final callback = Uri.parse(bandBbsBrowserReturnUri!);
      final id = callback.queryParameters['flow']!;
      final peer = web.BroadcastChannel('oronbox.oauth.$id');
      addTearDown(() => peer.close());
      final messages = <Map>[];
      final completed = Completer<void>();
      peer.onmessage = ((web.MessageEvent event) {
        final message = event.data.dartify() as Map;
        messages.add(message);
        if (message['type'] == 'completed' && !completed.isCompleted) {
          completed.complete();
        }
      }).toJS;
      final delivered = <Uri>[];
      final first = Completer<Uri>();
      final subscription = bandBbsBrowserCallbacks.listen((uri) {
        delivered.add(uri);
        if (!first.isCompleted) first.complete(uri);
      });
      addTearDown(subscription.cancel);
      final uri = callback.replace(
        queryParameters: {
          ...callback.queryParameters,
          'ticket': 'one-time-test-ticket',
        },
      );
      peer.postMessage(
        {
          'type': 'callback',
          'uri': 'https://other.test/?oauth=bandbbs&flow=$id&ticket=wrong',
        }.jsify(),
      );
      peer.postMessage({'type': 'callback', 'uri': uri.toString()}.jsify());
      expect(await first.future.timeout(const Duration(seconds: 3)), uri);
      peer.postMessage({'type': 'callback', 'uri': uri.toString()}.jsify());
      completeBandBbsBrowserCallback(uri, success: true);
      await completed.future.timeout(const Duration(seconds: 3));
      expect(delivered, [uri]);
      expect(
        messages
            .where((message) => message['type'] == 'completed')
            .first['success'],
        isTrue,
      );
      expect(Uri.base, original);
    },
  );

  testWidgets('callback page offers continuation when the original is absent', (
    tester,
  ) async {
    // Let the browser attach the test root before mounting the callback page.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    SharedPreferences.setMockInitialValues({});
    await SharedPrefsService.instance.init();
    final original = Uri.base;
    final callback = original.replace(
      queryParameters: {
        'oauth': 'bandbbs',
        'flow': 'missing-original',
        'ticket': 'test-ticket',
      },
    );
    addTearDown(() {
      web.window.history.replaceState(null, '', original.toString());
      web.window.sessionStorage.removeItem(
        'oronbox.oauth.callback.missing-original',
      );
    });
    web.window.history.replaceState(null, '', callback.toString());
    await tester.pumpWidget(
      const ProviderScope(child: BandBbsBrowserCallbackApp()),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    await tester.pump();
    expect(find.byType(FilledButton), findsOneWidget);
    expect(Uri.base.queryParameters.containsKey('ticket'), isFalse);
    expect(
      web.window.sessionStorage.getItem(
        'oronbox.oauth.callback.missing-original',
      ),
      contains('test-ticket'),
    );
    await tester.pumpWidget(const SizedBox());
  });
}
