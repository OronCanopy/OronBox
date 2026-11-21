import 'package:flutter_test/flutter_test.dart';
import 'package:oronbox/src/features/resources/services/watchface_payload_repair.dart';

void main() {
  group('isZeroVelaWatchfaceId', () {
    test('detects an all-zero id field at 0x28', () {
      expect(isZeroVelaWatchfaceId(List.filled(0x28 + 64, 0)), isTrue);
    });

    test('detects ascii zero characters as a zero id', () {
      expect(
        isZeroVelaWatchfaceId([
          ...List.filled(0x28, 0xAA),
          ...List.filled(63, 0x30),
          0,
        ]),
        isTrue,
      );
    });

    test('is false for a real id', () {
      expect(
        isZeroVelaWatchfaceId([
          ...List.filled(0x28, 0xAA),
          49,
          50,
          51,
          ...List.filled(61, 0),
        ]),
        isFalse,
      );
    });

    test('is false for a truncated payload', () {
      expect(isZeroVelaWatchfaceId(List.filled(0x28, 0)), isFalse);
    });
  });

  group('replaceVelaWatchfaceId', () {
    test('refuses to patch a payload shorter than the id field', () {
      expect(
        replaceVelaWatchfaceId(List.filled(0x28, 0), '123456789012'),
        isNull,
      );
    });

    test('writes a long id and leaves the title intact', () {
      final bytes = [...List.filled(0x68, 0), 0xAA, 0xBB, 0xCC, 0xDD];
      final result = replaceVelaWatchfaceId(bytes, 'canopus_manager')!;
      expect(result.sublist(0x28, 0x37), 'canopus_manager'.codeUnits);
      expect(result.sublist(0x37, 0x68), everyElement(0));
      expect(result.sublist(0x68), bytes.sublist(0x68));
      expect(replaceVelaWatchfaceId(bytes, 'a' * 64), isNull);
    });
  });
}
