bool isBandBbsOAuthCallback(Uri uri, {Uri? webLocation}) {
  if (uri.scheme == 'oronbox' &&
      uri.host == 'oauth' &&
      uri.path == '/bandbbs') {
    return true;
  }
  return webLocation != null &&
      (uri.scheme == 'https' || uri.scheme == 'http') &&
      uri.origin == webLocation.origin &&
      uri.queryParameters['oauth'] == 'bandbbs';
}

Uri withoutBandBbsOAuthParameters(Uri uri) => uri.replace(
  queryParameters: Map<String, String>.from(uri.queryParameters)
    ..remove('oauth')
    ..remove('ticket')
    ..remove('error')
    ..remove('flow')
    ..remove('oauth_continue'),
);
