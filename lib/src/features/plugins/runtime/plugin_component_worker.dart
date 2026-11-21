import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:wasm_abp/wasm_abp.dart';

/// Owns all component FFI calls on a dedicated isolate, including compilation
/// and disposal. Host requests and UI snapshots cross the isolate boundary.
final class PluginComponentWorker {
  PluginComponentWorker._(this._onUi, this._hostCall, this._onFailure);

  final void Function(String) _onUi;
  final Future<Object?> Function(String, List<Object?>) _hostCall;
  final void Function(Object) _onFailure;
  final _messages = ReceivePort();
  final _errors = ReceivePort();
  final _exits = ReceivePort();
  final _ready = Completer<SendPort>();
  final _pending = <int, Completer<Object?>>{};
  Isolate? _isolate;
  SendPort? _commands;
  int _nextId = 0;
  bool _closed = false;
  bool _exited = false;
  bool _stopping = false;
  Object? _failure;
  Future<void>? _closing;
  String? latestUi;
  Map<String, Object?> nativeDiagnostics = const {};

  static Future<PluginComponentWorker> start({
    required Uint8List bytes,
    required int apiLevel,
    required Map<String, String> preopens,
    required void Function(String) onUi,
    required Future<Object?> Function(String, List<Object?>) hostCall,
    required void Function(PluginComponentWorker) onReady,
    required void Function(Object) onFailure,
  }) async {
    final worker = PluginComponentWorker._(onUi, hostCall, onFailure);
    unawaited(worker._ready.future.then<void>((_) {}, onError: (_, _) {}));
    worker._messages.listen(worker._receive);
    worker._errors.listen(
      (error) => worker._workerExited(StateError('$error')),
    );
    worker._exits.listen((_) {
      if (!worker._closed) {
        worker._workerExited(StateError('Plugin component worker exited'));
      }
    });
    try {
      worker._isolate = await Isolate.spawn(
        _runComponent,
        worker._messages.sendPort,
        onError: worker._errors.sendPort,
        onExit: worker._exits.sendPort,
        debugName: 'plugin.component',
      );
      worker._commands = await worker._ready.future;
      onReady(worker);
      await worker._call('start', [bytes, preopens, apiLevel]);
      return worker;
    } catch (_) {
      await worker.close();
      rethrow;
    }
  }

  void _receive(dynamic message) {
    final values = message as List;
    switch (values[0]) {
      case 'ready':
        if (!_ready.isCompleted) _ready.complete(values[1] as SendPort);
      case 'ui':
        if (_closed || _stopping) return;
        latestUi = values[1] as String;
        _onUi(latestUi!);
      case 'host':
        if (_closed || _stopping) return;
        unawaited(_serveHost(values));
      case 'error':
        _fail(StateError(values[1] as String));
      case 'result':
        nativeDiagnostics = (values[4] as Map).cast<String, Object?>();
        final completer = _pending.remove(values[1]);
        if (completer == null) return;
        if (values[3] != null) {
          completer.completeError(StateError(values[3] as String));
        } else {
          completer.complete(values[2]);
        }
    }
  }

  Future<void> _serveHost(List request) async {
    Object? value;
    String? error;
    try {
      value = await _hostCall(
        request[2] as String,
        (request[3] as List).cast<Object?>(),
      );
    } catch (failure) {
      error = failure.toString();
    }
    if (!_closed && !_stopping) {
      _commands?.send([
        0,
        'host-response',
        [request[1], value, error],
      ]);
    }
  }

  void _fail(Object error) {
    final firstFailure = _failure == null;
    _failure ??= error;
    if (!_ready.isCompleted) _ready.completeError(error);
    for (final completer in _pending.values) {
      completer.completeError(error);
    }
    _pending.clear();
    if (firstFailure && !_closed && !_stopping) _onFailure(error);
  }

  void _workerExited(Object error) {
    _exited = true;
    _fail(error);
  }

