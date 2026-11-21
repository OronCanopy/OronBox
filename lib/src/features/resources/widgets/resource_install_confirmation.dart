import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:oronbox/src/core/storage/managed_temporary_files.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:oronbox/src/app/generated/app_localizations.dart';
import 'package:oronbox/src/app/utils/error_localization.dart';
import 'package:oronbox/src/app/widgets/dialog_helper.dart';
import 'package:oronbox/src/core/models/device.dart';
import 'package:oronbox/src/device/core/device_kind.dart';
import 'package:oronbox/src/device/core/device_profile.dart';
import 'package:oronbox/src/device/core/watchface_install_policy.dart';
import 'package:oronbox/src/features/devices/controllers/device_manager.dart';
import 'package:oronbox/src/features/resources/services/install_queue_notifier.dart';
import 'package:oronbox/src/features/resources/services/resource_install_service.dart';
import 'package:oronbox/src/features/resources/services/resource_payload_analyzer.dart';

enum _InstallDecision { cancel, selectedType, detectedType, forceDetectedType }

Future<bool> confirmAndEnqueueResourceFile({
  required BuildContext context,
  required WidgetRef ref,
  required XFile file,
  LocalDeviceInstallType? selectedType,
  bool retainSource = false,
  String? deviceId,
  bool Function()? isTargetCurrent,
}) async {
  try {
    final fileName = file.name;
    final fileLength = await file.length();
    final probe = await file
        .openRead(0, math.min(fileLength, 4096))
        .fold<List<int>>(<int>[], (bytes, chunk) => bytes..addAll(chunk));
    final isZip = probe.length >= 2 && probe[0] == 0x50 && probe[1] == 0x4b;
    final isTar =
        (probe.length >= 262 &&
            String.fromCharCodes(probe.sublist(257, 262)) == 'ustar') ||
        fileName.endsWith('.canopus') ||
        fileName.endsWith('.tar');
    var bytes = (isZip || isTar)
        ? await file.readAsBytes()
        : Uint8List.fromList(probe);
    final service = ResourceInstallService();
    var analysis = service.analyzePayload(
      fileName: fileName,
      bytes: bytes,
      hint: selectedType,
      source: 'manual-picker',
    );
    if (analysis == null &&
        bytes.length < fileLength &&
        fileLength <= 64 * 1024 * 1024) {
      bytes = await file.readAsBytes();
      analysis = service.analyzePayload(
        fileName: fileName,
        bytes: bytes,
        hint: selectedType,
        source: 'manual-picker',
      );
    }
    if (!context.mounted || isTargetCurrent?.call() == false) return false;
    final isWatchface =
        analysis?.type == LocalDeviceInstallType.watchface ||
        selectedType == LocalDeviceInstallType.watchface;
    if (isWatchface) {
      final restrictedId = restrictedWatchfaceIdFor(
        payload: analysis?.payload ?? bytes,
        analyzedIdentifier: analysis?.identifier,
      );
      if (restrictedId != null) {
        await _showRestrictedWatchfaceDialog(context);
        return false;
      }
    }
    final decision = await _confirmInstall(
      context,
      ref,
      analysis,
      selectedType: selectedType,
      fileName: fileName,
      fileSize: _formatFileSize(fileLength),
    );
    if (!context.mounted ||
        decision == _InstallDecision.cancel ||
        isTargetCurrent?.call() == false) {
      return false;
    }

    final effectiveType = switch (decision) {
      _InstallDecision.selectedType =>
        selectedType ?? analysis?.type ?? LocalDeviceInstallType.app,
      _InstallDecision.detectedType || _InstallDecision.forceDetectedType =>
        analysis?.type ?? selectedType ?? LocalDeviceInstallType.app,
      _InstallDecision.cancel =>
        selectedType ?? analysis?.type ?? LocalDeviceInstallType.app,
    };
    final installMode = switch (decision) {
      _InstallDecision.selectedType => ResourceInstallMode.forceType,
      _InstallDecision.forceDetectedType => ResourceInstallMode.forcePlatform,
      _InstallDecision.detectedType => ResourceInstallMode.automatic,
      _InstallDecision.cancel => ResourceInstallMode.automatic,
    };
    await ref
        .read(installQueueProvider.notifier)
        .enqueueConfirmedLocalFile(
          file,
          type: effectiveType,
          installMode: installMode,
          identifier: analysis?.identifier,
          deviceId: deviceId,
        );
    return true;
  } finally {
    if (!retainSource) await ManagedTemporaryFiles.releaseImport(file.path);
  }
}

