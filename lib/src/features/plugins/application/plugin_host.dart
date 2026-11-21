part of 'plugin_manager.dart';

final class _PluginSession {
  final stopped = StreamController<void>.broadcast(sync: true);
  final interconnect = <(String, String)>{};
  Future<void> interconnectDelivery = Future.value();
  final interconnectSync = <(String, String), DateTime>{};
  Future<void> queueDelivery = Future.value();
  final transport = <(String, int, int)>{};
  final cards = <String, Map<String, Object?>>{};
  final saves = <int, ({String name, BytesBuilder bytes})>{};
  final translations = <String, Object?>{};
  final apps = <(String, String), AppInfo>{};
  WasmScope? wasmScope;
  final wasmInstances = <String, ScopedWasmInstance>{};
  Future<void> storageWrites = Future<void>.value();
  Future<void> fileOperations = Future<void>.value();
  Timer? idleTimer;
  DateTime? idleDeadline;
  final idleClock = Stopwatch();
  int activeOperations = 0;
  bool hadActivity = false;
  int nextWasm = 0;
  bool observeInterconnect = false;
  bool observeProtocol = false;
  int nextRequest = 0;
  int nextSave = 0;
  bool deeplink = false;
}

extension _PluginHost on PluginManager {
  Future<Object?> _executeHostCall(
    InstalledPlugin plugin,
    String method,
    List<Object?> args,
  ) async {
    final id = plugin.manifest.id;
    final session = _sessions[id];
    if (session == null) throw StateError('Plugin session ended');
    String text(int index) => args.elementAtOrNull(index)?.toString() ?? '';
    switch (method) {
      case 'websocket.connect':
      case 'websocket.send':
      case 'websocket.receive':
      case 'websocket.close':
        final received = await _websockets
            .putIfAbsent(
              id,
              () => PluginWebSockets(
                emit: (name, payload) async {
                  if (!identical(_sessions[id], session)) return;
                  final runtime = _runtimes[id];
                  if (runtime == null) return;
                  await _withActivity(
                    id,
                    () => runtime.dispatchEvent(
                      'plugin-message',
                      jsonEncode({
                        'eventName': name,
                        'payload': payload,
                        'host': true,
                      }),
                    ),
                  );
                },
              ),
            )
            .handle(method, args);
        if (method == 'websocket.receive' &&
            received != null &&
            identical(_sessions[id], session)) {
          _recordActivity(session);
          unawaited(_applyBackgroundPolicy(id));
        }
        return received;
      case 'mass.send':
        final options = _jsonMap(args[3]);
        final requestedEvent = (options['progress-event'] as String?)?.trim();
        final progressEvent = requestedEvent?.isEmpty == true
            ? null
            : requestedEvent;
        var lastProgress = -250;
        var delivery = Future<void>.value();
        final clock = Stopwatch()..start();
        void report(double progress) {
          if (progressEvent == null || !identical(_sessions[id], session)) {
            return;
          }
          if (progress < 1 && clock.elapsedMilliseconds - lastProgress < 250) {
            return;
          }
          lastProgress = clock.elapsedMilliseconds;
          delivery = delivery
              .then((_) async {
                if (!identical(_sessions[id], session)) return;
                await _runtimes[id]?.dispatchEvent(
                  'plugin-message',
                  jsonEncode({
                    'eventName': progressEvent,
                    'payload': jsonEncode({'progress': progress}),
                    'host': true,
                  }),
                );
              })
              .catchError((Object error) {
                PluginManager._log.fine('MASS progress delivery failed', error);
              });
        }
        await deviceManager.sendPluginMass(
          text(0).trim(),
          text(1),
          _bytes(args[2]),
          watchfaceId: options['watchface-id'] as String?,
          packageName: options['package-name'] as String?,
          onProgress: (progress) {
            if (progress < 1) report(progress.clamp(0, 1));
          },
        );
        report(1);
        await delivery;
        return null;
      case 'network.open':
      case 'network.read':
      case 'network.close':
        return _httpClients
            .putIfAbsent(id, PluginHttpClient.new)
            .handle(method, args);
      case 'ui.render':
        await _renderUi(id, args);
        return null;
      case 'ui.get-render-size':
        final size = await _getRenderSize(id);
        return {
          'width': (size['width'] as num? ?? 0).floor(),
          'height': (size['height'] as num? ?? 0).floor(),
        };
      case 'os.device-id':
        const key = 'plugins.installation_id';
        var value = SharedPrefsService.instance.getString(key);
        if (value == null) {
          final random = Random.secure();
          value =
              'oronbox-${List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
          await SharedPrefsService.instance.setString(key, value);
        }
        return value;
      case 'os.arch':
        return pluginHostArchitecture();
      case 'os.hostname':
        return pluginHostHostname();
      case 'os.locale':
        return pluginHostLocale();
      case 'os.platform':
        return pluginHostPlatform();
      case 'os.version':
        return pluginHostVersion();
      case 'os.astrobox-language':
        return LocaleSettings.resolveActiveLocale().toLanguageTag();
      case 'os.appearance':
        return switch (ThemeSettings.load().themeMode) {
          AppThemeMode.light => 'light',
          AppThemeMode.dark || AppThemeMode.oledDark => 'dark',
          AppThemeMode.system =>
            WidgetsBinding.instance.platformDispatcher.platformBrightness.name,
        };
      case 'os.timezone-offset-minutes':
        return DateTime.now().timeZoneOffset.inMinutes;
      case 'device.get-device-list':
      case 'device.get-connected-device-list':
        final connected = deviceManager.connectedAddresses;
        return readDeviceState().pairedDevices
            .where(
              (device) =>
                  method == 'device.get-device-list' ||
                  connected.contains(device.addr),
            )
            .map((device) => {'name': device.name, 'addr': device.addr})
            .toList();
      case 'device.disconnect-device':
        await deviceManager.disconnect(text(0));
        return null;
      case 'interconnect.send-qaic-message':
        final app =
            session.apps[(_pluginAddress(text(0)), text(1))] ??
            await _findApp(session, text(0), text(1));
        await deviceManager.sendPluginInterconnect(
          text(0),
          app,
          Uint8List.fromList(utf8.encode(text(2))),
        );
        return null;
      case 'register.register-interconnect-recv':
        _registerInterconnect(id, session, text(0), text(1));
        return null;
      case 'register.register-transport-recv':
        final filter = _jsonMap(args[1]);
        session.transport.add((
          text(0),
          (filter['xiaomi-vela-v5-channel-id'] as num).toInt(),
          (filter['xiaomi-vela-v5-protobuf-typeid'] as num).toInt(),
        ));
        return null;
      case 'register.register-deeplink-action':
        session.deeplink = true;
        return null;
      case 'register.register-provider':
        final name = text(0);
        final existing = _providers[name];
        if (existing != null && existing.pluginId != id) {
          throw StateError('Provider name is already registered');
        }
        final provider = _PluginProvider(
          pluginId: id,
          id: name,
          name: name,
          type: text(1),
        );
        _providers[name] = provider;
        emitEvent(CommandEvent('plugin.provider', data: provider.toJson()));
        return null;
      case 'register.register-card':
        session.cards[text(1)] = {
          'type': text(0),
          'id': text(1),
          'name': text(2),
        };
        emitEvent(
          CommandEvent(
            'plugin.card',
            data: {'pluginId': id, ...session.cards[text(1)]!},
          ),
        );
        return null;
      case 'event.send-event':
        final payload = jsonEncode({'eventName': text(0), 'payload': text(1)});
        for (final entry in _runtimes.entries.toList()) {
          if (entry.key != id) {
            unawaited(
              entry.value.dispatchEvent('plugin-message', payload).catchError((
                Object error,
              ) {
                PluginManager._log.warning('Plugin broadcast failed', error);
              }),
            );
          }
        }
        return null;
      case 'provider-callback.resolve-provider-action':
      case 'provider-callback.report-provider-action-progress':
        return false;
      case 'thirdpartyapp.get-thirdparty-app-list':
        final address = _pluginAddress(text(0));
        final revision = _deviceRevisions[address] ?? 0;
        final apps = await deviceManager.listPluginApps(text(0));
        if (!identical(_sessions[id], session) ||
            (_deviceRevisions[address] ?? 0) != revision) {
          throw StateError('Plugin or device session ended');
        }
        session.apps.removeWhere((key, _) => key.$1 == address);
        for (final app in apps) {
          session.apps[(address, app.packageName)] = app;
        }
        return apps
            .map(
              (app) => {
                'package-name': app.packageName,
                'fingerprint': app.fingerprint,
                'version-code': app.versionCode,
                'can-remove': app.canRemove,
                'app-name': app.appName,
              },
            )
            .toList();
      case 'thirdpartyapp.launch-qa':
        final info = _jsonMap(args[1]);
        final app = AppInfo(
          packageName: info['package-name'] as String,
          fingerprint: (info['fingerprint'] as List).cast<int>(),
          versionCode: info['version-code'] as int,
          canRemove: info['can-remove'] as bool,
          appName: info['app-name'] as String,
        );
        await deviceManager.launchPluginApp(text(0), app, text(2));
        return null;
      case 'watchface.get-watchface-list':
        return (await deviceManager.listPluginWatchfaces(text(0)))
            .map(
              (face) => {
                'id': face.id,
                'name': face.name,
                'is-current': face.isCurrent,
              },
            )
            .toList();
      case 'watchface.set-current-watchface':
        await deviceManager.setPluginWatchface(text(0), text(1));
        return null;
      case 'transport.to-json':
        return XiaomiPluginProtocol.toJson(_bytes(args[1]));
      case 'transport.from-json':
        return XiaomiPluginProtocol.fromJson(text(1));
      case 'transport.send':
        await deviceManager.sendProtocolPacket(
          _bytes(args[1]),
          deviceId: text(0),
        );
        return null;
      case 'transport.request':
        return deviceManager.requestProtocolPacket(
          _bytes(args[1]),
          deviceId: text(0),
          cancellation: session.stopped.stream,
        );
      case 'clipboard.read-text':
        return (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
      case 'clipboard.write-text':
        await Clipboard.setData(ClipboardData(text: text(0)));
        return null;
      case 'dialog.open-url':
        final response = await _requestHost(id, 'openUrl', {'url': text(0)});
        if (response['opened'] != true) throw StateError('Unable to open URL');
        return null;
      case 'dialog.show-dialog':
        final info = _jsonMap(args[2]);
        final response = await _requestHost(id, 'dialog', {
          'title': info['title'],
          'message': info['content'],
          'input': text(0) == 'INPUT',
          'buttons': (info['buttons'] as List)
              .cast<Map>()
              .map((button) => {...button, 'text': button['content']})
              .toList(),
        });
        return {
          'clicked-btn-id': response['clickedBtnId'] ?? '',
          'input-result': response['inputResult'] ?? '',
        };
      case 'dialog.pick-file':
        final config = _jsonMap(args[0]);
        final filter = _jsonMap(args[1]);
        final response = await _requestHost(id, 'pickFile', filter);
        if (response['cancelled'] == true) return {'name': '', 'data': <int>[]};
        final bytes = _bytes(response['bytes']);
        final name = response['name'].toString();
        final copyTo = config['copy-to']?.toString();
        if (copyTo != null && copyTo.isNotEmpty) {
          if (copyTo.startsWith('/') || copyTo.contains('\\')) {
            throw const FormatException('Copy target must be a relative path');
          }
          var target = copyTo;
          final leaf = copyTo.split('/').last;
          if (leaf == '.' || !leaf.contains('.')) target = '$copyTo/$name';
          await _withSessionFiles(id, session, () async {
            await (await _storage).writeFile(
              id,
              _ngPath(target),
              bytes,
              allowPackageWrite: true,
            );
          });
        }
        return {
          'name': name,
          'data': config['read'] == true ? bytes.toList() : <int>[],
        };
      case 'dialog.save-file-start':
        final filter = _jsonMap(args[0]);
        final sessionId = ++session.nextSave;
        final name = filter['default-file-name']?.toString() ?? 'download.bin';
        session.saves[sessionId] = (
          name: name,
          bytes: BytesBuilder(copy: false),
        );
        return {'session-id': sessionId, 'name': name};
      case 'dialog.save-file-write-chunk':
        final save = session.saves[(args[0] as num).toInt()];
        if (save == null) throw StateError('Unknown save session');
        save.bytes.add(_bytes(args[1]));
        return null;
      case 'dialog.save-file-finish':
        final save = session.saves.remove((args[0] as num).toInt());
        if (save == null) throw StateError('Unknown save session');
        final response = await _requestHost(id, 'saveFile', {
          'name': save.name,
          'bytes': save.bytes.takeBytes().toList(),
        });
        if (response['cancelled'] == true) {
          throw StateError('File save cancelled');
        }
        return null;
      case 'dialog.save-file-abort':
        session.saves.remove((args[0] as num).toInt());
        return null;
      case 'queue.add-resource-to-queue':
        await _enqueueSandboxFile(id, [
          _ngPath(text(1)).virtualPath,
          {'type': text(0) == 'quickapp' ? 'app' : text(0)},
        ]);
        return null;
      case 'queue.enqueue-install':
        return _enqueuePluginInstall(id, session, _jsonMap(args.single));
      case 'queue.cancel-task':
        final queue = _taskQueue;
        final task = queue?.get(text(0));
        if (task == null || task.command.params['pluginId'] != id) {
          throw StateError('no such task');
        }
        if (!{'pending', 'held', 'waiting_device'}.contains(task.status)) {
          throw StateError('Task has already started or finished');
        }
        if (!queue!.cancel(task.id)) {
          throw StateError('Task cannot be canceled');
        }
        return null;
      case 'i18n.load-json':
        session.translations.addAll(
          (jsonDecode(text(0)) as Map).cast<String, Object?>(),
        );
        return null;
      case 'http-server.start':
      case 'http-server.stop':
      case 'http-server.list-servers':
        return _httpServers
            .putIfAbsent(
              id,
              () => PluginHttpServers(
                call: (name, args) {
                  if (name != 'handle') {
                    return _runtimes[id]!.callExport(name, args);
                  }
                  _recordActivity(session);
                  return _withActivity(
                    id,
                    () => _runtimes[id]!.callExport(name, args),
                  );
                },
              ),
            )
            .handle(method, args);
      case 'browser.open':
      case 'browser.wait-for-intercept':
      case 'browser.navigate':
      case 'browser.current-url':
      case 'browser.eval':
      case 'browser.get-cookies':
      case 'browser.close':
        return _browsers
            .putIfAbsent(id, () => PluginBrowserSessions(pluginId: id))
            .handle(method, args);
      case 'canopusconnect.send':
        final payload = _jsonMap(args[2]);
        final transition = _canopusTransitions[(text(0), text(1))];
        if (transition != null) await transition.catchError((Object _) {});
        await deviceManager.sendPluginCanopus(
          text(0),
          text(1),
          payload['case'] == 'text'
              ? Uint8List.fromList(utf8.encode(payload['value'].toString()))
              : _bytes(payload['value']),
          isText: payload['case'] == 'text',
        );
        return null;
      case 'canopusconnect.listen':
        await _listenCanopus(id, text(0), text(1), true);
        return null;
      case 'canopusconnect.unlisten':
        await _listenCanopus(id, text(0), text(1), false);
        return null;
      case 'notification.send':
        await deviceManager.sendPluginNotification(
          text(0),
          id,
          _jsonMap(args[1]),
        );
        return null;
      case 'notification.remove':
        await deviceManager.removePluginNotification(
          text(0),
          id,
          (args[1] as num).toInt(),
        );
        return null;
      default:
        throw UnsupportedError('Unsupported plugin host API $method');
    }
  }

  Future<AppInfo> _findApp(
    _PluginSession session,
    String addr,
    String package,
  ) async {
    final address = _pluginAddress(addr);
    final revision = _deviceRevisions[address] ?? 0;
    final apps = await deviceManager.listPluginApps(addr);
    if (!_sessions.values.contains(session) ||
        (_deviceRevisions[address] ?? 0) != revision) {
      throw StateError('Plugin or device session ended');
    }
    for (final app in apps) {
      session.apps[(address, app.packageName)] = app;
    }
    final app = session.apps[(address, package)];
    if (app == null) throw StateError('Quick app is not installed');
    return app;
  }

  PluginStoragePath _dataPath(String path) =>
      PluginStoragePath.parse(path.startsWith('/') ? path : '/data/$path');

  PluginStoragePath _ngPath(String path) => PluginStoragePath.parse(
    path.startsWith('/')
        ? path
        : '/plugin/${path.split('/').where((part) => part.isNotEmpty && part != '.').join('/')}',
  );
}
