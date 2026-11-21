import 'package:url_launcher/url_launcher.dart';

void reserveBandBbsAuthorization() {}
void cancelBandBbsAuthorization() {}
String? get bandBbsBrowserReturnUri => null;
Stream<Uri> get bandBbsBrowserCallbacks => const Stream.empty();
bool get isBandBbsBrowserCallback => false;
void completeBandBbsBrowserCallback(Uri uri, {required bool success}) {}
void clearBandBbsBrowserCallback() {}

Future<bool> openBandBbsAuthorization(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);
