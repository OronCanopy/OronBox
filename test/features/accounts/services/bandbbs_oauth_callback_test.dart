import 'package:flutter_test/flutter_test.dart';
import 'package:oronbox/src/features/accounts/services/bandbbs_oauth_callback.dart';

void main() {
  test(
    'accepts native and same-origin web callbacks with the OAuth marker',
    () {
      final location = Uri.parse('https://oronbox.test/app/');
      expect(
        isBandBbsOAuthCallback(
          Uri.parse('oronbox://oauth/bandbbs?ticket=test'),
        ),
        isTrue,
      );
      expect(
        isBandBbsOAuthCallback(
          Uri.parse('https://oronbox.test/app/?oauth=bandbbs&ticket=test'),
          webLocation: location,
        ),
        isTrue,
      );
      for (final value in [
        'https://other.test/?oauth=bandbbs&ticket=test',
        'https://oronbox.test:8443/?oauth=bandbbs&ticket=test',
        'http://oronbox.test/?oauth=bandbbs&ticket=test',
        'https://oronbox.test/?ticket=test',
        'oronbox://oauth/other?ticket=test',
      ]) {
        expect(
          isBandBbsOAuthCallback(Uri.parse(value), webLocation: location),
          isFalse,
          reason: value,
        );
      }
      expect(
        isBandBbsOAuthCallback(
          Uri.parse('https://oronbox.test/?oauth=bandbbs'),
        ),
        isFalse,
      );
    },
  );

  test(
    'callback cleanup preserves application route and unrelated parameters',
    () {
      final uri = Uri.parse(
        'https://oronbox.test/app/?source=community&oauth=bandbbs&flow=test&ticket=secret&oauth_continue=1#/settings/accounts',
      );
      final clean = withoutBandBbsOAuthParameters(uri);
      expect(clean.path, '/app/');
      expect(clean.fragment, '/settings/accounts');
      expect(clean.queryParameters, {'source': 'community'});
      expect(clean.toString(), isNot(contains('secret')));
    },
  );
}
