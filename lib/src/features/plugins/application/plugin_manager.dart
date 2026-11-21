import 'package:oronbox/src/features/plugins/application/plugin_repository.dart'
    show comparePluginVersions;
import 'package:oronbox/src/features/settings/application/app_data_maintenance.dart';

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:math';

import '../domain/plugin_host_settings.dart';

import 'package:oronbox/src/core/services/background_task_guard.dart';

import 'package:flutter/services.dart';
import 'package:oronbox/src/device/xiaomi/protocol/xiaomi_plugin_protocol.dart';
import 'package:oronbox/src/device/xiaomi/protocol/generated/wear.pb.dart'
    as xiaomi_pb;
import 'package:oronbox/src/device/core/event_bus.dart';
import 'package:oronbox/src/features/plugins/application/plugin_http_servers.dart';
import 'package:oronbox/src/features/plugins/widgets/plugin_browser_sessions.dart';

import 'package:material_ui/material_ui.dart';
import 'package:oronbox/src/commands/command_protocol.dart';
import 'package:oronbox/src/core/logging/logging_service.dart';
import 'package:oronbox/src/core/models/bt_models.dart';

import 'plugin_http_client.dart';
import 'plugin_websockets.dart';

import 'package:oronbox/src/host/tasks/task_queue.dart';
import 'package:oronbox/src/core/storage/managed_temporary_files.dart';

import 'package:oronbox/src/core/services/build_info_service.dart';
import 'package:oronbox/src/core/services/shared_prefs_service.dart';
import 'package:oronbox/src/core/providers/theme_locale_providers.dart';
import 'package:oronbox/src/features/devices/controllers/device_manager.dart';
import 'package:oronbox/src/features/plugins/domain/plugin_execution_models.dart';
import 'package:oronbox/src/features/plugins/domain/plugin_package.dart';
import 'package:oronbox/src/features/plugins/domain/plugin_permission.dart';
import 'package:oronbox/src/features/plugins/application/plugin_permission_broker.dart';
import 'package:oronbox/src/features/plugins/application/plugin_host_environment.dart';
import 'package:oronbox/src/features/plugins/runtime/plugin_runtime.dart';
import 'package:oronbox/src/features/plugins/runtime/plugin_runtime_wasm.dart';
import 'package:oronbox/src/features/plugins/runtime/plugin_runtime_js.dart';
import 'package:oronbox/src/features/plugins/runtime/plugin_wasi_sandbox.dart';
import 'package:oronbox/src/core/wasm/wasm_runtime.dart';
import 'package:oronbox/src/core/wasm/wasm_compatibility.dart';
import 'package:oronbox/src/features/resources/services/resource_install_service.dart';
import 'package:oronbox/src/features/plugins/storage/plugin_storage.dart';
import 'package:oronbox/src/features/plugins/storage/plugin_storage_factory.dart';

export 'package:oronbox/src/features/plugins/domain/plugin_execution_models.dart';

part 'plugin_management.dart';
part 'plugin_background_lifecycle.dart';
part 'plugin_host.dart';
part 'plugin_ng_host.dart';
part 'plugin_js_host.dart';
part 'plugin_js_permissions.dart';
part 'plugin_host_wasm.dart';
part 'plugin_host_files.dart';
part 'plugin_host_appside.dart';
part 'plugin_host_network.dart';
part 'plugin_host_interconnect.dart';
part 'plugin_host_queue.dart';

class PluginManager {
  PluginManager({
    required this.deviceManager,
    required this.readDeviceState,
    required this.emitEvent,
    this.backgroundIdleTimeout = const Duration(minutes: 10),
  }) : _safeMode =
           SharedPrefsService.instance.getBool(_safeModePreference) ?? false {
    _interconnectSubscription = deviceManager.interconnectMessages.listen((
      message,
    ) {
      _queueInterconnectDispatch(
        message.deviceId,
        message.pkgName,
        message.payload,
      );
    });
    _backgroundExpirationSubscription = backgroundTaskExpirations.listen((ids) {
      unawaited(
        _backgroundExpired(ids).catchError((Object error, StackTrace stack) {
          _log.warning(
            'Plugin background expiration cleanup failed',
            error,
            stack,
          );
        }),
      );
    });
    _deviceSubscription = deviceManager.deviceEvents.listen(
      _dispatchDeviceEvent,
    );
  }

  static final _log = getLogger('PluginManager');
  static const _safeModePreference = 'plugins.safe_mode';
  static const _operationTimeout = Duration(minutes: 5);

