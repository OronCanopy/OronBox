import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:image/image.dart' as image;

import 'wasm_compatibility.dart';
import 'wasm_compilation_cache.dart';
import 'wasm_webp_encoder.dart';

/// Exercises native compilation and execution using an image shipped with the app.
Future<void> testWasmCompatibility({
  WasmCompatibility? compatibility,
}) => (compatibility ?? WasmCompatibility.shared).test(() async {
  final cache = await WasmCompilationCache.prepare();
  final source = await rootBundle.load('assets/images/app_icon.png');
  final wasm = await rootBundle.load(WasmWebpEncoder.assetPath);
  await Isolate.run(() async {
    WasmCompilationCache.inheritConfiguration(cache);
    final decoded = image.decodePng(
      source.buffer.asUint8List(source.offsetInBytes, source.lengthInBytes),
    );
    if (decoded == null) throw StateError('Invalid compatibility test image');
    // A small image keeps the compatibility test quick on older phones.
    final resized = image.copyResize(decoded, width: 64);
    final rgba = resized
        .convert(format: image.Format.uint8, numChannels: 4, withPalette: false)
        .getBytes(order: image.ChannelOrder.rgba);
    final encoder = await WasmWebpEncoder.fromBytes(
      wasm.buffer.asUint8List(wasm.offsetInBytes, wasm.lengthInBytes),
    );
    try {
      final encoded = encoder.encode(rgba, resized.width, resized.height);
      final result = encoded == null ? null : image.decodeWebP(encoded);
      if (result == null ||
          result.width != resized.width ||
          result.height != resized.height) {
        throw StateError(
          'WebAssembly compatibility test produced invalid WebP',
        );
      }
    } finally {
      encoder.dispose();
    }
  });
});
