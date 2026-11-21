import 'dart:async';

import 'package:oronbox/src/app/widgets/app_scaffold_messenger.dart';
import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:oronbox/src/app/generated/app_localizations.dart';
import 'package:oronbox/src/app/utils/error_localization.dart';
import 'package:oronbox/src/app/utils/picked_file.dart';
import 'package:oronbox/src/app/widgets/app_state_view.dart';
import 'package:oronbox/src/app/widgets/page_container.dart';
import 'package:oronbox/src/app/widgets/release_notes_view.dart';
import 'package:oronbox/src/app/widgets/sys_app_bar.dart';
import 'package:oronbox/src/core/constants/style_constants.dart';
import 'package:oronbox/src/device/core/device_kind.dart';
import 'package:oronbox/src/features/devices/controllers/device_manager.dart';
import 'package:oronbox/src/core/storage/managed_temporary_files.dart';
import 'package:oronbox/src/features/devices/services/firmware_catalog.dart';
import 'package:oronbox/src/features/devices/services/firmware_download_resource.dart';
import 'package:oronbox/src/features/resources/services/download_queue_notifier.dart';
import 'package:oronbox/src/features/resources/services/resource_install_service.dart';
import 'package:oronbox/src/features/resources/widgets/resource_install_confirmation.dart';

typedef _FirmwareTarget = ({
  String address,
  String? codename,
  String model,
  String version,
  String? product,
});

_FirmwareTarget? _firmwareTarget(DeviceManagerState state) {
  final device = state.currentDevice;
  if (device == null || device.disconnected) return null;
  final info = state.systemInfo;
  return (
    address: device.addr,
    codename: device.codename,
    model: info?.model ?? '',
    version: info?.firmwareVersion.trim() ?? '',
    product: info?.productDevice,
  );
}

class DeviceFirmwarePage extends ConsumerStatefulWidget {
  const DeviceFirmwarePage({super.key});

  @override
  ConsumerState<DeviceFirmwarePage> createState() => _DeviceFirmwarePageState();
}

class _DeviceFirmwarePageState extends ConsumerState<DeviceFirmwarePage> {
  bool _checking = false;
  bool _checked = false;
  bool _sourceUnavailable = false;
  bool _installingUpdate = false;
  String? _error;
  List<FirmwareRelease> _releases = const [];
  _FirmwareTarget? _releaseTarget;
  int _lookup = 0;

  @override
  void initState() {
    super.initState();
    Future.microtask(_checkForUpdates);
  }

  Future<void> _checkForUpdates() async {
    if (!mounted) return;
    final manager = ref.read(deviceManagerProvider.notifier);
    final target = _firmwareTarget(ref.read(deviceManagerProvider));
    if (target == null || _checking) return;
    final lookup = ++_lookup;
    bool isCurrent() =>
        mounted &&
        lookup == _lookup &&
        _firmwareTarget(ref.read(deviceManagerProvider)) == target;
    setState(() {
      _checking = true;
      _sourceUnavailable = false;
      _error = null;
    });
    try {
      final releases = await ref
          .read(firmwareCatalogProvider)
          .findUpdates(
            FirmwareCatalogQuery(
              kind: manager.currentDeviceKind ?? DeviceKind.xiaomi,
              codename: target.codename,
              model: target.model,
              currentVersion: target.version,
              productDevice: target.product,
            ),
          );
      if (!isCurrent()) return;
      setState(() {
        _releases = releases;
        _releaseTarget = target;
        _checked = true;
      });
    } on FirmwareCatalogUnavailable {
      if (!isCurrent()) return;
      setState(() {
        _releases = const [];
        _checked = true;
        _sourceUnavailable = true;
      });
    } catch (error) {
      if (!isCurrent()) return;
      setState(() {
        _releases = const [];
        _checked = true;
        _error = localizedErrorMessage(AppLocalizations.of(context)!, error);
      });
    } finally {
      if (isCurrent()) setState(() => _checking = false);
    }
  }