Future<void> _showRestrictedWatchfaceDialog(BuildContext context) async {
  final l10n = AppLocalizations.of(context)!;
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(l10n.watchfaceRestrictedTitle),
      content: Text(l10n.watchfaceRestrictedMessage),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.close),
        ),
      ],
    ),
  );
}

Future<_InstallDecision> _confirmInstall(
  BuildContext context,
  WidgetRef ref,
  ResourcePayloadAnalysis? analysis, {
  LocalDeviceInstallType? selectedType,
  required String fileName,
  required String fileSize,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final device = ref.read(deviceManagerProvider).currentDevice;
  final deviceKind = device == null
      ? null
      : DeviceRegistry.resolveIdentity(
          name: device.name,
          codename: device.codename,
        ).kind;
  final selectedLabel = selectedType == null
      ? ''
      : _typeLabel(
          l10n,
          selectedType,
          platform: deviceKind == DeviceKind.zepp
              ? ResourcePlatform.zeppOs
              : ResourcePlatform.vela,
        );
  if (analysis == null) {
    if (selectedType == null) {
      // Opened externally (e.g. "open with OronBox"): nobody picked a type,
      // so there is nothing to fall back to, just report the unknown file.
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l10n.resourceTypeUnknownTitle),
          content: Text(l10n.resourceTypeUnknownNoType),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l10n.resourceInstallCancel),
            ),
          ],
        ),
      );
      return _InstallDecision.cancel;
    }
    return await showDialog<_InstallDecision>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(l10n.resourceTypeUnknownTitle),
            content: Text(l10n.resourceTypeUnknownMessage(selectedLabel)),
            actions: [
              TextButton(
                onPressed: () =>
                    Navigator.pop(context, _InstallDecision.cancel),
                child: Text(l10n.resourceInstallCancel),
              ),
              _DelayedInstallButton(
                label: (seconds) => seconds == 0
                    ? l10n.resourceInstallAsSelected(selectedLabel)
                    : l10n.resourceInstallAsSelectedCountdown(
                        selectedLabel,
                        seconds,
                      ),
                onPressed: () =>
                    Navigator.pop(context, _InstallDecision.selectedType),
              ),
            ],
          ),
        ) ??
        _InstallDecision.cancel;
  }

  final resourceKind = analysis.platform == ResourcePlatform.zeppOs
      ? DeviceKind.zepp
      : DeviceKind.xiaomi;
  if (device != null && deviceKind != resourceKind) {
    return await showDialog<_InstallDecision>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(l10n.resourceTypeErrorTitle),
            content: Text(
              l10n.resourcePlatformMismatchMessage(
                _platformLabel(analysis.platform),
                _typeLabel(l10n, analysis.type, platform: analysis.platform),
                device.localizedName(Localizations.localeOf(context)),
                deviceKind == DeviceKind.zepp ? 'ZeppOS' : 'VelaOS',
              ),
            ),
            actions: [
              TextButton(
                onPressed: () =>
                    Navigator.pop(context, _InstallDecision.cancel),
                child: Text(l10n.resourceInstallAcknowledge),
              ),
              _DelayedInstallButton(
                label: (seconds) => seconds == 0
                    ? l10n.resourceInstallForce
                    : l10n.resourceInstallForceCountdown(seconds),
                onPressed: () =>
                    Navigator.pop(context, _InstallDecision.forceDetectedType),
              ),
            ],
          ),
        ) ??
        _InstallDecision.cancel;
  }

  final isTypeMismatch = selectedType != null && analysis.type != selectedType;
  if (isTypeMismatch) {
    final detectedLabel = _typeLabel(
      l10n,
      analysis.type,
      platform: analysis.platform,
    );
    return await showDialog<_InstallDecision>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(l10n.resourceTypeErrorTitle),
            content: Text(
              l10n.resourceTypeMismatchMessage(detectedLabel, selectedLabel),
            ),
            actions: [
              TextButton(
                onPressed: () =>
                    Navigator.pop(context, _InstallDecision.cancel),
                child: Text(l10n.resourceInstallCancel),
              ),
              _DelayedInstallButton(
                label: (seconds) => seconds == 0
                    ? l10n.resourceInstallAsSelected(selectedLabel)
                    : l10n.resourceInstallAsSelectedCountdown(
                        selectedLabel,
                        seconds,
                      ),
                onPressed: () =>
                    Navigator.pop(context, _InstallDecision.selectedType),
              ),
              FilledButton(
                onPressed: () =>
                    Navigator.pop(context, _InstallDecision.detectedType),
                child: Text(l10n.resourceInstallAsDetected(detectedLabel)),
              ),
            ],
          ),
        ) ??
        _InstallDecision.cancel;
  }

  return await showDialog<_InstallDecision>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            l10n.resourceInstallConfirmTitle(
              _typeLabel(l10n, analysis.type, platform: analysis.platform),
            ),
          ),
          content: Text(l10n.resourceInstallConfirmMessage(fileName, fileSize)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, _InstallDecision.cancel),
              child: Text(l10n.resourceInstallCancel),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(context, _InstallDecision.detectedType),
              child: Text(l10n.resourceInstallConfirm),
            ),
          ],
        ),
      ) ??
      _InstallDecision.cancel;
}

