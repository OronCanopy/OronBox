import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:oronbox/src/device/core/event_bus.dart';
import 'package:oronbox/src/core/errors/coded_error.dart';

import 'package:oronbox/src/core/logging/logging_service.dart';
import 'package:oronbox/src/device/xiaomi/protocol/packet/l2_packet.dart';
import 'package:oronbox/src/device/xiaomi/protocol/canopus/canopus_package.dart';
import 'package:oronbox/src/device/xiaomi/protocol/canopus/corona_install_session.dart';
import 'package:oronbox/src/device/xiaomi/systems/xiaomi_system.dart';

class CanopusException implements CodedError {
  const CanopusException(this.code, this.message, {this.details});

  @override
  final String code;
  @override
  final String message;
  @override
  final Object? details;

  @override
  String toString() => '$code: $message';
}

class XiaomiCanopusSystem extends XiaomiSystem {
  XiaomiCanopusSystem() : _log = getLogger('XiaomiCanopusSystem');

  static const _magic = 0x43504332;
  static const _headerSize = 36;
  static const _abiMajor = 2;
  static const _abiMinor = 0;
  static const _maxPayload = 512;
  static const _chunkSize = _maxPayload - 4;
  static const maxConnectPayloadBytes = 480;

  static const _install = 2;
  static const _enable = 3;
  static const _disable = 4;
  static const _remove = 5;
  static const _queryModule = 8;
  static const _queryDevice = 9;
  static const _stageBegin = 15;
  static const _stageWrite = 16;
  static const _stageFinish = 17;
  static const _stageAbort = 18;
  static const _stageResBegin = 26;
  static const _stageResWrite = 27;
  static const _stageResFinish = 28;

  final Logger _log;
  final _pending = <int, (int, Completer<_CpcResponse>)>{};
  final _parser = const CanopusPackageParser();
  final _pluginConnectModules = <String>{};
  final _activeConnectModules = <String>{};
  Future<void> _installTail = Future<void>.value();
  Future<void> _connectListenTail = Future<void>.value();
  bool _coronaListening = false;
  CoronaInstallSession? _coronaSession;
  int _nextRequestId = 1;
  bool _disposed = false;

  Uint8List _connectPayload(String module, int kind, Uint8List bytes) {
    if (!isValidModuleId(module)) {
      throw const FormatException('Invalid Canopus module id');
    }
    if (bytes.length > maxConnectPayloadBytes) {
      throw const FormatException('CanopusConnect payload exceeds 480 bytes');
    }
    return Uint8List.fromList([
      kind,
      module.length,
      ...utf8.encode(module),
      ...bytes,
    ]);
  }

  Future<void> sendConnect(
    String module,
    Uint8List bytes, {
    required bool isText,
  }) async {
    final payload = _connectPayload(module, isText ? 1 : 2, bytes);
    if (_pluginConnectModules.contains(module) &&
        !_activeConnectModules.contains(module)) {
      await _updateConnectSubscription(() async {
        if (_pluginConnectModules.contains(module)) {
          await _setConnectListening(module, true);
        }
      });
    }
    final response = await _request(19, payload);
    _requireConnectCompleted(response, module);
  }

  Future<void> listenConnect(
    String module,
    bool enabled, {
    bool restoring = false,
  }) {
    return _updateConnectSubscription(() async {
      if (enabled) {
        if (restoring) {
          _pluginConnectModules.add(module);
          _activeConnectModules.remove(module);
        }
        await _setConnectListening(module, true);
        _pluginConnectModules.add(module);
      } else {
        _pluginConnectModules.remove(module);
        if (module != CoronaInstallSession.moduleId || !_coronaListening) {
          await _setConnectListening(module, false);
        }
      }
    });
  }

  Future<void> _listenCorona(bool enabled) =>
      _updateConnectSubscription(() async {
        if (!enabled) _coronaListening = false;
        if (enabled ||
            !_pluginConnectModules.contains(CoronaInstallSession.moduleId)) {
          await _setConnectListening(CoronaInstallSession.moduleId, enabled);
        }
        _coronaListening = enabled;
      });