  final Duration backgroundIdleTimeout;
  final DeviceManager deviceManager;
  final DeviceManagerState Function() readDeviceState;
  final void Function(CommandEvent event) emitEvent;
  final _plugins = <String, InstalledPlugin>{};
  final _hostSettings = <String, Map<String, Object?>>{};
  final _hostWrites = <String, Future<void>>{};
  final _managementOperations = <String, Future<void>>{};
  Future<void> _lifecycleTransition = Future<void>.value();
  Future<void>? _automaticStartup;
  final _views = <String, Map<String, bool>>{};
  final _backgroundTasks = <String, BackgroundTaskHandle>{};
  final _suspendedPlugins = <String>{};
  final _suspendedDeadlines = <String, DateTime>{};
  bool _foreground = true;
  final _runtimeStarts = <String, Future<PluginRuntime>>{};
  final _runtimeStops = <String, Future<void>>{};
  final _runtimeLifetimes = <String, Object>{};
  final _runtimes = <String, PluginRuntime>{};
  final _sessions = <String, _PluginSession>{};
  final _pendingInterconnect =
      Queue<
        ({String addr, String package, String payload, DateTime received})
      >();
  final _httpServers = <String, PluginHttpServers>{};
  final _httpClients = <String, PluginHttpClient>{};
  final _websockets = <String, PluginWebSockets>{};
  final _deviceRevisions = <String, int>{};
  HostTaskQueue? _taskQueue;
  StreamSubscription<CommandEvent>? _taskSubscription;
  final _browsers = <String, PluginBrowserSessions>{};
  final _uiRevisions = <(String, String), int>{};
  final _uiNodes = <String, Object?>{};
  final _openPages = <String, Object?>{};
  final _hostRequests =
      <
        String,
        ({
          String pluginId,
          String type,
          Map<String, Object?> data,
          Completer<Map<String, Object?>> result,
        })
      >{};
  final _hostRequestOwners = <String, String>{};
  final _zmlAttachments = <int, _PluginZmlAttachment>{};
  final _zmlTransitions = <int, Future<void>>{};
  final _installer = ResourceInstallService();
  final _providers = <String, _PluginProvider>{};
  final _failures = <String, PluginExecutionFailure>{};
  Future<void> _runtimeTransition = Future<void>.value();
  late final Future<PluginStorage> _storage = createPluginStorage();
  late final PluginPermissionBroker _permissionBroker = PluginPermissionBroker(
    prompt: _promptPermission,
    readPersistentGrants: (id) async =>
        (await _storage).readPermissionGrants(id),
    writePersistentGrants: (id, grants) async =>
        (await _storage).writePermissionGrants(id, grants),
    readPolicies: (id) async =>
        ((await _settingsFor(id))['permissionPolicies'] as Map? ?? {})
            .cast<String, Object?>(),
    writePolicies: (id, policies) async {
      await _writeHostPatch(id, {'permissionPolicies': policies});
      _emitState(id);
    },
  );
  late final StreamSubscription _interconnectSubscription;
  late final StreamSubscription _deviceSubscription;
  late final StreamSubscription _backgroundExpirationSubscription;
  final _canopusSubscriptions = <(String, String), Set<String>>{};
  final _canopusTransitions = <(String, String), Future<void>>{};
  Future<void>? _initialization;
  var _requestSequence = 0;
  var _closed = false;
  bool _safeMode;

  late final dataMaintenance = AppDataMaintenance(
    deviceManager: deviceManager,
    initialize: initialize,
    stopRuntimes: () async {
      await Future.wait(_managementOperations.values.toList());
      await _closeAllRuntimes();
      await _permissionBroker.drainWrites();
      await Future.wait(_hostWrites.values.toList());
    },
    reload: () async {
      final installed = await (await _storage).loadInstalled();
      _hostSettings.clear();
      await _permissionBroker.reload();
      _suspendedPlugins.clear();
      _suspendedDeadlines.clear();
      for (final plugin in installed) {
        await _settingsFor(plugin.manifest.id);
      }
      _plugins
        ..clear()
        ..addEntries(
          installed.map((plugin) => MapEntry(plugin.manifest.id, plugin)),
        );
    },
  );
  bool get maintainingData => dataMaintenance.active;

  Future<void> initialize() => _initialization ??= _loadInstalledPlugins();

  Future<void> _loadInstalledPlugins() async {
    try {
      final installed = await (await _storage).loadInstalled();
      for (final plugin in installed) {
        _plugins[plugin.manifest.id] = plugin;
        try {
          await _settingsFor(plugin.manifest.id);
        } catch (error, stack) {
          _log.warning(
            'Unable to load host settings for ${plugin.manifest.id}',
            error,
            stack,
          );
          // Corrupt settings must never implicitly activate a plugin.
          _hostSettings[plugin.manifest.id] = {'enabled': false};
        }
      }
    } catch (error, stackTrace) {
      _log.warning('Unable to load installed plugins', error, stackTrace);
    }
  }

  bool get safeMode => _safeMode;

  List<Map<String, Object?>> failures() => _failures.values
      .map((failure) => failure.toJson())
      .toList(growable: false);

  List<Map<String, Object?>> diagnosticSources() => _plugins.values
      .map(
        (plugin) => {
          'id': plugin.manifest.id,
          'name': plugin.manifest.name,
          'runtime': plugin.manifest.runtime.name,
          'running': _runtimes.containsKey(plugin.manifest.id),
        },
      )
      .toList(growable: false);

  List<Map<String, Object?>> diagnostics() =>
      _plugins.keys.map(diagnosticSnapshot).toList(growable: false);

  Map<String, Object?> diagnosticSnapshot(String id) {
    final plugin = _requirePlugin(id);
    final running = _runtimes.containsKey(id);
    return {
      'id': id,
      'name': plugin.manifest.name,
      'version': plugin.manifest.version,
      'runtime': plugin.manifest.runtime.name,
      'running': running,
      'state': running ? 'running' : 'stopped',
      'runtimeState': _runtimes[id]?.diagnostics ?? const {},
      if (_sessions[id] case final session?)
        'hostState': {
          'cards': session.cards.values.toList(),
          'translationLocales': session.translations.keys.toList(),
          'deeplinkRegistered': session.deeplink,
        },
      'layout': _uiNodes[id] ?? const <Map<String, Object?>>[],
      'storage': plugin.config,
      'wasmInstances': running ? 1 : 0,
      'permissions': plugin.manifest.permissions,
      if (_failures[id] case final failure?) 'failure': failure.toJson(),
    };
  }

  Future<List<Map<String, Object?>>> diagnosticStorageDirectory(
    String id,
    String path,
  ) async {
    await initialize();
    _requirePlugin(id);
    if (path.isEmpty) {
      return const [
        {'name': 'plugin', 'path': '/plugin', 'isDirectory': true},
        {'name': 'data', 'path': '/data', 'isDirectory': true},
        {'name': 'cache', 'path': '/cache', 'isDirectory': true},
        {'name': 'temp', 'path': '/temp', 'isDirectory': true},
      ];
    }
    final entries = await (await _storage).listDirectory(
      id,
      PluginStoragePath.parse(path),
    );
    return entries
        .map((entry) {
          final segments = entry.path
              .split('/')
              .where((part) => part.isNotEmpty);
          return {
            ...entry.toJson(),
            'name': segments.isEmpty ? entry.path : segments.last,
          };
        })
        .toList(growable: false)
      ..sort((a, b) {
        final directoryOrder =
            (b['isDirectory'] == true ? 1 : 0) -
            (a['isDirectory'] == true ? 1 : 0);
        return directoryOrder != 0
            ? directoryOrder
            : a['name'].toString().toLowerCase().compareTo(
                b['name'].toString().toLowerCase(),
              );
      });
  }

