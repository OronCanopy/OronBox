part of 'device_manager.dart';

extension PluginDeviceOperations on DeviceManager {
  Future<void> sendPluginMass(
    String addr,
    String type,
    Uint8List data, {
    String? watchfaceId,
    String? packageName,
    void Function(double)? onProgress,
  }) async {
    if (data.isEmpty) throw const FormatException('MASS payload is empty');
    final requestedPackage = packageName?.trim();
    packageName = requestedPackage?.isEmpty == true ? null : requestedPackage;
    if (packageName != null &&
        !RegExp(r'^[A-Za-z0-9._-]{1,128}$').hasMatch(packageName)) {
      throw const FormatException('Invalid package-name');
    }
    watchfaceId = watchfaceId?.trim();
    final system = _pluginEntity(addr).system<XiaomiInstallSystem>();
    if (system == null) throw UnsupportedError('MASS requires a Xiaomi device');
    switch (type) {
      case 'watchface':
        await system.installWatchface(
          data,
          watchfaceId: watchfaceId ?? '',
          onProgress: onProgress,
        );
      case 'quickapp':
        await system.installApp(
          data,
          packageName: packageName ?? 'a.b.c',
          onProgress: onProgress,
        );
      case 'firmware':
        await system.installFirmware(data, onProgress: onProgress);
      case 'notification-icon':
        if (packageName == null || packageName.trim().isEmpty) {
          throw const FormatException(
            'Notification icon requires package-name',
          );
        }
        await system.installNotificationIcon(
          data,
          packageName: packageName,
          onProgress: onProgress,
        );
      default:
        throw FormatException('Unknown MASS type $type');
    }
  }

  Future<void> syncPluginInterconnect(String addr, AppInfo app) async {
    final system = _pluginEntity(addr).system<XiaomiThirdpartyAppSystem>();
    if (system == null) {
      throw UnsupportedError('Interconnect requires a Xiaomi device');
    }
    await system.syncStatus(
      ThirdpartyAppInfo(
        packageName: app.packageName,
        fingerprint: Uint8List.fromList(app.fingerprint),
      ),
      pb_thirdparty.PhoneAppStatus_Status.CONNECTED,
    );
  }

  Future<List<AppInfo>> listPluginApps(String addr) async {
    final system = _pluginEntity(addr).system<XiaomiResourceSystem>();
    if (system == null) {
      throw UnsupportedError('Quick apps require a Xiaomi device');
    }
    return (await system.fetchInstalledQuickApps())
        .map(
          (item) => AppInfo(
            packageName: item.packageName,
            fingerprint: item.fingerprint,
            versionCode: item.versionCode,
            canRemove: item.canRemove,
            appName: item.appName,
          ),
        )
        .toList();
  }

  Future<void> launchPluginApp(String addr, AppInfo app, String page) async {
    final system = _pluginEntity(addr).system<XiaomiThirdpartyAppSystem>();
    if (system == null) {
      throw UnsupportedError('Quick apps require a Xiaomi device');
    }
    await system.launchApp(
      ThirdpartyAppInfo(
        packageName: app.packageName,
        fingerprint: Uint8List.fromList(app.fingerprint),
      ),
      page,
    );
  }

  Future<void> sendPluginInterconnect(
    String addr,
    AppInfo app,
    Uint8List payload,
  ) async {
    final system = _pluginEntity(addr).system<XiaomiThirdpartyAppSystem>();
    if (system == null) {
      throw UnsupportedError('Interconnect requires a Xiaomi device');
    }
    await system.sendPhoneMessage(
      app.packageName,
      payload,
      app: ThirdpartyAppInfo(
        packageName: app.packageName,
        fingerprint: Uint8List.fromList(app.fingerprint),
      ),
    );
  }

  Future<List<WatchfaceInfo>> listPluginWatchfaces(String addr) async {
    final system = _pluginEntity(addr).system<XiaomiInfoSystem>();
    if (system == null) {
      throw UnsupportedError('Watchfaces require a Xiaomi device');
    }
    return system.fetchInstalledWatchfaces();
  }

  Future<void> setPluginWatchface(String addr, String id) async {
    await _pluginXiaomi(addr).sendPbPacket(
      pb.WearPacket(
        type: pb.WearPacket_Type.WATCH_FACE,
        id: pb_watchface.WatchFace_WatchFaceID.SET_WATCH_FACE.value,
        watchFace: pb_watchface.WatchFace(id: id),
      ),
    );
  }

