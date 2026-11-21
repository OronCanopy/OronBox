part of 'plugin_manager.dart';

extension _JsHost on PluginManager {
  void _registerJsProvider(String id, List<Object?> args) {
    final definition = _jsonMap(args.firstOrNull);
    final providerId = definition['id']?.toString() ?? '';
    final name = definition['name']?.toString() ?? '';
    if (!RegExp(r'^[a-z][a-z0-9]*(?:[.-][a-z0-9][a-z0-9-]*)+$')
            .hasMatch(providerId) ||
        name.isEmpty) {
      throw const FormatException('Invalid provider identity');
    }
    final callbacks = <String, String>{};
    for (final key in ['categories', 'query', 'detail', 'download']) {
      final callback = definition[key]?.toString() ?? '';
      if (callback.isEmpty && key != 'categories') {
        throw FormatException('Provider $key callback is required');
      }
      if (callback.isNotEmpty) callbacks[key] = callback;
    }
    final existing = _providers[providerId];
    if (existing != null && existing.pluginId != id) {
      throw StateError('Provider belongs to another plugin');
    }
    final provider = _PluginProvider(
      pluginId: id,
      id: providerId,
      name: name,
      callbacks: callbacks,
    );
    _providers[providerId] = provider;
    emitEvent(CommandEvent('plugin.provider', data: provider.toJson()));
  }