  Future<void> _downloadLatest(
    FirmwareRelease release, {
    FirmwarePackage? selectedPackage,
  }) async {
    final state = ref.read(deviceManagerProvider);
    final target = _firmwareTarget(state);
    if (target == null ||
        target != _releaseTarget ||
        !_releases.contains(release)) {
      return;
    }
    final codename = target.codename ?? '';
    final package = selectedPackage ?? release.packageFor(target.version);
    if (package.isIncremental &&
        normalizeFirmwareVersion(package.fromVersion!) !=
            normalizeFirmwareVersion(target.version)) {
      return;
    }
    final detail = firmwareDownloadResource(release, package, codename);
    ref
        .read(downloadQueueProvider.notifier)
        .enqueue(
          resource: detail,
          file: detail.files.first,
          codename: codename,
          deviceId: target.address,
        );
    if (!mounted) return;
    appScaffoldMessengerOf(context).showSnackBar(
      SnackBar(content: Text(AppLocalizations.of(context)!.downloadTaskAdded)),
    );
  }

  Future<void> _installLatest(
    FirmwareRelease release,
    FirmwarePackage package,
  ) async {
    if (_installingUpdate) return;
    setState(() => _installingUpdate = true);
    try {
      await _downloadLatest(release, selectedPackage: package);
    } finally {
      if (mounted) setState(() => _installingUpdate = false);
    }
  }

