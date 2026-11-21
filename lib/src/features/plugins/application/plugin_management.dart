part of 'plugin_manager.dart';

extension _PluginManagement on PluginManager {
  PluginHostSettings _settings(String id) =>
      PluginHostSettings.fromJson(_hostSettings[id] ?? {});

  void _checkActivation(String id) {
    if (!_settings(id).enabled) throw StateError('plugin_disabled');
    if (!_foreground &&
        _settings(id).background == PluginBackgroundMode.forbidden) {
      throw StateError('plugin_in_background');
    }
  }

  bool _isPermissionError(Object? error) =>
      error is PluginPermissionException ||
      RegExp(
        r'PluginPermissionException\((permission_denied|permission_changed|permission_not_declared|plugin_stopped),',
      ).hasMatch(error.toString());

  bool _isCapabilityError(Object? error) =>
      error.toString().contains('wasm_compatibility_required') ||
      error.toString().contains('platform_capability_unavailable:');

  Future<T> _withManagement<T>(String id, Future<T> Function() action) {
    final previous = _managementOperations[id] ?? Future<void>.value();
    final result = previous.then((_) async {
      if (_closed) throw StateError('Plugin manager is closed');
      return action();
    });
    late final Future<void> completion;
    completion = result.then<void>((_) {}, onError: (_, _) {}).whenComplete(() {
      if (identical(_managementOperations[id], completion)) {
        _managementOperations.remove(id);
      }
    });
    _managementOperations[id] = completion;
    return result;
  }

  Future<Map<String, Object?>> _settingsFor(String id) async {
    if (_hostSettings[id] case final settings?) return settings;
    final settings = await (await _storage).readHostSettings(id);
    return _hostSettings.putIfAbsent(id, () => settings);
  }

  Future<void> _writeHostPatch(String id, Map<String, Object?> patch) {
    final previous = _hostWrites[id] ?? Future<void>.value();
    late final Future<void> writing;
    writing = previous
        .catchError((_) {})
        .then((_) async {
          final old = await _settingsFor(id);
          final updated = {...old, ...patch};
          _hostSettings[id] = updated;
          try {
            await (await _storage).writeHostSettings(id, updated);
          } catch (_) {
            if (identical(_hostSettings[id], updated)) _hostSettings[id] = old;
            rethrow;
          }
        })
        .whenComplete(() {
          if (identical(_hostWrites[id], writing)) _hostWrites.remove(id);
        });
    _hostWrites[id] = writing;
    return writing;
  }

  Future<void> _awaitHostWrites(String id) async => await _hostWrites[id];
}

extension PluginManagement on PluginManager {
  Future<void> startAutomaticPlugins() async {
    await initialize();
    if (_closed || _safeMode || maintainingData) return;
    return _automaticStartup ??= _startAutomaticPlugins();
  }

  Future<void> _startAutomaticPlugins() async {
    for (final id in _plugins.keys.toList()) {
      if (_closed || _safeMode || maintainingData) break;
      if (!_settings(id).enabled || !_settings(id).autoStart) continue;
      if (!_foreground &&
          _settings(id).background == PluginBackgroundMode.forbidden) {
        _suspendedPlugins.add(id);
        continue;
      }
      try {
        await open(id);
      } catch (error, stack) {
        PluginManager._log.warning(
          'Automatic plugin startup failed for $id',
          error,
          stack,
        );
      }
    }
  }

  Future<Object?> attachView(
    String id,
    String view, {
    bool visible = true,
  }) async {
    if (view.isEmpty) throw ArgumentError('Missing plugin view identity');
    await initialize();
    _requirePlugin(id);
    (_views[id] ??= {})[view] = visible;
    _sessions[id]?.idleTimer?.cancel();
    try {
      return await open(id, interactive: visible);
    } catch (_) {
      _views[id]?.remove(view);
      if (_views[id]?.isEmpty == true) _views.remove(id);
      await _applyBackgroundPolicy(id);
      rethrow;
    }
  }

  Future<void> detachView(String id, String view) async {
    if (_views[id]?.remove(view) == null) return;
    if (_views[id]!.isEmpty) _views.remove(id);
    await _applyBackgroundPolicy(id);
  }

  Future<void> setViewVisibility(String id, String view, bool visible) async {
    await initialize();
    if (_views[id]?.containsKey(view) != true) return;
    _views[id]![view] = visible;
    if (visible && _foreground && _settings(id).enabled) {
      await open(id, interactive: true);
    } else {
      await _applyBackgroundPolicy(id);
    }
  }

