import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../commands/command_protocol.dart';
import '../core/storage/managed_temporary_files.dart';
import '../device/xiaomi/systems/canopus_system.dart';
import '../features/devices/services/device_log_archive.dart';
import 'local_server_auth.dart';
import 'local_server_mdns.dart';
import 'local_server_protocol.dart';

/// Network-facing Local API Server for OronBox clients and CLI integrations.
///
/// Exposes a typed, secured HTTP/1.1 API with Ed25519 challenge-based authentication
/// and Server-Sent Events (SSE) stream for real-time state and task broadcasts.
class LocalServer {
  LocalServer({
    required this.serverId,
    required this.displayName,
    required this.platform,
    required this.identity,
    required this.host,
    required this.commandBus,
    this.port = defaultLocalServerPort,
    this.maxUploadBytes = 256 * 1024 * 1024,
    DateTime Function()? now,
    this.onChanged,
    Iterable<LocalAuthorizedClient> authorizedClients = const [],
    this.onAuthorizationChanged,
    this.onPairingRequested,
  }) : _now = now ?? DateTime.now,
       authenticator = LocalServerAuthenticator(
         serverId: serverId,
         serverIdentity: identity,
         now: now,
         authorizedClients: authorizedClients,
       );

  final String serverId;
  final String displayName;
  final String platform;
  final LocalServerEd25519KeyPair identity;
  final InternetAddress host;
  final int port;
  final int maxUploadBytes;
  final OronBoxCommandBus commandBus;
  final void Function()? onChanged;
  final void Function()? onAuthorizationChanged;
  final void Function(LocalServerPairingRequest pairing)? onPairingRequested;
  final LocalServerAuthenticator authenticator;
  final DateTime Function() _now;

  final _logOperations = <String, _LocalLogOperation>{};
  final _activeSseClients = <HttpResponse, _LocalEventSubscription>{};

  StreamSubscription<CommandEvent>? _commandBusEventsSub;
  LocalServerMdnsAdvertiser? _mdns;
  HttpServer? _httpServer;
  Timer? _maintenanceTimer;
  Timer? _ssePingTimer;
  bool _mdnsAvailable = false;

  bool get isRunning => _httpServer != null;
  int get boundPort => _httpServer?.port ?? port;
  List<LocalServerPairingRequest> get pendingPairings =>
      authenticator.pendingPairings;
  List<LocalAuthorizedClient> get authorizedClients =>
      authenticator.authorizedClients;

  LocalServerInfo get info => LocalServerInfo(
    serverId: serverId,
    displayName: displayName,
    platform: platform,
    port: boundPort,
    protocolVersion: localServerProtocolVersion,
    secure: false,
    capabilities: _mdnsAvailable
        ? localServerCapabilities
        : localServerCapabilities.difference(const {'discovery.mdns'}),
    fingerprint: identity.fingerprint,
    publicKeyHex: identity.publicKeyHex,
  );

  Future<LocalServerInfo> start() async {
    if (_httpServer != null) return info;
    _httpServer = await HttpServer.bind(host, port, shared: true);
    _httpServer!.listen(_handleRequest, onError: (_) {});

    _commandBusEventsSub = commandBus.events.listen(_broadcastSseEvent);

    _mdns = LocalServerMdnsAdvertiser(
      serverId: serverId,
      displayName: displayName,
      platform: platform,
      port: boundPort,
      fingerprint: identity.fingerprint,
    );
    _mdnsAvailable = await _mdns!.start();

    _maintenanceTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => unawaited(_purgeExpiredState()),
    );

