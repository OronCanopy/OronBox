part of 'plugin_manager.dart';

extension _PluginBackgroundLifecycle on PluginManager {
  static const _activityMethods = {
    'interconnect.send',
    'interconnect.send-qaic-message',
    'protocol.send',
    'protocol.request',
    'transport.send',
    'transport.request',
    'canopusconnect.send',
    'network.fetch',
    'network.download',
    'network.open',
    'network.read',
    'websocket.connect',
    'websocket.send',
    'mass.send',
    'queue.enqueue-install',
    'file.pick',
    'file.unload',
    'dialog.pick-file',
    'dialog.save-file-finish',
    'queue.add-resource-to-queue',
    'appside.send',
    'device.connect',
    'device.disconnect',
    'device.apps.list',
    'device.apps.launch',
    'device.apps.uninstall',
    'device.install',
    'watchface.list',
    'watchface.set',
    'thirdpartyapp.launch-qa',
    'thirdpartyapp.get-thirdparty-app-list',
    'watchface.get-watchface-list',
    'watchface.set-current-watchface',
    'notification.send',
    'notification.remove',
    'appside.zml.request',
    'appside.zml.call',
  };

  bool _hasVisibleView(String id) =>
      _foreground && _views[id]?.values.any((visible) => visible) == true;

  bool _hasExternalInteraction(String id) => _hostRequests.values.any(
    (request) =>
        request.pluginId == id &&
        {'pickFile', 'saveFile', 'openUrl'}.contains(request.type),
  );

  void _recordActivity(_PluginSession session) {
    session.hadActivity = true;
    session.idleDeadline = null;
    session.idleClock
      ..reset()
      ..start();
  }

  Future<T> _withActivity<T>(String id, Future<T> Function() action) async {
    final session = _sessions[id];
    if (session == null) throw StateError('Plugin session ended');
    session.activeOperations++;
    session.idleTimer?.cancel();
    try {
      final result = await action();
      if (identical(_sessions[id], session)) {
        _recordActivity(session);
      }
      return result;
    } finally {
      session.activeOperations--;
      // Reply to a guest host call before an idle stop can await guest shutdown.
      if (!_closed && identical(_sessions[id], session)) {
        session.idleTimer?.cancel();
        session.idleTimer = Timer(Duration.zero, () {
          if (_closed || !identical(_sessions[id], session)) return;
          unawaited(
            _applyBackgroundPolicy(id)
                .catchError((Object error, StackTrace stack) {
                  PluginManager._log.warning(
                    'Plugin activity cleanup failed',
                    error,
                    stack,
                  );
                }),
          );
        });
      }
    }
  }

  Future<void> _applyBackgroundPolicy(String id) async {
    final session = _sessions[id];
    if (_closed || session == null) return;
    session.idleTimer?.cancel();
    if (_hasVisibleView(id)) {
      session.idleDeadline = null;
      session.idleClock
        ..stop()
        ..reset();
      return;
    }
    if (_hasExternalInteraction(id) || _runtimeStarts.containsKey(id)) return;
    final mode = _settings(id).background;
    if (mode == PluginBackgroundMode.forbidden) {
      await _stopInactivePlugin(id);
      return;
    }
    if (mode == PluginBackgroundMode.continuous) return;
    if (!session.idleClock.isRunning) session.idleClock.start();
    if (session.activeOperations != 0) return;
    final remaining =
        session.idleDeadline?.difference(DateTime.now()) ??
        (backgroundIdleTimeout - session.idleClock.elapsed);
    if (remaining <= Duration.zero) {
      await _stopInactivePlugin(id);
      return;
    }
    session.idleTimer = Timer(remaining, () {
      if (!identical(_sessions[id], session)) return;
      unawaited(
        _applyBackgroundPolicy(id).catchError((Object error, StackTrace stack) {
          PluginManager._log.warning(
            'Plugin idle cleanup failed',
            error,
            stack,
          );
        }),
      );
    });
  }

