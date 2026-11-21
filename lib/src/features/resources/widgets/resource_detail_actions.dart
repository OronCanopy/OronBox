import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:oronbox/src/app/generated/app_localizations.dart';
import 'package:oronbox/src/app/theme/app_theme.dart';
import 'package:oronbox/src/app/widgets/app_scaffold_messenger.dart';
import 'package:oronbox/src/data/community/community_source.dart';
import 'package:oronbox/src/device/xiaomi/xiaomi_device_catalog.dart';
import 'package:oronbox/src/features/resources/application/resource_catalog_providers.dart';
import 'package:oronbox/src/features/resources/domain/community_resource.dart';
import 'package:oronbox/src/features/resources/services/download_queue_notifier.dart';
import 'package:oronbox/src/features/resources/services/install_queue_notifier.dart';
import 'package:oronbox/src/features/resources/services/resource_task_status.dart';
import 'package:oronbox/src/features/resources/widgets/resource_external_link.dart';
import 'package:oronbox/src/features/resources/widgets/resource_install_confirmation.dart';

class ResourceDetailActions extends ConsumerStatefulWidget {
  const ResourceDetailActions({
    super.key,
    required this.detail,
    required this.currentCodename,
    this.secondaryActions,
  });
  final CommunityResourceDetail detail;
  final String currentCodename;
  final Widget? secondaryActions;

  @override
  ConsumerState<ResourceDetailActions> createState() =>
      _ResourceDetailActionsState();
}

class _ResourceDetailActionsState extends ConsumerState<ResourceDetailActions> {
  String? _sizeKey;
  int? _preferredFileSize;
  bool _probeScheduled = false;
  String? _completedChoice;
  Timer? _completionTimer;
  double? _menuMaxHeight;

  @override
  void dispose() {
    _completionTimer?.cancel();
    super.dispose();
  }

  String _choiceKey(ResourceInstallChoice choice) =>
      '${detail.ref.key}|${choice.file.id}|${_targetFor(choice)}';

  String _targetFor(ResourceInstallChoice choice) =>
      choice.codename.isEmpty ? currentCodename : choice.codename;

  bool _matchesInstall(InstallTask task, ResourceInstallChoice choice) =>
      task.resource?.ref == detail.ref &&
      task.file?.id == choice.file.id &&
      (task.description.isEmpty || task.description == _targetFor(choice));

  CommunityResourceDetail get detail => widget.detail;
  String get currentCodename => widget.currentCodename;

