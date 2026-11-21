import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:oronbox/src/core/wasm/wasm_opus_decoder.dart';
import 'package:oronbox/src/core/wasm/wasm_runtime.dart';
import 'package:oronbox/src/core/wasm/wasm_compilation_cache.dart';
import 'package:wasm_abp/wasm_abp.dart';
import 'package:oronbox/src/features/resources/services/resource_image_processor.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  test('indexed PNG pixels are expanded to RGBA before WebP encoding', () {
    final palette = img.PaletteUint8(2, 4)
      ..setRgba(0, 12, 34, 56, 255)
      ..setRgba(1, 210, 180, 90, 128);
    final indexed =
        img.Image(
            width: 2,
            height: 1,
            numChannels: 1,
            withPalette: true,
            palette: palette,
          )
          ..setPixelIndex(0, 0, 0)
          ..setPixelIndex(1, 0, 1);
    final decoded = img.decodePng(img.encodePng(indexed));
    expect(decoded, isNotNull);

    expect(
      materializeResourceImageRgba(decoded!),
      Uint8List.fromList([12, 34, 56, 255, 210, 180, 90, 128]),
    );
  });

  test(
    'resource image processing starts its worker, caches and encodes WebP',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'oronbox-webp-worker-',
      );
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (_) async => root.path,
      );
      addTearDown(() async {
        WasmAbpEngine.shared.configureCache(null);
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
        await root.delete(recursive: true);
      });
      final source = img.Image(width: 16, height: 8, numChannels: 4);
      img.fill(source, color: img.ColorRgba8(200, 80, 40, 255));
      final png = Uint8List.fromList(img.encodePng(source));
      for (var request = 0; request < 2; request++) {
        final result = await processResourceImage(png, maxDimension: 8);
        expect(result, isNotNull);
        expect(result!.width, 8);
        expect(result.height, 4);
        expect(String.fromCharCodes(result.bytes.sublist(0, 4)), 'RIFF');
        expect(String.fromCharCodes(result.bytes.sublist(8, 12)), 'WEBP');
        final decoded = img.decodeWebP(result.bytes);
        expect(decoded, isNotNull);
        expect(decoded!.width, 8);
        expect(decoded.height, 4);
      }
      final compiled = Directory.fromUri(root.uri.resolve('wasm/compiled/'));
      expect(
        await compiled
            .list(recursive: true)
            .where((file) => file.path.endsWith('.cwasm'))
            .toList(),
        hasLength(1),
      );
      await WasmCompilationCache.clear();
      expect(await compiled.exists(), isFalse);
      final afterClearing = await processResourceImage(png, maxDimension: 8);
      expect(afterClearing!.width, 8);
      expect(img.decodeWebP(afterClearing.bytes)!.height, 4);
      expect(await compiled.exists(), isFalse);
    },
  );

  test('libwebp wasm encodes RGBA into a valid WebP payload', () async {
    final bytes = await File('assets/wasm/webp_encoder.wasm').readAsBytes();
    final scope = WasmRuntime.shared.openScope('test.webp-encoder');
    addTearDown(scope.dispose);
    final instance = await scope.instantiate(bytes);
    final memory = instance.memory('memory');

    const width = 8, height = 8;
    final rgba = Uint8List(width * height * 4);
    for (var i = 0; i < rgba.length; i += 4) {
      rgba[i] = 200;
      rgba[i + 1] = 80;
      rgba[i + 2] = 40;
      rgba[i + 3] = 255;
    }
    int intResult(List<int> results) => results.first;

    final input = intResult(instance.call('webp_alloc', [rgba.length]));
    expect(input, isNonZero);
    memory.write(input, rgba);
    final size = intResult(
      instance.call('webp_encode_rgba', [input, width, height, 75]),
    );
    expect(size, greaterThan(0));
    final output = intResult(instance.call('webp_get_output'));
    final webp = memory.read(output, size);
    // RIFF....WEBP container magic
    expect(String.fromCharCodes(webp.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(webp.sublist(8, 12)), 'WEBP');
  });

  test('runtime executes a minimal module and releases its scope', () async {
    final scope = WasmRuntime.shared.openScope('test.minimum');
    final module = Uint8List.fromList([
      0,
      97,
      115,
      109,
      1,
      0,
      0,
      0,
      1,
      5,
      1,
      96,
      0,
      1,
      127,
      3,
      2,
      1,
      0,
      7,
      10,
      1,
      6,
      97,
      110,
      115,
      119,
      101,
      114,
      0,
      0,
      10,
      6,
      1,
      4,
      0,
      65,
      42,
      11,
    ]);
    final instance = await scope.instantiate(module);
    expect(instance.call('answer'), [42]);
    scope.dispose();
    expect(() => instance.call('answer'), throwsStateError);
  });

  test(
    'Opus module decodes a silence packet and releases its instance',
    () async {
      final decoder = await WasmOpusDecoder.create();
      final pcm = decoder.decode(Uint8List.fromList([0xf8, 0xff, 0xfe]));
      expect(pcm, isNotEmpty);
      expect(pcm.every((sample) => sample.isFinite), isTrue);
      for (var session = 0; session < 16; session++) {
        decoder.reset();
        final restarted = decoder.decode(
          Uint8List.fromList([0xf8, 0xff, 0xfe]),
        );
        expect(restarted.length, pcm.length);
        expect(restarted.every((sample) => sample.isFinite), isTrue);
      }
      decoder.dispose();
      expect(() => decoder.reset(), throwsStateError);
      expect(() => decoder.decode(Uint8List(1)), throwsStateError);
    },
  );
}