  Future<Object?> _call(String command, List<Object?> arguments) {
    if (_closed || _exited || (_stopping && command != 'close')) {
      return Future.error(StateError('Plugin worker is closed'));
    }
    if (command != 'close' && _failure != null) return Future.error(_failure!);
    final completer = Completer<Object?>();
    final id = ++_nextId;
    _pending[id] = completer;
    _commands!.send([id, command, arguments]);
    return completer.future;
  }

  Future<String?> render(String elementId) async {
    final ui = await _call('render', [elementId]) as String?;
    if (ui != null) latestUi = ui;
    return ui;
  }

  Future<String?> invoke(String id, String eventType, String payload) async {
    return await _call('invoke', [id, eventType, payload]) as String?;
  }

  Future<String> callExport(String name, List<Object?> args) async =>
      await _call('export', [name, args]) as String;

  Future<void> dispatch(String name, String payload) async {
    await _call('event', [name, payload]);
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    if (_closed) return;
    _stopping = true;
    latestUi = null;
    try {
      if (!_exited && _commands != null) {
        await _call('close', const []);
      }
    } catch (_) {
      if (!_exited) rethrow;
    } finally {
      _closed = true;
      _fail(StateError('Plugin worker closed'));
      _messages.close();
      _errors.close();
      _exits.close();
      _isolate?.kill(priority: Isolate.immediate);
    }
  }
}

void _runComponent(SendPort output) async {
  final commands = ReceivePort();
  output.send(['ready', commands.sendPort]);
  AbpComponent? component;
  AbpComponentInstance? instance;
  final hostRequests = <int, Completer<Object?>>{};
  var nextHostRequest = 0;
  final stopped = Completer<void>();
  commands.listen((message) async {
    final values = message as List;
    final id = values[0] as int;
    final command = values[1] as String;
    final args = values[2] as List;
    try {
      Object? result;
      switch (command) {
        case 'host-response':
          final request = hostRequests.remove(args[0]);
          if (args[2] != null) {
            request?.completeError(StateError(args[2] as String));
          } else {
            request?.complete(args[1]);
          }
        case 'start':
          component = AbpComponent.compile(
            args[0] as Uint8List,
            apiLevel: args[2] as int,
          );
          instance = component!.instantiate(
            preopens: (args[1] as Map).cast<String, String>(),
          );
          instance!.setUiListener((ui) => output.send(['ui', ui]));
          instance!.hostCall = (method, arguments) {
            final requestId = ++nextHostRequest;
            final pending = Completer<Object?>();
            hostRequests[requestId] = pending;
            output.send(['host', requestId, method, arguments]);
            return pending.future;
          };
          instance!.onError = (error) =>
              output.send(['error', error.toString()]);
          await instance!.callOnLoad();
        case 'render':
          final ui = await instance!.callOnUiRender(
            elementId: args[0] as String,
          );
          result = ui.isNotEmpty && ui != '{}' ? ui : instance!.getRenderedUi();
        case 'invoke':
          result = await instance!.callOnUiEvent(
            eventId: args[0] as String,
            eventType: args[1] as String,
            payload: args[2] as String,
          );
        case 'event':
          await instance!.callOnEvent(
            eventName: args[0] as String,
            payload: args[1] as String,
          );
        case 'export':
          result = await instance!.callExport(
            args[0] as String,
            (args[1] as List).cast<Object?>(),
          );
        case 'close':
          for (final pending in hostRequests.values) {
            pending.completeError(StateError('Plugin closed'));
          }
          hostRequests.clear();
          instance?.dispose();
          instance = null;
          component?.dispose();
          component = null;
      }
      output.send([
        'result',
        id,
        result,
        null,
        AbpComponent.runtimeDiagnostics,
      ]);
    } catch (error, stack) {
      output.send([
        'result',
        id,
        null,
        '$error\n$stack',
        AbpComponent.isRuntimeLoaded
            ? AbpComponent.runtimeDiagnostics
            : const <String, Object?>{},
      ]);
    }
    if (command == 'close' && !stopped.isCompleted) stopped.complete();
  });
  await stopped.future;
  instance?.dispose();
  component?.dispose();
  commands.close();
}
