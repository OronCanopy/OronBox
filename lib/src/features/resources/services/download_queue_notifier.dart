import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:oronbox/src/commands/command_protocol.dart';
import 'package:oronbox/src/core/providers/app_settings_providers.dart';
import 'package:oronbox/src/features/resources/application/resource_catalog_providers.dart';
import 'package:oronbox/src/features/resources/domain/community_resource.dart';
import 'package:oronbox/src/features/resources/domain/community_resource_codec.dart';
import 'package:oronbox/src/features/resources/services/install_queue_notifier.dart';
import 'package:oronbox/src/features/resources/services/resource_install_service.dart';
import 'package:oronbox/src/host/application_host_provider.dart';
import 'package:oronbox/src/device/xiaomi/xiaomi_device_catalog.dart';
import 'package:oronbox/src/device/zeppos/zeppos_device_catalog.dart';

export 'package:oronbox/src/features/resources/services/resource_install_service.dart'
    show ResourceTaskStatus;

class ResourceTask {
  const ResourceTask({
    required this.id,
    required this.resource,
    required this.file,
    required this.codename,
    this.deviceId,
    this.status = ResourceTaskStatus.pending,
    this.progress = 0,
    this.error,
    this.filePath = '',
    this.bytes,
    this.installType,
  });

  final String id;
  final CommunityResourceDetail resource;
  final CommunityResourceFile file;
  final String codename;
  final String? deviceId;
  final ResourceTaskStatus status;
  final double progress;
  final String? error;

  /// Staged payload handed from download to the install queue.
  final String filePath;
  final Uint8List? bytes;
  final String? installType;

  String get title => resource.name;
}

String resourceTargetDeviceDisplayName(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty) return normalized;
  final xiaomi = normalizeXiaomiWearableIdentity(normalized);
  if (xiaomi != null) return xiaomi.displayName;
  final zeppId = normalized.startsWith('zepp:')
      ? normalized.substring('zepp:'.length)
      : normalized;
  for (final device in zeppOsDeviceCatalog) {
    if (device.id == zeppId && device.bluetoothNames.isNotEmpty) {
      return device.bluetoothNames.first;
    }
  }
  return normalized;
}

/// Runs downloads concurrently (up to [maxConcurrent]) on both platforms and
/// hands each finished payload to the install queue, which stays serial. The
/// install type is resolved by the payload analyzer before a resource enters
/// the install queue, so the queue always shows the detected type.
class DownloadQueueNotifier extends Notifier<List<ResourceTask>> {
  static const maxConcurrent = 3;

  int _active = 0;
  final Set<String> _enqueuing = {};

  @override
  List<ResourceTask> build() => const [];

  ResourceTask? get runningTask => state
      .where(
        (task) =>
            task.status == ResourceTaskStatus.downloading ||
            task.status == ResourceTaskStatus.installing,
      )
      .firstOrNull;

  bool enqueue({
    required CommunityResourceDetail resource,
    required CommunityResourceFile file,
    required String codename,
    String? deviceId,
  }) {
    final key =
        '${resource.ref.key}:${file.id}:$codename${deviceId == null ? '' : ':$deviceId'}';
    if (_enqueuing.contains(key)) return false;
    if (state.any(
      (task) =>
          task.resource.ref == resource.ref &&
          task.file.id == file.id &&
          task.codename == codename &&
          task.deviceId == deviceId &&
          task.status != ResourceTaskStatus.completed,
    )) {
      return false;
    }
    _enqueuing.add(key);
    unawaited(
      _enqueue(
        resource,
        file,
        codename,
        deviceId,
      ).whenComplete(() => _enqueuing.remove(key)),
    );
    return true;
  }

  Future<void> _enqueue(
    CommunityResourceDetail resource,
    CommunityResourceFile file,
    String codename,
    String? deviceId,
  ) async {
    final task = ResourceTask(
      id: '${resource.ref.key}:${file.id}:$codename${deviceId == null ? '' : ':$deviceId'}',
      resource: resource,
      file: file,
      codename: codename,
      deviceId: deviceId,
    );
    state = [...state, task];
    _startNext();
  }

  void _startNext() {
    while (_active < maxConcurrent) {
      final next = state
          .where((task) => task.status == ResourceTaskStatus.pending)
          .firstOrNull;
      if (next == null) break;
      _active += 1;
      unawaited(_run(next));
    }
  }

  Future<void> _run(ResourceTask task) async {
    _update(task.id, ResourceTaskStatus.downloading, 0, null);
    try {
      final ResourceTask completed = await _download(task);
      if (!state.any((entry) => entry.id == task.id)) {
        return;
      }
      await _handToInstallQueue(completed);
      state = state.where((entry) => entry.id != task.id).toList();
    } catch (error) {
      if (state.any((entry) => entry.id == task.id)) {
        final current = state.where((entry) => entry.id == task.id).firstOrNull;
        if (current?.status != ResourceTaskStatus.failed) {
          _update(task.id, ResourceTaskStatus.failed, 0, error.toString());
        }
      }
    } finally {
      _active -= 1;
      _startNext();
    }
  }

