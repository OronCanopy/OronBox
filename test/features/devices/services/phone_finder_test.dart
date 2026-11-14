import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oronbox/src/features/devices/services/phone_finder.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('oronbox/find_phone');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('vibration mode does not request ringtone and stop has no arguments', () async {
    await PhoneFinder.setFinding(true, ring: false);
    await PhoneFinder.setFinding(false);
    expect(calls.map((call) => call.method), ['start', 'stop']);
    expect(calls.first.arguments, {'ring': false});
    expect(calls.last.arguments, isNull);
  });

  test('existing callers retain ringtone playback', () async {
    await PhoneFinder.setFinding(true);
    expect(calls.single.arguments, {'ring': true});
  });

  test('unsupported platform does not invoke Android channel', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    await PhoneFinder.setFinding(true);
    expect(calls, isEmpty);
  });
}