  Future<Map<String, Object?>> diagnosticStorageFile(
    String id,
    String path,
  ) async {
    await initialize();
    _requirePlugin(id);
    final bytes = await (await _storage).readFile(
      id,
      PluginStoragePath.parse(path),
    );
    const previewLimit = 1024 * 1024;
    final preview = bytes.take(previewLimit).toList(growable: false);
    final binary = preview.any((byte) => byte == 0);
    return {
      'path': path,
      'size': bytes.length,
      'truncated': bytes.length > preview.length,
      'format': binary ? 'hex' : 'text',
      'content': binary
          ? preview
                .take(4096)
                .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
                .toList()
                .asMap()
                .entries
                .map(
                  (entry) => entry.key % 16 == 15
                      ? '${entry.value}\n'
                      : '${entry.value} ',
                )
                .join()
                .trimRight()
          : utf8.decode(preview, allowMalformed: true),
    };
  }

  Future<void> setSafeMode(bool enabled) async {
    await initialize();
    if (_safeMode == enabled) return;
    _safeMode = enabled;
    await SharedPrefsService.instance.setBool(_safeModePreference, enabled);
    if (enabled) {
      _suspendedPlugins.clear();
      _suspendedDeadlines.clear();
      await _closeAllRuntimes();
    }
    emitEvent(CommandEvent('plugin.safeMode', data: {'enabled': enabled}));
    if (!enabled) {
      _automaticStartup = null;
      await startAutomaticPlugins();
    }
  }

  Future<List<Map<String, Object?>>> list({bool includeIcons = true}) async {
    await initialize();
    return Future.wait(
      _plugins.values.map(
        (plugin) => _summary(plugin, includeIcon: includeIcons),
      ),
    );
  }

  Future<Map<String, Object?>> install(
    Uint8List bytes, {
    bool includeIcon = true,
    ({String id, String runtime, String version})? expectedUpdate,
  }) async {
    if (maintainingData) throw StateError('Data maintenance is active');
    await initialize();
    final package = const PluginPackageReader().read(bytes);
    final id = package.manifest.id;
    if (expectedUpdate != null &&
        (id != expectedUpdate.id ||
            package.manifest.runtime.name != expectedUpdate.runtime ||
            package.manifest.version != expectedUpdate.version)) {
      throw StateError('Plugin update does not match the catalog');
    }
    return _withManagement(id, () async {
      final previous = _plugins[id];
      if (expectedUpdate != null) {
        if (previous == null ||
            previous.manifest.runtime != package.manifest.runtime) {
          throw StateError('Plugin is no longer installed');
        }
        if (comparePluginVersions(
              package.manifest.version,
              previous.manifest.version,
            ) <=
            0) {
          return _summary(previous, includeIcon: includeIcon);
        }
      }
      final config = previous?.config ?? const <String, Object?>{};
      await _closeRuntime(id);
      _failures.remove(id);
      final plugin = await (await _storage).install(package, config: config);
      _plugins[id] = plugin;
      _emitState(id);
      return _summary(plugin, includeIcon: includeIcon);
    });
  }

  Future<Map<String, Object?>> get(String id) async {
    await initialize();
    final plugin = _requirePlugin(id);
    return {
      ...await _summary(plugin),
      'ui': _uiNodes[id] ?? const <Object?>[],
      'page': _openPages[id],
      'permissionPolicies': await _permissionBroker.policies(id),
    };
  }

  Future<Object?> open(String id, {bool interactive = false}) async {
    await initialize();
    final plugin = _requirePlugin(id);
    _checkActivation(id);
    await WasmCompatibility.shared.ensureAllowed(interactive: interactive);
    _failures.remove(id);
    return _runPluginOperation(plugin, 'open', () async {
      await _ensureRuntime(id);
      return _uiNodes[id] ?? const <Object?>[];
    });
  }

  Future<Object?> invoke(String id, String callbackId, Object? value) async {
    await initialize();
    final plugin = _requirePlugin(id);
    _checkActivation(id);
    return _runPluginOperation(plugin, 'callback', () async {
      final failure = _failures[id];
      if (failure != null) throw PluginExecutionException.fromFailure(failure);
      final runtime = await _ensureRuntime(id);
      await runtime.invokeCallback(callbackId, value);
      return _uiNodes[id] ?? const <Object?>[];
    });
  }

  Future<void> closePlugin(String id) async {
    await initialize();
    _requirePlugin(id);
    _suspendedPlugins.remove(id);
    _suspendedDeadlines.remove(id);
    await _closeRuntime(id);
    _emitState(id);
  }

  Future<void> clearData(String id) async {
    if (maintainingData) throw StateError('Data maintenance is active');
    await initialize();
    await _withManagement(id, () async {
      final plugin = _requirePlugin(id);
      _suspendedPlugins.remove(id);
      _suspendedDeadlines.remove(id);
      await _closeRuntime(id);
      await _permissionBroker.clearPlugin(id);
      await _awaitHostWrites(id);
      await (await _storage).clearPluginData(id);
      _hostSettings.remove(id);
      _plugins[id] = plugin.copyWith(config: const {});
      _failures.remove(id);
      _uiNodes.remove(id);
      _openPages.remove(id);
      _emitState(id);
    });
  }

  Future<void> remove(String id) async {
    if (maintainingData) throw StateError('Data maintenance is active');
    await initialize();
    await _withManagement(id, () async {
      _requirePlugin(id);
      await _closeRuntime(id);
      await _permissionBroker.clearPlugin(id);
      await _awaitHostWrites(id);
      await (await _storage).removePlugin(id);
      _hostSettings.remove(id);
      _views.remove(id);
      _suspendedPlugins.remove(id);
      _suspendedDeadlines.remove(id);
      _plugins.remove(id);
      _failures.remove(id);
      _uiNodes.remove(id);
      _providers.removeWhere((_, provider) => provider.pluginId == id);
      _emitState(id);
    });
  }

