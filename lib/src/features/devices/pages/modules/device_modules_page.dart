import 'package:oronbox/src/app/widgets/app_scaffold_messenger.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:oronbox/src/app/generated/app_localizations.dart';
import 'package:oronbox/src/app/utils/error_localization.dart';
import 'package:oronbox/src/app/utils/picked_file.dart';
import 'package:oronbox/src/app/widgets/app_state_view.dart';
import 'package:oronbox/src/app/widgets/page_container.dart';
import 'package:oronbox/src/app/widgets/sys_app_bar.dart';
import 'package:oronbox/src/core/constants/style_constants.dart';
import 'package:oronbox/src/device/core/device_state.dart' as proto;
import 'package:oronbox/src/device/xiaomi/systems/canopus_system.dart';
import 'package:oronbox/src/features/devices/controllers/device_manager.dart';
import 'package:oronbox/src/features/resources/services/resource_payload_analyzer.dart';
import 'package:oronbox/src/features/resources/widgets/resource_install_confirmation.dart';

enum _ModuleAction { toggle, uninstall }

class DeviceModulesPage extends ConsumerStatefulWidget {
  const DeviceModulesPage({super.key});

  @override
  ConsumerState<DeviceModulesPage> createState() => _DeviceModulesPageState();
}

class _DeviceModulesPageState extends ConsumerState<DeviceModulesPage> {
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    Future.microtask(_refresh);
  }

  Future<void> _refresh() async {
    if (!mounted || _loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ref.read(deviceManagerProvider.notifier).fetchModules();
    } catch (e) {
      if (!mounted) return;
      final l10n = AppLocalizations.of(context)!;
      final message =
          e is CanopusException && e.code == 'canopus_module_list_incomplete'
          ? l10n.errorUnknown
          : localizedErrorMessage(l10n, e);
      if (!ref.read(deviceManagerProvider).hasCanopus) {
        setState(() => _error = message);
      } else {
        appScaffoldMessengerOf(context)
            .showSnackBar(SnackBar(content: Text(message)));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _install() async {
    final file = await pickFileData(
      type: FileType.any,
      loadBytes: shouldLoadPickedFileData,
    );
    final selected = file?.xFile;
    if (selected == null || !mounted) return;
    await confirmAndEnqueueResourceFile(
      context: context,
      ref: ref,
      file: selected,
      selectedType: LocalDeviceInstallType.canopus,
    );
  }

  Future<void> _confirmUninstall(CanopusModuleInfo module) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.uninstall),
        content: Text(l10n.moduleUninstallConfirm(module.moduleId)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.uninstall),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await ref
          .read(deviceManagerProvider.notifier)
          .removeModule(module.moduleId);
    } catch (e) {
      if (!mounted) return;
      appScaffoldMessengerOf(
        context,
      ).showSnackBar(SnackBar(content: Text(localizedErrorMessage(l10n, e))));
    }
  }

  Future<void> _toggleModule(CanopusModuleInfo module, bool enabled) async {
    final l10n = AppLocalizations.of(context)!;
    try {
      await ref
          .read(deviceManagerProvider.notifier)
          .setModuleEnabled(module.moduleId, enabled);
    } catch (e) {
      if (!mounted) return;
      appScaffoldMessengerOf(
        context,
      ).showSnackBar(SnackBar(content: Text(localizedErrorMessage(l10n, e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final state = ref.watch(deviceManagerProvider);
    final ready = state.protocolState == proto.ProtocolState.ready;
    final loaded = state.hasCanopus;
    final modules = state.modules;

    return Scaffold(
      appBar: SysAppBar(
        secondary: true,
        title: Text(l10n.moduleManagementTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: ready ? _install : null,
            tooltip: l10n.deviceFeaturesInstallModule,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: ready && !_loading ? _refresh : null,
            tooltip: l10n.refresh,
          ),
        ],
      ),
      body: !ready
          ? EmptyStateView(
              icon: Icons.bluetooth_disabled_outlined,
              title: l10n.deviceNotConnected,
            )
          : !loaded && _loading
          ? const Center(child: CircularProgressIndicator())
          : !loaded && _error != null
          ? ErrorStateView(message: _error!, onRetry: _refresh)
          : modules.isEmpty
          ? EmptyStateView(
              icon: Icons.extension_outlined,
              title: l10n.moduleManagementNone,
            )
          : PageContainer(
              padding: EdgeInsets.zero,
              child: ListView.separated(
                padding: EdgeInsets.fromLTRB(
                  StyleConstants.pagePadding,
                  8,
                  StyleConstants.pagePadding,
                  bottomContentPadding(context, extra: 16),
                ),
                itemCount: modules.length,
                itemBuilder: (context, index) {
                  final module = modules[index];
                  return SectionCard(
                    margin: EdgeInsets.zero,
                    padding: EdgeInsets.zero,
                    child: ListTile(
                      title: Text(module.moduleId),
                      subtitle: Text(
                        '${l10n.version}: ${module.version} · ${module.isEnabled ? l10n.moduleStatusEnabled : l10n.moduleStatusDisabled}',
                      ),
                      trailing: PopupMenuButton<_ModuleAction>(
                        onSelected: (action) async {
                          switch (action) {
                            case _ModuleAction.toggle:
                              await _toggleModule(module, !module.isEnabled);
                            case _ModuleAction.uninstall:
                              await _confirmUninstall(module);
                          }
                        },
                        itemBuilder: (context) => [
                          PopupMenuItem(
                            value: _ModuleAction.toggle,
                            child: Row(
                              children: [
                                Icon(
                                  module.isEnabled
                                      ? Icons.pause_circle_outline
                                      : Icons.check_circle_outline,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  module.isEnabled
                                      ? l10n.moduleDisable
                                      : l10n.moduleEnable,
                                ),
                              ],
                            ),
                          ),
                          PopupMenuItem(
                            value: _ModuleAction.uninstall,
                            child: Row(
                              children: [
                                const Icon(Icons.delete_outline),
                                const SizedBox(width: 8),
                                Text(l10n.uninstall),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
                separatorBuilder: (context, index) =>
                    const SizedBox(height: StyleConstants.cardSpace),
              ),
            ),
    );
  }
}