  Future<ResourceTask> _download(ResourceTask task) async {
    final resource = task.resource;
    if (kIsWeb) {
      String? downloadError;
      final downloaded = await ResourceInstallService().downloadResource(
        resource: resource,
        file: task.file,
        catalog: ref.read(
          localCommunityCatalogProviderForSource(resource.ref.source),
        ),
        targetDevice: task.codename,
        onUpdate: (status, progress, error) {
          if (error != null) downloadError = error;
          _update(task.id, status, progress, error);
        },
      );
      if (downloaded == null) {
        throw StateError(downloadError ?? 'Resource download failed');
      }
      return ResourceTask(
        id: task.id,
        resource: resource,
        file: task.file,
        codename: task.codename,
        deviceId: task.deviceId,
        status: ResourceTaskStatus.completed,
        progress: 1,
        filePath: downloaded.path,
        bytes: downloaded.bytes,
      );
    }
    final host = ref.read(applicationHostProvider);
    final operationId =
        'download:${task.id}:${DateTime.now().microsecondsSinceEpoch}';
    final progressSubscription = host.events.listen((event) {
      if (event.data['operationId']?.toString() != operationId) {
        return;
      }
      final rawProgress = event.data['progress'];
      if (rawProgress is! num) return;
      final progress =
          (rawProgress <= 1
                  ? rawProgress.toDouble()
                  : rawProgress.toDouble() / 100)
              .clamp(0, 1)
              .toDouble();
      if (event.event == ResourceTaskStatus.downloading.name) {
        _update(task.id, ResourceTaskStatus.downloading, progress, null);
      }
    });
    try {
      final result = await host.execute(
        OronBoxCommand(
          method: 'resource.download',
          params: {
            'ref': resource.ref.key,
            'file': task.file.id,
            'targetDevice': task.codename,
            'title': resource.name,
            'operationId': operationId,
            'resource': communityResourceDetailToJson(resource),
          },
        ),
      );
      if (!result.ok) {
        throw result.error!;
      }
      final download = (result.value as Map).cast<String, Object?>();
      return ResourceTask(
        id: task.id,
        resource: resource,
        file: task.file,
        codename: task.codename,
        deviceId: task.deviceId,
        status: ResourceTaskStatus.completed,
        progress: 1,
        filePath: download['path']?.toString() ?? '',
        installType: download['type']?.toString(),
      );
    } finally {
      await progressSubscription.cancel();
    }
  }

  Future<void> _handToInstallQueue(ResourceTask task) async {
    if (kIsWeb) {
      final service = ResourceInstallService();
      final bytes = task.bytes;
      if (bytes == null) {
        throw StateError('Downloaded payload is empty');
      }
      // Resolve the real type once, before the payload enters the install
      // queue; the catalog label is only a hint.
      final analysis = service.analyzePayload(
        fileName: task.file.fileName,
        bytes: bytes,
        hint: switch (task.resource.type) {
          CommunityResourceType.quickApp ||
          CommunityResourceType.miniprogram => LocalDeviceInstallType.app,
          CommunityResourceType.watchface => LocalDeviceInstallType.watchface,
          CommunityResourceType.firmware => LocalDeviceInstallType.firmware,
          CommunityResourceType.canopus => LocalDeviceInstallType.canopus,
          CommunityResourceType.resPack => LocalDeviceInstallType.resPack,
        },
        source: 'download-queue',
      );
      ref
          .read(installQueueProvider.notifier)
          .enqueueResource(
            resource: task.resource,
            file: task.file,
            codename: task.codename,
            deviceId: task.deviceId,
            filePath: task.filePath,
            bytes: bytes,
            analysis: analysis,
          );
      return;
    }
    final autoInstall = ref.read(appSettingsProvider).autoInstall;
    final result = await ref
        .read(applicationHostProvider)
        .execute(
          OronBoxCommand(
            method: 'task.enqueue',
            params: {
              'held': !autoInstall,
              'command': OronBoxCommand(
                method: 'install.local',
                params: {
                  'type': task.installType,
                  'path': task.filePath,
                  'title': task.resource.name,
                  'description': task.codename,
                  if (task.deviceId != null) 'device': task.deviceId,
                  'deleteAfter': true,
                  'autoClean': true,
                  'resource': communityResourceDetailToJson(task.resource),
                  'file': task.file.id,
                },
              ).toJson(),
            },
          ),
        );
    if (!result.ok) {
      throw result.error!;
    }
  }

  void _update(
    String id,
    ResourceTaskStatus status,
    double progress,
    String? error,
  ) {
    final current = state.where((task) => task.id == id).firstOrNull;
    if (current == null) return;
    final normalized = progress.clamp(0.0, 1.0).toDouble();
    if (status == ResourceTaskStatus.downloading &&
        normalized < current.progress) {
      return;
    }
    state = [
      for (final task in state)
        if (task.id == id)
          ResourceTask(
            id: task.id,
            resource: task.resource,
            file: task.file,
            codename: task.codename,
            deviceId: task.deviceId,
            status: status,
            progress: normalized,
            error: error,
            filePath: current.filePath,
            bytes: current.bytes,
            installType: current.installType,
          )
        else
          task,
    ];
  }

  void remove(String id) {
    state = state.where((entry) => entry.id != id).toList();
    _startNext();
  }

  void clearTerminal() {
    state = state
        .where(
          (task) =>
              task.status != ResourceTaskStatus.completed &&
              task.status != ResourceTaskStatus.failed,
        )
        .toList();
    _startNext();
  }

  void retry(String id) {
    state = [
      for (final task in state)
        if (task.id == id)
          ResourceTask(
            id: task.id,
            resource: task.resource,
            file: task.file,
            codename: task.codename,
            deviceId: task.deviceId,
          )
        else
          task,
    ];
    _startNext();
  }
}

final downloadQueueProvider =
    NotifierProvider<DownloadQueueNotifier, List<ResourceTask>>(
      DownloadQueueNotifier.new,
    );
