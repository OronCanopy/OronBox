import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../errors/coded_error.dart';
import '../logging/logging_service.dart';
import '../storage/app_data_directory.dart';

enum WasmCompatibilityState { unknown, deferred, running, ready }

final class WasmCompatibilityRequired implements CodedError {
  const WasmCompatibilityRequired();

  @override
  String get code => 'wasm_compatibility_required';
  @override
  String get message => code;
  @override
  Object? get details => null;
  @override
  String toString() => code;
}

/// Android's crash marker is shared by all native Wasm entry points.
final class WasmCompatibility {
  WasmCompatibility({this._directory, bool? android, this._highRisk})
    : _android = android ?? (!kIsWeb && Platform.isAndroid);

  static final shared = WasmCompatibility();
  static final _log = getLogger('WasmCompatibility');
  static const _systemInfoChannel = MethodChannel(
    'org.oroncanopy.oronbox/system_info',
  );
  static final _authorizedZone = Object();
  static bool _workerAuthorized = false;

  final bool _android;
  AppDataDirectory? _directory;
  bool? _highRisk;
  Future<void>? _initializing;
  Future<void> _writes = Future.value();
  Future<bool>? _permission;
  final _started = <String>{};
  var _state = WasmCompatibilityState.unknown;
  var _previous = WasmCompatibilityState.unknown;
  var _active = 0;
  var _succeeded = false;

  Future<bool> Function()? requestTest;

  WasmCompatibilityState get state => _state;
  bool get shouldPromptOnStartup =>
      _android && _highRisk == true && _state == WasmCompatibilityState.unknown;

  static bool isHighRisk(int? sdk, String kernel) =>
      sdk != null && sdk >= 26 && sdk <= 28 && kernel.trim().startsWith('4.');

  static void inheritAuthorization() => _workerAuthorized = true;

  Future<void> initialize() {
    if (!_android || _workerAuthorized) return Future.value();
    return _initializing ??= _initialize().catchError((
      Object error,
      StackTrace stack,
    ) {
      _initializing = null;
      Error.throwWithStackTrace(error, stack);
    });
  }

  Future<void> _initialize() async {
    _directory ??= await openAppDataDirectory('wasm');
    final bytes = await _directory!.read('compatibility.json');
    if (bytes != null) {
      try {
        final record = jsonDecode(utf8.decode(bytes)) as Map;
        _state = WasmCompatibilityState.values.byName(
          record['state'] as String,
        );
      } on Object catch (error, stack) {
        _log.warning('Unreadable Wasm compatibility record', error, stack);
        _state = WasmCompatibilityState.deferred;
      }
    }
    if (_state == WasmCompatibilityState.running) {
      await _save(WasmCompatibilityState.deferred);
      _log.warning(
        'Previous Wasm startup interrupted; deferring compatibility test',
      );
    }
    if (_highRisk != null) return;
    try {
      final info = await _systemInfoChannel.invokeMapMethod<String, dynamic>(
        'getAndroidKernelInfo',
      );
      final sdkVersion = info?['sdkInt'] as int?;
      final kernel = info?['kernelRelease'] as String? ?? '';
      _highRisk = isHighRisk(sdkVersion, kernel);
    } on Object catch (error, stack) {
      _log.warning('Unable to determine Android Wasm risk group', error, stack);
      _highRisk = false;
    }
  }

  bool get _authorized {
    final authorization = Zone.current[_authorizedZone];
    return _workerAuthorized ||
        authorization is _StartupAuthorization &&
            identical(authorization.owner, this) &&
            authorization.active;
  }

  Future<void> ensureAllowed({bool interactive = false}) async {
    if (!_android || _authorized) {
      return;
    }
    await initialize();
    final pending = _permission;
    if (pending != null) {
      if (interactive &&
          await pending &&
          _state == WasmCompatibilityState.ready) {
        return;
      }
      throw const WasmCompatibilityRequired();
    }
    if (_state == WasmCompatibilityState.ready || _active > 0) return;
    if (_state == WasmCompatibilityState.unknown && _highRisk != true) return;
    if (!interactive || requestTest == null) {
      throw const WasmCompatibilityRequired();
    }
    final permission = requestTest!();
    _permission = permission;
    try {
      if (!await permission || _state != WasmCompatibilityState.ready) {
        throw const WasmCompatibilityRequired();
      }
    } finally {
      _permission = null;
    }
  }

  Future<void> defer() =>
      _exclusive(() => _save(WasmCompatibilityState.deferred));

  Future<T> run<T>(String entry, Future<T> Function() operation) async {
    if (!_android || _authorized) {
      return operation();
    }
    await ensureAllowed();
    if (_started.contains(entry)) return operation();
    return _tracked(entry, operation);
  }

  /// The test callback includes compilation, an actual encode and output validation.
  Future<void> test(Future<void> Function() operation) async {
    if (!_android) return operation();
    await initialize();
    await _tracked('compatibility-test', operation);
  }

  Future<T> _tracked<T>(String entry, Future<T> Function() operation) async {
    await _exclusive(() async {
      if (_active == 0) {
        _previous = _state;
        _succeeded = false;
        // AppDataDirectory flushes the record before entering native code.
        await _save(WasmCompatibilityState.running);
      }
      _active++;
    });
    var succeeded = false;
    final authorization = _StartupAuthorization(this);
    try {
      final result = await runZoned(
        operation,
        zoneValues: {_authorizedZone: authorization},
      );
      succeeded = true;
      _started.add(entry);
      return result;
    } finally {
      // Stream listeners retain their zone after startup and need a fresh guard.
      authorization.active = false;
      await _exclusive(() async {
        _succeeded |= succeeded;
        _active--;
        if (_active == 0) {
          try {
            await _save(_succeeded ? WasmCompatibilityState.ready : _previous);
          } catch (_) {
            _state = WasmCompatibilityState.deferred;
            _started.clear();
            rethrow;
          }
        }
      });
    }
  }

  Future<void> _save(WasmCompatibilityState state) async {
    await _directory!.write(
      'compatibility.json',
      Uint8List.fromList(utf8.encode(jsonEncode({'state': state.name}))),
    );
    _state = state;
  }

  Future<void> _exclusive(Future<void> Function() action) {
    final result = _writes.then((_) => action());
    _writes = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }
}

final class _StartupAuthorization {
  _StartupAuthorization(this.owner);
  final WasmCompatibility owner;
  bool active = true;
}