  void _ensurePreferredFileSize(CommunityResourceFile? file) {
    if (file == null) return;
    final key = _fileSizeKey(file);
    if (key == _sizeKey || _probeScheduled) return;
    _probeScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _probeScheduled = false;
      if (mounted) _probeFileSize(file, key);
    });
  }

  Future<void> _probeFileSize(CommunityResourceFile file, String key) async {
    if (!mounted) return;
    setState(() {
      _sizeKey = key;
      _preferredFileSize = file.size;
    });
    if (file.size != null) return;
    try {
      final size = await ref
          .read(communityCatalogProviderForSource(detail.ref.source))
          .probeDownloadSize(file);
      if (!mounted || _sizeKey != key) return;
      setState(() => _preferredFileSize = size);
    } catch (_) {
      // Some sources omit Content-Length.
    }
  }

  String _fileSizeKey(CommunityResourceFile file) =>
      '${file.id}|${file.downloadUrl}';

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final files = detail.files;
    final choices = buildResourceInstallChoices(
      detail,
      locale: Localizations.localeOf(context),
    );
    final purchaseLink = detail.purchaseLink;
    if (files.isEmpty &&
        purchaseLink == null &&
        widget.secondaryActions == null) {
      return const SizedBox.shrink();
    }
    final preferred = preferredResourceInstallChoice(
      detail,
      choices,
      currentCodename,
    );
    final preferredFile = preferred?.file;
    _ensurePreferredFileSize(preferredFile);
    final preferredFileKey = preferredFile == null
        ? null
        : _fileSizeKey(preferredFile);
    final preferredFileSize = preferredFileKey == _sizeKey
        ? _preferredFileSize
        : preferredFile?.size;
    final downloads = ref.watch(downloadQueueProvider);
    final installs = ref.watch(installQueueProvider).tasks;
    ref.listen(installQueueProvider, (previous, next) {
      if (preferred == null) return;
      final completed = next.tasks.where(
        (task) =>
            _matchesInstall(task, preferred) &&
            task.status == ResourceTaskStatus.completed &&
            previous?.tasks.any(
                  (old) =>
                      old.id == task.id &&
                      (old.status == ResourceTaskStatus.installing ||
                          old.status == ResourceTaskStatus.pending),
                ) ==
                true,
      );
      if (completed.isEmpty) return;
      _completionTimer?.cancel();
      setState(() => _completedChoice = _choiceKey(preferred));
      _completionTimer = Timer(resourceTaskCompletionDisplayDuration, () {
        if (mounted) setState(() => _completedChoice = null);
      });
    });
    ResourceTask? downloadFor(ResourceInstallChoice choice) => downloads
        .reversed
        .where(
          (task) =>
              task.resource.ref == detail.ref &&
              task.file.id == choice.file.id &&
              task.codename ==
                  (choice.codename.isEmpty
                      ? currentCodename
                      : choice.codename) &&
              task.status != ResourceTaskStatus.completed,
        )
        .firstOrNull;
    InstallTask? installFor(ResourceInstallChoice choice) => installs.reversed
        .where(
          (task) =>
              _matchesInstall(task, choice) &&
              task.status != ResourceTaskStatus.completed,
        )
        .firstOrNull;
    bool isBusy(ResourceInstallChoice choice) {
      final status = downloadFor(choice)?.status ?? installFor(choice)?.status;
      return status != null && status != ResourceTaskStatus.failed;
    }

    final download = preferred == null ? null : downloadFor(preferred);
    final install = preferred == null ? null : installFor(preferred);
    final succeeded =
        preferred != null &&
        _completedChoice == _choiceKey(preferred) &&
        download == null &&
        install == null;
    final status =
        install?.status ??
        download?.status ??
        (succeeded ? ResourceTaskStatus.completed : null);
    final progress = install?.progress ?? download?.progress ?? 0;
    final inQueue = preferred != null && isBusy(preferred);
    final canInstall =
        detail.canDownload &&
        !inQueue &&
        !succeeded &&
        (install?.status != ResourceTaskStatus.failed ||
            install?.canRetry != false);
    void enqueue(ResourceInstallChoice choice) {
      if (!mounted) return;
      _completionTimer?.cancel();
      setState(() => _completedChoice = null);
      if (detail.ref.source == CommunitySourceId.astroboxRepo &&
          choice.file.purchaseRequired) {
        unawaited(showAstroBoxResourcePurchaseDialog(context, detail.ref));
        return;
      }
      final target = choice.codename.isNotEmpty
          ? choice.codename
          : currentCodename;
      final previous = ref
          .read(downloadQueueProvider)
          .where(
            (task) =>
                task.resource.ref == detail.ref &&
                task.file.id == choice.file.id &&
                task.codename == target &&
                task.status == ResourceTaskStatus.failed,
          )
          .firstOrNull;
      if (previous != null) {
        if (isAstroBoxResourcePurchaseRequired(previous.error)) {
          unawaited(showAstroBoxResourcePurchaseDialog(context, detail.ref));
        } else {
          ref.read(downloadQueueProvider.notifier).retry(previous.id);
        }
        return;
      }
      final failedInstall = installFor(choice);
      if (failedInstall?.status == ResourceTaskStatus.failed) {
        unawaited(retryResourceInstallTask(context, ref, failedInstall!));
        return;
      }
      final accepted = ref
          .read(downloadQueueProvider.notifier)
          .enqueue(resource: detail, file: choice.file, codename: target);
      if (!accepted) return;
      appScaffoldMessengerOf(context)
          .showSnackBar(SnackBar(content: Text(l10n.downloadStarted)));
    }

    final color = Theme.of(context).colorScheme;
    final percent = (progress * 100).clamp(0, 100).round().toString();
    final baseLabel = switch (status) {
      ResourceTaskStatus.pending => l10n.queueStatusPending,
      ResourceTaskStatus.downloading => l10n.queueStatusDownloading(percent),
      ResourceTaskStatus.installing => l10n.queueStatusInstalling(percent),
      ResourceTaskStatus.failed => l10n.retry,
      ResourceTaskStatus.completed => l10n.resourceInstallSucceeded,
      _ => l10n.install,
    };
    final metadata = <String>[
      if (preferredFile?.version.isNotEmpty == true) preferredFile!.version,
      if (preferredFileSize != null) _formatResourceFileSize(preferredFileSize),
    ].join(' · ');
    final menuItems = <Widget>[
      for (final choice in choices)
        MenuItemButton(
          onPressed:
              detail.canDownload &&
                  !isBusy(choice) &&
                  (installFor(choice)?.status != ResourceTaskStatus.failed ||
                      installFor(choice)?.canRetry != false)
              ? () => enqueue(choice)
              : null,
          leadingIcon: choice.file.purchaseRequired || choice.file.encrypted
              ? const Icon(Icons.lock_outline)
              : null,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 280),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  choice.label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  [
                    if (choice.file.version.isNotEmpty) choice.file.version,
                    if (choice.file.size != null)
                      _formatResourceFileSize(choice.file.size!),
                  ].join(' · '),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
    ];
    Widget anchor(Widget Function(BuildContext, MenuController) button) =>
        MenuAnchor(
          style: MenuStyle(
            alignment: AlignmentDirectional.bottomStart,
            maximumSize: _menuMaxHeight == null
                ? null
                : WidgetStatePropertyAll(
                    Size(double.infinity, _menuMaxHeight!),
                  ),
          ),
          alignmentOffset: const Offset(0, 4),
          menuChildren: menuItems,
          builder: (anchorContext, controller, _) =>
              button(anchorContext, controller),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (files.isNotEmpty)
          anchor(
            (anchorContext, controller) => FilledButton(
              onPressed: canInstall
                  ? preferred != null
                        ? () => enqueue(preferred)
                        : () => _toggleMenu(controller, anchorContext)
                  : null,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                backgroundColor: context.appSelectionContainer,
                foregroundColor: context.appSelectionForeground,
                disabledBackgroundColor: color.onSurface.withValues(alpha: .08),
                disabledForegroundColor: color.onSurface.withValues(alpha: .38),
              ),
              child: Row(
                children: [
                  if (inQueue)
                    SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(
                        value: progress > 0 ? progress : null,
                        strokeWidth: 2,
                      ),
                    )
                  else
                    Icon(
                      succeeded
                          ? Icons.check
                          : preferred?.file.purchaseRequired == true
                          ? Icons.lock_outline
                          : Icons.download,
                    ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      preferred == null
                          ? l10n.resourceMoreDevicesDownload
                          : baseLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  if (metadata.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        metadata,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.end,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          color:
                              (canInstall
                                      ? context.appSelectionForeground
                                      : color.onSurface.withValues(alpha: .38))
                                  .withValues(alpha: .72),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        if (purchaseLink != null) ...[
          if (files.isNotEmpty) const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: () => openResourceExternalLink(context, purchaseLink),
            icon: const Icon(Icons.shopping_bag_outlined),
            label: Text(_purchaseLabel(l10n, detail)),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              alignment: Alignment.centerLeft,
              backgroundColor: context.appSelectionContainer.withValues(
                alpha: .58,
              ),
              foregroundColor: context.appSelectionForeground,
            ),
          ),
        ],
        if ((preferred != null && choices.length > 1) ||
            widget.secondaryActions != null) ...[
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              if (preferred != null && choices.length > 1)
                Flexible(
                  child: anchor(
                    (anchorContext, controller) => TextButton.icon(
                      onPressed: detail.canDownload
                          ? () => _toggleMenu(controller, anchorContext)
                          : null,
                      icon: const Icon(Icons.chevron_right, size: 18),
                      iconAlignment: IconAlignment.end,
                      label: Text(
                        l10n.resourceMoreDevicesDownload,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                )
              else
                const SizedBox.shrink(),
              if (widget.secondaryActions != null)
                Flexible(child: widget.secondaryActions!),
            ],
          ),
        ],
      ],
    );
  }

  String _purchaseLabel(AppLocalizations l10n, CommunityResourceDetail detail) {
    final price = detail.purchasePrice;
    if (price == null) return l10n.resourcePurchaseFullVersion;
    final amount = price.toStringAsFixed(2);
    final base = l10n.resourcePurchaseFullVersion;
    return '$base (¥$amount)';
  }

  void _toggleMenu(MenuController controller, BuildContext anchorContext) {
    if (controller.isOpen) {
      controller.close();
    } else {
      final box = anchorContext.findRenderObject()! as RenderBox;
      final rect = box.localToGlobal(Offset.zero) & box.size;
      final media = MediaQuery.of(anchorContext);
      final above =
          rect.top - math.max(media.padding.top, media.viewInsets.top);
      final below =
          media.size.height -
          math.max(media.padding.bottom, media.viewInsets.bottom) -
          rect.bottom;
      setState(() => _menuMaxHeight = math.max(1, math.max(above, below) - 16));
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) controller.open();
      });
    }
  }
}

