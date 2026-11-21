import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:oronbox/src/core/wasm/wasm_webp_encoder.dart';
import 'package:oronbox/src/core/wasm/wasm_compatibility.dart';
import 'package:oronbox/src/core/wasm/wasm_compilation_cache.dart';

/// The canonical dimensions used by creator media.
const creatorIconMaxDimension = 256;
const creatorMediaMaxDimension = 1500;

// A source image above this size is almost certainly an accidental upload or
// an image that would create an unsafe temporary allocation before resizing.
const _maxSourcePixels = 24 * 1000 * 1000;
const _workerStartupTimeout = Duration(seconds: 15);

/// Decodes, bounds, and encodes a creator image as WebP.
///
/// Native platforms use one long-lived serial worker so image decoding,
/// resizing, and WASM encoding never block Flutter's UI isolate. Web builds
/// keep the synchronous fallback because browser isolates have different
/// asset and WASM loading rules.
Future<ProcessedResourceImage?> processResourceImage(
  Uint8List raw, {
  int maxDimension = creatorMediaMaxDimension,
  double quality = 75,
}) async {
  await WasmCompatibility.shared.ensureAllowed(interactive: true);
  if (kIsWeb) {
    final encoder = await WasmWebpEncoder.instance();
    return _encodeResourceImage(
      raw,
      maxDimension: maxDimension,
      quality: quality,
      encoder: encoder,
    );
  }
  return (await _ResourceImageWorker.instance()).process(
    raw,
    maxDimension: maxDimension,
    quality: quality,
  );
}

/// Performs all CPU-heavy image work on the caller's isolate.
///
/// This is shared by the worker and the web fallback so both paths have the
/// same frame selection, source limits, dimensions, and encoding behavior.
ProcessedResourceImage? _encodeResourceImage(
  Uint8List raw, {
  required int maxDimension,
  required double quality,
  required WasmWebpEncoder encoder,
}) {
  if (maxDimension <= 0) {
    throw ArgumentError.value(maxDimension, 'maxDimension');
  }
  final decoder = img.findDecoderForData(raw);
  final info = decoder?.startDecode(raw);
  if (decoder == null || info == null) return null;
  if (info.width <= 0 || info.height <= 0) return null;
  final sourcePixels = info.width * info.height;
  if (sourcePixels > _maxSourcePixels) {
    throw StateError(
      'imageTooLarge: ${info.width}x${info.height} exceeds '
      '$_maxSourcePixels pixels',
    );
  }

  // Preview media is static. Decoding only the first frame prevents an
  // animated GIF/WebP from materializing every frame at once.
  final decoded = decoder.decode(raw, frame: 0);
  if (decoded == null) return null;
  var processed = decoded;
  if (decoded.width > maxDimension || decoded.height > maxDimension) {
    final width = decoded.width >= decoded.height
        ? maxDimension
        : (decoded.width * maxDimension / decoded.height).round();
    final height = decoded.width >= decoded.height
        ? (decoded.height * maxDimension / decoded.width).round()
        : maxDimension;
    processed = img.copyResize(
      decoded,
      width: width,
      height: height,
      interpolation: img.Interpolation.cubic,
    );
  }

  // Always materialize a non-palette 8-bit RGBA image first. Palette images
  // report the palette's channel count even though their backing data contains
  // one-byte indices; even getBytes(rgba) can therefore pass those indices on
  // unchanged. Optimizers such as TinyPNG commonly produce this indexed PNG
  // representation.
  final rgba = materializeResourceImageRgba(processed);
  final webp = encoder.encode(
    rgba,
    processed.width,
    processed.height,
    quality: quality,
  );
  if (webp == null || webp.isEmpty) return null;
  return ProcessedResourceImage(
    bytes: webp,
    width: processed.width,
    height: processed.height,
  );
}