    _ssePingTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _pingSseClients(),
    );

    onChanged?.call();
    return info;
  }

  Future<void> stop() async {
    final server = _httpServer;
    _httpServer = null;

    _maintenanceTimer?.cancel();
    _maintenanceTimer = null;

    _ssePingTimer?.cancel();
    _ssePingTimer = null;

    await _commandBusEventsSub?.cancel();
    _commandBusEventsSub = null;

    for (final client in _activeSseClients.keys.toList()) {
      _closeEventStream(client);
    }
    final logs = _logOperations.values.toList();
    _logOperations.clear();
    for (final operation in logs) {
      await _releaseLogFiles(operation);
    }

    await _mdns?.stop();
    _mdns = null;
    _mdnsAvailable = false;

    await server?.close(force: true);
    onChanged?.call();
  }

  void approvePairing(String pairingId, {bool remember = true}) {
    authenticator.approvePairing(pairingId);
    if (remember) {
      onAuthorizationChanged?.call();
    }
    onChanged?.call();
  }

  void rejectPairing(String pairingId) {
    authenticator.rejectPairing(pairingId);
    onChanged?.call();
  }

  void approveClient(LocalAuthorizedClient client) {
    authenticator.approveClient(client);
    onAuthorizationChanged?.call();
    onChanged?.call();
  }

  void rejectClient(String fingerprint) {
    authenticator.rejectClient(fingerprint);
    onChanged?.call();
  }

  void revokeClient(String fingerprint) {
    authenticator.revokeClient(fingerprint);
    onAuthorizationChanged?.call();
    onChanged?.call();
  }

  Future<void> _purgeExpiredState() async {
    authenticator.clearExpired();
    final current = _now().toUtc();
    final expired = _logOperations.values
        .where(
          (op) =>
              op.finishedAt != null &&
              current.difference(op.finishedAt!) > const Duration(hours: 1),
        )
        .toList();
    for (final operation in expired) {
      _logOperations.remove(operation.id);
      await _releaseLogFiles(operation);
    }
  }

  Future<void> _releaseLogFiles(_LocalLogOperation operation) async {
    final files = [operation.archiveFile, operation.currentLogFile];
    operation.archiveFile = null;
    operation.currentLogFile = null;
    for (final file in files.nonNulls) {
      try {
        await ManagedTemporaryFiles.release(file.path);
      } on FileSystemException {
        // Expired files can also be reclaimed by temporary storage cleanup.
      }
    }
  }

  void _broadcastSseEvent(CommandEvent event) {
    if (_activeSseClients.isEmpty) return;
    final message =
        'event: ${event.event}\ndata: ${jsonEncode(event.data)}\n\n';
    for (final entry in _activeSseClients.entries.toList()) {
      final client = entry.key;
      final subscription = entry.value;
      final session = authenticator.verifySession(subscription.token);
      if (session == null) {
        _closeEventStream(client);
        continue;
      }
      final device = event.data['deviceId'];
      if (device is String && !_allowsDevice(session, device)) continue;
      if (subscription.matches(event)) _writeEventFrame(client, message);
    }
  }

  void _pingSseClients() {
    for (final entry in _activeSseClients.entries.toList()) {
      if (authenticator.verifySession(entry.value.token) == null) {
        _closeEventStream(entry.key);
      } else {
        _writeEventFrame(entry.key, ': ping\n\n');
      }
    }
  }

  void _writeEventFrame(HttpResponse client, String frame) {
    final subscription = _activeSseClients[client];
    if (subscription == null) return;
    if (subscription.frames.length >= 256 ||
        (subscription.frames.isNotEmpty &&
            subscription.pendingCharacters + frame.length > 4 * 1024 * 1024)) {
      _closeEventStream(client);
      return;
    }
    subscription.frames.addLast(frame);
    subscription.pendingCharacters += frame.length;
    if (subscription.writing) return;
    subscription.writing = true;
    unawaited(_drainEventFrames(client, subscription));
  }

  Future<void> _drainEventFrames(
    HttpResponse client,
    _LocalEventSubscription subscription,
  ) async {
    try {
      while (subscription.frames.isNotEmpty) {
        final frame = subscription.frames.removeFirst();
        subscription.pendingCharacters -= frame.length;
        client.write(frame);
        await client.flush();
      }
    } catch (_) {
      _closeEventStream(client);
    } finally {
      subscription.writing = false;
      if (!_activeSseClients.containsKey(client)) {
        await _finishEventStream(client);
      }
    }
  }

  void _closeEventStream(HttpResponse client) {
    final subscription = _activeSseClients.remove(client);
    if (subscription == null) return;
    subscription.frames.clear();
    if (!subscription.writing) unawaited(_finishEventStream(client));
  }

  Future<void> _finishEventStream(HttpResponse client) async {
    try {
      await client.close();
    } catch (_) {}
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      final path = request.uri.path;
      final method = request.method;

      // 1. Public Info
      if (method == 'GET' && path == '/v1/info') {
        return await _sendJson(request, 200, {
          ...info.toJson(),
          'publicKey': identity.publicKeyBase64Url,
          'publicKeyHex': identity.publicKeyHex,
        });
      }

      // 2. Authentication Flow
      if (method == 'POST' && path == '/v1/auth/pairing-requests') {
        return await _handlePairingRequest(request);
      }
      final pairingMatch = RegExp(r'^/v1/auth/pairing-requests/([^/]+)$')
          .firstMatch(path);
      if (method == 'GET' && pairingMatch != null) {
        final pairingId = Uri.decodeComponent(pairingMatch.group(1)!);
        final pairing = authenticator.getPairingRequest(pairingId);
        if (pairing == null) {
          return _sendError(request, 404, 'pairing_request_not_found');
        }
        return await _sendJson(request, 200, pairing.toPublicStatus());
      }
      if (method == 'POST' && path == '/v1/auth/challenges') {
        return await _handleChallengeRequest(request);
      }
      if (method == 'POST' && path == '/v1/auth/sessions') {
        return await _handleSessionRequest(request);
      }

      // Authenticated Area
      final session = _sessionFor(request);
      if (session == null) {
        return _sendError(request, 401, 'unauthorized');
      }

      // 3. SSE Stream
      if (method == 'GET' && path == localServerEventsPath) {
        if (!_hasScope(session, 'events.subscribe')) {
          return _sendError(request, 403, 'scope_required');
        }
        return await _handleSseStream(request, session);
      }

      final selectedDevice = request.uri.queryParameters['deviceId'];
      if (!_allowsDevice(session, selectedDevice)) {
        return _sendError(request, 403, 'device_not_authorized');
      }
      if (selectedDevice != null &&
          selectedDevice.isNotEmpty &&
          !_hasScope(session, 'device.control')) {
        return _sendError(request, 403, 'scope_required');
      }

      // 4. Devices
      if (method == 'GET' && path == '/v1/devices') {
        if (!_hasScope(session, 'device.read')) {
          return _sendError(request, 403, 'scope_required');
        }
        return await _handleDeviceList(request);
      }
      if (method == 'GET' && path == '/v1/devices/info') {
        if (!_hasScope(session, 'device.read')) {
          return _sendError(request, 403, 'scope_required');
        }
        return await _executeDeviceCommand(request, 'device.info');
      }
      if (method == 'GET' && path == '/v1/devices/current') {
        if (!_hasScope(session, 'device.read')) {
          return _sendError(request, 403, 'scope_required');
        }
        return await _executeDeviceCommand(request, 'device.status');
      }
      if (method == 'POST' && path == '/v1/devices/connect') {
        if (!_hasScope(session, 'device.control')) {
          return _sendError(request, 403, 'scope_required');
        }
        final body = await _readJson(request, maxBytes: 64 * 1024);
        final deviceId = (body['deviceId'] ?? '').toString().trim();
        if (deviceId.isEmpty) {
          return _sendError(request, 400, 'device_id_required');
        }
        final result = await commandBus.execute(
          OronBoxCommand(
            method: 'device.connect',
            params: {
              'device': deviceId,
              '_localApiDeviceAllowlist': session.deviceAllowlist,
            },
          ),
        );
        if (!result.ok) return _sendCommandFailure(request, result);
        return await _sendJson(request, 200, {
          'deviceId': deviceId,
          'connectionState': 'connected',
        });
      }
      if (method == 'POST' && path == '/v1/devices/disconnect') {
        if (!_hasScope(session, 'device.control')) {
          return _sendError(request, 403, 'scope_required');
        }
        final body = await _readJson(request, maxBytes: 64 * 1024);
        final deviceId = body['deviceId']?.toString().trim();
        return await _executeDeviceCommand(
          request,
          'device.disconnect',
          params: {
            if (deviceId != null && deviceId.isNotEmpty) 'device': deviceId,
          },
        );
      }

      // 5. Apps
      if (method == 'GET' && path == '/v1/apps') {
        if (!_hasScope(session, 'app.read')) {
          return _sendError(request, 403, 'scope_required');
        }
        final result = await commandBus.execute(
          OronBoxCommand(
            method: 'app.list',
            params: {
              if (request.uri.queryParameters['deviceId'] case final target?)
                'device': target,
              '_localApiDeviceAllowlist': session.deviceAllowlist,
            },
          ),
        );
        if (!result.ok) return _sendCommandFailure(request, result);
        return await _sendJson(request, 200, {'items': result.value});
      }
      if (method == 'POST' && path == '/v1/apps/launch') {
        if (!_hasScope(session, 'app.control')) {
          return _sendError(request, 403, 'scope_required');
        }
        final body = await _readJson(request, maxBytes: 64 * 1024);
        final pkg = body['packageName']?.toString().trim() ?? '';
        final page = body['page']?.toString().trim();
        if (pkg.isEmpty) {
          return _sendError(request, 400, 'package_required');
        }
        final params = <String, Object?>{'package': pkg};
        if (page != null && page.isNotEmpty) {
          params['page'] = page;
        }
        return await _executeDeviceCommand(
          request,
          'app.launch',
          params: params,
        );
      }
      final appDeleteMatch = RegExp(r'^/v1/apps/([^/]+)$').firstMatch(path);
      if (appDeleteMatch != null && method == 'DELETE') {
        final pkg = Uri.decodeComponent(appDeleteMatch.group(1)!);
        if (!_hasScope(session, 'app.control')) {
          return _sendError(request, 403, 'scope_required');
        }
        return await _executeDeviceCommand(
          request,
          'app.uninstall',
          params: {'package': pkg},
        );
      }

      // 6. Watchfaces
      if (method == 'GET' && path == '/v1/watchfaces') {
        if (!_hasScope(session, 'watchface.read')) {
          return _sendError(request, 403, 'scope_required');
        }
        final result = await commandBus.execute(
          OronBoxCommand(
            method: 'watchface.list',
            params: {
              if (request.uri.queryParameters['deviceId'] case final target?)
                'device': target,
              '_localApiDeviceAllowlist': session.deviceAllowlist,
            },
          ),
        );
        if (!result.ok) return _sendCommandFailure(request, result);
        return await _sendJson(request, 200, {'items': result.value});
      }
      if (method == 'POST' && path == '/v1/watchfaces/set') {
        if (!_hasScope(session, 'watchface.control')) {
          return _sendError(request, 403, 'scope_required');
        }
        final body = await _readJson(request, maxBytes: 64 * 1024);
        final id = body['id']?.toString().trim() ?? '';
        if (id.isEmpty) return _sendError(request, 400, 'id_required');
        return await _executeDeviceCommand(
          request,
          'watchface.set',
          params: {'id': id},
        );
      }
      final wfDeleteMatch = RegExp(r'^/v1/watchfaces/([^/]+)$')
          .firstMatch(path);
      if (wfDeleteMatch != null && method == 'DELETE') {
        final id = Uri.decodeComponent(wfDeleteMatch.group(1)!);
        if (!_hasScope(session, 'watchface.control')) {
          return _sendError(request, 403, 'scope_required');
        }
        return await _executeDeviceCommand(
          request,
          'watchface.remove',
          params: {'id': id},
        );
      }

      if (method == 'GET' && path == '/v1/modules') {
        if (!_hasScope(session, 'module.read')) {
          return _sendError(request, 403, 'scope_required');
        }
        return await _executeDeviceCommand(request, 'device.module.list');
      }

      final moduleMatch = RegExp(r'^/v1/modules/([^/]+)(/enabled)?$')
          .firstMatch(path);
      if (moduleMatch != null) {
        final moduleId = Uri.decodeComponent(moduleMatch.group(1)!);
        final settingEnabled = moduleMatch.group(2) != null;
        if (method != (settingEnabled ? 'PUT' : 'DELETE')) {
          return _sendError(request, 405, 'method_not_allowed');
        }
        if (!_hasScope(session, 'module.control')) {
          return _sendError(request, 403, 'scope_required');
        }
        final body = settingEnabled
            ? await _readJson(request, maxBytes: 64 * 1024)
            : const <String, Object?>{};
        if (!XiaomiCanopusSystem.isValidModuleId(moduleId) ||
            (settingEnabled && body['enabled'] is! bool)) {
          return _sendError(request, 400, 'invalid_module_operation');
        }
        return await _executeDeviceCommand(
          request,
          settingEnabled ? 'device.module.enable' : 'device.module.remove',
          params: {
            'moduleId': moduleId,
            if (settingEnabled) 'enabled': body['enabled'],
          },
        );
      }

      if (method == 'POST' && path == '/v1/canopus-connect/send') {
        if (!_hasScope(session, 'canopusconnect.send')) {
          return _sendError(request, 403, 'scope_required');
        }
        final body = await _readJson(request, maxBytes: 64 * 1024);
        final moduleId = body['moduleId'];
        final payload = body['payload'];
        final isText = body['isText'];
        if (moduleId is! String ||
            !XiaomiCanopusSystem.isValidModuleId(moduleId) ||
            (isText != null && isText is! bool) ||
            payload is! List ||
            payload.length > XiaomiCanopusSystem.maxConnectPayloadBytes ||
            payload.any((byte) => byte is! int || byte < 0 || byte > 255)) {
          return _sendError(request, 400, 'invalid_canopus_message');
        }
        if (isText == true) {
          try {
            utf8.decode(payload.cast<int>());
          } on FormatException {
            return _sendError(request, 400, 'invalid_canopus_message');
          }
        }
        return await _executeDeviceCommand(
          request,
          'device.canopus.send',
          params: {
            'moduleId': moduleId,
            'payload': payload,
            if (isText != null) 'isText': isText,
            if (body['deviceId'] case final target?) 'device': target,
          },
        );
      }

      if (method == 'POST' && path == '/v1/interconnect/send') {
        if (!_hasScope(session, 'interconnect.send')) {
          return _sendError(request, 403, 'scope_required');
        }
        final body = await _readJson(request, maxBytes: 1024 * 1024);
        final packageName = body['packageName'];
        final payload = body['payload'];
        if (packageName is! String ||
            packageName.trim().isEmpty ||
            packageName.contains(RegExp(r'\s')) ||
            payload is! List ||
            payload.any((byte) => byte is! int || byte < 0 || byte > 255)) {
          return _sendError(request, 400, 'invalid_interconnect_message');
        }
        return await _executeDeviceCommand(
          request,
          'device.interconnect.send',
          params: {
            'package': packageName,
            'payload': payload,
            if (body['deviceId'] case final target?) 'device': target,
          },
        );
      }

      // 7. Install Endpoint
      if (method == 'POST' && path == '/v1/install') {
        if (!_hasScope(session, 'install.upload')) {
          return _sendError(request, 403, 'scope_required');
        }
        return await _handleInstallUpload(request);
      }

      // 8. Tasks & Queue
      final taskMatch = RegExp(r'^/v1/tasks/([^/]+)(?:/(cancel))?$')
          .firstMatch(path);
      if (taskMatch != null) {
        final taskId = Uri.decodeComponent(taskMatch.group(1)!);
        final action = taskMatch.group(2);
        if (action == 'cancel') {
          if (method != 'POST') {
            return _sendError(request, 405, 'method_not_allowed');
          }
          if (!_hasScope(session, 'task.control')) {
            return _sendError(request, 403, 'scope_required');
          }
          return await _executeJson(
            request,
            OronBoxCommand(method: 'queue.cancel', params: {'id': taskId}),
          );
        }
        if (method == 'GET') {
          if (!_hasScope(session, 'task.read')) {
            return _sendError(request, 403, 'scope_required');
          }
          final result = await commandBus.execute(
            OronBoxCommand(method: 'queue.get', params: {'id': taskId}),
          );
          if (!result.ok) return _sendCommandFailure(request, result);
          final taskData = result.value is Map
              ? (result.value as Map).cast<String, Object?>()
              : {'taskId': taskId, 'status': 'unknown'};
          return await _sendJson(request, 200, taskData);
        }
        return _sendError(request, 405, 'method_not_allowed');
      }

      // 9. Device Logs
      if (method == 'POST' && path == '/v1/device-logs') {
        if (!_hasScope(session, 'diagnostics.read')) {
          return _sendError(request, 403, 'scope_required');
        }
        return await _startDeviceLogExport(request);
      }
      final logMatch = RegExp(
        r'^/v1/device-logs/([^/]+)(?:/(archive|current-log|cancel))?$',
      ).firstMatch(path);
      if (logMatch != null) {
        if (!_hasScope(session, 'diagnostics.read')) {
          return _sendError(request, 403, 'scope_required');
        }
        final operation = _logOperations[logMatch.group(1)!];
        if (operation == null) return _sendError(request, 404, 'not_found');
        final suffix = logMatch.group(2);
        if (suffix == 'cancel') {
          if (method != 'POST') {
            return _sendError(request, 405, 'method_not_allowed');
          }
          if (operation.finishedAt == null) {
            operation.state = LocalServerOperationState.cancelled;
            operation.stage = 'cancelled';
            operation.finishedAt = _now().toUtc();
            operation.message = 'cancelled';
            await commandBus.execute(
              OronBoxCommand(
                method: 'device.logs.cancel',
                params: {'operationId': operation.id},
              ),
            );
          }
          return await _sendJson(request, 200, operation.toJson());
        }
        if (suffix == null) {
          if (method != 'GET') {
            return _sendError(request, 405, 'method_not_allowed');
          }
          return await _sendJson(request, 200, operation.toJson());
        }
        if (method != 'GET' ||
            operation.state != LocalServerOperationState.completed) {
          return _sendError(request, 409, 'operation_not_completed');
        }
        final file = suffix == 'archive'
            ? operation.archiveFile
            : operation.currentLogFile;
        if (file == null || !await file.exists()) {
          return _sendError(request, 404, 'file_not_available');
        }
        return await _sendFile(
          request,
          file,
          currentLog: suffix == 'current-log',
        );
      }

      return _sendError(request, 404, 'not_found');
    } on LocalServerAuthException catch (e) {
      return _sendError(request, e.status, e.code, message: e.message);
    } on FormatException catch (e) {
      return _sendError(request, 400, 'invalid_request', message: e.message);
    } catch (e) {
      return _sendError(request, 500, 'internal_error', message: e.toString());
    }
  }

  // --- Auth Handlers ---

  Future<void> _handlePairingRequest(HttpRequest request) async {
    final body = await _readJson(request, maxBytes: 64 * 1024);
    final clientName = (body['clientName'] ?? body['displayName'] ?? 'cli')
        .toString()
        .trim();
    final publicKey = (body['publicKey'] ?? '').toString().trim();
    if (publicKey.isEmpty) {
      return _sendError(request, 400, 'public_key_required');
    }

    final rawScopes = body['requestedScopes'] ?? body['scopes'];
    final requestedScopes = rawScopes is List
        ? rawScopes
              .map((s) => s.toString().trim())
              .where((s) => s.isNotEmpty)
              .toSet()
        : localServerScopes;

    final rawAllowlist = body['deviceAllowlist'];
    final allowlist = rawAllowlist is List
        ? rawAllowlist.map((d) => d.toString().trim()).toList()
        : const <String>[];

    final pairing = authenticator.createPairingRequest(
      clientName: clientName,
      publicKey: publicKey,
      requestedScopes: requestedScopes,
      deviceAllowlist: allowlist,
    );

    if (pairing.state == LocalServerPairingState.pending) {
      onPairingRequested?.call(pairing);
    }
    onChanged?.call();
    final status = pairing.state == LocalServerPairingState.granted ? 200 : 202;
    return await _sendJson(request, status, pairing.toPublicStatus());
  }

  Future<void> _handleChallengeRequest(HttpRequest request) async {
    final body = await _readJson(request, maxBytes: 64 * 1024);
    final fingerprint = (body['fingerprint'] ?? '').toString().trim();
    if (fingerprint.isEmpty) {
      return _sendError(request, 400, 'fingerprint_required');
    }
    final challenge = authenticator.issueChallenge(fingerprint: fingerprint);
    return await _sendJson(request, 200, challenge.toJson());
  }

  Future<void> _handleSessionRequest(HttpRequest request) async {
    final body = await _readJson(request, maxBytes: 64 * 1024);
    final challengeId = (body['challengeId'] ?? '').toString().trim();
    final signature = (body['signature'] ?? '').toString().trim();
    if (challengeId.isEmpty || signature.isEmpty) {
      return _sendError(request, 400, 'challengeId_and_signature_required');
    }
    final session = authenticator.createSession(
      challengeId: challengeId,
      signatureBase64Url: signature,
    );
    return await _sendJson(request, 200, session.toJson());
  }

  // --- SSE Handler ---

  Future<void> _handleSseStream(
    HttpRequest request,
    LocalServerSession session,
  ) async {
    final query = request.uri.queryParametersAll;
    final events = query['event']?.toSet() ?? <String>{};
    final fields = <String, Set<String>>{
      for (final entry in query.entries)
        if (entry.key.startsWith('filter.'))
          entry.key.substring(7): entry.value.toSet(),
    };
    if (events.contains('') || fields.containsKey('')) {
      return _sendError(request, 400, 'invalid_event_filter');
    }
    final subscription = _LocalEventSubscription(
      token: session.token,
      events: events,
      fields: fields,
    );
    final response = request.response;
    response.statusCode = HttpStatus.ok;
    response.bufferOutput = false;
    response.headers.contentType = ContentType(
      'text',
      'event-stream',
      charset: 'utf-8',
    );
    response.headers.set('cache-control', 'no-cache, no-transform');
    response.headers.set('connection', 'keep-alive');
    response.headers.set('x-accel-buffering', 'no');

    _activeSseClients[response] = subscription;

    final readyPayload = jsonEncode({
      'serverId': serverId,
      'protocolVersion': localServerProtocolVersion,
      'connectedAt': _now().toUtc().toIso8601String(),
    });
    unawaited(
      response.done.then<void>(
        (_) => _closeEventStream(response),
        onError: (Object _) => _closeEventStream(response),
      ),
    );
    _writeEventFrame(response, 'event: ready\ndata: $readyPayload\n\n');
  }

  // --- Devices & Execution ---

  Future<void> _handleDeviceList(HttpRequest request) async {
    final result = await commandBus.execute(
      const OronBoxCommand(method: 'device.paired'),
    );
    if (!result.ok) return _sendCommandFailure(request, result);

    final statusResult = await commandBus.execute(
      const OronBoxCommand(method: 'device.status'),
    );
    final statusMap = statusResult.ok && statusResult.value is Map
        ? (statusResult.value as Map).cast<String, Object?>()
        : const <String, Object?>{};
    final currentDevice = statusMap['device'] is Map
        ? (statusMap['device'] as Map).cast<String, Object?>()
        : null;
    final currentAddr = currentDevice?['address']?.toString().toLowerCase();
    final isConnected = statusMap['connected'] == true;

    final pairedList = result.value is List ? (result.value as List) : const [];
    final devices = <Map<String, Object?>>[];

    for (final item in pairedList) {
      if (item is! Map) continue;
      final m = item.cast<String, Object?>();
      final addr = (m['address'] ?? '').toString();
      if (!_allowsDevice(_sessionFor(request)!, addr)) continue;
      final isCurrent =
          currentAddr != null && currentAddr == addr.toLowerCase();
      devices.add({
        'deviceId': addr,
        'name': m['name']?.toString() ?? 'Wearable',
        'kind': m['codename']?.toString() ?? 'wearable',
        'known': true,
        'connectionState': isCurrent && isConnected
            ? 'connected'
            : 'disconnected',
        'connectType': m['connectType']?.toString() ?? 'BLE',
      });
    }

    return await _sendJson(request, 200, {'items': devices});
  }

  Future<void> _handleInstallUpload(HttpRequest request) async {
    final fileName = Uri.decodeComponent(
      request.headers.value('x-oronbox-file-name') ?? 'resource.bin',
    );
    final type = request.headers.value('x-oronbox-type') ?? 'auto';
    if (!const {
      'auto',
      'app',
      'quickapp',
      'miniprogram',
      'watchface',
      'firmware',
      'canopus',
      'module',
      'res_pack',
      'resPack',
    }.contains(type)) {
      return _sendError(request, 400, 'invalid_install_type');
    }
    final sha256Header = request.headers.value('x-oronbox-sha256') ?? '';
    final sizeHeader = request.headers.value('x-oronbox-size');
    final declaredSize =
        int.tryParse(sizeHeader ?? '') ?? request.headers.contentLength;
    if (sizeHeader != null &&
        (int.tryParse(sizeHeader) == null || int.parse(sizeHeader) < 0)) {
      return _sendError(request, 400, 'invalid_upload_size');
    }
    final requestedDevice = request.headers
        .value('x-oronbox-device-id')
        ?.trim();
    final session = _sessionFor(request)!;
    if (requestedDevice?.isNotEmpty == true &&
        !_hasScope(session, 'device.control')) {
      return _sendError(request, 403, 'scope_required');
    }
    if (declaredSize > maxUploadBytes) {
      return _sendError(request, 413, 'upload_too_large');
    }

    final deviceId = requestedDevice?.isNotEmpty == true
        ? requestedDevice
        : await _currentDeviceId();
    if (deviceId == null) return _sendError(request, 409, 'no_device');
    if (!_allowsDevice(session, deviceId)) {
      return _sendError(request, 403, 'device_not_authorized');
    }
    final safeName = _safeFileName(fileName);
    final digestSink = _DigestSink();
    final digestInput = sha256.startChunkedConversion(digestSink);
    String? ownedPath;
    try {
      final path = ownedPath = await ManagedTemporaryFiles.create(
        TemporaryFilePurpose.installs,
        safeName,
        (path) async {
          final output = await File(path).open(mode: FileMode.write);
          var received = 0;
          try {
            await for (final chunk in request) {
              received += chunk.length;
              if (received > maxUploadBytes) {
                throw const _UploadFailure(413, 'upload_size_exceeded');
              }
              digestInput.add(chunk);
              await output.writeFrom(chunk);
            }
          } finally {
            await output.close();
          }
          digestInput.close();
          if (declaredSize >= 0 && received != declaredSize) {
            throw const _UploadFailure(400, 'size_mismatch');
          }
        },
      );
      final actualSha256 = digestSink.value.toString().toLowerCase();
      if (sha256Header.isNotEmpty &&
          actualSha256 != sha256Header.toLowerCase().trim()) {
        throw const _UploadFailure(400, 'sha256_mismatch');
      }

      final queued = await commandBus.execute(
        OronBoxCommand(
          method: 'task.enqueue',
          params: {
            'command': {
              'method': 'install.local',
              'params': {
                'path': path,
                'fileName': safeName,
                'type': type,
                'deleteAfter': true,
                '_localApiDeviceAllowlist': session.deviceAllowlist,
                'device': deviceId,
                'title': 'Local install $safeName',
              },
            },
          },
        ),
      );
      if (!queued.ok) return _sendCommandFailure(request, queued);
      ownedPath = null;

      final taskId = (queued.value as Map)['taskId'];
      return await _sendJson(request, 202, {
        'taskId': taskId,
        'deviceId': deviceId,
        'status': 'queued',
        'fileName': safeName,
        'sha256': actualSha256,
      });
    } on _UploadFailure catch (error) {
      return _sendError(request, error.status, error.code);
    } finally {
      if (ownedPath != null) await ManagedTemporaryFiles.release(ownedPath);
    }
  }

  Future<String?> _currentDeviceId() async {
    final result = await commandBus.execute(
      const OronBoxCommand(method: 'device.status'),
    );
    if (!result.ok || result.value is! Map) return null;
    final device = (result.value as Map)['device'];
    if (device is! Map) return null;
    final id = device['address'];
    return id is String && id.isNotEmpty ? id : null;
  }

  Future<void> _startDeviceLogExport(HttpRequest request) async {
    final body = await _readJson(request, maxBytes: 64 * 1024);
    final session = _sessionFor(request)!;
    final deviceId = body['deviceId']?.toString();
    if (!_allowsDevice(session, deviceId)) {
      return _sendError(request, 403, 'device_not_authorized');
    }
    if (deviceId != null && !_hasScope(session, 'device.control')) {
      return _sendError(request, 403, 'scope_required');
    }
    final operation = _LocalLogOperation(
      id: _newToken(),
      deviceId: deviceId,
      allowedDevices: session.deviceAllowlist,
    );
    _logOperations[operation.id] = operation;
    unawaited(_runDeviceLogExport(operation));
    return _sendJson(request, 202, operation.toJson());
  }

  Future<void> _runDeviceLogExport(_LocalLogOperation operation) async {
    bool isCurrent() =>
        operation.finishedAt == null &&
        identical(_logOperations[operation.id], operation);
    operation.state = LocalServerOperationState.running;
    operation.stage = 'preparing';
    final subscription = commandBus.events.listen((event) {
      if (!isCurrent() ||
          event.event != 'device.log.progress' ||
          event.data['operationId']?.toString() != operation.id) {
        return;
      }
      operation.stage = event.data['stage']?.toString();
      operation.message = event.data['message']?.toString();
      operation.progress = (event.data['progress'] as num?)?.toDouble();
      operation.fileName = event.data['fileName']?.toString();
      operation.currentPart = (event.data['currentPart'] as num?)?.toInt();
      operation.totalParts = (event.data['totalParts'] as num?)?.toInt();
      operation.channel = (event.data['channel'] as num?)?.toInt();
      operation.bytesDone = (event.data['bytesDone'] as num?)?.toInt();
      operation.bytesTotal = (event.data['bytesTotal'] as num?)?.toInt();
    });

    try {
      final result = await commandBus.execute(
        OronBoxCommand(
          method: 'device.logs.pull',
          params: {
            'operationId': operation.id,
            '_localApiDeviceAllowlist': operation.allowedDevices,
            if (operation.deviceId != null) ...{
              'deviceId': operation.deviceId,
              'device': operation.deviceId,
            },
          },
        ),
      );
      if (!isCurrent()) return;
      if (!result.ok) {
        operation.state = LocalServerOperationState.failed;
        operation.finishedAt = _now().toUtc();
        operation.message = result.error?.message ?? 'device log export failed';
        operation.error = result.error?.toJson();
        return;
      }
      final value = (result.value as Map).cast<String, Object?>();
      final bytes = Uint8List.fromList(
        (value['bytes'] as List? ?? const [])
            .whereType<num>()
            .map((item) => item.toInt() & 0xff)
            .toList(growable: false),
      );
      if (bytes.isEmpty) {
        throw StateError('device returned an empty log archive');
      }
      final extension = _archiveExtension(value['name']?.toString() ?? '');
      operation.archiveFile = await _stageLog('device-log$extension', bytes);
      if (!isCurrent()) return;

      final currentBytes = Uint8List.fromList(
        (value['currentLogBytes'] as List? ?? const [])
            .whereType<num>()
            .map((item) => item.toInt() & 0xff)
            .toList(growable: false),
      );
      final extracted = currentBytes.isNotEmpty
          ? currentBytes
          : extractCurrentDeviceLog(bytes);
      if (extracted != null && extracted.isNotEmpty) {
        operation.currentLogFile = await _stageLog('device-tmp.log', extracted);
        if (!isCurrent()) return;
      }

      operation.state = LocalServerOperationState.completed;
      operation.finishedAt = _now().toUtc();
      operation.stage = 'completed';
      operation.progress = 1;
      operation.fileName = value['name']?.toString();
      operation.bytesDone = bytes.length;
      operation.bytesTotal = bytes.length;
      if (operation.totalParts != null) {
        operation.currentPart = operation.totalParts;
      }
    } catch (error) {
      if (!isCurrent()) return;
      operation.state = LocalServerOperationState.failed;
      operation.finishedAt = _now().toUtc();
      operation.stage = 'failed';
      operation.message = error.toString();
      operation.error = {'code': 'internal', 'message': error.toString()};
    } finally {
      await subscription.cancel();
      if (operation.state != LocalServerOperationState.completed) {
        await _releaseLogFiles(operation);
      }
    }
  }

  Future<File> _stageLog(String name, List<int> bytes) async {
    final path = await ManagedTemporaryFiles.create(
      TemporaryFilePurpose.deviceLogs,
      name,
      (path) async {
        await File(path).writeAsBytes(bytes, flush: true);
      },
    );
    return File(path);
  }

  Future<void> _executeDeviceCommand(
    HttpRequest request,
    String method, {
    Map<String, Object?> params = const {},
  }) async {
    final deviceId =
        (params['device'] ?? request.uri.queryParameters['deviceId'])
            ?.toString()
            .trim();
    final session = _sessionFor(request)!;
    if (!_allowsDevice(session, deviceId)) {
      return _sendError(request, 403, 'device_not_authorized');
    }
    if (deviceId != null &&
        deviceId.isNotEmpty &&
        !_hasScope(session, 'device.control')) {
      return _sendError(request, 403, 'scope_required');
    }
    return _executeJson(
      request,
      OronBoxCommand(
        method: method,
        params: {
          ...params,
          if (deviceId != null && deviceId.isNotEmpty) 'device': deviceId,
          '_localApiDeviceAllowlist': session.deviceAllowlist,
        },
      ),
    );
  }

  bool _allowsDevice(LocalServerSession session, String? deviceId) =>
      deviceId == null ||
      deviceId.isEmpty ||
      session.deviceAllowlist.isEmpty ||
      session.deviceAllowlist.any(
        (allowed) => allowed.toLowerCase() == deviceId.toLowerCase(),
      );

  LocalServerSession? _sessionFor(HttpRequest request) {
    final value = request.headers.value('authorization');
    if (value == null || !value.startsWith('Bearer ')) return null;
    final token = value.substring('Bearer '.length).trim();
    return authenticator.verifySession(token);
  }

  bool _hasScope(LocalServerSession session, String scope) =>
      session.scopes.contains(scope);

  Future<void> _executeJson(HttpRequest request, OronBoxCommand command) async {
    final result = await commandBus.execute(command);
    if (!result.ok) return _sendCommandFailure(request, result);
    return _sendJson(request, 200, {'result': result.value});
  }

  Future<Map<String, Object?>> _readJson(
    HttpRequest request, {
    required int maxBytes,
  }) async {
    final bytes = <int>[];
    await for (final chunk in request) {
      bytes.addAll(chunk);
      if (bytes.length > maxBytes) {
        throw const FormatException('Request too large');
      }
    }
    if (bytes.isEmpty) return const {};
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map) throw const FormatException('JSON object required');
    return value.cast<String, Object?>();
  }

  void _sendCommandFailure(HttpRequest request, CommandResult result) {
    final status = switch (result.error?.code) {
      'forbidden' => 403,
      'no_device' => 409,
      'canopus_transport_unavailable' => 409,
      'canopus_timeout' => 504,
      _ => 502,
    };
    _sendJson(request, status, {'error': result.error?.toJson()});
  }

  void _sendError(
    HttpRequest request,
    int status,
    String code, {
    String? message,
  }) {
    _sendJson(request, status, {
      'error': {'code': code, 'message': message ?? code},
    });
  }

  Future<void> _sendJson(HttpRequest request, int status, Object value) async {
    final response = request.response;
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.headers.set('cache-control', 'no-store');
    response.write(jsonEncode(value));
    await response.close();
  }

  Future<void> _sendFile(
    HttpRequest request,
    File file, {
    required bool currentLog,
  }) async {
    final response = request.response;
    response.statusCode = 200;
    final lower = file.path.toLowerCase();
    response.headers.contentType = currentLog
        ? ContentType('text', 'plain', charset: 'utf-8')
        : lower.endsWith('.zip')
        ? ContentType('application', 'zip')
        : lower.endsWith('.tar.gz') || lower.endsWith('.tgz')
        ? ContentType('application', 'gzip')
        : ContentType('application', 'octet-stream');
    response.headers.set('cache-control', 'no-store');
    await response.addStream(file.openRead());
    await response.close();
  }
}

