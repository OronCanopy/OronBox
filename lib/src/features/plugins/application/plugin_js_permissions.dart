part of 'plugin_manager.dart';

extension _JsPermissions on PluginManager {
  PluginPermissionRequest? _jsPermissionRequest(
    InstalledPlugin plugin,
    String method,
    List<Object?> arguments,
  ) {
    final policy = switch (method) {
      'ui.render' ||
      'ui.update' ||
      'ui.openPage' ||
      'ui.getRenderSize' => ('ui', PluginPermissionRisk.low),
      'ui.dialog' || 'ui.openExternal' => ('ui', PluginPermissionRisk.medium),
      'file.read' ||
      'file.write' ||
      'file.list' ||
      'file.stat' ||
      'file.mkdir' ||
      'file.copy' ||
      'file.move' ||
      'file.remove' => ('file', PluginPermissionRisk.low),
      'file.pick' || 'file.unload' => ('file', PluginPermissionRisk.medium),
      'interconnect.send' ||
      'interconnect.observe' => ('interconnect', PluginPermissionRisk.medium),
      'provider.register' ||
      'provider.unregister' => ('provider', PluginPermissionRisk.medium),
      'device.list' ||
      'device.info' ||
      'device.apps.list' ||
      'watchface.list' => ('device', PluginPermissionRisk.medium),
      'device.connect' ||
      'device.disconnect' ||
      'device.apps.launch' ||
      'device.apps.uninstall' ||
      'device.install' ||
      'watchface.set' => ('device', PluginPermissionRisk.high),
      'protocol.observe' => ('protocol', PluginPermissionRisk.medium),
      'protocol.send' ||
      'protocol.request' => ('protocol', PluginPermissionRisk.high),
      'appside.list' ||
      'appside.sessions' ||
      'appside.events' => ('appside', PluginPermissionRisk.medium),
      'appside.start' ||
      'appside.stop' ||
      'appside.send' ||
      'appside.inject' ||
      'appside.clearEvents' ||
      'appside.zml.attach' ||
      'appside.zml.request' ||
      'appside.zml.call' ||
      'appside.zml.detach' => ('appside', PluginPermissionRisk.high),
      _ => null,
    };
    if (policy == null) return null;
    final resource = _jsPermissionResource(method, arguments);
    final scoped =
        method == 'ui.openExternal' ||
        method.startsWith('interconnect.') ||
        method.startsWith('device.') ||
        method.startsWith('protocol.') ||
        method.startsWith('watchface.') ||
        method.startsWith('appside.');
    return PluginPermissionRequest(
      pluginId: plugin.manifest.id,
      pluginName: plugin.manifest.name,
      capability: policy.$1,
      operation: method,
      risk: policy.$2,
      description: _jsPermissionDescription(method, resource),
      resource: resource,
      scope: scoped ? _jsPermissionScope(method, arguments, resource) : null,
    );
  }

  String? _jsPermissionScope(
    String method,
    List<Object?> args,
    String? resource,
  ) {
    final current = readDeviceState().currentDevice?.addr;
    if (method == 'interconnect.send') {
      return jsonEncode([
        args.elementAtOrNull(2)?.toString().isNotEmpty == true
            ? args[2]
            : current,
        args.firstOrNull,
      ]);
    }
    if (method == 'device.list' ||
        method == 'interconnect.observe' ||
        method == 'protocol.observe') {
      return null;
    }
    if (method == 'device.apps.launch' ||
        method == 'device.apps.uninstall' ||
        method == 'watchface.set') {
      return jsonEncode([current, args.firstOrNull]);
    }
    if (method == 'device.connect') {
      final requested = args.firstOrNull?.toString() ?? '';
      return jsonEncode([
        requested.isEmpty
            ? readDeviceState().pairedDevices.firstOrNull?.addr
            : requested,
      ]);
    }
    if (method == 'device.info' ||
        method == 'device.disconnect' ||
        method == 'device.apps.list') {
      final requested = args.firstOrNull?.toString() ?? '';
      return jsonEncode([requested.isEmpty ? current : requested]);
    }
    if (method.startsWith('protocol.') ||
        method.startsWith('device.') ||
        method.startsWith('watchface.')) {
      return jsonEncode([current]);
    }
    return resource;
  }

  String? _jsPermissionResource(String method, List<Object?> arguments) {
    if (method == 'ui.openExternal') {
      return Uri.tryParse(arguments.firstOrNull?.toString() ?? '')?.host;
    }
    if (method == 'interconnect.send' ||
        method.startsWith('device.apps.') ||
        method == 'watchface.set') {
      return arguments.firstOrNull?.toString();
    }
    if (method == 'device.connect' || method == 'device.disconnect') {
      return arguments.firstOrNull?.toString();
    }
    if (method.startsWith('device.') ||
        method.startsWith('protocol.') ||
        method.startsWith('watchface.')) {
      return readDeviceState().currentDevice?.name;
    }
    if (method.startsWith('appside.')) {
      return arguments.firstOrNull?.toString();
    }
    if (method == 'file.unload') return arguments.firstOrNull?.toString();
    return null;
  }

  String _jsPermissionDescription(String method, String? resource) {
    final target = resource?.isNotEmpty == true ? ' $resource' : '';
    return switch (method) {
      'file.pick' => 'select files from the host',
      'file.unload' => 'export a file$target',
      'interconnect.send' => 'communicate with$target',
      'interconnect.observe' => 'receive interconnect messages',
      'provider.register' => 'register a resource provider',
      'provider.unregister' => 'remove a resource provider',
      'device.list' => 'access paired devices',
      'device.info' => 'read information from$target',
      'device.connect' => 'connect to$target',
      'device.disconnect' => 'disconnect$target',
      'device.apps.list' => 'read applications from$target',
      'device.apps.launch' => 'launch$target',
      'device.apps.uninstall' => 'uninstall$target',
      'device.install' => 'install a file on$target',
      'protocol.observe' => 'observe the protocol of$target',
      'protocol.send' => 'send raw protocol data to$target',
      'protocol.request' => 'send a protocol request to$target',
      'watchface.list' => 'read watchface list from$target',
      'watchface.set' => 'switch the watchface on$target',
      'appside.list' => 'list cached app-side scripts',
      'appside.sessions' => 'view app-side sessions',
      'appside.events' => 'read app-side debug events',
      'appside.start' => "start app-side$target",
      'appside.stop' => "stop app-side$target",
      'appside.send' => "send app-side message to watch$target",
      'appside.inject' => "inject a simulated message into app-side$target",
      'appside.clearEvents' => "clear app-side debug events$target",
      _ => method,
    };
  }
}