String _formatFileSize(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }
  return '${(bytes / 1024).toStringAsFixed(1)} KB';
}

String _platformLabel(ResourcePlatform platform) => switch (platform) {
  ResourcePlatform.vela => 'VelaOS',
  ResourcePlatform.zeppOs => 'ZeppOS',
};

String _typeLabel(
  AppLocalizations l10n,
  LocalDeviceInstallType type, {
  required ResourcePlatform platform,
}) => switch (type) {
  LocalDeviceInstallType.app =>
    platform == ResourcePlatform.vela
        ? l10n.resourceTypeQuickApp
        : l10n.resourceTypeApp,
  LocalDeviceInstallType.watchface => l10n.resourceTypeWatchface,
  LocalDeviceInstallType.firmware => l10n.resourceTypeFirmware,
  LocalDeviceInstallType.canopus => l10n.module,
  LocalDeviceInstallType.resPack => l10n.resourceTypeResPack,
};

class _DelayedInstallButton extends StatefulWidget {
  const _DelayedInstallButton({required this.label, required this.onPressed});

  final String Function(int seconds) label;
  final VoidCallback onPressed;

  @override
  State<_DelayedInstallButton> createState() => _DelayedInstallButtonState();
}

class _DelayedInstallButtonState extends State<_DelayedInstallButton> {
  static const _delaySeconds = 3;
  Timer? _timer;
  int _remaining = _delaySeconds;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      setState(() => _remaining--);
      if (_remaining == 0) timer.cancel();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: _remaining == 0 ? widget.onPressed : null,
      child: Text(widget.label(_remaining)),
    );
  }
}

Future<void> retryResourceInstallTask(
  BuildContext context,
  WidgetRef ref,
  InstallTask task,
) async {
  if (!task.canRetry) return;
  final l10n = AppLocalizations.of(context)!;
  final code = task.errorCode ?? task.error;
  final queue = ref.read(installQueueProvider.notifier);
  if ((code == 'install_low_storage' || code == 'install_quantity_limit') &&
      !queue.storageManagementReviewed(task.id)) {
    final managementPath = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          code == 'install_low_storage'
              ? l10n.installStorageFullTitle
              : l10n.installQuantityLimitTitle,
        ),
        content: Text(
          code == 'install_low_storage'
              ? l10n.installStorageFullHelp
              : l10n.installQuantityLimitHelp,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, '/devices/apps'),
            child: Text(l10n.appManagementTitle),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, '/devices/watchfaces'),
            child: Text(l10n.watchfaceManagementTitle),
          ),
        ],
      ),
    );
    if (managementPath == null || !context.mounted) return;
    if (task.deviceId != null &&
        task.deviceId!.isNotEmpty &&
        task.deviceId!.toLowerCase() !=
            ref.read(deviceManagerProvider).currentDevice?.addr.toLowerCase()) {
      OronBoxDialog.showToast(
        context: context,
        message: l10n.installTargetDeviceChanged,
      );
      return;
    }
    // Returning from management leaves the next retry available for this failure.
    queue.markStorageManagementReviewed(task.id);
    unawaited(context.push<void>(managementPath));
    return;
  }
  if (!task.canReplaceWatchface) {
    ref.read(installQueueProvider.notifier).retry(task.id);
    return;
  }
  final removeExisting = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(l10n.installQueueReinstallWatchface),
      content: Text(
        l10n.installQueueReplaceWatchfaceMessage(task.conflictingWatchfaceId!),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(l10n.installQueueRetryDirectly),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(l10n.installQueueReplaceWatchface),
        ),
      ],
    ),
  );
  if (removeExisting == null || !context.mounted) return;
  final notifier = ref.read(installQueueProvider.notifier);
  if (!removeExisting) {
    notifier.retry(task.id);
    return;
  }
  try {
    await notifier.reinstallWatchface(
      task.id,
      identifier: task.conflictingWatchfaceId!,
      removeExisting: true,
    );
  } catch (error) {
    if (context.mounted) {
      OronBoxDialog.showToast(
        context: context,
        message: localizedErrorMessage(l10n, error),
      );
    }
  }
}