@visibleForTesting
Uint8List materializeResourceImageRgba(img.Image image) {
  if (!image.hasPalette &&
      image.format == img.Format.uint8 &&
      image.numChannels == 4) {
    return image.getBytes(order: img.ChannelOrder.rgba);
  }
  final rgbaImage = image.convert(
    format: img.Format.uint8,
    numChannels: 4,
    withPalette: false,
  );
  return rgbaImage.getBytes(order: img.ChannelOrder.rgba);
}

final class _ResourceImageWorker {
  _ResourceImageWorker._(
    this._isolate,
    this._commands,
    this._responses,
    this._errors,
    this._exit,
  );

  static Future<_ResourceImageWorker>? _shared;

  final Isolate _isolate;
  final SendPort _commands;
  final ReceivePort _responses;
  final ReceivePort _errors;
  final ReceivePort _exit;
  final _pending = <int, Completer<ProcessedResourceImage?>>{};
  late final StreamSubscription<Object?> _responseSubscription;
  late final StreamSubscription<Object?> _errorSubscription;
  late final StreamSubscription<Object?> _exitSubscription;
  var _nextRequestId = 0;
  var _closed = false;

  static Future<_ResourceImageWorker> instance() {
    final existing = _shared;
    if (existing != null) return existing;
    final started = WasmCompatibility.shared.run('core', _start);
    _shared = started.catchError((Object error, StackTrace stack) {
      _shared = null;
      Error.throwWithStackTrace(error, stack);
    });
    return _shared!;
  }

  static Future<_ResourceImageWorker> _start() async {
    final responses = ReceivePort();
    final errors = ReceivePort();
    final exit = ReceivePort();
    Isolate? isolate;
    final ready = Completer<Map<Object?, Object?>>();
    late final StreamSubscription<Object?> responseSubscription;
    try {
      responseSubscription = responses.listen((message) {
        if (ready.isCompleted) return;
        if (message is Map && message['type'] == 'ready') {
          ready.complete(message.cast<Object?, Object?>());
        } else if (message is Map && message['type'] == 'startup-error') {
          ready.completeError(
            StateError(
              'resource image worker failed to start: ${message['error']}',
            ),
          );
        } else {
          ready.completeError(
            StateError('resource image worker returned invalid startup state'),
          );
        }
      });
      final cacheDirectory = await WasmCompilationCache.prepare();
      final data = await rootBundle.load(WasmWebpEncoder.assetPath);
      isolate = await Isolate.spawn<List<Object?>>(
        _resourceImageWorkerMain,
        <Object?>[
          responses.sendPort,
          TransferableTypedData.fromList([
            data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          ]),
          cacheDirectory,
        ],
        debugName: 'oronbox.resource-image-worker',
      );
      isolate.addErrorListener(errors.sendPort);
      isolate.addOnExitListener(exit.sendPort);

      final readyMessage = await ready.future.timeout(_workerStartupTimeout);
      final worker = _ResourceImageWorker._(
        isolate,
        readyMessage['commands'] as SendPort,
        responses,
        errors,
        exit,
      );
      responseSubscription.onData(worker._handleResponse);
      worker._responseSubscription = responseSubscription;
      worker._errorSubscription = errors.listen(worker._handleFatalError);
      worker._exitSubscription = exit.listen(worker._handleFatalError);
      return worker;
    } catch (_) {
      await responseSubscription.cancel();
      isolate?.kill(priority: Isolate.immediate);
      responses.close();
      errors.close();
      exit.close();
      rethrow;
    }
  }

  Future<ProcessedResourceImage?> process(
    Uint8List raw, {
    required int maxDimension,
    required double quality,
  }) {
    if (_closed) {
      throw StateError('resource image worker is closed');
    }
    final id = ++_nextRequestId;
    final completer = Completer<ProcessedResourceImage?>();
    _pending[id] = completer;
    try {
      _commands.send(<Object?>[
        id,
        TransferableTypedData.fromList([raw]),
        maxDimension,
        quality,
      ]);
    } catch (error, stack) {
      _pending.remove(id);
      completer.completeError(error, stack);
    }
    return completer.future;
  }

