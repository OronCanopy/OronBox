import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/services.dart';

import '../wasm/wasm_compilation_cache.dart';
import '../wasm/wasm_runtime.dart';
import '../wasm/wasm_compatibility.dart';

part 'quickjs_wasm_context.dart';

typedef JavaScriptHostCall = FutureOr<Object?> Function(
  String method,
  List<Object?> arguments,
);

/// Owns a QuickJS worker. Synchronous guest code executes off the UI isolate.
final class QuickJsWasmRuntime {
  ReceivePort? _messages;
  ReceivePort? _errors;
  ReceivePort? _exits;
  Isolate? _isolate;
  SendPort? _commands;
  JavaScriptHostCall? _hostCall;
  final _pending = <int, Completer<Object?>>{};
  Map<String, Object?> _diagnostics = const {};
  Completer<void>? _exited;
  Completer<SendPort>? _ready;
  int _nextId = 0;
  int _generation = 0;
  bool _stopping = false;
  bool _workerExited = false;
  Future<void>? _closing;

  Map<String, Object?> get diagnostics => {
    ..._diagnostics,
    'engine': 'quickjs-wasm',
    'running': _commands != null && !_stopping,
  };

  Future<void> start({
    required String owner,
    required String bootstrap,
    required JavaScriptHostCall hostCall,
  }) async {
    final generation = ++_generation;
    return WasmCompatibility.shared.run('core', () async {
      await (_closing ??= _close());
      if (generation != _generation) {
        throw StateError('JavaScript startup cancelled');
      }
      _closing = null;
      _stopping = false;
      _workerExited = false;
      _hostCall = hostCall;
      final cache = await WasmCompilationCache.prepare();
      final bytes = await rootBundle.load('assets/wasm/quickjs.wasm');
      if (generation != _generation) {
        throw StateError('JavaScript startup cancelled');
      }
      final messages = ReceivePort();
      final errors = ReceivePort();
      final exits = ReceivePort();
      _messages = messages;
      _errors = errors;
      _exits = exits;
      final ready = Completer<SendPort>();
      _ready = ready;
      // Spawn and close can race before the ready port arrives.
      unawaited(ready.future.then<void>((_) {}, onError: (_, _) {}));
      final exited = Completer<void>();
      _exited = exited;
      messages.listen((message) {
        if (!identical(_messages, messages)) return;
        final values = message as List;
        switch (values[0]) {
          case 'ready':
            if (!ready.isCompleted) ready.complete(values[1] as SendPort);
          case 'result':
            _diagnostics = (values[4] as Map).cast<String, Object?>();
            final result = _pending.remove(values[1]);
            if (values[3] == null) {
              result?.complete(values[2]);
            } else {
              result?.completeError(StateError(values[3].toString()));
            }
          case 'host':
            unawaited(_serveHost(generation, values));
          case 'diagnostics':
            _diagnostics = (values[1] as Map).cast<String, Object?>();
        }
      });
      void fail(Object error) {
        if (generation != _generation) return;
        if (!ready.isCompleted) ready.completeError(error);
        _fail(error);
      }

      errors.listen(
        (error) => fail(StateError('JavaScript worker failed: $error')),
      );
      exits.listen((_) {
        if (!exited.isCompleted) exited.complete();
        if (!identical(_exits, exits)) return;
        _workerExited = true;
        if (!_stopping) fail(StateError('JavaScript worker exited'));
      });
      try {
        final isolate = await Isolate.spawn(
          _runJavaScript,
          [messages.sendPort, cache],
          onError: errors.sendPort,
          onExit: exits.sendPort,
          debugName: owner,
        );
        if (generation != _generation) {
          isolate.kill(priority: Isolate.immediate);
          throw StateError('JavaScript startup cancelled');
        }
        _isolate = isolate;
        _commands = await ready.future;
        await _call('start', [
          owner,
          bootstrap,
          bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        ]);
      } catch (_) {
        if (generation == _generation) await close();
        rethrow;
      }
    });
  }

