import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:oronbox/src/core/wasm/wasm_runtime.dart';
import 'package:oronbox/src/core/wasm/wasm_unsupported_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    WasmRuntime.setPlatformSupportedForTesting(null);
    resetWasmUnsupportedAlertSilencedForTesting();
  });

  group('WasmRuntime platform guard', () {
    test('intercepts compile when platform is unsupported', () async {
      WasmRuntime.setPlatformSupportedForTesting(false);
      expect(WasmRuntime.isPlatformSupported, isFalse);

      final scope = WasmRuntime.shared.openScope('test.unsupported');
      expect(
        () => scope.instantiate(Uint8List.fromList([0x00, 0x61, 0x73, 0x6d])),
        throwsA(isA<WasmUnsupportedPlatformException>()),
      );
    });

    test('allows compile when platform is supported', () {
      WasmRuntime.setPlatformSupportedForTesting(true);
      expect(WasmRuntime.isPlatformSupported, isTrue);
    });

    test('WasmUnsupportedPlatformException toString includes message', () {
      const exception = WasmUnsupportedPlatformException('custom message');
      expect(exception.toString(), contains('custom message'));
    });

    test('session silencing flag can be queried and reset', () {
      expect(isWasmUnsupportedAlertSilenced, isFalse);
      resetWasmUnsupportedAlertSilencedForTesting();
      expect(isWasmUnsupportedAlertSilenced, isFalse);
    });
  });
}