  Future<void> _stopInactivePlugin(String id) async {
    _suspendedPlugins.remove(id);
    _suspendedDeadlines.remove(id);
    await _closeRuntime(id);
    if (_plugins.containsKey(id)) _emitState(id);
  }

  Future<void> _suspendForSystem(String id) async {
    final session = _sessions[id];
    _suspendedPlugins.add(id);
    if (session != null &&
        _settings(id).background == PluginBackgroundMode.active) {
      _suspendedDeadlines[id] =
          session.idleDeadline ??
          DateTime.now().add(backgroundIdleTimeout - session.idleClock.elapsed);
    }
    await _closeRuntime(id);
  }

  Future<void> _backgroundExpired(Set<int> ids) async {
    for (final entry in _backgroundTasks.entries.toList()) {
      if (!ids.contains(entry.value.id)) continue;
      _backgroundTasks.remove(entry.key);
      if (!_foreground) {
        await _suspendForSystem(entry.key);
      }
      if (_plugins.containsKey(entry.key)) _emitState(entry.key);
    }
  }

  Future<void> _beginPluginBackground(String id) async {
    if (_backgroundTasks.containsKey(id)) return;
    final session = _sessions[id];
    if (session == null) return;
    try {
      final handle = await beginBackgroundTask(
        _requirePlugin(id).manifest.name,
        plugin: true,
      );
      if (_foreground ||
          !identical(_sessions[id], session) ||
          _settings(id).background == PluginBackgroundMode.forbidden ||
          _backgroundTasks.containsKey(id)) {
        await handle.end();
        return;
      }
      _backgroundTasks[id] = handle;
    } catch (error, stack) {
      PluginManager._log.warning(
        'Plugin background execution unavailable',
        error,
        stack,
      );
    }
  }

  Future<void> _applyForeground() async {
    await initialize();
    if (_closed) return;
    if (_foreground) {
      for (final entry in _backgroundTasks.entries.toList()) {
        if (identical(_backgroundTasks[entry.key], entry.value)) {
          _backgroundTasks.remove(entry.key);
          await entry.value.end();
        }
      }
    }
    for (final id in {..._runtimes.keys, ..._runtimeStarts.keys}) {
      await _applyBackgroundPolicy(id);
      if (_foreground ||
          _hasExternalInteraction(id) ||
          !_sessions.containsKey(id)) {
        continue;
      }
      if (_settings(id).background != PluginBackgroundMode.forbidden) {
        await _beginPluginBackground(id);
      }
      if (!_backgroundTasks.containsKey(id)) {
        await _suspendForSystem(id);
        if (_plugins.containsKey(id)) _emitState(id);
      }
    }
    if (!_foreground) return;
    for (final id in {
      ..._suspendedPlugins,
      ..._views.keys.where(_hasVisibleView),
    }) {
      if (!_foreground || _closed || maintainingData) break;
      _suspendedPlugins.remove(id);
      final deadline = _suspendedDeadlines.remove(id);
      if (!_hasVisibleView(id) &&
          deadline != null &&
          !deadline.isAfter(DateTime.now())) {
        continue;
      }
      if (_runtimes.containsKey(id)) continue;
      if (!_plugins.containsKey(id) ||
          !_settings(id).enabled ||
          _safeMode ||
          _failures.containsKey(id)) {
        continue;
      }
      try {
        await open(id);
        final session = _sessions[id];
        if (!_hasVisibleView(id) &&
            deadline != null &&
            session != null &&
            !session.hadActivity) {
          session.idleClock.stop();
          // Preserve the original idle deadline across platform suspension.
          session.idleDeadline = deadline;
          await _applyBackgroundPolicy(id);
        }
      } catch (error, stack) {
        PluginManager._log.warning(
          'Plugin foreground restoration failed for $id',
          error,
          stack,
        );
      }
    }
  }
}

extension PluginForegroundLifecycle on PluginManager {
  Future<void> setForeground(bool foreground) {
    _foreground = foreground;
    final transition = _lifecycleTransition
        .catchError((_) {})
        .then((_) => _applyForeground());
    _lifecycleTransition = transition;
    return transition;
  }
}