  Future<void> _installLocal() async {
    final target = _firmwareTarget(ref.read(deviceManagerProvider));
    if (target == null) return;
    final file = await pickFileData(
      type: FileType.any,
      loadBytes: shouldLoadPickedFileData,
    );
    final selected = file?.xFile;
    if (selected == null) return;
    if (!mounted ||
        _firmwareTarget(ref.read(deviceManagerProvider)) != target) {
      await ManagedTemporaryFiles.releaseImport(selected.path);
      return;
    }
    await confirmAndEnqueueResourceFile(
      context: context,
      ref: ref,
      file: selected,
      selectedType: LocalDeviceInstallType.firmware,
      deviceId: target.address,
      isTargetCurrent: () =>
          _firmwareTarget(ref.read(deviceManagerProvider)) == target,
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(deviceManagerProvider.select(_firmwareTarget), (previous, next) {
      ++_lookup;
      setState(() {
        _releases = const [];
        _releaseTarget = null;
        _checked = false;
        _checking = false;
        _sourceUnavailable = false;
        _error = null;
      });
      if (next != null) unawaited(_checkForUpdates());
    });
    final l10n = AppLocalizations.of(context)!;
    final state = ref.watch(deviceManagerProvider);
    final device = state.currentDevice;
    final currentVersion = state.systemInfo?.firmwareVersion.trim() ?? '';
    final latest = _releases.firstOrNull;
    final updatePackage = latest?.packageFor(currentVersion);
    final history = _releases.length > 1
        ? _releases.skip(1).toList(growable: false)
        : const <FirmwareRelease>[];
    final hasUpdate =
        latest != null &&
        updatePackage != null &&
        currentVersion.isNotEmpty &&
        compareFirmwareVersions(latest.version, currentVersion) > 0;

    return Scaffold(
      appBar: SysAppBar(
        secondary: true,
        title: Text(l10n.deviceFeaturesInstallFirmware),
      ),
      body: ListView(
        padding: EdgeInsets.zero,
        children: [
          PageContainer(
            padding: EdgeInsets.fromLTRB(
              StyleConstants.pagePadding,
              8,
              StyleConstants.pagePadding,
              bottomContentPadding(context, extra: 24),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SectionHeader(title: l10n.firmwareCurrentVersion),
                Text(
                  currentVersion.isEmpty
                      ? l10n.firmwareVersionUnknown
                      : currentVersion,
                  style: Theme.of(context).textTheme.displaySmall,
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(child: Text(_statusText(l10n, latest, hasUpdate))),
                    TextButton.icon(
                      onPressed: _checking ? null : _checkForUpdates,
                      icon: _checking
                          ? const SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh),
                      label: Text(_checking ? l10n.refreshing : l10n.refresh),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.tonalIcon(
                        onPressed: latest == null
                            ? null
                            : () => _downloadLatest(
                                latest,
                                selectedPackage: latest.fullPackage,
                              ),
                        icon: const Icon(Icons.download_outlined),
                        label: Text(l10n.firmwareDownloadLatestFull),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.tonalIcon(
                        onPressed: device == null ? null : _installLocal,
                        icon: const Icon(Icons.folder_open_outlined),
                        label: Text(l10n.localFirmwareInstall),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 28),
                SectionHeader(title: l10n.firmwareLatestRelease),
                const SizedBox(height: 8),
                SectionCard(
                  margin: EdgeInsets.zero,
                  child: latest == null
                      ? EmptyStateView(
                          compact: true,
                          icon: Icons.system_update_alt,
                          title: _emptyText(l10n),
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              latest.version,
                              style: Theme.of(context).textTheme.headlineSmall,
                            ),
                            if (hasUpdate) ...[
                              const SizedBox(height: 12),
                              FilledButton.icon(
                                onPressed: _installingUpdate
                                    ? null
                                    : () =>
                                          _installLatest(latest, updatePackage),
                                icon: _installingUpdate
                                    ? const SizedBox.square(
                                        dimension: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(Icons.system_update_alt),
                                label: Text(
                                  updatePackage.isIncremental
                                      ? l10n.firmwareUpdateIncrementalPackage
                                      : l10n.firmwareUpdateFullPackage,
                                ),
                              ),
                            ],
                            const SizedBox(height: 20),
                            Text(
                              l10n.firmwareReleaseNotes,
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            const SizedBox(height: 8),
                            if (latest.releaseNotes?.trim().isNotEmpty == true)
                              ReleaseNotesView(
                                data: latest.releaseNotes!.trim(),
                              )
                            else
                              Text(l10n.firmwareReleaseNotesUnavailable),
                          ],
                        ),
                ),
                if (history.isNotEmpty) ...[
                  const SizedBox(height: 28),
                  SectionHeader(title: l10n.firmwareHistoricalReleases),
                  const SizedBox(height: 8),
                  for (final release in history) ...[
                    SectionCard(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  release.version,
                                  style: Theme.of(context).textTheme.titleMedium
                                      ?.copyWith(fontWeight: FontWeight.w700),
                                ),
                              ),
                              IconButton(
                                tooltip: l10n.download,
                                icon: const Icon(Icons.download_outlined),
                                onPressed: () => _downloadLatest(release),
                              ),
                            ],
                          ),
                          if (release.releaseNotes?.trim().isNotEmpty ==
                              true) ...[
                            const SizedBox(height: 8),
                            ReleaseNotesView(
                              data: release.releaseNotes!.trim(),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _statusText(
    AppLocalizations l10n,
    FirmwareRelease? latest,
    bool hasUpdate,
  ) {
    if (_checking) return l10n.firmwareCheckingUpdates;
    if (_error != null) return l10n.updateCheckFailed;
    if (_sourceUnavailable) return l10n.firmwareSourceUnavailable;
    if (!_checked || latest == null) return l10n.firmwareNoUpdatesFound;
    return hasUpdate ? l10n.firmwareUpdateAvailable : l10n.firmwareUpToDate;
  }

  String _emptyText(AppLocalizations l10n) {
    if (_checking) return l10n.firmwareCheckingUpdates;
    if (_error != null) return l10n.updateCheckFailed;
    if (_sourceUnavailable) return l10n.firmwareSourceUnavailable;
    return l10n.firmwareNoUpdatesFound;
  }
}
