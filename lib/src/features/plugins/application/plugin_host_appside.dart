part of 'plugin_manager.dart';

extension _PluginAppSide on PluginManager {
  Future<List<int>> _appSideList() => deviceManager.listZeppOsAppSides();

  Future<void> _appSideStart(List<Object?> arguments) async {
    final appId = _parseAppSideId(arguments);
    await deviceManager.startZeppOsAppSide(appId);
  }

  Future<void> _appSideStop(List<Object?> arguments) async {
    final appId = _parseAppSideId(arguments);
    await deviceManager.stopZeppOsAppSide(appId);
  }

  Future<void> _appSideSend(List<Object?> arguments) async {
    final appId = _parseAppSideId(arguments);
    final data = _decodeHex(arguments.elementAtOrNull(1)?.toString() ?? '');
    await deviceManager.sendZeppOsAppSideMessage(appId, data);
  }

  Future<void> _appSideInject(List<Object?> arguments) async {
    final appId = _parseAppSideId(arguments);
    final data = _decodeHex(arguments.elementAtOrNull(1)?.toString() ?? '');
    await deviceManager.injectZeppOsAppSideMessage(appId, data);
  }

  Future<List<Map<String, Object?>>> _appSideSessions() async {
    final sessions = await deviceManager.zeppOsAppSideSessions();
    return sessions
        .map(
          (s) => {
            'appId': s.appId,
            'version': s.version,
            'port1': s.port1,
            'port2': s.port2,
            'extra': s.extra,
            'watchSessionOpen': s.watchSessionOpen,
          },
        )
        .toList(growable: false);
  }

  Future<List<Map<String, Object?>>> _appSideEvents(
    List<Object?> arguments,
  ) async {
    final appId = _parseAppSideId(arguments);
    final events = await deviceManager.zeppOsAppSideEvents(appId);
    return events
        .map(
          (e) => {
            'timestamp': e.timestamp.toIso8601String(),
            'type': e.type,
            'message': e.message,
            if (e.direction != null) 'direction': e.direction,
            if (e.source != null) 'source': e.source,
            if (e.payload != null) 'payload': base64Encode(e.payload!),
          },
        )
        .toList(growable: false);
  }

  Future<void> _appSideClearEvents(List<Object?> arguments) async {
    final appId = _parseAppSideId(arguments);
    await deviceManager.clearZeppOsAppSideEvents(appId);
  }

  Future<T> _withZmlTransition<T>(int appId, Future<T> Function() action) {
    final previous = _zmlTransitions[appId] ?? Future<void>.value();
    final operation = previous.then((_) => action());
    final settled = operation.then<void>((_) {}, onError: (_, _) {});
    _zmlTransitions[appId] = settled;
    unawaited(
      settled.then((_) {
        if (identical(_zmlTransitions[appId], settled)) {
          _zmlTransitions.remove(appId);
        }
      }),
    );
    return operation;
  }

  Future<void> _appSideZmlAttach(
    InstalledPlugin plugin,
    List<Object?> arguments,
  ) async {
    final appId = _parseAppSideId(arguments);
    final session = _sessions[plugin.manifest.id];
    final hooks =
        (arguments.elementAtOrNull(1) as Map?)?.cast<String, Object?>() ??
        const {};
    final existing = _zmlAttachments[appId];
    if (existing != null && existing.pluginId != plugin.manifest.id) {
      throw StateError(
        'ZML App-side $appId is already attached by another plugin',
      );
    }
    final attachment = _PluginZmlAttachment(
      pluginId: plugin.manifest.id,
      hooks: hooks.map((name, callback) => MapEntry(name, callback.toString())),
    );
    _zmlAttachments[appId] = attachment;
    Future<Object?> invokeHook(String hook, Object? payload) async {
      final current = _zmlAttachments[appId];
      if (!identical(current, attachment)) return null;
      if (!attachment.ready) {
        attachment.pending.add((hook: hook, payload: payload));
        return null;
      }
      final callbackId = current?.hooks[hook];
      if (callbackId == null || callbackId.isEmpty) return null;
      final runtime = _runtimes[plugin.manifest.id];
      if (runtime == null) return null;
      if (runtime is! JavaScriptPluginRuntime) return null;
      return runtime.invokeRegistered(
        callbackId,
        payload == null ? const [] : [payload],
      );
    }

    try {
      await _withZmlTransition(appId, () async {
        if (!identical(_sessions[plugin.manifest.id], session) ||
            !identical(_zmlAttachments[appId], attachment)) {
          throw StateError('Plugin session ended');
        }
        await deviceManager.attachZeppOsZml(appId, invokeHook);
      });
      if (!identical(_zmlAttachments[appId], attachment)) return;
      attachment.ready = true;
      final pending = List.of(attachment.pending);
      attachment.pending.clear();
      scheduleMicrotask(() {
        for (final event in pending) {
          unawaited(
            invokeHook(event.hook, event.payload).catchError((
              Object error,
              StackTrace stack,
            ) {
              PluginManager._log.warning(
                'Pending App-side hook failed',
                error,
                stack,
              );
              return null;
            }),
          );
        }
      });
    } catch (_) {
      if (identical(_zmlAttachments[appId], attachment)) {
        _zmlAttachments.remove(appId);
      }
      rethrow;
    }
  }

  Future<Object?> _appSideZmlInvoke(
    InstalledPlugin plugin,
    List<Object?> arguments,
    String method,
  ) {
    final appId = _parseAppSideId(arguments);
    final attachment = _zmlAttachments[appId];
    if (attachment?.pluginId != plugin.manifest.id) {
      throw StateError('Plugin is not attached to ZML App-side $appId');
    }
    return deviceManager.invokeZeppOsZml(
      appId,
      method,
      arguments.skip(1).toList(growable: false),
    );
  }

  Future<void> _appSideZmlDetach(
    InstalledPlugin plugin,
    List<Object?> arguments,
  ) async {
    final appId = _parseAppSideId(arguments);
    final attachment = _zmlAttachments[appId];
    if (attachment?.pluginId != plugin.manifest.id) return;
    _zmlAttachments.remove(appId);
    await _withZmlTransition(
      appId,
      () => deviceManager.stopZeppOsAppSide(appId),
    );
  }

  int _parseAppSideId(List<Object?> arguments) {
    final value = arguments.firstOrNull;
    final parsed = value is num
        ? value.toInt()
        : int.tryParse(value?.toString() ?? '');
    if (parsed == null || parsed <= 0) {
      throw const FormatException('appId must be a positive integer');
    }
    return parsed;
  }

  static Uint8List _decodeHex(String value) {
    if (value.length.isOdd || !RegExp(r'^[0-9a-fA-F]*$').hasMatch(value)) {
      throw const FormatException('Invalid hex');
    }
    return Uint8List.fromList([
      for (var i = 0; i < value.length; i += 2)
        int.parse(value.substring(i, i + 2), radix: 16),
    ]);
  }
}

class _PluginZmlAttachment {
  _PluginZmlAttachment({required this.pluginId, required this.hooks});
  final String pluginId;
  final Map<String, String> hooks;
  final pending = <({String hook, Object? payload})>[];
  bool ready = false;
}