  Future<void> respondToHostRequest(
    String requestId,
    Map<String, Object?> response, {
    String? owner,
  }) async {
    if (owner != null && _hostRequestOwners[requestId] != owner) return;
    _hostRequestOwners.remove(requestId);
    final request = _hostRequests.remove(requestId);
    if (request == null) {
      _log.warning('received response for unknown host request $requestId');
      return;
    }
    _log.info(
      'host request $requestId completed '
      '(cancelled=${response['cancelled'] == true})',
    );
    request.result.complete(response);
    if ({'pickFile', 'saveFile', 'openUrl'}.contains(request.type)) {
      Timer.run(() {
        if (!_closed && !_foreground) {
          unawaited(
            setForeground(false).catchError((Object error, StackTrace stack) {
              _log.warning(
                'Plugin suspension after host interaction failed',
                error,
                stack,
              );
            }),
          );
        }
      });
    }
  }

  Future<List<Map<String, Object?>>> providers() async {
    await initialize();
    return _providers.values
        .map((provider) => provider.toJson())
        .toList(growable: false);
  }

  bool providerAvailable(String id) =>
      _providers[id]?.callbacks.isNotEmpty == true;

  Future<Object?> callProvider(
    String id,
    String operation,
    List<Object?> args,
  ) async {
    await initialize();
    final provider = _providers[id];
    if (provider == null || provider.callbacks.isEmpty) {
      throw StateError('plugin_provider_unavailable');
    }
    final plugin = _requirePlugin(provider.pluginId);
    return _runPluginOperation(plugin, 'provider.$operation', () async {
      final runtime = await _ensureRuntime(provider.pluginId);
      if (runtime is! JavaScriptPluginRuntime) {
        throw StateError('plugin_provider_unavailable');
      }
      final callback = provider.callbacks[operation];
      if (callback == null && operation == 'categories') return <Object?>[];
      if (callback == null) {
        throw UnsupportedError('Provider operation $operation');
      }
      return runtime.invokeRegistered(callback, args);
    });
  }

  Future<Uint8List> readProviderFile(String id, String path) async {
    final provider = _providers[id];
    if (provider == null || provider.callbacks.isEmpty) {
      throw StateError('plugin_provider_unavailable');
    }
    return (await _storage).readFile(
      provider.pluginId,
      PluginStoragePath.parse(path),
    );
  }

  String providerDisplayName(String id) => _providers[id]?.name ?? id;

  Future<PluginRuntime> _ensureRuntime(String id) async {
    await initialize();
    if (_closed) throw StateError('Plugin manager is closed');
    final plugin = _requirePlugin(id);
    await _managementOperations[id];
    _checkActivation(id);
    if (_safeMode || maintainingData) {
      throw PluginExecutionException(
        plugin.manifest.id,
        plugin.manifest.name,
        'Plugins are disabled in safe mode',
      );
    }
    final failure = _failures[id];
    if (failure != null) throw PluginExecutionException.fromFailure(failure);
    final pending = _runtimeStarts[id];
    if (pending != null) return pending;
    if (_runtimes[id] case final runtime?) return runtime;
    final lifetime = _runtimeLifetimes.putIfAbsent(id, Object.new);
    late final Future<PluginRuntime> start;
    start = _runtimeTransition.catchError((_) {}).then((_) {
      if (_closed || !identical(_runtimeStarts[id], start)) {
        throw StateError('Plugin startup cancelled');
      }
      return _startRuntime(id, lifetime);
    });
    _runtimeTransition = start.then<void>((_) {}, onError: (_, _) {});
    _runtimeStarts[id] = start;
    try {
      return await start;
    } finally {
      if (identical(_runtimeStarts[id], start)) {
        _runtimeStarts.remove(id);
      }
    }
  }

  Future<PluginRuntime> _startRuntime(String id, Object lifetime) async {
    final plugin = _requirePlugin(id);
    await _closeRuntime(id, cancelStart: false);
    _uiNodes.remove(id);
    _providers.removeWhere((_, provider) => provider.pluginId == id);
    final storage = await _storage;
    if (_closed || !identical(_runtimeLifetimes[id], lifetime)) {
      throw StateError('Plugin startup cancelled');
    }
    final PluginRuntime runtime =
        plugin.manifest.runtime == PluginRuntimeType.wasm
        ? WasmPluginRuntime(storage: storage)
        : JavaScriptPluginRuntime(
            entryName: plugin.manifest.entry,
            modules: await _javaScriptSources(id),
          );
    if (_closed || !identical(_runtimeLifetimes[id], lifetime)) {
      throw StateError('Plugin startup cancelled');
    }
    _sessions[id] = _PluginSession();
    _runtimes[id] = runtime;
    try {
      if (!_foreground &&
          _settings(id).background != PluginBackgroundMode.forbidden) {
        await _beginPluginBackground(id);
      }
      if (_closed ||
          !identical(_runtimes[id], runtime) ||
          !identical(_runtimeLifetimes[id], lifetime)) {
        throw StateError('Plugin startup cancelled');
      }
      if (!_foreground && !_backgroundTasks.containsKey(id)) {
        _suspendedPlugins.add(id);
        throw PluginExecutionException(
          id,
          plugin.manifest.name,
          'Background execution unavailable',
        );
      }
      await runtime.start(
        pluginId: id,
        pluginName: plugin.manifest.name,
        pluginVersion: plugin.manifest.version,
        runtimeVersion: BuildInfoService.appVersion,
        apiLevel: plugin.manifest.apiLevel,
        entryBytes: plugin.entryBytes,
        hostCall: (method, arguments) {
          if (!identical(_runtimes[id], runtime)) {
            throw StateError('Plugin instance has stopped');
          }
          return _handleHostCall(plugin, method, arguments);
        },
      );
      if (!identical(_runtimes[id], runtime)) {
        await runtime.close();
        throw StateError('Plugin stopped during startup');
      }
      await runtime.renderUi();
      _emitState(id);
      return runtime;
    } catch (_) {
      _providers.removeWhere((_, provider) => provider.pluginId == id);
      if (identical(_runtimes[id], runtime)) await _closeRuntime(id);
      rethrow;
    }
  }

