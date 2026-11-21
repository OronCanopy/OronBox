part of 'quickjs_wasm_runtime.dart';

/// One isolated QuickJS context, including its jobs, timers and host requests.
final class _QuickJsContext {
  WasmScope? _scope;
  ScopedWasmInstance? _instance;
  WasmMemoryView? _memory;
  JavaScriptHostCall? _hostCall;
  final _timers = <int, Timer>{};
  final _requests = <String>{};
  final _operations = <int, Completer<Object?>>{};
  int _generation = 0;
  int _nextOperation = 0;

  Map<String, Object?> get diagnostics => {
    'engine': 'quickjs-wasm',
    'running': _instance != null,
    'timers': _timers.length,
    'hostRequests': _requests.length,
    'operations': _operations.length,
  };

  Future<void> start({
    required String owner,
    required Uint8List runtimeBytes,
    required String bootstrap,
    required JavaScriptHostCall hostCall,
  }) async {
    final generation = ++_generation;
    _dispose();
    _hostCall = hostCall;
    final scope = WasmRuntime.shared.openScope(owner);
    _scope = scope;
    try {
      final instance = await scope.instantiate(runtimeBytes);
      if (_generation != generation) {
        scope.dispose();
        throw StateError('JavaScript startup cancelled');
      }
      _instance = instance;
      _memory = instance.memory();
      if (instance.call('qjs_init').firstOrNull != 0) {
        throw StateError('QuickJS initialization failed');
      }
      _evaluate(_operationBootstrap, 'runtime.js');
      if (bootstrap.isNotEmpty) _evaluate(bootstrap, 'bootstrap.js');
    } catch (_) {
      if (_generation == generation) await close();
      rethrow;
    }
  }

  Future<Object?> evaluate(String source, {String name = 'script.js'}) {
    if (_instance == null) {
      return Future.error(StateError('JavaScript runtime is closed'));
    }
    final id = ++_nextOperation;
    final result = Completer<Object?>();
    _operations[id] = result;
    try {
      _evaluate('__obRun($id, ${jsonEncode(source)})', name);
    } catch (error, stack) {
      _operations.remove(id);
      result.completeError(error, stack);
    }
    return result.future;
  }

  void addModule(String name, String source) =>
      _evaluate(source, name, function: 'qjs_add_module');

  Future<Object?> evaluateEntry(String source, String name) async {
    _evaluate(source, name, function: 'qjs_eval_entry');
    try {
      return await evaluate('globalThis.__obModuleResult', name: name);
    } finally {
      if (_instance != null) {
        _evaluate('delete globalThis.__obModuleResult', 'entry_cleanup.js');
      }
    }
  }

  Future<Object?> invoke(
    String function, [
    List<Object?> arguments = const [],
  ]) => evaluate(
    'globalThis[${jsonEncode(function)}](...${jsonEncode(arguments)})',
  );

  Future<void> close() async {
    ++_generation;
    _dispose();
  }

  void _dispose() {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    _requests.clear();
    _hostCall = null;
    final operations = _operations.values.toList();
    _operations.clear();
    for (final operation in operations) {
      operation.completeError(StateError('JavaScript runtime closed'));
    }
    final instance = _instance;
    _instance = null;
    _memory = null;
    if (instance != null) {
      try {
        instance.call('qjs_destroy');
      } finally {
        _scope?.dispose();
      }
    } else {
      _scope?.dispose();
    }
    _scope = null;
  }

  void _evaluate(String source, String name, {String function = 'qjs_eval'}) {
    final instance = _instance;
    final memory = _memory;
    if (instance == null || memory == null) {
      throw StateError('JavaScript runtime closed');
    }
    final code = utf8.encode(source);
    final filename = utf8.encode(name);
    final codePtr = instance.call('qjs_alloc', [code.length + 1]).first;
    if (codePtr == 0) throw StateError('QuickJS out of memory');
    var namePtr = 0;
    try {
      memory.write(codePtr, Uint8List.fromList([...code, 0]));
      namePtr = instance.call('qjs_alloc', [filename.length + 1]).first;
      if (namePtr == 0) throw StateError('QuickJS out of memory');
      memory.write(namePtr, Uint8List.fromList([...filename, 0]));
      final arguments = function == 'qjs_add_module'
          ? [namePtr, codePtr]
          : [codePtr, code.length, namePtr];
      if (instance.call(function, arguments).first != 0 ||
          instance.call('qjs_loop').first < 0) {
        final pointer = instance.call('qjs_get_last_error').first;
        throw StateError(
          'QuickJS $name: ${pointer == 0 ? 'execution failed' : _readString(memory, pointer)}',
        );
      }
      _drainMessages(instance, memory);
    } finally {
      instance.call('qjs_free', [codePtr]);
      if (namePtr != 0) instance.call('qjs_free', [namePtr]);
    }
  }