  DeviceEntity _pluginEntity(String addr) {
    if (this case final LocalDeviceManager manager) {
      final entity =
          manager._pooledEntities[addr] ??
          (manager._currentEntity?.id == addr ? manager._currentEntity : null);
      if (entity != null &&
          !entity.isDisposed &&
          connectedAddresses.contains(addr)) {
        return entity;
      }
    }
    throw StateError('Device is not connected');
  }

  XiaomiDeviceComponent _pluginXiaomi(String addr) {
    final component = _pluginEntity(addr).get<XiaomiDeviceComponent>();
    if (component == null) {
      throw UnsupportedError('Device does not support Xiaomi protobuf');
    }
    return component;
  }

  Future<void> sendPluginProtobuf(String addr, Uint8List bytes) =>
      _pluginXiaomi(addr).sendProtobufBytes(bytes);

  Future<void> sendPluginProtocol(
    String addr,
    Uint8List bytes, {
    int? channel,
  }) async {
    final entity = _pluginEntity(addr);
    final xiaomi = entity.get<XiaomiDeviceComponent>();
    if (xiaomi != null) {
      if (channel == null || channel == L2Channel.pb.value) {
        await xiaomi.sendProtobufBytes(bytes);
      } else {
        if (xiaomi.sppV1) {
          throw UnsupportedError('SPP v1 only supports protobuf plugin writes');
        }
        await xiaomi.sendL2Data(L2Channel.fromValue(channel), bytes);
      }
      return;
    }
    final zepp = entity.get<ZeppOsDeviceComponent>();
    if (zepp == null) throw UnsupportedError('Device protocol is unavailable');
    if (channel == null || channel < 0 || channel > 0xffff) {
      throw const FormatException(
        'ZeppOS requires an endpoint channel from 0 to 65535',
      );
    }
    await zepp.sendToEndpoint(channel, bytes, encrypted: true);
  }

  Future<Uint8List> requestPluginProtocol(
    String addr,
    Uint8List bytes, {
    int? channel,
    Duration timeout = const Duration(seconds: 5),
    Stream<void>? cancellation,
  }) async {
    if (timeout <= Duration.zero) {
      throw const FormatException('Timeout must be positive');
    }
    final entity = _pluginEntity(addr);
    final xiaomi = entity.get<XiaomiDeviceComponent>();
    if (xiaomi != null && (channel == null || channel == L2Channel.pb.value)) {
      final packet = pb.WearPacket.fromBuffer(bytes);
      return xiaomi.requestPool.request<Uint8List>(
        packet: packet,
        typeMatcher: (response) =>
            response.type == packet.type && response.id == packet.id,
        responseMapper: (response) => response.writeToBuffer(),
        timeout: timeout,
        cancellation: cancellation,
      );
    }
    if (channel == null) {
      throw const FormatException('An endpoint channel is required');
    }
    var requests = entity.system<ProtocolRequestSystem>();
    if (requests == null) {
      requests = ProtocolRequestSystem();
      entity.registerSystem(requests);
    }
    return requests.request(
      channel: channel,
      send: () => sendPluginProtocol(addr, bytes, channel: channel),
      timeout: timeout,
      cancellation: cancellation,
    );
  }

  Future<void> sendPluginCanopus(
    String addr,
    String module,
    Uint8List bytes, {
    required bool isText,
  }) async {
    final system = _pluginEntity(addr).system<XiaomiCanopusSystem>();
    if (system == null) {
      throw UnsupportedError('Device does not support CanopusConnect');
    }
    await system.sendConnect(module, bytes, isText: isText);
  }

  Future<void> listenPluginCanopus(
    String addr,
    String module,
    bool enabled, {
    bool restoring = false,
  }) async {
    // Authentication finishes before the manager publishes the ready state.
    final manager = this;
    final authenticatedEntity = restoring && manager is LocalDeviceManager
        ? manager._currentEntity
        : null;
    final entity =
        authenticatedEntity != null &&
            authenticatedEntity.id == addr &&
            !authenticatedEntity.isDisposed
        ? authenticatedEntity
        : _pluginEntity(addr);
    final system = entity.system<XiaomiCanopusSystem>();
    if (system == null) {
      throw UnsupportedError('Device does not support CanopusConnect');
    }
    await system.listenConnect(module, enabled, restoring: restoring);
  }

  Future<void> sendPluginNotification(
    String addr,
    String source,
    Map<String, Object?> message,
  ) async {
    await sendPluginProtobuf(
      addr,
      XiaomiPluginNotification.encode(source, message),
    );
  }

  Future<void> removePluginNotification(
    String addr,
    String source,
    int id,
  ) async {
    await sendPluginProtobuf(addr, XiaomiPluginNotification.remove(source, id));
  }
}