  Future<void> _closeRuntime(String id, {bool cancelStart = true}) {
    if (cancelStart) {
      _runtimeStarts.remove(id);
      _runtimeLifetimes.remove(id);
    }
    if (_runtimeStops[id] case final stopping?) return stopping;
    late final Future<void> stopping;
    stopping = _disposeRuntime(id).whenComplete(() {
      if (identical(_runtimeStops[id], stopping)) _runtimeStops.remove(id);
    });
    _runtimeStops[id] = stopping;
    return stopping;
  }

  Future<void> _disposeRuntime(String id) async {
    final runtime = _runtimes.remove(id);
    final session = _sessions.remove(id);
    session?.idleTimer?.cancel();
    session?.idleClock.stop();
    _openPages.remove(id);
    session?.stopped.add(null);
    session?.wasmScope?.dispose();
    final appSides = <int>[
      for (final appId
          in _zmlAttachments.entries
              .where((e) => e.value.pluginId == id)
              .map((e) => e.key)
              .toList())
        appId,
    ];
    for (final appId in appSides) {
      _zmlAttachments.remove(appId);
    }
    _permissionBroker.endSession(id);
    _uiNodes.remove(id);
    _uiRevisions.removeWhere((key, _) => key.$1 == id);
    _providers.removeWhere((_, provider) => provider.pluginId == id);
    for (final entry
        in _hostRequests.entries
            .where((entry) => entry.value.pluginId == id)
            .toList()) {
      _hostRequests.remove(entry.key);
      _hostRequestOwners.remove(entry.key);
      entry.value.result.completeError(
        StateError('Plugin instance has stopped'),
      );
      emitEvent(
        CommandEvent('plugin.hostCancelled', data: {'requestId': entry.key}),
      );
    }
    final cleanup = <Future<void>>[
      if (runtime != null) runtime.close(),
      if (session != null) session.storageWrites,
      if (session != null) session.fileOperations,
      if (session != null) session.stopped.close(),
      for (final appId in appSides)
        _withZmlTransition(appId, () => deviceManager.stopZeppOsAppSide(appId)),
      if (_httpServers.remove(id) case final server?) server.close(),
      if (_httpClients.remove(id) case final client?) client.close(),
      if (_websockets.remove(id) case final sockets?) sockets.close(),
      if (_browsers.remove(id) case final browser?) browser.close(),
    ];
    cleanup.addAll([
      for (final key in _canopusSubscriptions.keys.toList())
        if (_canopusSubscriptions[key]!.contains(id))
          _listenCanopus(id, key.$1, key.$2, false).catchError((Object error) {
            _log.fine('Canopus listener cleanup failed', error);
          }),
    ]);
    final background = _backgroundTasks.remove(id);
    try {
      await Future.wait([...cleanup, if (background != null) background.end()]);
    } finally {
      if (session != null) {
        final storage = await _storage;
        await storage.clearTemporaryFiles(id);
      }
    }
  }

  Future<void> _closeAllRuntimes() async {
    for (final id in {
      ..._runtimes.keys,
      ..._runtimeStarts.keys,
      ..._runtimeStops.keys,
    }) {
      await _closeRuntime(id);
    }
  }

  Future<Object?> _handleHostCall(
    InstalledPlugin plugin,
    String method,
    List<Object?> arguments,
  ) async {
    if (method == 'runtime.error') {
      if (_isPermissionError(arguments.single)) return null;
      if (_isCapabilityError(arguments.single)) return null;
      await _recordFailure(
        plugin,
        StateError(arguments.single.toString()),
        StackTrace.current,
        phase: 'background',
      );
      return null;
    }
    Future<Object?> dispatch() => dataMaintenance.hostCall(
      () => plugin.manifest.runtime == PluginRuntimeType.wasm
          ? _dispatchNgHostCall(plugin, method, arguments)
          : _dispatchJsHostCall(plugin, method, arguments),
    );
    try {
      if (!_PluginBackgroundLifecycle._activityMethods.contains(method)) {
        return await dispatch();
      }
      return await _withActivity(plugin.manifest.id, dispatch);
    } catch (error) {
      if (_isCapabilityError(error)) {
        emitEvent(
          CommandEvent(
            'plugin.notice',
            data: {
              'pluginId': plugin.manifest.id,
              'code': 'platform_capability_unavailable',
            },
          ),
        );
      }
      rethrow;
    }
  }

  Future<PluginPermissionDecision> _promptPermission(
    PluginPermissionRequest request,
  ) async {
    final response = await _requestHost(
      request.pluginId,
      'permission',
      request.toJson(),
    );
    return switch (response['decision']?.toString()) {
      'once' => PluginPermissionDecision.once,
      'session' => PluginPermissionDecision.session,
      'always' => PluginPermissionDecision.always,
      _ => PluginPermissionDecision.deny,
    };
  }

  Future<void> _enqueueSandboxFile(
    String pluginId,
    List<Object?> arguments,
  ) async {
    final session = _sessions[pluginId];
    if (session == null) throw StateError('Plugin session ended');
    final path = _dataPath(arguments.firstOrNull?.toString() ?? '');
    final options = _jsonMap(arguments.elementAtOrNull(1));
    final bytes = await (await _storage).readFile(pluginId, path);
    final response = await _requestHost(pluginId, 'enqueueFile', {
      'resourceType': options['type'],
      'name': path.relativePath.split('/').last,
      'bytes': bytes,
    }, session: session);
    if (response['queued'] != true) {
      throw StateError('Unable to enqueue plugin resource');
    }
  }