class _LocalLogOperation {
  _LocalLogOperation({
    required this.id,
    this.deviceId,
    this.allowedDevices = const [],
  });

  final String id;
  final String? deviceId;
  final List<String> allowedDevices;
  LocalServerOperationState state = LocalServerOperationState.queued;
  String? stage;
  String? message;
  double? progress;
  int? currentPart;
  int? totalParts;
  int? channel;
  int? bytesDone;
  int? bytesTotal;
  String? fileName;
  Map<String, Object?>? error;
  File? archiveFile;
  File? currentLogFile;
  DateTime? finishedAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': 'device_logs',
    'state': state.name,
    if (deviceId != null) 'deviceId': deviceId,
    if (stage != null) 'stage': stage,
    if (message != null) 'message': message,
    if (progress != null) 'progress': progress,
    if (currentPart != null) 'currentPart': currentPart,
    if (totalParts != null) 'totalParts': totalParts,
    if (channel != null) 'channel': channel,
    if (bytesDone != null) 'bytesDone': bytesDone,
    if (bytesTotal != null) 'bytesTotal': bytesTotal,
    if (fileName != null) 'fileName': fileName,
    if (error != null) 'error': error,
    if (archiveFile != null) 'archiveUrl': '/v1/device-logs/$id/archive',
    if (currentLogFile != null)
      'currentLogUrl': '/v1/device-logs/$id/current-log',
  };
}

