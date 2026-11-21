import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:wear_location/wear_location.dart';
import 'package:segmented_list/segmented_list.dart';
import 'package:oronbox/src/app/generated/app_localizations.dart';
import 'package:oronbox/src/app/widgets/app_scaffold_messenger.dart';
import 'package:oronbox/src/app/widgets/page_container.dart';
import 'package:oronbox/src/app/widgets/sys_app_bar.dart';
import 'package:oronbox/src/core/constants/style_constants.dart';
import 'package:oronbox/src/core/services/device_location_service.dart';
import 'package:oronbox/src/core/services/system_notification_bridge.dart';
import 'package:oronbox/src/features/devices/services/device_notification_preferences.dart';

final _displayNotificationsProvider = FutureProvider.autoDispose<bool>(
  (ref) => SystemNotificationBridge.hasPermission(),
);

final _readNotificationsProvider = FutureProvider.autoDispose<bool>(
  (ref) => PhoneNotifications.hasAccess(),
);

class AppPermissionsPage extends ConsumerStatefulWidget {
  const AppPermissionsPage({super.key});

  @override
  ConsumerState<AppPermissionsPage> createState() => _AppPermissionsPageState();
}

class _AppPermissionsPageState extends ConsumerState<AppPermissionsPage>
    with WidgetsBindingObserver {
  LocationPermission? _permission;
  bool _precise = false;
  bool _serviceEnabled = false;
  bool _supported = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _supported = DeviceLocationService().isSupported;
    if (_supported) _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (_supported) _refresh();
    if (SystemNotificationBridge.isSupported) {
      ref.invalidate(_displayNotificationsProvider);
    }
    if (PhoneNotifications.isSupported) {
      ref.invalidate(_readNotificationsProvider);
    }
  }

  Future<void> _openNotificationSettings(
    Future<void> Function() open,
    FutureProvider<bool> permission,
  ) async {
    try {
      await open();
      if (mounted) ref.invalidate(permission);
    } catch (_) {
      if (!mounted) return;
      final l10n = AppLocalizations.of(context)!;
      appScaffoldMessengerOf(context)
          .showSnackBar(SnackBar(content: Text(l10n.errorOperationFailed)));
    }
  }

  Future<void> _refresh() async {
    try {
      final location = WearLocation.instance;
      final permission = await location.checkPermission();
      final precise = await location.isPreciseLocationEnabled();
      final enabled = await location.isLocationServiceEnabled();
      if (!mounted) return;
      setState(() {
        _permission = permission;
        _precise = precise;
        _serviceEnabled = enabled;
        _failed = false;
      });
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _openLocationSettings() async {
    try {
      await WearLocation.instance.openLocationSettings();
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _requestOrOpenSettings() async {
    try {
      if (_permission == LocationPermission.denied) {
        await WearLocation.instance.requestPermission();
      } else {
        await WearLocation.instance.openSettings();
      }
      await _refresh();
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _requestBackgroundPermission() async {
    try {
      if (_permission == LocationPermission.always) {
        await WearLocation.instance.openSettings();
      } else {
        await WearLocation.instance.requestBackgroundPermission();
      }
      await _refresh();
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final canDisplay = SystemNotificationBridge.isSupported;
    final canRead = PhoneNotifications.isSupported;

    Widget? notificationStatus(FutureProvider<bool> provider) => ref
        .watch(provider)
        .when(
          data: (enabled) => Text(
            enabled
                ? l10n.notificationPermissionEnabled
                : l10n.notificationPermissionDisabled,
          ),
          loading: () => null,
          error: (_, _) => Text(l10n.notificationPermissionUnavailable),
        );

    return Scaffold(
      appBar: SysAppBar(
        secondary: true,
        title: Text(l10n.settingsPermissionsTitle),
      ),
      body: PageContainer(
        padding: EdgeInsets.zero,
        child: SegmentedList(
          maxWidth: StyleConstants.pageMaxWidth,
          contentPadding: EdgeInsets.only(
            top: 8,
            bottom: bottomContentPadding(context, extra: 16),
          ),
          sections: [
            if (canDisplay || canRead)
              SegmentedSection(
                title: Text(l10n.notificationPermissionsSection),
                tiles: [
                  if (canDisplay)
                    SegmentedTile.navigation(
                      leading: const Icon(Icons.notifications_outlined),
                      title: Text(l10n.notificationPermissionDisplay),
                      description: notificationStatus(
                        _displayNotificationsProvider,
                      ),
                      onPressed: (_) => _openNotificationSettings(
                        SystemNotificationBridge.openSettings,
                        _displayNotificationsProvider,
                      ),
                    ),
                  if (canRead)
                    SegmentedTile.navigation(
                      leading: const Icon(Icons.notifications_active_outlined),
                      title: Text(l10n.notificationPermissionRead),
                      description: notificationStatus(
                        _readNotificationsProvider,
                      ),
                      onPressed: (_) => _openNotificationSettings(
                        PhoneNotifications.openAccessSettings,
                        _readNotificationsProvider,
                      ),
                    ),
                ],
              ),
            if (!_supported && !canDisplay && !canRead)
              SegmentedSection(
                tiles: [
                  SegmentedTile(
                    leading: const Icon(Icons.info_outline),
                    title: Text(l10n.phoneLocationMobileOnly),
                  ),
                ],
              )
            else if (_supported && _failed)
              SegmentedSection(
                tiles: [
                  SegmentedTile(
                    leading: Icon(
                      Icons.warning_amber_outlined,
                      color: theme.colorScheme.error,
                    ),
                    title: Text(l10n.phoneLocationUnavailable),
                    onPressed: (_) => _refresh(),
                  ),
                ],
              )
            else if (_supported)
              SegmentedSection(
                title: Text(l10n.phoneLocationPermissionsSection),
                tiles: [
                  SegmentedTile.navigation(
                    leading: const Icon(Icons.location_on_outlined),
                    title: Text(l10n.phoneLocationServiceEnabled),
                    description: Text(
                      _serviceEnabled
                          ? l10n.phoneLocationEnabledText
                          : l10n.phoneLocationDisabledText,
                    ),
                    onPressed: (_) => _openLocationSettings(),
                  ),
                  SegmentedTile.navigation(
                    leading: const Icon(Icons.gps_fixed_outlined),
                    title: Text(l10n.phoneLocationPreciseTitle),
                    description: Text(
                      _precise
                          ? l10n.phoneLocationPreciseGranted
                          : l10n.phoneLocationPreciseDenied,
                    ),
                    onPressed: (_) => _requestOrOpenSettings(),
                  ),
                  SegmentedTile.navigation(
                    leading: const Icon(Icons.security_outlined),
                    title: Text(l10n.phoneLocationBackgroundTitle),
                    description: Text(
                      _permission == LocationPermission.always
                          ? l10n.phoneLocationBackgroundAlways
                          : (_permission == LocationPermission.whileInUse
                                ? l10n.phoneLocationBackgroundWhileInUse
                                : l10n.phoneLocationBackgroundDenied),
                    ),
                    onPressed: (_) => _requestBackgroundPermission(),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