  Uint8List _bytes(Object? value) {
    if (value is Uint8List) return value;
    if (value is List) {
      return Uint8List.fromList(
        value.whereType<num>().map((item) => item.toInt() & 0xff).toList(),
      );
    }
    if (value is String) return base64Decode(value);
    throw const FormatException('Binary data is required');
  }

  void _queueInterconnectDispatch(
    String addr,
    String packageName,
    Uint8List bytes,
  ) {
    final payload = utf8.decode(bytes, allowMalformed: true);
    for (final entry in _sessions.entries.toList()) {
      if (entry.value.observeInterconnect) {
        _deliverEvent(
          entry.key,
          'interconnect',
          jsonEncode({
            'deviceId': addr,
            'packageName': packageName,
            'data': payload,
          }),
        );
      }
      if (_matchesInterconnect(entry.value, addr, packageName)) {
        _deliverInterconnect(
          entry.key,
          entry.value,
          addr,
          packageName,
          payload,
        );
      }
    }
    if (!_sessions.values.any(
      (session) => _matchesInterconnect(session, addr, packageName),
    )) {
      _pendingInterconnect.removeWhere(
        (message) =>
            DateTime.now().difference(message.received) >=
            const Duration(seconds: 15),
      );
      if (_pendingInterconnect.length >= 64) _pendingInterconnect.removeFirst();
      _pendingInterconnect.add((
        addr: addr,
        package: packageName,
        payload: payload,
        received: DateTime.now(),
      ));
    }
  }

  void _deliverEvent(String id, String type, String payload) {
    final runtime = _runtimes[id];
    if (runtime == null) return;
    _recordActivity(_sessions[id]!);
    unawaited(
      _withActivity(id, () => runtime.dispatchEvent(type, payload)).catchError((
        Object error,
        StackTrace stack,
      ) {
        _log.warning('Plugin event failed', error, stack);
      }),
    );
  }

  void _dispatchDeviceEvent(DeviceEvent event) {
    if (event is DeviceAuthenticated || event is TransportDisconnected) {
      final connected = event is DeviceAuthenticated;
      final address = _pluginAddress(event.deviceId);
      _deviceRevisions[address] = (_deviceRevisions[address] ?? 0) + 1;
      for (final session in _sessions.values) {
        session.apps.removeWhere((key, _) => key.$1 == address);
        session.interconnectSync.removeWhere((key, _) => key.$1 == address);
      }
      if (connected) {
        _taskQueue?.resumeWaiting();
        for (final key in _canopusSubscriptions.keys.toList()) {
          final owner = _canopusSubscriptions[key]?.firstOrNull;
          if (_samePluginAddress(key.$1, event.deviceId) && owner != null) {
            unawaited(
              _listenCanopus(
                owner,
                key.$1,
                key.$2,
                true,
                resubscribe: true,
              ).catchError((Object error) {
                _log.warning('Canopus resubscription failed', error);
              }),
            );
          }
        }
      }
      final device = readDeviceState().pairedDevices
          .where((item) => _samePluginAddress(item.addr, event.deviceId))
          .firstOrNull;
      final payload = jsonEncode({
        'action': connected ? 'connected' : 'disconnected',
        'addr': event.deviceId,
        'name': device?.name,
      });
      for (final entry in _runtimes.entries.toList()) {
        unawaited(
          entry.value.dispatchEvent('device-action', payload).catchError((
            Object error,
          ) {
            _log.warning('Plugin device event failed', error);
          }),
        );
      }
      if (connected) {
        for (final entry in _sessions.entries.toList()) {
          for (final registration in entry.value.interconnect) {
            if (registration.$1.isEmpty ||
                _samePluginAddress(registration.$1, event.deviceId)) {
              _syncInterconnect(
                entry.key,
                entry.value,
                event.deviceId,
                registration.$2,
              );
            }
          }
        }
      }
    }
    if (event is ProtocolPacketReceived) {
      final payload = jsonEncode({
        'deviceId': event.deviceId,
        'protocol': event.protocol,
        'channel': event.channel,
        'data': base64Encode(event.payload),
      });
      for (final entry in _sessions.entries.toList()) {
        if (entry.value.observeProtocol) {
          _deliverEvent(entry.key, 'protocol.data', payload);
        }
      }
    }
    if (event is XiaomiProtocolPacketReceived) {
      int? type;
      if (event.channel == 1) {
        try {
          type = xiaomi_pb.WearPacket.fromBuffer(event.payload).type.value;
        } catch (_) {
          return;
        }
      }
      for (final entry in _sessions.entries.toList()) {
        if (entry.value.transport.any(
          (filter) =>
              filter.$1.toLowerCase() == event.deviceId.toLowerCase() &&
              filter.$2 == event.channel &&
              (event.channel != 1 || filter.$3 == type),
        )) {
          _deliverEvent(
            entry.key,
            'transport-packet',
            base64Encode(event.payload),
          );
        }
      }
    } else if (event is CanopusConnectMessage) {
      for (final id
          in _canopusSubscriptions[(event.deviceId, event.module)]?.toList() ??
              <String>[]) {
        final runtime = _runtimes[id];
        if (runtime == null) continue;
        _recordActivity(_sessions[id]!);
        unawaited(
          _withActivity(
            id,
            () => runtime.callExport('on-message', [
              event.deviceId,
              event.module,
              {
                'case': event.isText ? 'text' : 'binary',
                'value': event.isText
                    ? utf8.decode(event.payload)
                    : event.payload.toList(),
              },
            ]),
          ).then<void>(
            (_) {},
            onError: (Object error) {
              _log.warning('Canopus event failed', error);
            },
          ),
        );
      }
    }
  }