class _UploadFailure implements Exception {
  const _UploadFailure(this.status, this.code);

  final int status;
  final String code;
}

class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest digest) {
    if (value != null) throw StateError('Digest already set');
    value = digest;
  }

  @override
  void close() {
    if (value == null) throw StateError('Digest was not set');
  }
}

String _safeFileName(String value) {
  final normalized = value.replaceAll('\\', '/');
  final name = normalized.split('/').last.trim();
  if (name.isEmpty || name.startsWith('.')) return 'resource.bin';
  return name.replaceAll(RegExp(r'[\x00-\x1f\x7f<>:"|?*]'), '_');
}

String _newToken() {
  final random = List<int>.generate(32, (_) => Random.secure().nextInt(256));
  return base64Url.encode(random).replaceAll('=', '');
}

String _archiveExtension(String name) {
  final lower = name.toLowerCase();
  if (lower.endsWith('.tar.gz')) return '.tar.gz';
  if (lower.endsWith('.tgz')) return '.tgz';
  if (lower.endsWith('.zip')) return '.zip';
  return '.bin';
}

class _LocalEventSubscription {
  _LocalEventSubscription({
    required this.token,
    required this.events,
    required this.fields,
  });

  final String token;
  final Set<String> events;
  final Map<String, Set<String>> fields;
  final frames = Queue<String>();
  int pendingCharacters = 0;
  bool writing = false;

  bool matches(CommandEvent event) {
    if (events.isNotEmpty && !events.contains(event.event)) return false;
    return fields.entries.every((entry) {
      final value = event.data[entry.key];
      return (value is String || value is bool || value is num) &&
          entry.value.contains(value.toString());
    });
  }
}