  Future<Object?> _dispatchJsHostCall(
    InstalledPlugin plugin,
    String method,
    List<Object?> args,
  ) async {
    final id = plugin.manifest.id;
    final session = _sessions[id];
    if (session == null) throw StateError('Plugin session ended');
    final permissionRevision = _permissionBroker.revision(id);
    final permission = _jsPermissionRequest(plugin, method, args);
    if (permission != null) {
      await _permissionBroker.authorize(plugin, permission);
    }
    _permissionBroker.requireRevision(id, permissionRevision);
    if (permission?.scope !=
        _jsPermissionRequest(plugin, method, args)?.scope) {
      throw const PluginPermissionException(
        'permission_changed',
        'Device target changed while awaiting approval',
      );
    }
    if (!identical(_sessions[id], session)) {
      throw StateError('Plugin session ended');
    }
    String text(int index) => args.elementAtOrNull(index)?.toString() ?? '';
    switch (method) {
      case 'runtime.reportError':
      case 'log.debug':
      case 'log.info':
      case 'log.warning':
      case 'log.error':
        logPluginDiagnostic(
          pluginId: id,
          runtime: plugin.manifest.runtime.name,
          level: method == 'log.debug'
              ? Level.FINE
              : method == 'log.info'
              ? Level.INFO
              : method == 'log.warning'
              ? Level.WARNING
              : Level.SEVERE,
          message: args.join(' '),
        );
        return null;
      case 'storage.get':
        if (text(0).isEmpty) {
          throw const FormatException('Storage key is required');
        }
        await session.storageWrites;
        return _requirePlugin(id).config[text(0)];
      case 'storage.set':
      case 'storage.remove':
      case 'storage.clear':
        final previous = session.storageWrites;
        final write = previous.catchError((_) {}).then((_) async {
          if (!identical(_sessions[id], session)) {
            throw StateError('Plugin session ended');
          }
          final current = _requirePlugin(id);
          final config = Map<String, Object?>.of(current.config);
          if (method == 'storage.clear') {
            config.clear();
          } else {
            if (text(0).isEmpty) {
              throw const FormatException('Storage key is required');
            }
            if (method == 'storage.set') {
              config[text(0)] = args.elementAtOrNull(1);
            } else {
              config.remove(text(0));
            }
          }
          await (await _storage).writeConfig(id, config);
          if (!identical(_sessions[id], session)) return;
          _plugins[id] = current.copyWith(config: config);
          _emitDiagnosticState(id);
        });
        session.storageWrites = write.then<void>((_) {}, onError: (_, _) {});
        return write;
      case 'file.read':
      case 'file.write':
      case 'file.list':
      case 'file.stat':
      case 'file.mkdir':
      case 'file.copy':
      case 'file.move':
      case 'file.remove':
        return _jsFileCall(id, session, method, args);
      case 'file.pick':
        return _pickSandboxFile(id, args);
      case 'file.unload':
        return _unloadSandboxFile(id, args);
      case 'network.fetch':
      case 'network.download':
        return _jsNetwork(plugin, session, method, args);
      case 'ui.render':
      case 'ui.update':
        await _renderUi(id, args);
        return null;
      case 'ui.openPage':
        final tree = await _resolveUiAssets(id, _parseUiTree(args.firstOrNull));
        if (!identical(_sessions[id], session)) {
          throw StateError('Plugin session ended');
        }
        _openPages[id] = tree;
        emitEvent(
          CommandEvent(
            'plugin.ui',
            data: {'id': id, 'nodes': tree, 'page': true},
          ),
        );
        return null;
      case 'ui.getRenderSize':
        return _getRenderSize(id);
      case 'ui.openExternal':
        return _executeHostCall(plugin, 'dialog.open-url', args);
      case 'ui.dialog':
        final options = _jsonMap(args.firstOrNull);
        return _requestHost(id, 'dialog', options);
      case 'os.language':
        return LocaleSettings.resolveActiveLocale().languageCode;
      case 'os.timezone':
        return DateTime.now().timeZoneOffset.inMinutes;
      case 'os.arch':
      case 'os.hostname':
      case 'os.locale':
      case 'os.platform':
      case 'os.version':
      case 'os.appearance':
        return _executeHostCall(plugin, method, args);
      case 'device.list':
        return _jsDeviceList();
      case 'device.info':
        return _jsDeviceInfo(text(0));
      case 'device.connect':
        return _connectJsDevice(text(0));
      case 'device.disconnect':
        await deviceManager.disconnect(text(0).isEmpty ? null : text(0));
        return null;
      case 'device.apps.list':
        _requireActiveDevice(text(0));
        await deviceManager.fetchApps();
        return readDeviceState().apps
            .map(
              (app) => {
                'packageName': app.packageName,
                'name': app.appName,
                'versionCode': app.versionCode,
                'canRemove': app.canRemove,
              },
            )
            .toList();
      case 'device.apps.launch':
        final options = _jsonMap(args.elementAtOrNull(1));
        _requireActiveDevice(options['deviceId']?.toString() ?? '');
        final app = await _jsApp(session, text(0));
        await deviceManager.openApp(
          app,
          page: options['page']?.toString() ?? '',
        );
        return null;
      case 'device.apps.uninstall':
        _requireActiveDevice('');
        final app = await _jsApp(session, text(0));
        await deviceManager.uninstallApp(app);
        return null;
      case 'device.install':
        await _installJsFile(id, session, args);
        return null;
      case 'interconnect.send':
        return _executeHostCall(plugin, 'interconnect.send-qaic-message', [
          _deviceAddress(text(2)),
          text(0),
          text(1),
        ]);
      case 'interconnect.observe':
        session.observeInterconnect = true;
        return null;
      case 'interconnect.unobserve':
        session.observeInterconnect = false;
        return null;
      case 'protocol.observe':
        session.observeProtocol = true;
        return null;
      case 'protocol.unobserve':
        session.observeProtocol = false;
        return null;
      case 'protocol.send':
      case 'protocol.request':
        final options = _jsonMap(args.elementAtOrNull(1));
        _requireActiveDevice(options['id']?.toString() ?? '');
        final bytes = _bytes(args.firstOrNull);
        if (method == 'protocol.send') {
          await deviceManager.sendProtocolPacket(
            bytes,
            deviceId: options['id']?.toString(),
            channel: (options['channel'] as num?)?.toInt(),
          );
          return null;
        }
        return {
          'data': base64Encode(
            await deviceManager.requestProtocolPacket(
              bytes,
              deviceId: options['id']?.toString(),
              channel: (options['channel'] as num?)?.toInt(),
              cancellation: session.stopped.stream,
              timeout: Duration(
                milliseconds: (options['timeout'] as num?)?.toInt() ?? 5000,
              ),
            ),
          ),
        };
      case 'watchface.list':
        _requireActiveDevice(text(0));
        await deviceManager.fetchWatchfaces();
        return readDeviceState().watchfaces
            .map(
              (face) => {
                'id': face.id,
                'name': face.name,
                'current': face.isCurrent,
              },
            )
            .toList();
      case 'watchface.set':
        _requireActiveDevice(text(1));
        final face = readDeviceState().watchfaces
            .where((face) => face.id == text(0))
            .firstOrNull;
        if (face == null) throw StateError('Watchface not found');
        await deviceManager.setWatchface(face);
        return null;
      case 'provider.register':
        _registerJsProvider(id, args);
        return null;
      case 'provider.unregister':
        final provider = _providers[text(0)];
        if (provider != null && provider.pluginId != id) {
          throw StateError('Provider belongs to another plugin');
        }
        _providers.remove(text(0));
        emitEvent(
          CommandEvent(
            'plugin.provider',
            data: {'id': text(0), 'removed': true},
          ),
        );
        return null;
      case 'appside.list':
        return _appSideList();
      case 'appside.start':
        await _appSideStart(args);
        return null;
      case 'appside.stop':
        await _appSideStop(args);
        return null;
      case 'appside.send':
        await _appSideSend(args);
        return null;
      case 'appside.inject':
        await _appSideInject(args);
        return null;
      case 'appside.sessions':
        return _appSideSessions();
      case 'appside.events':
        return _appSideEvents(args);
      case 'appside.clearEvents':
        await _appSideClearEvents(args);
        return null;
      case 'appside.zml.attach':
        await _appSideZmlAttach(plugin, args);
        return null;
      case 'appside.zml.detach':
        await _appSideZmlDetach(plugin, args);
        return null;
      case 'appside.zml.request':
        return _appSideZmlInvoke(plugin, args, 'request');
      case 'appside.zml.call':
        return _appSideZmlInvoke(plugin, args, 'call');
      case 'wasm.load':
      case 'wasm.call':
      case 'wasm.memory.read':
      case 'wasm.memory.write':
      case 'wasm.dispose':
        return _jsWasm(plugin, session, method, args);
      default:
        throw UnsupportedError('Unsupported OronBox JS host API $method');
    }
  }