  Future<void> setSettings(String id, Map<String, Object?> patch) async {
    await initialize();
    if (patch.containsKey('background') &&
        !PluginBackgroundMode.values.any(
          (mode) => mode.name == patch['background'],
        )) {
      throw ArgumentError('Unknown plugin background mode');
    }
    var restartView = false;
    await _withManagement(id, () async {
      _requirePlugin(id);
      if (maintainingData) throw StateError('Data maintenance is active');
      await _writeHostPatch(id, {
        for (final key in ['enabled', 'autoStart'])
          if (patch[key] is bool) key: patch[key],
        if (patch.containsKey('background')) 'background': patch['background'],
      });
      final settings = _settings(id);
      final session = _sessions[id];
      if (patch.containsKey('background') && session != null) {
        session.idleDeadline = null;
        session.idleClock
          ..reset()
          ..start();
      }
      restartView =
          patch['enabled'] == true && settings.enabled && _hasVisibleView(id);
      if (!settings.enabled) {
        _suspendedPlugins.remove(id);
        _suspendedDeadlines.remove(id);
        await _closeRuntime(id);
      } else {
        if (settings.background == PluginBackgroundMode.forbidden) {
          await _backgroundTasks.remove(id)?.end();
        } else if (!_foreground && _runtimes.containsKey(id)) {
          await _beginPluginBackground(id);
        }
        await _applyBackgroundPolicy(id);
      }
      _emitState(id);
    });
    if (restartView && _foreground) await open(id);
  }

  bool hasHostRequest(String requestId) => _hostRequests.containsKey(requestId);

  bool claimHostRequest(String requestId, String owner) {
    if (owner.isEmpty || !_hostRequests.containsKey(requestId)) return false;
    final existing = _hostRequestOwners[requestId];
    if (existing != null && existing != owner) return false;
    _hostRequestOwners[requestId] = owner;
    return true;
  }

  void releaseHostRequests(String owner, {String? requestId}) {
    for (final id in _hostRequestOwners.keys.toList()) {
      if (_hostRequestOwners[id] != owner ||
          (requestId != null && id != requestId)) {
        continue;
      }
      _hostRequestOwners.remove(id);
      final request = _hostRequests[id];
      if (request == null) continue;
      emitEvent(
        CommandEvent(
          'plugin.hostRequest',
          data: {
            ...request.data,
            'requestId': id,
            'pluginId': request.pluginId,
            'type': request.type,
          },
        ),
      );
    }
  }

  Future<void> setPermission(
    String id,
    String key,
    Map<String, Object?> policy,
  ) async {
    await initialize();
    await _withManagement(id, () async {
      final plugin = _requirePlugin(id);
      if (maintainingData) throw StateError('Data maintenance is active');
      if (key.isEmpty) throw ArgumentError('Missing permission identity');
      final existing = await _permissionBroker.policies(id);
      final old = (existing[key] as Map?)?.cast<String, Object?>();
      final capability = (old?['capability']?.toString() ?? key)
          .trim()
          .toLowerCase();
      if (old == null &&
          !plugin.manifest.permissions.any(
            (value) => value.trim().toLowerCase() == capability,
          )) {
        throw ArgumentError('Unknown permission');
      }
      await _permissionBroker.setPolicy(id, old == null ? capability : key, {
        ...?old,
        'capability': capability,
        if (old == null) 'operation': '*',
        'decision': policy['decision'],
      });
      for (final entry in _hostRequests.entries.toList()) {
        if (entry.value.pluginId != id || entry.value.type != 'permission') {
          continue;
        }
        _hostRequests.remove(entry.key);
        _hostRequestOwners.remove(entry.key);
        entry.value.result.completeError(
          const PluginPermissionException(
            'permission_changed',
            'Plugin permissions changed',
          ),
        );
        emitEvent(
          CommandEvent('plugin.hostCancelled', data: {'requestId': entry.key}),
        );
      }
      if (policy['decision'] != 'allow') {
        await _revokeSubscriptions(
          id,
          capability,
          old?['scope']?.toString(),
          old?['operation']?.toString(),
        );
      }
      _emitState(id);
    });
  }

  Future<void> _revokeSubscriptions(
    String id,
    String capability,
    String? scope,
    String? operation,
  ) async {
    final session = _sessions[id];
    if (session == null) return;
    if (capability == 'interconnect' &&
        (operation == null ||
            operation == '*' ||
            operation == 'interconnect.observe')) {
      session.observeInterconnect = false;
    }
    if (capability == 'protocol' &&
        (operation == null ||
            operation == '*' ||
            operation == 'protocol.observe')) {
      session.observeProtocol = false;
    }
    if (capability == 'register_interconnect_recv' ||
        capability == 'interconnect') {
      session.interconnect.removeWhere(
        (target) =>
            scope == null || scope == jsonEncode([target.$1, target.$2]),
      );
    }
    if (capability == 'register_transport_recv' || capability == 'protocol') {
      session.transport.removeWhere(
        (target) =>
            scope == null ||
            scope == jsonEncode([target.$1, target.$2, target.$3]),
      );
    }
    if (capability == 'canopusconnect.listen') {
      for (final key in _canopusSubscriptions.keys.toList()) {
        if (scope == null || scope == jsonEncode([key.$1, key.$2])) {
          await _listenCanopus(id, key.$1, key.$2, false);
        }
      }
    }
    if (capability == 'register_provider' ||
        (capability == 'provider' && operation != 'provider.unregister')) {
      _providers.removeWhere((_, value) => value.pluginId == id);
    }
    if (capability == 'register_deeplink_action') session.deeplink = false;
    if (capability == 'http-server' || capability == 'http-server.lan') {
      await _httpServers.remove(id)?.close();
    }
  }
}
