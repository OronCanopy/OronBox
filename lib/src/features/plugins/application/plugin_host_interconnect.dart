part of 'plugin_manager.dart';

String _pluginAddress(String addr) =>
    addr.trim().replaceAll('-', ':').toUpperCase();

bool _samePluginAddress(String left, String right) =>
    _pluginAddress(left) == _pluginAddress(right);

extension _PluginInterconnect on PluginManager {
  bool _matchesInterconnect(
    _PluginSession session,
    String addr,
    String package,
  ) => session.interconnect.any(
    (registration) =>
        registration.$2 == package &&
        (registration.$1.isEmpty || _samePluginAddress(registration.$1, addr)),
  );

  void _registerInterconnect(
    String id,
    _PluginSession session,
    String addr,
    String package,
  ) {
    if (session.interconnect.any(
      (item) => item.$2 == package && _samePluginAddress(item.$1, addr),
    )) {
      return;
    }
    session.interconnect.add((addr, package));
    final now = DateTime.now();
    final replay = _pendingInterconnect
        .where(
          (message) =>
              message.package == package &&
              (addr.isEmpty || _samePluginAddress(addr, message.addr)) &&
              now.difference(message.received) < const Duration(seconds: 15),
        )
        .toList();
    _pendingInterconnect.removeWhere(replay.contains);
    for (final message in replay) {
      for (final receiver in _sessions.entries.toList()) {
        if (_matchesInterconnect(receiver.value, message.addr, package)) {
          _deliverInterconnect(
            receiver.key,
            receiver.value,
            message.addr,
            package,
            message.payload,
          );
        }
      }
    }
    for (final target in deviceManager.connectedAddresses) {
      if (addr.isEmpty || _samePluginAddress(addr, target)) {
        _syncInterconnect(id, session, target, package);
      }
    }
  }

  void _deliverInterconnect(
    String id,
    _PluginSession session,
    String addr,
    String package,
    String payload,
  ) {
    final runtime = _runtimes[id];
    if (runtime == null) return;
    session.interconnectDelivery = session.interconnectDelivery
        .then((_) async {
          if (!identical(_sessions[id], session) ||
              !_matchesInterconnect(session, addr, package)) {
            return;
          }
          await _withActivity(
            id,
            () => runtime.dispatchEvent('interconnect-message', payload),
          );
        })
        .catchError((Object error, StackTrace stack) {
          PluginManager._log.warning(
            'Interconnect delivery failed',
            error,
            stack,
          );
        });
  }

  void _syncInterconnect(
    String id,
    _PluginSession session,
    String addr,
    String package,
  ) {
    final key = (_pluginAddress(addr), package);
    final revision = _deviceRevisions[key.$1] ?? 0;
    final now = DateTime.now();
    session.interconnectSync.removeWhere(
      (_, time) => now.difference(time) >= const Duration(seconds: 3),
    );
    if (session.interconnectSync.containsKey(key)) return;
    session.interconnectSync[key] = now;
    unawaited(() async {
      try {
        final app = session.apps[key] ?? await _findApp(session, addr, package);
        if (!identical(_sessions[id], session) ||
            !_matchesInterconnect(session, addr, package) ||
            (_deviceRevisions[key.$1] ?? 0) != revision) {
          return;
        }
        await deviceManager.syncPluginInterconnect(addr, app);
      } catch (error) {
        PluginManager._log.fine('Interconnect status sync unavailable', error);
      }
    }());
  }
}