  List<Map<String, Object?>> _jsDeviceList() {
    final state = readDeviceState();
    final connected = deviceManager.connectedAddresses;
    return state.pairedDevices
        .map(
          (device) => {
            'id': device.addr,
            'name': device.name,
            'connectType': device.connectType,
            if (device.codename != null) 'codename': device.codename,
            'connected': connected.contains(device.addr),
            'current': state.currentDevice?.addr == device.addr,
          },
        )
        .toList();
  }

  String _deviceAddress(String requested) {
    final address = requested.isEmpty
        ? readDeviceState().currentDevice?.addr
        : requested;
    if (address == null ||
        !deviceManager.connectedAddresses.contains(address)) {
      throw StateError('Device is not connected');
    }
    return address;
  }

  void _requireActiveDevice(String requested) {
    final address = _deviceAddress(requested);
    if (address != readDeviceState().currentDevice?.addr) {
      throw StateError('Device is not the active device');
    }
  }

  Map<String, Object?> _jsDeviceInfo(String requested) {
    _requireActiveDevice(requested);
    final state = readDeviceState();
    final device = state.currentDevice!;
    return {
      'id': device.addr,
      'name': device.name,
      if (device.codename != null) 'codename': device.codename,
      if (state.battery != null) 'battery': state.battery!.capacity,
      if (state.systemInfo != null) ...{
        'model': state.systemInfo!.model,
        'firmwareVersion': state.systemInfo!.firmwareVersion,
      },
    };
  }

  Future<Object?> _connectJsDevice(String requested) async {
    final device = readDeviceState().pairedDevices
        .where((device) => requested.isEmpty || device.addr == requested)
        .firstOrNull;
    if (device == null) throw StateError('Paired device not found');
    if (device.authkey?.isNotEmpty != true) {
      throw StateError('Device has no authentication key');
    }
    await deviceManager.connect(
      device.addr,
      device.name,
      device.authkey!,
      connectType: device.connectType,
    );
    return _jsDeviceInfo(device.addr);
  }

  Future<void> _installJsFile(
    String id,
    _PluginSession session,
    List<Object?> args,
  ) async {
    final path = PluginStoragePath.parse(args[0].toString());
    final options = _jsonMap(args.elementAtOrNull(1));
    final type = switch (options['type']) {
      'app' => LocalDeviceInstallType.app,
      'watchface' => LocalDeviceInstallType.watchface,
      'firmware' => LocalDeviceInstallType.firmware,
      _ => throw const FormatException('Unsupported install type'),
    };
    final bytes = await _withSessionFiles(
      id,
      session,
      () async => (await _storage).readFile(id, path),
    );
    if (!identical(_sessions[id], session)) {
      throw StateError('Plugin session ended');
    }
    await _installer.installLocalPayload(
      type: type,
      fileName:
          options['fileName']?.toString() ?? path.relativePath.split('/').last,
      bytes: bytes,
      deviceManager: deviceManager,
      onProgress: (progress) => emitEvent(
        CommandEvent(
          'plugin.installProgress',
          data: {'pluginId': id, 'progress': progress},
        ),
      ),
    );
  }

  Future<AppInfo> _jsApp(_PluginSession session, String packageName) async {
    await deviceManager.fetchApps();
    if (!_sessions.values.contains(session)) {
      throw StateError('Plugin session ended');
    }
    final app = readDeviceState().apps
        .where((app) => app.packageName == packageName)
        .firstOrNull;
    if (app == null) throw StateError('Application not found');
    return app;
  }
}