String _formatResourceFileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    final value = bytes / 1024;
    return '${value.toStringAsFixed(value >= 100 ? 0 : 1)} KB';
  }
  if (bytes < 1024 * 1024 * 1024) {
    final value = bytes / (1024 * 1024);
    return '${value.toStringAsFixed(value >= 100 ? 0 : 1)} MB';
  }
  final value = bytes / (1024 * 1024 * 1024);
  return '${value.toStringAsFixed(value >= 100 ? 0 : 2)} GB';
}

class ResourceInstallChoice {
  const ResourceInstallChoice({
    required this.file,
    required this.codename,
    required this.label,
  });

  final CommunityResourceFile file;
  final String codename;
  final String label;
}

List<ResourceInstallChoice> buildResourceInstallChoices(
  CommunityResourceDetail detail, {
  Locale? locale,
}) {
  final choices = <ResourceInstallChoice>[];
  for (final file in detail.files) {
    if (detail.ref.source == CommunitySourceId.bandbbs ||
        detail.ref.source == CommunitySourceId.huamiAppStore) {
      choices.add(
        ResourceInstallChoice(file: file, codename: '', label: file.fileName),
      );
      continue;
    }
    final devices = file.supportedDevices.isNotEmpty
        ? file.supportedDevices
        : detail.supportedDevices;
    if (devices.isEmpty) {
      choices.add(
        ResourceInstallChoice(file: file, codename: '', label: file.label),
      );
      continue;
    }
    for (final device in devices) {
      final codename = normalizeXiaomiWearableCodename(device);
      if (codename.isEmpty) continue;
      choices.add(
        ResourceInstallChoice(
          file: file,
          codename: codename,
          label: xiaomiDisplayNameForIdentity(
            name: codename,
            codename: codename,
            locale: locale,
          ),
        ),
      );
    }
  }
  return choices;
}

