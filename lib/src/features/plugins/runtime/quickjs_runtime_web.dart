import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'plugin_runtime.dart';

@JS('OronBoxPluginRuntime.create')
external JSPromise<_WebQuickJs> _create(
  JSString bootstrap,
  JSFunction hostCall,
);

extension type _WebQuickJs._(JSObject _) implements JSObject {
  external JSPromise<JSString> evaluateEntry(
    JSString source,
    JSString name,
    JSString modules,
  );

  external JSPromise<JSString> invoke(JSString name, JSString arguments);
  external void close();
}

final class QuickJsWasmRuntime {
  _WebQuickJs? _runtime;
  int _generation = 0;

  Map<String, Object?> get diagnostics => {
    'engine': 'quickjs-wasm',
    'running': _runtime != null,
  };

  Future<void> start({
    required String owner,
    required String bootstrap,
    required PluginHostCall hostCall,
  }) async {
    final generation = ++_generation;
    _dispose();
    Future<JSString> call(JSString method, JSString args) async {
      final value = await hostCall(
        method.toDart,
        (jsonDecode(args.toDart) as List).cast<Object?>(),
      );
      return jsonEncode(value).toJS;
    }

    final runtime = await _create(
      bootstrap.toJS,
      ((JSString method, JSString args) => call(method, args).toJS).toJS,
    ).toDart;
    if (generation != _generation) {
      runtime.close();
      throw StateError('JavaScript startup cancelled');
    }
    _runtime = runtime;
  }

  Future<Object?> evaluateEntry(
    String source, {
    String name = 'main.js',
    Map<String, String> modules = const {},
  }) async => jsonDecode(
    (await _active
            .evaluateEntry(source.toJS, name.toJS, jsonEncode(modules).toJS)
            .toDart)
        .toDart,
  );

  Future<Object?> invoke(
    String name, [
    List<Object?> arguments = const [],
  ]) async => jsonDecode(
    (await _active.invoke(name.toJS, jsonEncode(arguments).toJS).toDart).toDart,
  );

  _WebQuickJs get _active =>
      _runtime ?? (throw StateError('JavaScript runtime is closed'));

  Future<void> close() async {
    ++_generation;
    _dispose();
  }

  void _dispose() {
    final runtime = _runtime;
    _runtime = null;
    runtime?.close();
  }
}
