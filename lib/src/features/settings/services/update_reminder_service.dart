import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:oronbox/src/core/logging/logging_service.dart';
import 'package:oronbox/src/commands/command_protocol.dart';
import 'package:oronbox/src/core/network/dio_provider.dart';
import 'package:oronbox/src/data/astrobox/astrobox_repo_resource_provider.dart';
import 'package:oronbox/src/data/community/community_source.dart';
import 'package:oronbox/src/device/core/device_kind.dart';
import 'package:oronbox/src/device/core/device_state.dart';
import 'package:oronbox/src/features/devices/controllers/device_manager.dart';
import 'package:oronbox/src/features/devices/services/firmware_catalog.dart';
import 'package:oronbox/src/features/devices/services/firmware_download_resource.dart';
import 'package:oronbox/src/features/plugins/application/plugin_repository.dart';
import 'package:oronbox/src/features/resources/application/resource_catalog_providers.dart';
import 'package:oronbox/src/features/resources/domain/community_resource.dart';
import 'package:oronbox/src/features/resources/services/download_queue_notifier.dart';
import 'package:oronbox/src/features/resources/services/install_queue_notifier.dart';
import 'package:oronbox/src/features/resources/services/resource_install_service.dart'
    show installedResourceSource;
import 'package:oronbox/src/core/services/shared_prefs_service.dart';
import 'package:oronbox/src/features/resources/services/installed_resource_updates.dart';
import 'package:oronbox/src/host/application_host_provider.dart';

enum UpdateReminderKind { firmware, resources, plugins, inbox }

class UpdateReminderItem {
  const UpdateReminderItem({
    required this.id,
    required this.name,
    required this.version,
    required this.revision,
    this.currentVersion,
    this.source,
    this.resource,
    this.install,
    this.batch = true,
    this.group,
    this.purchaseRequired = false,
    this.available,
  });

  final String id;
  final String name;
  final String version;
  final String revision;
  final String? currentVersion;
  final String? source;
  final ResourceRef? resource;
  final Future<bool> Function()? install;
  final bool batch;
  final String? group;
  final bool purchaseRequired;
  final bool Function()? available;
}

final updateReminderServiceProvider = Provider(UpdateReminderService.new);

class UpdateReminderService {
  const UpdateReminderService(this.ref);

  static final _log = getLogger('UpdateReminderService');
  final Ref ref;

  bool isQueued(
    ResourceRef resource,
    String file,
    String deviceId,
    String codename,
  ) =>
      ref
          .read(downloadQueueProvider)
          .any(
            (task) =>
                task.resource.ref == resource &&
                task.file.id == file &&
                task.codename == codename &&
                (task.deviceId == null || task.deviceId == deviceId),
          ) ||
      ref
          .read(installQueueProvider)
          .tasks
          .any(
            (task) =>
                task.resource?.ref == resource &&
                task.file?.id == file &&
                (task.deviceId == deviceId ||
                    (task.deviceId == null && task.description == codename)) &&
                task.status != ResourceTaskStatus.completed,
          );

  Future<List<UpdateReminderItem>> firmware(String deviceId) async {
    final state = ref.read(deviceManagerProvider);
    final device = state.currentDevice;
    final info = state.systemInfo;
    final kind = ref.read(deviceManagerProvider.notifier).currentDeviceKind;
    if (device?.addr != deviceId ||
        info == null ||
        kind == null ||
        kind == DeviceKind.zepp) {
      return const [];
    }
    final current = info.firmwareVersion;
    if (normalizeFirmwareVersion(current).isEmpty) return const [];
    final query = FirmwareCatalogQuery(
      kind: kind,
      codename: device!.codename,
      model: info.model,
      productDevice: info.productDevice,
      currentVersion: current,
    );
    final catalog = ref.read(firmwareCatalogProvider);
    final latest = (await catalog.findUpdates(query)).firstOrNull;
    if (latest == null ||
        compareFirmwareVersions(latest.version, current) <= 0) {
      return const [];
    }
    final codename = device.codename ?? '';
    final file = latest.packageFor(current).fileName;
    bool available() =>
        _isCurrent(deviceId) &&
        ref.read(deviceManagerProvider).systemInfo?.firmwareVersion ==
            current &&
        !isQueued(
          ResourceRef(source: CommunitySourceId.astroboxRepo, id: file),
          file,
          deviceId,
          codename,
        );
    return [
      UpdateReminderItem(
        id: 'firmware',
        name: device.name,
        version: latest.version,
        revision: normalizeFirmwareVersion(latest.version),
        currentVersion: current,
        available: available,
        install: () async {
          if (!_isCurrent(deviceId) ||
              ref.read(deviceManagerProvider).systemInfo?.firmwareVersion !=
                  current) {
            return false;
          }
          final release = (await catalog.findUpdates(query)).firstOrNull;
          if (!_isCurrent(deviceId) ||
              release?.version != latest.version ||
              ref.read(deviceManagerProvider).systemInfo?.firmwareVersion !=
                  current) {
            return false;
          }
          final detail = firmwareDownloadResource(
            release!,
            release.packageFor(current),
            codename,
          );
          return _enqueue(detail, detail.files.single, deviceId, codename);
        },
      ),
    ];
  }