  String _readString(WasmMemoryView memory, int pointer) {
    final length = _instance!.call('qjs_string_length', [pointer]).first;
    return utf8.decode(memory.read(pointer, length));
  }

  void _drainMessages(ScopedWasmInstance instance, WasmMemoryView memory) {
    final count = instance.call('qjs_get_message_count').first;
    final messages = <(String, String)>[];
    for (var i = 0; i < count; i++) {
      messages.add((
        _readString(
          memory,
          instance.call('qjs_get_message_channel', [i]).first,
        ),
        _readString(
          memory,
          instance.call('qjs_get_message_payload', [i]).first,
        ),
      ));
    }
    instance.call('qjs_clear_messages');
    for (final (channel, payload) in messages) {
      if (channel != 'OronBoxHost' && channel != 'OronBoxResult') continue;
      final value = (jsonDecode(payload) as Map).cast<String, Object?>();
      if (channel == 'OronBoxResult') {
        final result = _operations.remove((value['id'] as num).toInt());
        if (result == null) continue;
        if (value['ok'] == true) {
          result.complete(value['value']);
        } else {
          result.completeError(StateError(value['error'].toString()));
        }
      } else if (channel == 'OronBoxHost') {
        _request(value);
      }
    }
  }

  void _request(Map<String, Object?> value) {
    final generation = _generation;
    final id = value['requestId']?.toString() ?? '';
    final method = value['method']?.toString() ?? '';
    final args = (value['args'] as List?)?.cast<Object?>() ?? const [];
    if (id.isNotEmpty && !_requests.add(id)) return;
    scheduleMicrotask(() async {
      if (generation != _generation || _instance == null) return;
      Object? payload;
      var succeeded = true;
      try {
        payload = switch (method) {
          'runtime.setTimer' => _setTimer(args),
          'runtime.clearTimer' => _clearTimer(args),
          _ => await _hostCall?.call(method, args),
        };
        // Validate before entering the VM so serialization errors reject the Promise.
        jsonEncode(payload);
      } catch (error) {
        succeeded = false;
        payload = error.toString();
      }
      if (generation != _generation || _instance == null) return;
      _requests.remove(id);
      if (id.isEmpty) return;
      try {
        _evaluate(
          'globalThis.__obSettleHostRequest(${jsonEncode(id)}, $succeeded, ${jsonEncode(payload)})',
          'host_result.js',
        );
      } catch (error) {
        _reportError(error);
      }
    });
  }

  int _setTimer(List<Object?> args) {
    final id = (args[0] as num).toInt();
    final delay = (args[1] as num).toInt();
    final repeat = args[2] == true;
    final generation = _generation;
    _timers.remove(id)?.cancel();
    void fire() {
      if (generation != _generation || _instance == null) return;
      if (!repeat) _timers.remove(id);
      unawaited(
        evaluate(
          '(globalThis.__obFireTimer || globalThis.__obDispatchTimer)($id)',
        ).then<void>((_) {}, onError: (Object error) => _reportError(error)),
      );
    }

    final duration = Duration(milliseconds: delay < 0 ? 0 : delay);
    _timers[id] = repeat
        ? Timer.periodic(duration, (_) => fire())
        : Timer(duration, fire);
    return id;
  }

  bool _clearTimer(List<Object?> args) {
    _timers.remove((args[0] as num).toInt())?.cancel();
    return true;
  }

  void _reportError(Object error) {
    final call = _hostCall;
    if (call != null) {
      unawaited(
        Future.sync(() => call('runtime.reportError', [error.toString()]))
            .then<void>((_) {}, onError: (_, _) {}),
      );
    }
  }
}

const _operationBootstrap = r'''
globalThis.__obRun = (id, source) => {
  const fail = error => {
    // QuickJS stacks contain frames without the exception message.
    let message = String(error);
    if (error && error.stack) message += '\n' + error.stack;
    sendMessage('OronBoxResult', JSON.stringify({id, ok: false, error: message}));
  };
  Promise.resolve().then(() => (0, eval)(source)).then(value => {
    try {
      sendMessage('OronBoxResult', JSON.stringify({id, ok: true, value: value === undefined ? null : value}));
    } catch (error) { fail(error); }
  }, fail);
};
''';
