part of 'plugin_manager.dart';

extension _NgHost on PluginManager {
  Future<Object?> _dispatchNgHostCall(
    InstalledPlugin plugin,
    String method,
    List<Object?> args,
  ) async {
    final id = plugin.manifest.id;
    final session = _sessions[id]!;
    final permissionRevision = _permissionBroker.revision(id);
    final permission = _ngPermission(plugin, method, args);
    if (permission != null) {
      await _permissionBroker.authorize(plugin, permission);
    }
    if (method == 'http-server.start' &&
        (args.single as Map)['bind-all-interfaces'] == true) {
      await _permissionBroker.authorize(
        plugin,
        PluginPermissionRequest(
          pluginId: id,
          pluginName: plugin.manifest.name,
          capability: 'http-server.lan',
          operation: method,
          risk: PluginPermissionRisk.medium,
          description: method,
        ),
      );
    }
    _permissionBroker.requireRevision(id, permissionRevision);
    if (!identical(_sessions[id], session) || !_runtimes.containsKey(id)) {
      throw StateError('Plugin instance has stopped');
    }
    return _executeHostCall(plugin, method, args);
  }

  PluginPermissionRequest? _ngPermission(
    InstalledPlugin plugin,
    String method,
    List<Object?> args,
  ) {
    final capability = switch (method) {
      'ui.render' || 'ui.get-render-size' => null,
      'device.get-device-list' ||
      'device.get-connected-device-list' => 'device',
      'device.disconnect-device' => 'device',
      'interconnect.send-qaic-message' => 'interconnect',
      'register.register-interconnect-recv' => 'register_interconnect_recv',
      'transport.send' || 'transport.request' => 'request',
      'register.register-transport-recv' => 'register_transport_recv',
      'clipboard.read-text' => 'clipboard.read',
      'clipboard.write-text' => 'clipboard.write',
      'os.device-id' => 'os.device-id',
      'register.register-deeplink-action' => 'register_deeplink_action',
      'browser.open' => 'browser',
      'http-server.start' => 'http-server',
      'notification.send' || 'notification.remove' => 'notification',
      'canopusconnect.send' => 'canopusconnect.send',
      'canopusconnect.listen' => 'canopusconnect.listen',
      'thirdpartyapp.launch-qa' ||
      'thirdpartyapp.get-thirdparty-app-list' => 'thirdpartyapp',
      'watchface.get-watchface-list' ||
      'watchface.set-current-watchface' => 'watchface',
      'queue.add-resource-to-queue' => 'queue',
      'queue.enqueue-install' => 'queue',
      'mass.send' =>
        args.elementAtOrNull(1) == 'firmware' ? 'mass.firmware' : 'mass',
      'register.register-provider' => 'register_provider',
      _ => null,
    };
    if (capability == null) return null;
    return PluginPermissionRequest(
      pluginId: plugin.manifest.id,
      pluginName: plugin.manifest.name,
      capability: capability,
      operation: method,
      risk: capability == 'mass.firmware'
          ? PluginPermissionRisk.high
          : PluginPermissionRisk.medium,
      description: method,
      resource: _ngPermissionResource(method, args),
      scope: _ngPermissionScope(method, args),
    );
  }

  String? _ngPermissionScope(String method, List<Object?> args) {
    final addr = args.firstOrNull?.toString() ?? '';
    return switch (method) {
      'interconnect.send-qaic-message' ||
      'register.register-interconnect-recv' ||
      'canopusconnect.send' ||
      'canopusconnect.listen' => jsonEncode([addr, args.elementAtOrNull(1)]),
      'register.register-transport-recv' => jsonEncode([
        addr,
        _jsonMap(args.elementAtOrNull(1))['xiaomi-vela-v5-channel-id'],
        _jsonMap(args.elementAtOrNull(1))['xiaomi-vela-v5-protobuf-typeid'],
      ]),
      'device.disconnect-device' ||
      'transport.send' ||
      'transport.request' ||
      'thirdpartyapp.get-thirdparty-app-list' ||
      'watchface.get-watchface-list' ||
      'notification.send' ||
      'notification.remove' => jsonEncode([addr]),
      'mass.send' => jsonEncode([addr, args.elementAtOrNull(1)]),
      'queue.enqueue-install' => jsonEncode([
        _jsonMap(args.firstOrNull)['device-addr'],
      ]),
      'thirdpartyapp.launch-qa' => jsonEncode([
        addr,
        _jsonMap(args.elementAtOrNull(1))['package-name'],
      ]),
      'watchface.set-current-watchface' => jsonEncode([
        addr,
        args.elementAtOrNull(1),
      ]),
      _ => null,
    };
  }

  String? _ngPermissionResource(String method, List<Object?> args) {
    final scope = _ngPermissionScope(method, args);
    if (scope == null) return null;
    final addr = method == 'queue.enqueue-install'
        ? _jsonMap(args.firstOrNull)['device-addr']?.toString() ?? ''
        : args.firstOrNull?.toString() ?? '';
    final device = readDeviceState().pairedDevices
        .where((device) => device.addr == addr)
        .firstOrNull;
    final name = device?.name ?? addr;
    final target = switch (method) {
      'interconnect.send-qaic-message' ||
      'register.register-interconnect-recv' ||
      'canopusconnect.send' ||
      'canopusconnect.listen' ||
      'watchface.set-current-watchface' => args.elementAtOrNull(1)?.toString(),
      'thirdpartyapp.launch-qa' => _jsonMap(
        args.elementAtOrNull(1),
      )['package-name']?.toString(),
      _ => null,
    };
    return target == null ? name : '$name / $target';
  }
}