  Future<({List<UpdateReminderItem> items, bool complete})> resources(
    String deviceId, {
    required bool Function() canRead,
  }) async {
    final manager = ref.read(deviceManagerProvider.notifier);
    Future<bool> read(Future<void> Function() fetch, String kind) async {
      if (!ref.mounted || !canRead()) return false;
      try {
        await fetch();
        return ref.mounted && canRead();
      } catch (error, stack) {
        _log.warning('Unable to read installed $kind', error, stack);
        return false;
      }
    }

    final watchfacesRead = await read(manager.fetchWatchfaces, 'watchfaces');
    final appsRead = await read(manager.fetchApps, 'apps');
    if (!ref.mounted || !canRead() || (!appsRead && !watchfacesRead)) {
      return (items: const <UpdateReminderItem>[], complete: false);
    }
    final state = ref.read(deviceManagerProvider);
    final codename = state.currentDevice?.codename ?? '';
    if (codename.isEmpty) {
      return (items: const <UpdateReminderItem>[], complete: false);
    }
    final kind = ref.read(deviceManagerProvider.notifier).currentDeviceKind;
    final source = ref.read(
      localCommunityCatalogProviderForSource(CommunitySourceId.astroboxRepo),
    ) as AstroBoxRepoCatalog;
    final (
      items: candidates,
      :complete,
    ) = await InstalledResourceUpdates(ref.read(appDioProvider), source).find(
      codename,
      [
        for (final face in state.watchfaces)
          if (watchfacesRead && face.versionCode > 0)
            InstalledResourceVersion('watchface', face.id, face.versionCode),
        for (final app in state.apps)
          if (appsRead && app.versionCode > 0)
            InstalledResourceVersion(
              kind == DeviceKind.zepp ? 'zepp_app' : 'quickapp',
              app.packageName,
              app.versionCode,
            ),
      ],
    );
    if (!ref.mounted || !_isCurrent(deviceId)) {
      return (items: const <UpdateReminderItem>[], complete: false);
    }
    await SharedPrefsService.instance.reload();
    if (!ref.mounted || !_isCurrent(deviceId)) {
      return (items: const <UpdateReminderItem>[], complete: false);
    }
    final groups = <(String, String), List<ResourceUpdateCandidate>>{};
    for (final candidate in candidates) {
      (groups[(candidate.package.kind, candidate.package.id)] ??= []).add(
        candidate,
      );
    }
    final result = <UpdateReminderItem>[];
    for (final entry in groups.entries) {
      final candidates = entry.value;
      final installedSource = installedResourceSource(
        deviceId,
        entry.key.$1,
        entry.key.$2,
        candidates.first.package.versionCode,
      );
      final preferred = candidates
          .where((item) => item.ref.source == installedSource)
          .toList();
      final selected = preferred.isEmpty ? candidates : preferred;
      selected.sort((a, b) => b.versionCode.compareTo(a.versionCode));
      final unique = <String>{};
      final choices = selected
          .where(
            (item) => unique.add(
              item.sha256.isEmpty
                  ? '${item.ref.key}:${item.fileId}'
                  : item.sha256,
            ),
          )
          .toList();
      final sources = choices.map((item) => item.ref.source).toSet();
      final latest = sources.length == 1
          ? choices
                .where((item) => item.versionCode == choices.first.versionCode)
                .toList()
          : choices;
      for (final item in latest) {
        bool available() =>
            _isCurrent(deviceId) &&
            _installedVersion(item.package) == item.package.versionCode &&
            !isQueued(item.ref, item.fileId, deviceId, codename);
        result.add(
          UpdateReminderItem(
            id: '${entry.key.$1}:${entry.key.$2}:${item.ref.key}:${item.fileId}',
            name: item.name,
            version: item.version,
            revision: item.versionCode.toString(),
            source: latest.length > 1 ? item.ref.source.displayName : null,
            resource: item.ref,
            group: '${entry.key.$1}:${entry.key.$2}',
            purchaseRequired: item.purchaseRequired,
            available: available,
            batch: latest.length == 1 && !item.purchaseRequired,
            install: () async {
              if (!available()) return false;
              final detail = await ref
                  .read(localCommunityCatalogProviderForSource(item.ref.source))
                  .getDetail(item.ref);
              final file = detail.files
                  .where(
                    (file) =>
                        file.id == item.fileId &&
                        file.version == item.version &&
                        (item.sha256.isEmpty ||
                            file.sha256?.toLowerCase() == item.sha256) &&
                        (file.versionCode == null ||
                            file.versionCode == item.versionCode),
                  )
                  .firstOrNull;
              if (file == null ||
                  file.purchaseRequired ||
                  !detail.canDownload ||
                  !available()) {
                return false;
              }
              return _enqueue(detail, file, deviceId, codename);
            },
          ),
        );
      }
    }
    return (items: result, complete: complete && appsRead && watchfacesRead);
  }