  Future<void> _listenCanopus(
    String id,
    String addr,
    String module,
    bool enabled, {
    bool resubscribe = false,
  }) {
    final key = (addr, module);
    final runtime = _runtimes[id];
    final permissionRevision = _permissionBroker.revision(id);
    final address = _pluginAddress(addr);
    final deviceRevision = _deviceRevisions[address];
    final previous = _canopusTransitions[key] ?? Future<void>.value();
    late final Future<void> operation;
    operation = previous
        .catchError((_) {})
        .then((_) async {
          final owners = _canopusSubscriptions[key] ?? <String>{};
          if (resubscribe) {
            if (owners.isNotEmpty &&
                _deviceRevisions[address] == deviceRevision) {
              await deviceManager.listenPluginCanopus(
                addr,
                module,
                true,
                restoring: true,
              );
            }
            return;
          }
          if (enabled) {
            _permissionBroker.requireRevision(id, permissionRevision);
            if (runtime == null || !identical(_runtimes[id], runtime)) {
              throw StateError('Plugin instance has stopped');
            }
            if (owners.contains(id)) return;
            if (await runtime.callExport('has-export', ['on-message']) !=
                'true') {
              throw StateError('Plugin does not export Canopus on-message');
            }
            if (!identical(_runtimes[id], runtime)) {
              throw StateError('Plugin instance has stopped');
            }
            if (owners.isEmpty) {
              await deviceManager.listenPluginCanopus(addr, module, true);
            }
            if (!identical(_runtimes[id], runtime) ||
                permissionRevision != _permissionBroker.revision(id)) {
              if (owners.isEmpty) {
                await deviceManager.listenPluginCanopus(addr, module, false);
              }
              _permissionBroker.requireRevision(id, permissionRevision);
              throw StateError('Plugin instance has stopped');
            }
            owners.add(id);
            _canopusSubscriptions[key] = owners;
          } else {
            if (!owners.remove(id)) return;
            if (owners.isEmpty) {
              _canopusSubscriptions.remove(key);
              await deviceManager.listenPluginCanopus(addr, module, false);
            }
          }
        })
        .whenComplete(() {
          if (identical(_canopusTransitions[key], operation)) {
            _canopusTransitions.remove(key);
          }
        });
    _canopusTransitions[key] = operation;
    return operation;
  }

  Future<void> _renderUi(String id, List<Object?> arguments) async {
    final raw = _jsonMap(arguments.firstOrNull);
    final target = raw['target_id']?.toString() ?? '';
    final key = (id, target);
    final generation = _sessions[id];
    if (generation == null) throw StateError('Plugin session ended');
    final revision = (_uiRevisions[key] ?? 0) + 1;
    _uiRevisions[key] = revision;
    final tree = await _resolveUiAssets(id, _parseUiTree(raw));
    if (!identical(generation, _sessions[id]) ||
        _uiRevisions[key] != revision) {
      return;
    }
    if (generation.cards.containsKey(target) == true) {
      emitEvent(
        CommandEvent(
          'plugin.cardUi',
          data: {'id': id, 'targetId': target, 'nodes': tree},
        ),
      );
      return;
    }
    _uiNodes[id] = tree;
    emitEvent(
      CommandEvent(
        'plugin.ui',
        data: {'id': id, 'targetId': target, 'nodes': tree},
      ),
    );
    _emitDiagnosticState(id);
  }

  Future<Map<String, Object?>> _resolveUiAssets(
    String pluginId,
    Map<String, Object?> node,
  ) async {
    final props = Map<String, Object?>.of(
      (node['props'] as Map?)?.cast<String, Object?>() ?? const {},
    );
    if (node['type']?.toString().toUpperCase() == 'IMAGE') {
      final source = props['src']?.toString() ?? '';
      if (source.startsWith('/')) {
        final bytes = await (await _storage).readFile(
          pluginId,
          PluginStoragePath.parse(source),
        );
        props['data'] = base64Encode(bytes);
      }
    }
    final rawChildren = node['children'];
    final children = <Map<String, Object?>>[];
    if (rawChildren is List) {
      for (final child in rawChildren.whereType<Map>()) {
        children.add(
          await _resolveUiAssets(pluginId, child.cast<String, Object?>()),
        );
      }
    }
    return {
      ...node,
      'type': node['type'],
      'props': props,
      'children': children,
    };
  }

  Future<Map<String, Object?>> _getRenderSize(String id) =>
      _requestHost(id, 'renderSize', const {});

  Map<String, Object?> _parseUiTree(Object? value) {
    final raw = value is String ? jsonDecode(value) : value;
    if (raw is! Map) throw const FormatException('Plugin UI must be an object');
    final node = raw['root'] is Map ? raw['root'] as Map : raw;
    return _parseTreeNode(node.cast<String, Object?>());
  }

  Map<String, Object?> _parseTreeNode(Map<String, Object?> node) {
    final type = node['type']?.toString();
    if (type == null || type.isEmpty) {
      throw const FormatException('Plugin UI node must have a type');
    }
    final props = (node['props'] as Map?)?.cast<String, Object?>() ?? const {};
    final rawChildren = node['children'];
    final children = rawChildren is List
        ? rawChildren
              .whereType<Map>()
              .map((c) => _parseTreeNode(c.cast<String, Object?>()))
              .toList(growable: false)
        : const <Map<String, Object?>>[];
    return {...node, 'type': type, 'props': props, 'children': children};
  }

  Future<Map<String, Object?>> _requestHost(
    String pluginId,
    String type,
    Map<String, Object?> data, {
    _PluginSession? session,
  }) {
    if (!_sessions.containsKey(pluginId) ||
        (session != null && !identical(_sessions[pluginId], session))) {
      return Future.error(StateError('Plugin session ended'));
    }
    final requestId =
        '${DateTime.now().microsecondsSinceEpoch}-${++_requestSequence}';
    final completer = Completer<Map<String, Object?>>();
    _hostRequests[requestId] = (
      pluginId: pluginId,
      type: type,
      data: data,
      result: completer,
    );
    _log.info(
      'dispatching host request $requestId type=$type for plugin $pluginId',
    );
    emitEvent(
      CommandEvent(
        'plugin.hostRequest',
        data: {
          'requestId': requestId,
          'pluginId': pluginId,
          'type': type,
          ...data,
        },
      ),
    );
    return completer.future.timeout(
      const Duration(minutes: 5),
      onTimeout: () {
        _hostRequests.remove(requestId);
        _hostRequestOwners.remove(requestId);
        emitEvent(
          CommandEvent('plugin.hostCancelled', data: {'requestId': requestId}),
        );
        _log.warning(
          'host request $requestId type=$type timed out for plugin $pluginId',
        );
        throw TimeoutException('Plugin host request timed out');
      },
    );
  }