  Future<void> _serveHost(int generation, List values) async {
    if (_stopping) return;
    Object? result;
    String? error;
    try {
      result = await _hostCall?.call(
        values[2] as String,
        (values[3] as List).cast<Object?>(),
      );
    } catch (failure) {
      error = failure.toString();
    }
    if (generation == _generation && !_stopping) {
      _commands?.send([
        0,
        'host-result',
        [values[1], result, error],
      ]);
    }
  }

  Future<Object?> evaluate(String source, {String name = 'script.js'}) =>
      _call('evaluate', [source, name]);

  Future<Object?> evaluateEntry(
    String source, {
    String name = 'main.js',
    Map<String, String> modules = const {},
  }) => _call('entry', [source, name, modules]);

  Future<Object?> invoke(
    String function, [
    List<Object?> arguments = const [],
  ]) => evaluate(
    'globalThis[${jsonEncode(function)}](...${jsonEncode(arguments)})',
  );

  Future<Object?> _call(String command, List<Object?> args) {
    if (_commands == null || (_stopping && command != 'close')) {
      return Future.error(StateError('JavaScript runtime closed'));
    }
    final id = ++_nextId;
    final result = Completer<Object?>();
    _pending[id] = result;
    _commands!.send([id, command, args]);
    return result.future;
  }

  void _fail(Object error) {
    for (final pending in _pending.values) {
      pending.completeError(error);
    }
    _pending.clear();
  }

  Future<void> close() {
    ++_generation;
    return _closing ??= _close();
  }

  Future<void> _close() async {
    _stopping = true;
    _hostCall = null;
    _fail(StateError('JavaScript runtime closed'));
    final ready = _ready;
    _ready = null;
    if (ready != null && !ready.isCompleted) {
      ready.completeError(StateError('JavaScript startup cancelled'));
    }
    try {
      if (_commands != null && !_workerExited) await _call('close', const []);
    } finally {
      _commands = null;
      final isolate = _isolate;
      _isolate = null;
      isolate?.kill(priority: Isolate.immediate);
      if (isolate != null) await _exited?.future;
      _messages?.close();
      _errors?.close();
      _exits?.close();
      _messages = null;
      _errors = null;
      _exits = null;
      _diagnostics = const {'timers': 0, 'hostRequests': 0, 'operations': 0};
    }
  }
}

void _runJavaScript(List bootstrap) {
  final output = bootstrap[0] as SendPort;
  WasmCompilationCache.inheritConfiguration(bootstrap[1] as String?);
  final commands = ReceivePort();
  final context = _QuickJsContext();
  final requests = <int, Completer<Object?>>{};
  var nextRequest = 0;
  commands.listen((message) async {
    final values = message as List;
    final id = values[0] as int;
    final args = values[2] as List;
    Object? result;
    String? error;
    try {
      switch (values[1]) {
        case 'start':
          await context.start(
            owner: args[0] as String,
            bootstrap: args[1] as String,
            runtimeBytes: args[2] as Uint8List,
            hostCall: (method, arguments) {
              final request = ++nextRequest;
              final pending = Completer<Object?>();
              requests[request] = pending;
              output.send(['host', request, method, arguments]);
              return pending.future;
            },
          );
        case 'evaluate':
          result = await context.evaluate(
            args[0] as String,
            name: args[1] as String,
          );
        case 'entry':
          for (final entry in (args[2] as Map).cast<String, String>().entries) {
            context.addModule(entry.key, entry.value);
          }
          result = await context.evaluateEntry(
            args[0] as String,
            args[1] as String,
          );
        case 'host-result':
          final pending = requests.remove(args[0]);
          if (args[2] == null) {
            pending?.complete(args[1]);
          } else {
            pending?.completeError(StateError(args[2].toString()));
          }
          // Settlement resumes in a microtask. Publish counters after it drains.
          scheduleMicrotask(
            () => output.send(['diagnostics', context.diagnostics]),
          );
          return;
        case 'close':
          await context.close();
          for (final pending in requests.values) {
            pending.completeError(StateError('JavaScript runtime closed'));
          }
          requests.clear();
          commands.close();
      }
    } catch (failure) {
      error = failure.toString();
    }
    output.send(['result', id, result, error, context.diagnostics]);
  });
  output.send(['ready', commands.sendPort]);
}