  void _handleResponse(Object? message) {
    if (message is! Map || message['type'] != 'result') return;
    final id = message['id'];
    if (id is! int) return;
    final completer = _pending.remove(id);
    if (completer == null || completer.isCompleted) return;
    if (message['ok'] != true) {
      completer.completeError(
        StateError(message['error']?.toString() ?? 'image processing failed'),
      );
      return;
    }
    final data = message['bytes'];
    if (data == null) {
      completer.complete(null);
      return;
    }
    if (data is! TransferableTypedData) {
      completer.completeError(
        StateError('resource image worker returned invalid bytes'),
      );
      return;
    }
    final width = message['width'];
    final height = message['height'];
    if (width is! int || height is! int) {
      completer.completeError(
        StateError('resource image worker returned invalid dimensions'),
      );
      return;
    }
    completer.complete(
      ProcessedResourceImage(
        bytes: data.materialize().asUint8List(),
        width: width,
        height: height,
      ),
    );
  }

  void _handleFatalError(Object? error) {
    if (_closed) return;
    final failure = StateError('resource image worker stopped: $error');
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(failure);
    }
    _pending.clear();
    _closed = true;
    _shared = null;
  }

  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    _commands.send(const <Object?>['shutdown']);
    _isolate.kill(priority: Isolate.beforeNextEvent);
    await _responseSubscription.cancel();
    await _errorSubscription.cancel();
    await _exitSubscription.cancel();
    _responses.close();
    _errors.close();
    _exit.close();
    _pending.clear();
    _shared = null;
  }
}

@pragma('vm:entry-point')
void _resourceImageWorkerMain(List<Object?> bootstrap) {
  final responses = bootstrap[0] as SendPort;
  final wasmData = (bootstrap[1] as TransferableTypedData)
      .materialize()
      .asUint8List();
  final commands = ReceivePort();

  () async {
    try {
      WasmCompilationCache.inheritConfiguration(bootstrap[2] as String?);
      final encoder = await WasmWebpEncoder.fromBytes(wasmData);
      responses.send(<String, Object?>{
        'type': 'ready',
        'commands': commands.sendPort,
      });
      var queue = Future<void>.value();
      commands.listen((message) {
        queue = queue.then(
          (_) => _handleWorkerMessage(message, responses, encoder, commands),
        );
      });
    } catch (error, stack) {
      responses.send(<String, Object?>{
        'type': 'startup-error',
        'error': '$error\n$stack',
      });
    }
  }();
}

Future<void> _handleWorkerMessage(
  Object? message,
  SendPort responses,
  WasmWebpEncoder encoder,
  ReceivePort commands,
) async {
  if (message is! List || message.isEmpty) return;
  if (message.length == 1 && message.first == 'shutdown') {
    encoder.dispose();
    commands.close();
    return;
  }
  if (message.length < 4 || message[0] is! int) return;
  final id = message[0] as int;
  try {
    final raw = (message[1] as TransferableTypedData)
        .materialize()
        .asUint8List();
    final result = _encodeResourceImage(
      raw,
      maxDimension: (message[2] as num).toInt(),
      quality: (message[3] as num).toDouble(),
      encoder: encoder,
    );
    responses.send(<String, Object?>{
      'type': 'result',
      'id': id,
      'ok': true,
      if (result != null) ...{
        'bytes': TransferableTypedData.fromList([result.bytes]),
        'width': result.width,
        'height': result.height,
      },
    });
  } catch (error, stack) {
    responses.send(<String, Object?>{
      'type': 'result',
      'id': id,
      'ok': false,
      'error': '$error\n$stack',
    });
  }
}

final class ProcessedResourceImage {
  const ProcessedResourceImage({
    required this.bytes,
    required this.width,
    required this.height,
  });

  final Uint8List bytes;
  final int width;
  final int height;
}