  Future<List<UpdateReminderItem>> plugins() async {
    final host = ref.read(applicationHostProvider);
    final result = await host.execute(
      const OronBoxCommand(
        method: 'plugin.repository.updates',
        params: {'force': true},
      ),
    );
    if (!result.ok) throw result.error!;
    final latest = <(String, String), Map>{};
    for (final item in (result.value as List? ?? const []).whereType<Map>()) {
      final key = (item['runtime'].toString(), item['installedId'].toString());
      final previous = latest[key];
      if (previous == null ||
          comparePluginVersions(
                item['version'].toString(),
                previous['version'].toString(),
              ) >
              0) {
        latest[key] = item;
      }
    }
    return [
      for (final entry in latest.entries)
        UpdateReminderItem(
          id: '${entry.key.$1}:${entry.key.$2}',
          name: entry.value['name'].toString(),
          version: entry.value['version'].toString(),
          revision: entry.value['version'].toString(),
          install: () async {
            final installed = await host.execute(
              OronBoxCommand(
                method: 'plugin.repository.install',
                params: {
                  'source': entry.value['source'],
                  'id': entry.value['id'],
                  'expectedVersion': entry.value['version'],
                },
              ),
            );
            if (!installed.ok) throw installed.error!;
            return true;
          },
        ),
    ];
  }

  int? _installedVersion(InstalledResourceVersion item) {
    final state = ref.read(deviceManagerProvider);
    return item.kind == 'watchface'
        ? state.watchfaces
              .where((face) => face.id == item.id)
              .firstOrNull
              ?.versionCode
        : state.apps
              .where((app) => app.packageName == item.id)
              .firstOrNull
              ?.versionCode;
  }

  bool _isCurrent(String deviceId) {
    if (!ref.mounted) return false;
    final device = ref.read(deviceManagerProvider).currentDevice;
    return device?.addr == deviceId &&
        device?.disconnected == false &&
        ref.read(deviceManagerProvider).protocolState == ProtocolState.ready;
  }

  bool _enqueue(
    CommunityResourceDetail detail,
    CommunityResourceFile file,
    String deviceId,
    String codename,
  ) {
    if (isQueued(detail.ref, file.id, deviceId, codename)) return true;
    return ref
        .read(downloadQueueProvider.notifier)
        .enqueue(
          resource: detail,
          file: file,
          codename: codename,
          deviceId: deviceId,
        );
  }
}