ResourceInstallChoice? preferredResourceInstallChoice(
  CommunityResourceDetail detail,
  List<ResourceInstallChoice> choices,
  String currentCodename,
) {
  if (detail.ref.source == CommunitySourceId.huamiAppStore ||
      detail.ref.source == CommunitySourceId.bandbbs) {
    return choices.firstOrNull;
  }
  return choices
      .where((choice) => _matchesDevice(choice.file, currentCodename))
      .where(
        (choice) =>
            choice.codename.isEmpty ||
            normalizeXiaomiWearableCodename(choice.codename) == currentCodename,
      )
      .firstOrNull;
}

bool _matchesDevice(CommunityResourceFile file, String codename) {
  if (file.supportedDevices.isEmpty) return true;
  return file.supportedDevices
      .map(normalizeXiaomiWearableCodename)
      .contains(codename);
}

class ResourceCompatibility extends StatelessWidget {
  const ResourceCompatibility({
    super.key,
    required this.detail,
    required this.codename,
  });
  final CommunityResourceDetail detail;
  final String codename;
  @override
  Widget build(BuildContext context) {
    final compatible = detail.ref.source == CommunitySourceId.huamiAppStore
        ? (detail.files.isEmpty
              ? detail.supportedDevices.contains(codename)
              : detail.files.any((file) {
                  final models = file.supportedDevices.isNotEmpty
                      ? file.supportedDevices
                      : detail.supportedDevices;
                  return models.contains(codename);
                }))
        : preferredResourceInstallChoice(
                detail,
                buildResourceInstallChoices(detail),
                codename,
              ) !=
              null;
    final color = Theme.of(context).colorScheme;
    final statusColor = compatible ? context.appColors.success : color.error;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          compatible ? Icons.check_circle_outline : Icons.info_outline,
          size: 20,
          color: statusColor,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            compatible
                ? AppLocalizations.of(context)!.resourceCompatibleWithDevice
                : AppLocalizations.of(context)!.resourceIncompatibleWithDevice,
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(color: statusColor),
          ),
        ),
      ],
    );
  }
}
