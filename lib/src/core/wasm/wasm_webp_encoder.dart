import 'dart:typed_data';

import 'package:oronbox/src/core/wasm/wasm_runtime.dart';

/// libwebp compiled to a freestanding WASM module (zig, see tool/webp_encoder/).
/// Encode failures return null so callers can fall back to PNG.
final class WasmWebpEncoder {
  WasmWebpEncoder._(this._instance, this._memory);

  static const assetPath = 'assets/wasm/webp_encoder.wasm';
  static Future<WasmWebpEncoder>? _shared;

  final ScopedWasmInstance _instance;
  final WasmMemoryView _memory;

  static Future<WasmWebpEncoder> instance() => _shared ??= _create();

  /// Creates an encoder from bytes already loaded by another isolate.
  static Future<WasmWebpEncoder> fromBytes(Uint8List bytes) =>
      _create(bytes: bytes);

  static Future<WasmWebpEncoder> _create({Uint8List? bytes}) async {
    final scope = WasmRuntime.shared.openScope('system.webp-encoder');
    try {
      final instance = bytes == null
          ? await scope.instantiateAsset(assetPath)
          : await scope.instantiate(bytes);
      return WasmWebpEncoder._(instance, instance.memory('memory'));
    } catch (_) {
      scope.dispose();
      rethrow;
    }
  }

  Uint8List? encode(
    Uint8List rgba,
    int width,
    int height, {
    double quality = 75,
  }) {
    final input = _intResult(_instance.call('webp_alloc', [rgba.length]));
    if (input == 0) return null;
    _memory.write(input, rgba);
    final size = _intResult(
      _instance.call('webp_encode_rgba', [
        input,
        width,
        height,
        quality.toInt(),
      ]),
    );
    _instance.call('webp_free', [input]);
    if (size <= 0) return null;
    final output = _intResult(_instance.call('webp_get_output'));
    final bytes = _memory.read(output, size);
    _instance.call('webp_free', [output]);
    return bytes;
  }

  void dispose() => _instance.dispose();

  static int _intResult(List<int> results) {
    return results.firstOrNull ?? 0;
  }
}