  Map<String, Object?> _jsonMap(Object? value) {
    final raw = value is String ? jsonDecode(value) : value;
    return (raw as Map?)?.cast<String, Object?>() ?? const {};
  }

  InstalledPlugin _requirePlugin(String id) {
    final plugin = _plugins[id];
    if (plugin == null) throw StateError('Plugin not found: $id');
    return plugin;
  }

  void _emitState(String id) {
    emitEvent(CommandEvent('plugin.state', data: {'id': id}));
    if (_plugins.containsKey(id)) _emitDiagnosticState(id);
  }

  void _emitDiagnosticState(String id) {
    emitEvent(
      CommandEvent(
        'debug.plugin.changed',
        data: {'plugin': diagnosticSnapshot(id)},
      ),
    );
  }

  Future<Map<String, Object?>> _summary(
    InstalledPlugin plugin, {
    bool includeIcon = true,
  }) async {
    final json = plugin.summaryJson(includeIcon: includeIcon);
    final icon = plugin.manifest.iconPath;
    if (icon != null) {
      final native = (await _storage).nativePath(
        plugin.manifest.id,
        PluginStoragePath.parse('/plugin/$icon'),
      );
      if (native != null) json['iconPath'] = native;
    }
    if (_failures[plugin.manifest.id] case final failure?) {
      json['failure'] = failure.toJson();
    }
    json['safeMode'] = _safeMode;
    json['running'] = _runtimes.containsKey(plugin.manifest.id);
    json['backgroundActive'] = _backgroundTasks.containsKey(plugin.manifest.id);
    json.addAll(_settings(plugin.manifest.id).toJson());
    return json;
  }

  Future<T> _runPluginOperation<T>(
    InstalledPlugin plugin,
    String phase,
    Future<T> Function() operation,
  ) async {
    final id = plugin.manifest.id;
    final lifetime = _runtimeLifetimes.putIfAbsent(id, Object.new);
    final session = _sessions[id];
    if (session != null) {
      session.activeOperations++;
      session.idleTimer?.cancel();
    }
    try {
      final result = await operation().timeout(
        _operationTimeout,
        onTimeout: () => throw TimeoutException(
          'Plugin operation $phase timed out',
          _operationTimeout,
        ),
      );
      if (!identical(_runtimeLifetimes[id], lifetime)) {
        throw StateError('Plugin instance has stopped');
      }
      if (phase.startsWith('provider.')) {
        if (_sessions[id] case final current?) {
          _recordActivity(current);
        }
      }
      return result;
    } on PluginExecutionException {
      rethrow;
    } catch (error, stackTrace) {
      if (identical(_runtimeLifetimes[id], lifetime) &&
          !_isPermissionError(error) &&
          !_isCapabilityError(error)) {
        await _recordFailure(plugin, error, stackTrace, phase: phase);
      }
      throw PluginExecutionException(
        plugin.manifest.id,
        plugin.manifest.name,
        error.toString(),
      );
    } finally {
      if (session != null) session.activeOperations--;
      if (identical(_runtimeLifetimes[id], lifetime)) {
        await _applyBackgroundPolicy(id);
      }
    }
  }

  Future<void> _recordFailure(
    InstalledPlugin plugin,
    Object error,
    StackTrace stackTrace, {
    required String phase,
  }) async {
    if (_isCapabilityError(error)) return;
    final id = plugin.manifest.id;
    if (_closed || _failures.containsKey(id)) return;
    final failure = PluginExecutionFailure(
      pluginId: id,
      pluginName: plugin.manifest.name,
      phase: phase,
      message: error.toString(),
      occurredAt: DateTime.now(),
    );
    _failures[id] = failure;
    _log.warning(
      'Plugin ${plugin.manifest.name} failed during $phase',
      error,
      stackTrace,
    );
    emitEvent(CommandEvent('plugin.error', data: failure.toJson()));
    _emitState(id);
    unawaited(
      _closeRuntime(id).catchError((Object cleanupError) {
        _log.warning('Plugin failure cleanup failed', cleanupError);
      }),
    );
  }

  Future<void> close() async {
    _closed = true;
    await dataMaintenance.dispose();
    await _interconnectSubscription.cancel();
    await _deviceSubscription.cancel();
    await _backgroundExpirationSubscription.cancel();
    await _taskSubscription?.cancel();
    await Future.wait(_managementOperations.values.toList());
    await _closeAllRuntimes();
    _pendingInterconnect.clear();
    _runtimeStarts.clear();
    _runtimeLifetimes.clear();
    for (final request in _hostRequests.values) {
      if (!request.result.isCompleted) {
        request.result.completeError(StateError('Plugin host is closing'));
      }
    }
    _hostRequests.clear();
    _hostRequestOwners.clear();
    await _permissionBroker.drainWrites();
    await Future.wait(_hostWrites.values.toList());
    await (await _storage).close();
  }
}

class _PluginProvider {
  const _PluginProvider({
    required this.pluginId,
    required this.id,
    required this.name,
    this.type = 'resource',
    this.callbacks = const {},
  });
  final String pluginId;
  final String id;
  final String name;
  final String type;
  final Map<String, String> callbacks;
  Map<String, Object?> toJson() => {
    'pluginId': pluginId,
    'id': id,
    'name': name,
    'type': type,
    'available': callbacks.isNotEmpty,
  };
}
