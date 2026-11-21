import 'dart:typed_data';

import 'package:oronbox/src/core/wasm/wasm_runtime.dart';

final class WasmOpusDecoder {
  WasmOpusDecoder._(
    this._scope,
    this._instance,
    this._memory,
    this._decoderPointer,
    this._mappingPointer,
    this._inputPointer,
    this._outputPointer,
    this._inputCapacity,
    this._sampleRate,
  );

  static const _assetPath = 'assets/wasm/opus_frame_decoder.wasm';
  static const _outputCapacity = 5760;
  static const _initialInputCapacity = 4096;

  final WasmScope _scope;
  final ScopedWasmInstance _instance;
  final WasmMemoryView _memory;
  int _decoderPointer;
  final int _sampleRate;
  final int _mappingPointer;
  int _inputPointer;
  final int _outputPointer;
  int _inputCapacity;
  bool _disposed = false;

  static Future<WasmOpusDecoder> create({
    int sampleRate = 16000,
    int channels = 1,
  }) async {
    if (channels != 1) {
      throw ArgumentError.value(channels, 'channels', 'only mono is supported');
    }

    final scope = WasmRuntime.shared.openScope('system.opus-decoder');
    try {
      final instance = await scope.instantiateAsset(_assetPath);
      final memory = instance.memory();

      final mappingPointer = _intResult(instance.call('opus_alloc', [channels]));
      final inputPointer = _intResult(instance.call('opus_alloc', [_initialInputCapacity]));
      final outputPointer = _intResult(
        instance.call('opus_alloc', [_outputCapacity * channels * Float32List.bytesPerElement]),
      );
      if (mappingPointer == 0 || inputPointer == 0 || outputPointer == 0) {
        throw StateError('libopus WASM memory allocation failed');
      }
      memory.write(mappingPointer, Uint8List(1));

      final decoderPointer = _intResult(
        instance.call('opus_decoder_create', [
          sampleRate,
          channels,
          1,
          0,
          mappingPointer,
          0,
          0,
        ]),
      );
      if (decoderPointer == 0) {
        throw StateError('libopus WASM decoder creation failed');
      }

      return WasmOpusDecoder._(
        scope,
        instance,
        memory,
        decoderPointer,
        mappingPointer,
        inputPointer,
        outputPointer,
        _initialInputCapacity,
        sampleRate,
      );
    } catch (_) {
      scope.dispose();
      rethrow;
    }
  }

  Float32List decode(Uint8List packet) {
    _ensureActive();
    if (packet.isEmpty) return Float32List(0);
    _ensureInputCapacity(packet.length);

    _memory.write(_inputPointer, packet);
    final samples = _intResult(
      _instance.call('opus_decode_float', [
        _decoderPointer,
        _inputPointer,
        packet.length,
        _outputPointer,
      ]),
    );
    if (samples < 0) {
      throw StateError(_opusError(samples));
    }
    if (samples > _outputCapacity) {
      throw StateError('libopus returned too many samples: $samples');
    }

    final bytes = _memory.read(
      _outputPointer,
      samples * Float32List.bytesPerElement,
    );
    return Float32List.sublistView(
      ByteData.sublistView(bytes),
    );
  }

  void reset() {
    _ensureActive();
    _instance.call('opus_decoder_destroy', [_decoderPointer]);
    _instance.call('opus_free', [_decoderPointer]);
    _decoderPointer = _intResult(
      _instance.call('opus_decoder_create', [_sampleRate, 1, 1, 0, _mappingPointer, 0, 0]),
    );
    if (_decoderPointer == 0) {
      throw StateError('libopus WASM decoder reset failed');
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    try {
      _instance.call('opus_decoder_destroy', [_decoderPointer]);
      _instance.call('opus_free', [_decoderPointer]);
      _instance.call('opus_free', [_mappingPointer]);
      _instance.call('opus_free', [_inputPointer]);
      _instance.call('opus_free', [_outputPointer]);
    } finally {
      _scope.dispose();
    }
  }

  void _ensureInputCapacity(int required) {
    if (required <= _inputCapacity) return;
    final replacement = _intResult(_instance.call('opus_alloc', [required]));
    if (replacement == 0) {
      throw StateError('libopus WASM input allocation failed');
    }
    _instance.call('opus_free', [_inputPointer]);
    _inputPointer = replacement;
    _inputCapacity = required;
  }

  void _ensureActive() {
    if (_disposed) throw StateError('Opus decoder is disposed');
  }

  static int _intResult(List<int> result) {
    if (result.isEmpty) {
      throw StateError('Unexpected empty WASM result');
    }
    return result.first;
  }

  static String _opusError(int code) => switch (code) {
    -1 => 'libopus: invalid argument',
    -2 => 'libopus: output buffer too small',
    -3 => 'libopus: internal error',
    -4 => 'libopus: invalid packet',
    -5 => 'libopus: unimplemented operation',
    -6 => 'libopus: invalid state',
    -7 => 'libopus: allocation failed',
    _ => 'libopus: unknown error $code',
  };
}
