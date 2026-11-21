import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:segmented_list/segmented_list.dart';
import 'package:oronbox/src/app/generated/app_localizations.dart';
import 'package:oronbox/src/app/widgets/app_checkbox_tile.dart';
import 'package:oronbox/src/app/widgets/page_container.dart';
import 'package:oronbox/src/app/widgets/sys_app_bar.dart';
import 'package:oronbox/src/core/constants/style_constants.dart';
import 'package:oronbox/src/device/core/device_kind.dart';
import 'package:oronbox/src/device/core/device_state.dart';
import 'package:oronbox/src/features/devices/controllers/device_manager.dart';
import 'package:oronbox/src/features/devices/services/device_notification_preferences.dart';

class DeviceSettingsPage extends ConsumerWidget {
  const DeviceSettingsPage({super.key, required this.deviceId});
  final String deviceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final id = deviceId;
    final state = ref.watch(deviceManagerProvider);
    final current = state.currentDevice?.addr == id;
    final kind = current
        ? ref.read(deviceManagerProvider.notifier).currentDeviceKind
        : null;
    final preferences = ref.watch(deviceNotificationPreferencesProvider(id));
    final notifier = ref.read(
      deviceNotificationPreferencesProvider(id).notifier,
    );
    final forwarding = PhoneNotifications.isSupported;
    return Scaffold(
      appBar: SysAppBar(secondary: true, title: Text(l10n.deviceSettingsTitle)),
      body: SegmentedList(
        maxWidth: StyleConstants.pageMaxWidth,
        contentPadding: EdgeInsets.only(
          top: 8,
          bottom: bottomContentPadding(context, extra: 16),
        ),
        sections: [
          if (forwarding)
            SegmentedSection(
              tiles: [
                SegmentedTile.switchTile(
                  initialValue: preferences.enabled,
                  onToggle: (value) => notifier.setEnabled(value ?? false),
                  leading: const Icon(Icons.notifications_outlined),
                  title: Text(l10n.deviceNotificationSync),
                  description: Text(l10n.deviceNotificationSyncDescription),
                ),
                SegmentedTile.navigation(
                  onPressed: (_) => context.push(
                    '/devices/settings/apps?device=${Uri.encodeQueryComponent(id)}',
                  ),
                  leading: const Icon(Icons.apps_outlined),
                  title: Text(l10n.deviceNotificationApps),
                  value: Text('${preferences.apps.length}'),
                ),
              ],
            ),
          if (kind == DeviceKind.xiaomi)
            SegmentedSection(
              tiles: [
                SegmentedTile.navigation(
                  onPressed: (_) =>
                      context.push('/devices/settings/app-arrangement'),
                  enabled: state.protocolState == ProtocolState.ready,
                  leading: const Icon(Icons.dashboard_customize_outlined),
                  title: Text(l10n.appArrangementTitle),
                  description: Text(l10n.appArrangementDescription),
                ),
              ],
            ),
          if (!forwarding && kind != DeviceKind.xiaomi)
            CustomSegmentedSection(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(l10n.deviceSettingsUnavailable),
              ),
            ),
        ],
      ),
    );
  }
}

class DeviceNotificationAppsPage extends ConsumerStatefulWidget {
  const DeviceNotificationAppsPage({super.key, required this.deviceId});
  final String deviceId;

  @override
  ConsumerState<DeviceNotificationAppsPage> createState() =>
      _DeviceNotificationAppsPageState();
}

class _DeviceNotificationAppsPageState
    extends ConsumerState<DeviceNotificationAppsPage> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final provider = deviceNotificationPreferencesProvider(widget.deviceId);
    final selected = ref.watch(provider).apps;
    final installed = ref.watch(notificationAppsProvider);
    return Scaffold(
      appBar: SysAppBar(
        secondary: true,
        title: Text(l10n.deviceNotificationApps),
      ),
      body: Column(
        children: [
          SafeArea(
            top: false,
            bottom: false,
            child: PageContainer(
              safeArea: false,
              padding: const EdgeInsets.all(StyleConstants.pagePadding),
              child: TextField(
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: l10n.search,
                ),
                onChanged: (value) =>
                    setState(() => _query = value.trim().toLowerCase()),
              ),
            ),
          ),
          Expanded(
            child: installed.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (_, _) => Center(
                child: TextButton(
                  onPressed: () => ref.invalidate(notificationAppsProvider),
                  child: Text(l10n.retry),
                ),
              ),
              data: (apps) {
                final names = {for (final app in apps) app.id: app.name};
                for (final id in selected) {
                  names.putIfAbsent(id, () => id);
                }
                final matching = names.entries
                    .where(
                      (item) =>
                          item.value.toLowerCase().contains(_query) ||
                          item.key.toLowerCase().contains(_query),
                    )
                    .toList();
                if (matching.isEmpty) {
                  return Center(child: Text(l10n.deviceNotificationAppsEmpty));
                }
                return Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: StyleConstants.pageMaxWidth,
                    ),
                    child: ListView.builder(
                      padding: EdgeInsets.only(
                        bottom: bottomContentPadding(context, extra: 16),
                      ),
                      itemCount: matching.length,
                      itemBuilder: (context, index) {
                        final app = matching[index];
                        return AppCheckboxTile(
                          value: selected.contains(app.key),
                          onChanged: (value) => ref
                              .read(provider.notifier)
                              .setApp(app.key, value ?? false),
                          title: Text(app.value),
                        );
                      },
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