  Future<void> _updateConnectSubscription(Future<void> Function() update) {
    final operation = _connectListenTail.then((_) => update());
    _connectListenTail = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> _setConnectListening(String module, bool enabled) async {
    if (enabled == _activeConnectModules.contains(module)) return;
    if (!enabled) _activeConnectModules.remove(module);
    final response = await _request(
      20,
      _connectPayload(module, enabled ? 1 : 0, Uint8List(0)),
    );
    _requireConnectCompleted(response, module);
    if (enabled) _activeConnectModules.add(module);
  }

  bool _dispatchConnectMessage(Uint8List bytes) {
    if (bytes.length < _headerSize) return false;
    final header = ByteData.sublistView(bytes);
    if (header.getUint32(0, Endian.little) != _magic ||
        header.getUint16(6, Endian.little) != 3) {
      return false;
    }
    if (header.getUint16(8, Endian.little) != _abiMajor ||
        header.getUint16(10, Endian.little) > _abiMinor ||
        header.getUint32(16, Endian.little) != 21 ||
        header.getUint32(20, Endian.little) != 0) {
      throw const FormatException('Invalid CanopusConnect event');
    }
    final offset = header.getUint16(4, Endian.little);
    final length = header.getUint32(32, Endian.little);
    if (offset < _headerSize ||
        header.getUint32(12, Endian.little) != bytes.length ||
        offset + length != bytes.length ||
        length < 3) {
      throw const FormatException('Invalid CanopusConnect event length');
    }
    final payload = Uint8List.sublistView(bytes, offset);
    final idLength = payload[1];
    if (idLength < 1 || idLength > 16 || idLength + 2 > payload.length) {
      throw const FormatException('Invalid CanopusConnect module length');
    }
    final module = utf8.decode(payload.sublist(2, 2 + idLength));
    final data = Uint8List.sublistView(payload, 2 + idLength);
    _connectPayload(module, payload[0], data);
    if (payload[0] != 1 && payload[0] != 2) {
      throw const FormatException('Invalid CanopusConnect payload kind');
    }
    if (payload[0] == 1) utf8.decode(data);
    entity.emit(
      CanopusConnectMessage(
        deviceId: entity.id,
        module: module,
        payload: Uint8List.fromList(data),
        isText: payload[0] == 1,
      ),
    );
    return true;
  }

  Future<void> installResourcePack(
    Uint8List bytes, {
    void Function(double progress)? onProgress,
  }) async {
    final previous = _installTail;
    final done = Completer<void>();
    _installTail = done.future;
    await previous;
    final module = CoronaInstallSession.moduleId;
    final session = CoronaInstallSession(
      send: (bytes) async {
        try {
          await sendConnect(module, bytes, isText: false);
        } on CanopusException catch (error) {
          if (error.code == 'canopus_timeout') {
            throw TimeoutException(error.message);
          }
          rethrow;
        }
      },
      frames: entity
          .on<CanopusConnectMessage>()
          .where((event) => event.module == module && !event.isText)
          .map((event) => event.payload),
    );
    var listening = false;
    try {
      if (_disposed) throw StateError('Canopus system is disposed');
      _coronaSession = session;
      await _listenCorona(true);
      listening = true;
      await session.install(bytes, onProgress: onProgress);
    } finally {
      _coronaSession = null;
      await session.close();
      if (listening && !_disposed) {
        try {
          await _listenCorona(false);
        } catch (error) {
          _log.fine('Failed to close Corona subscription', error);
        }
      }
      done.complete();
    }
  }

  Future<void> install(
    Uint8List data, {
    void Function(double progress)? onProgress,
  }) async {
    final previous = _installTail;
    final done = Completer<void>();
    _installTail = done.future;
    await previous;
    try {
      await _installExclusive(data, onProgress: onProgress);
    } finally {
      if (!done.isCompleted) done.complete();
    }
  }

  Future<void> _installExclusive(
    Uint8List data, {
    void Function(double progress)? onProgress,
  }) async {
    onProgress?.call(0);
    final deviceInfo = await _queryDeviceInfoRequired();
    final targetId = deviceInfo.targetId!;
    final CanopusPackage package;
    try {
      package = _parser.parse(data, targetId: targetId);
    } on CanopusPackageTargetMismatch catch (error) {
      throw CanopusException('canopus_target_mismatch', error.message);
    } on FormatException catch (error) {
      throw CanopusException('canopus_invalid_package', error.message);
    }
    final availableSlots = (deviceInfo.requestSlots ?? 4) - 1;
    if (availableSlots < 1) {
      throw const CanopusException(
        'canopus_invalid_response',
        'Canopus Supervisor has no staging request slots',
      );
    }
    final windowSize = min(availableSlots, 8);
    _requireCompleted(
      await _request(_stageBegin, package.receipt),
      _stageBegin,
    );
    try {
      var transferred = 0;
      final total =
          package.artifact.length +
          package.resources.fold<int>(
            0,
            (sum, resource) => sum + resource.data.length,
          );
      Future<void> writeChunks(int command, Uint8List data) async {
        if (data.isEmpty) return;
        var deviceWritten = 0;
        var nextSendOffset = 0;
        var stalledRetries = 0;
        void acceptOffset(int written) {
          if (written > nextSendOffset) {
            throw const CanopusException(
              'canopus_invalid_response',
              'Canopus Supervisor acknowledged unsent data',
            );
          }
          if (written > deviceWritten) deviceWritten = written;
        }

        final inFlight = <int, (Future<_CpcResponse>, int)>{};

        while (deviceWritten < data.length) {
          while (inFlight.length < windowSize && nextSendOffset < data.length) {
            final offset = nextSendOffset;
            final end = (offset + _chunkSize).clamp(0, data.length);
            final payload = BytesBuilder()
              ..add(_u32(offset))
              ..add(data.sublist(offset, end));
            final fut = _request(command, payload.takeBytes());
            inFlight[offset] = (fut, end);
            nextSendOffset = end;
          }

          final completedOffset = await Future.any(
            inFlight.entries.map((e) async {
              try {
                await e.value.$1;
              } catch (_) {}
              return e.key;
            }),
          );

          final entry = inFlight.remove(completedOffset)!;
          final response = await entry.$1;
          final chunkEnd = entry.$2;

          final previouslyWritten = deviceWritten;
          final disallowed = response.result == _CpcResult.disallowed;
          if (disallowed || response.result == _CpcResult.completed) {
            if (response.payload.length >= 4) {
              acceptOffset(_readU32(response.payload, 0));
            } else if (!disallowed) {
              acceptOffset(chunkEnd);
            }
          } else {
            _requireCompleted(response, command);
          }
          if (disallowed) {
            for (final (future, end) in inFlight.values) {
              final reply = await future;
              if (reply.result != _CpcResult.disallowed) {
                _requireCompleted(reply, command);
              }
              if (reply.payload.length >= 4) {
                acceptOffset(_readU32(reply.payload, 0));
              } else if (reply.result == _CpcResult.completed) {
                acceptOffset(end);
              }
            }
            inFlight.clear();
          }
          if (deviceWritten > previouslyWritten) {
            stalledRetries = 0;
            onProgress?.call(0.97 * (transferred + deviceWritten) / total);
          }
          if (deviceWritten < data.length &&
              (disallowed ||
                  (inFlight.isEmpty && nextSendOffset == data.length))) {
            if (deviceWritten == previouslyWritten && ++stalledRetries > 3) {
              throw CanopusException(
                'canopus_command_rejected',
                'Canopus staging made no progress',
                details: {'opcode': command, 'offset': deviceWritten},
              );
            }
            nextSendOffset = deviceWritten;
          }
        }

        if (inFlight.isNotEmpty) {
          final remaining = inFlight.values.map((v) => v.$1).toList();
          inFlight.clear();
          for (final fut in remaining) {
            try {
              await fut;
            } catch (_) {}
          }
        }

        transferred += data.length;
        onProgress?.call(0.97 * transferred / total);
      }

      await writeChunks(_stageWrite, package.artifact);
      _requireCompleted(
        await _request(_stageFinish, Uint8List(0)),
        _stageFinish,
      );
      for (final resource in package.resources) {
        _requireCompleted(
          await _request(_stageResBegin, _resourceBeginPayload(resource)),
          _stageResBegin,
        );
        await writeChunks(_stageResWrite, resource.data);
        _requireCompleted(
          await _request(_stageResFinish, Uint8List(0)),
          _stageResFinish,
        );
      }
      final response = await _request(
        _install,
        _moduleIdPayload(package.moduleId),
        timeout: const Duration(seconds: 30),
      );
      if (response.result != _CpcResult.completed &&
          response.result != _CpcResult.rebootRequired) {
        throw StateError('Canopus install returned ${response.result.name}');
      }
      onProgress?.call(1);
    } catch (_) {
      try {
        await _request(
          _stageAbort,
          Uint8List(0),
          timeout: const Duration(seconds: 5),
        );
      } catch (error, stackTrace) {
        _log.warning(
          '[${entity.id}] Canopus staging abort failed',
          error,
          stackTrace,
        );
      }
      rethrow;
    }
  }

  Future<CanopusDeviceInfo> queryDeviceInfo({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final response = await _request(
      _queryDevice,
      Uint8List(0),
      timeout: timeout,
    );
    _requireCompleted(response, _queryDevice);
    try {
      return parseDeviceInfo(response.payload);
    } on FormatException catch (error) {
      throw CanopusException('canopus_invalid_response', error.message);
    }
  }

  Future<CanopusModuleInfo?> queryModule(
    int slot, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final response = await _request(_queryModule, _u32(slot), timeout: timeout);
    if (response.result == _CpcResult.disallowed && response.payload.isEmpty) {
      return null;
    }
    _requireCompleted(response, _queryModule);
    try {
      final module = parseModuleInfo(response.payload);
      if (module.slot != slot || module.state == 0) {
        throw const FormatException(
          'Canopus query returned a different or empty module slot',
        );
      }
      return module;
    } on FormatException catch (error) {
      throw CanopusException('canopus_invalid_response', error.message);
    }
  }

  Future<List<CanopusModuleInfo>> listModules({
    CanopusDeviceInfo? deviceInfo,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final info = deviceInfo ?? await queryDeviceInfo(timeout: timeout);
    final modules = <CanopusModuleInfo>[];
    for (var slot = 0; slot < 16; slot++) {
      if (modules.length >= info.moduleCount) break;
      final module = await queryModule(slot, timeout: timeout);
      if (module != null) {
        modules.add(module);
      }
    }
    if (modules.length != info.moduleCount) {
      throw CanopusException(
        'canopus_module_list_incomplete',
        'Canopus returned an incomplete module list. Try again',
        details: {'expected': info.moduleCount, 'received': modules.length},
      );
    }
    return modules;
  }

  Future<void> setModuleEnabled(
    String moduleId,
    bool enabled, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final command = enabled ? _enable : _disable;
    final response = await _request(
      command,
      _moduleIdPayload(moduleId),
      timeout: timeout,
    );
    _requireCompleted(response, command, allowRebootRequired: true);
  }

  Future<void> removeModule(
    String moduleId, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final response = await _request(
      _remove,
      _moduleIdPayload(moduleId),
      timeout: timeout,
    );
    _requireCompleted(response, _remove, allowRebootRequired: true);
  }

  Future<CanopusDeviceInfo> _queryDeviceInfoRequired() async {
    final info = await queryDeviceInfo(timeout: const Duration(seconds: 10));
    final targetId = info.targetId;
    if (targetId == null || targetId.isEmpty) {
      throw const CanopusException(
        'canopus_target_missing',
        'Canopus Supervisor did not provide a target ID',
      );
    }
    return info;
  }

  static CanopusDeviceInfo parseDeviceInfo(Uint8List payload) {
    if (payload.length < 36) {
      throw const FormatException('Payload too short for device info');
    }
    final magic = _readU32(payload, 0);
    // CQD1 magic is 0x43514431 in little-endian wire representation
    // ("1DQC") or 0x31445143 if treated as raw ASCII "CQD1".
    if (magic != 0x43514431 && magic != 0x31445143) {
      throw const FormatException('Invalid Canopus device info');
    }
    final size = _readU32(payload, 4);
    if (size < 36 || size != payload.length || (size > 36 && size < 84)) {
      throw const FormatException('Invalid Canopus device info size');
    }
    String? targetId;
    if (size >= 84) {
      final fixed = payload.sublist(36, 84);
      final end = fixed.indexOf(0);
      if (end <= 0 || fixed.sublist(end).any((value) => value != 0)) {
        throw const FormatException('Canopus device did not report target_id');
      }
      targetId = utf8.decode(fixed.sublist(0, end));
    }
    final frameworkRevision = _readU32(payload, 8);
    final safeMode = _readU32(payload, 12) != 0;
    final moduleCount = _readU32(payload, 16);
    final safeModeReason = _readU32(payload, 20);
    final errorCode = _readU32(payload, 24);
    final flags = _readU32(payload, 28);
    final scanSummary = _readU32(payload, 32);
    final requestSlots = payload.length >= 88 ? _readU32(payload, 84) : null;

    return CanopusDeviceInfo(
      frameworkRevision: frameworkRevision,
      safeMode: safeMode,
      moduleCount: moduleCount,
      safeModeReason: safeModeReason,
      errorCode: errorCode,
      flags: flags,
      scanSummary: scanSummary,
      targetId: targetId,
      requestSlots: (requestSlots != null && requestSlots != 0)
          ? requestSlots
          : null,
    );
  }

  static CanopusModuleInfo parseModuleInfo(Uint8List payload) {
    if (payload.length < 64) {
      throw FormatException(
        'Payload too short for module info: ${payload.length} bytes',
      );
    }
    final magic = _readU32(payload, 0);
    // CQM1 magic is 0x43514D31 in little-endian wire representation
    // ("1MQC") or 0x314D5143 if treated as raw ASCII "CQM1".
    if (magic != 0x43514D31 && magic != 0x314D5143) {
      throw FormatException('Invalid CQM1 magic: 0x${magic.toRadixString(16)}');
    }
    final size = _readU32(payload, 4);
    if (size < 64 || size != payload.length) {
      throw const FormatException('Invalid Canopus module info size');
    }
    final slot = _readU32(payload, 8);
    final state = _readU32(payload, 12);
    final lifecycleClass = _readU32(payload, 16);
    final version = _readU32(payload, 20);
    final flags = _readU32(payload, 24);
    final fixed = payload.sublist(28, 60);
    final end = fixed.indexOf(0);
    if (end <= 0 || fixed.sublist(end).any((v) => v != 0)) {
      throw const FormatException('Invalid Canopus module identity padding');
    }
    final moduleId = utf8.decode(fixed.sublist(0, end));
    if (!isValidModuleId(moduleId)) {
      throw const FormatException(
        'Invalid Canopus module identity in query response',
      );
    }
    final activationError = _readU32(payload, 60);

    return CanopusModuleInfo(
      slot: slot,
      moduleId: moduleId,
      version: version,
      state: state,
      lifecycleClass: lifecycleClass,
      flags: flags,
      activationError: activationError,
    );
  }

  static bool isValidModuleId(String id) {
    final bytes = utf8.encode(id);
    if (bytes.isEmpty || bytes.length > 16) return false;
    final first = bytes.first;
    if (first < 0x61 || first > 0x7a) return false;
    for (final b in bytes) {
      final isLower = b >= 0x61 && b <= 0x7a;
      final isDigit = b >= 0x30 && b <= 0x39;
      final isUnderscore = b == 0x5f;
      if (!isLower && !isDigit && !isUnderscore) return false;
    }
    return true;
  }

  static void _requireCompleted(
    _CpcResponse response,
    int command, {
    bool allowRebootRequired = false,
  }) {
    if (allowRebootRequired && response.result == _CpcResult.rebootRequired) {
      return;
    }
    if (response.result != _CpcResult.completed) {
      throw CanopusException(
        'canopus_command_rejected',
        'Canopus command $command returned ${response.result.name}',
        details: {'opcode': command, 'result': response.result.value},
      );
    }
  }

  static void _requireConnectCompleted(_CpcResponse response, String module) {
    if (response.result == _CpcResult.completed) return;
    final status = response.payload.firstOrNull;
    final (code, message) = switch ((response.result, status)) {
      (_, null) => (
        'canopus_connect_unsupported',
        'This Canopus Supervisor does not support CanopusConnect',
      ),
      (_CpcResult.disallowed, 1) => (
        'canopus_module_not_installed',
        'Canopus module $module is not installed',
      ),
      (_CpcResult.disallowed, 2) => (
        'canopus_module_not_listening',
        'Canopus module $module is not listening for messages',
      ),
      (_CpcResult.disallowed, 3) => (
        'canopus_listener_limit',
        'The Canopus device cannot take more listeners',
      ),
      _ => (
        'canopus_command_rejected',
        'CanopusConnect returned ${response.result.name}',
      ),
    };
    throw CanopusException(
      code,
      message,
      details: {
        'opcode': response.opcode,
        'result': response.result.value,
        'status': status,
        'moduleId': module,
      },
    );
  }

  Future<_CpcResponse> _request(
    int command,
    Uint8List payload, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (_disposed) throw StateError('Canopus system is disposed');
    final requestId = _nextRequestId++;
    if (_nextRequestId == 0) _nextRequestId = 1;
    final completer = Completer<_CpcResponse>();
    _pending[requestId] = (command, completer);
    unawaited(completer.future.then<void>((_) {}, onError: (Object _) {}));
    try {
      final frame = _encodeRequest(command, requestId, payload);
      await component.sendL2Data(L2Channel.canopus, frame);
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      throw CanopusException(
        'canopus_timeout',
        'Canopus Supervisor did not respond in time',
        details: {'opcode': command},
      );
    } finally {
      _pending.remove(requestId);
    }
  }

  @override
  void onLayer2Packet(L2Channel channel, L2OpCode opcode, Uint8List payload) {
    if (channel != L2Channel.canopus || opcode == L2OpCode.read) return;
    try {
      if (_dispatchConnectMessage(payload)) return;
      final response = _decodeResponse(payload);
      if (_pending[response.requestId] case (final expected, final waiter)
          when !waiter.isCompleted) {
        if (response.opcode == expected) {
          waiter.complete(response);
        } else {
          waiter.completeError(
            CanopusException(
              'canopus_invalid_response',
              'Canopus response opcode does not match the request',
              details: {'expected': expected, 'received': response.opcode},
            ),
          );
        }
      }
      entity.emit(
        CanopusCommandResponse(
          deviceId: entity.id,
          opcode: response.opcode,
          requestId: response.requestId,
          result: response.result.value,
        ),
      );
    } on FormatException catch (error, stackTrace) {
      if (payload.length >= _headerSize) {
        final header = ByteData.sublistView(payload);
        if (header.getUint32(0, Endian.little) == _magic &&
            header.getUint16(6, Endian.little) == 2) {
          final waiter = _pending[header.getUint32(20, Endian.little)]?.$2;
          if (waiter != null && !waiter.isCompleted) {
            waiter.completeError(
              CanopusException('canopus_invalid_response', error.message),
            );
          }
        }
      }

      _log.warning(
        '[${entity.id}] invalid Canopus response',
        error,
        stackTrace,
      );
    }
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    for (final (_, waiter) in _pending.values) {
      if (!waiter.isCompleted) {
        waiter.completeError(StateError('Canopus system disposed'));
      }
    }
    _pending.clear();
    await _coronaSession?.close();
    await super.dispose();
  }

  static Uint8List _encodeRequest(
    int command,
    int requestId,
    Uint8List payload,
  ) {
    if (payload.length > _maxPayload) {
      throw ArgumentError('Canopus CPC2 payload is too large');
    }
    final output = Uint8List(_headerSize + payload.length);
    final data = ByteData.sublistView(output);
    data.setUint32(0, _magic, Endian.little);
    data.setUint16(4, _headerSize, Endian.little);
    data.setUint16(6, 1, Endian.little);
    data.setUint16(8, _abiMajor, Endian.little);
    data.setUint16(10, _abiMinor, Endian.little);
    data.setUint32(12, output.length, Endian.little);
    data.setUint32(16, command, Endian.little);
    data.setUint32(20, requestId, Endian.little);
    data.setUint32(24, 0, Endian.little);
    data.setUint32(28, 0, Endian.little);
    data.setUint32(32, payload.length, Endian.little);
    output.setRange(_headerSize, output.length, payload);
    return output;
  }

  static _CpcResponse _decodeResponse(Uint8List payload) {
    if (payload.length < _headerSize) {
      throw const FormatException('CPC2 response is too short');
    }
    final data = ByteData.sublistView(payload);
    if (data.getUint32(0, Endian.little) != _magic ||
        data.getUint16(4, Endian.little) < _headerSize ||
        data.getUint16(6, Endian.little) != 2 ||
        data.getUint16(8, Endian.little) != _abiMajor ||
        data.getUint16(10, Endian.little) > _abiMinor ||
        data.getUint32(12, Endian.little) != payload.length) {
      throw const FormatException('Invalid CPC2 response header');
    }
    final headerSize = data.getUint16(4, Endian.little);
    final payloadSize = data.getUint32(32, Endian.little);
    if (payloadSize > _maxPayload ||
        headerSize + payloadSize != payload.length) {
      throw const FormatException('Invalid CPC2 response length');
    }
    return _CpcResponse(
      opcode: data.getUint32(16, Endian.little),
      requestId: data.getUint32(20, Endian.little),
      result: _CpcResult.fromValue(data.getUint32(28, Endian.little)),
      payload: Uint8List.sublistView(payload, headerSize),
    );
  }

  static Uint8List _moduleIdPayload(String moduleId) =>
      Uint8List.fromList([...utf8.encode(moduleId), 0]);

  static Uint8List _resourceBeginPayload(CanopusPackageResource resource) {
    final name = utf8.encode(resource.name);
    if (name.isEmpty || name.length > 255) {
      throw FormatException('Invalid Canopus resource name: ${resource.name}');
    }
    return Uint8List.fromList([
      name.length,
      ...name,
      ..._u32(resource.data.length),
      ...resource.sha256,
    ]);
  }

  static Uint8List _u32(int value) {
    final output = Uint8List(4);
    ByteData.sublistView(output).setUint32(0, value, Endian.little);
    return output;
  }

  static int _readU32(Uint8List payload, int offset) => ByteData.sublistView(
    payload,
    offset,
    offset + 4,
  ).getUint32(0, Endian.little);
}

enum _CpcResult {
  rejected(1),
  accepted(2),
  queued(3),
  running(4),
  completed(5),
  failed(6),
  disallowed(7),
  rebootRequired(8);

  const _CpcResult(this.value);
  final int value;

  static _CpcResult fromValue(int value) => _CpcResult.values.firstWhere(
    (item) => item.value == value,
    orElse: () => throw FormatException('Invalid CPC2 result: $value'),
  );
}

class _CpcResponse {
  const _CpcResponse({
    required this.opcode,
    required this.requestId,
    required this.result,
    required this.payload,
  });

  final int opcode;
  final int requestId;
  final _CpcResult result;
  final Uint8List payload;
}

class CanopusDeviceInfo {
  const CanopusDeviceInfo({
    required this.frameworkRevision,
    required this.safeMode,
    required this.moduleCount,
    required this.safeModeReason,
    required this.errorCode,
    required this.flags,
    required this.scanSummary,
    this.targetId,
    this.requestSlots,
  });

  final int frameworkRevision;
  final bool safeMode;
  final int moduleCount;
  final int safeModeReason;
  final int errorCode;
  final int flags;
  final int scanSummary;
  final String? targetId;
  final int? requestSlots;
}

class CanopusModuleInfo {
  const CanopusModuleInfo({
    required this.slot,
    required this.moduleId,
    required this.version,
    required this.state,
    required this.lifecycleClass,
    required this.flags,
    required this.activationError,
  });

  final int slot;
  final String moduleId;
  final int version;
  final int state;
  final int lifecycleClass;
  final int flags;
  final int activationError;

  bool get isEnabled => switch (state) {
    5 || 6 || 7 || 8 || 9 || 13 => true,
    _ => false,
  };
}
