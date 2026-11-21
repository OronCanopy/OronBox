import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:oronbox/src/app/utils/picked_file.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late Directory imports;
  setUp(() async {
    imports = await Directory.systemTemp.createTemp('oronbox-picker-');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => imports.path,
    );
  });
  tearDown(() async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    await imports.delete(recursive: true);
  });
  test('consumed picker copies are released and repeated reads use the captured bytes', () async {
    final directory = await Directory('${imports.path}/file_picker/session')
        .create(recursive: true);
    final file = await File('${directory.path}/input').writeAsBytes([1, 2, 3]);
    final picked = PickedFileData(name: 'input', path: file.path);
    expect(await picked.readAsBytes(), [1, 2, 3]);
    expect(await file.exists(), isFalse);
    expect(picked.path, isNull);
    expect(await picked.readAsBytes(), [1, 2, 3]);
    expect(await picked.xFile!.readAsBytes(), [1, 2, 3]);
  });
  test('bounded reads reject oversized memory and file inputs', () async {
    await expectLater(
      PickedFileData(
        name: 'audio.wav',
        bytes: Uint8List(9),
      ).readAsBytes(maxBytes: 8),
      throwsA(isA<PickedFileTooLarge>()),
    );
    final directory = await Directory.systemTemp.createTemp(
      'oronbox-picked-test-',
    );
    try {
      final file = File('${directory.path}/input');
      await file.writeAsBytes(List.filled(100000, 1));
      final input = PickedFileData(name: 'input', path: file.path);
      await expectLater(
        input.readAsBytes(maxBytes: 100),
        throwsA(isA<PickedFileTooLarge>()),
      );
      expect((await input.readAsBytes(maxBytes: 100000))!.length, 100000);
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
