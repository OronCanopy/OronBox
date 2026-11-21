import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oronbox/src/features/settings/application/app_data_inventory.dart';
import 'package:oronbox/src/features/settings/application/app_data_inventory_io.dart';

void main() {
  test('compiled Wasm, plugin files and picker copies are counted in separate categories', () async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    final root = await Directory.systemTemp.createTemp('oronbox-inventory-');
    addTearDown(() => root.delete(recursive: true));
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      final category = switch (call.method) {
        'getApplicationSupportDirectory' => 'support',
        'getApplicationCacheDirectory' => 'cache',
        _ => 'temp',
      };
      return (await Directory('${root.path}/$category').create()).path;
    });
    addTearDown(
      () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    Future<void> write(String path, int bytes) async {
      final file = File('${root.path}/$path');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(List.filled(bytes, 1));
    }

    await write('temp/oronbox/plugins-session/.owner', 5);
    await write('temp/oronbox/plugins-session/.lease', 0);
    expect((await collectFileUsage())[AppDataCategory.cache], 0);

    await write('cache/wasm/compiled/module.cwasm', 10);
    await write('cache/plugins/example/file.bin', 13);
    await write('temp/oronbox/plugins-session/example/file.bin', 17);
    await write('temp/oronbox/plugins-session/example/.owner', 3);
    await write('temp/oronbox/plugins-session/example/.lease', 4);
    await write('temp/file_picker/session/file.bin', 19);
    final usage = await collectFileUsage();
    expect(usage[AppDataCategory.compilation], 10);
    expect(usage[AppDataCategory.cache], 37);
    expect(usage[AppDataCategory.downloads], 19);
  });
}
