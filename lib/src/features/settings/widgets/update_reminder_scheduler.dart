import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart' show SnackBar, Text;
import 'package:oronbox/src/app/device_maintenance_tick.dart';
import 'package:oronbox/src/app/generated/app_localizations.dart';
import 'package:oronbox/src/app/modal/global_modal_coordinator.dart';
import 'package:oronbox/src/app/modal/global_modal_models.dart';
import 'package:oronbox/src/app/router/app_router.dart';
import 'package:oronbox/src/app/widgets/app_scaffold_messenger.dart';
import 'package:oronbox/src/core/logging/logging_service.dart';
import 'package:oronbox/src/core/services/shared_prefs_service.dart';
import 'package:oronbox/src/core/services/system_notification_bridge.dart';
import 'package:oronbox/src/device/core/device_state.dart';
import 'package:oronbox/src/features/accounts/application/host_accounts.dart';
import 'package:oronbox/src/features/devices/controllers/device_manager.dart';
import 'package:oronbox/src/features/messages/application/message_center.dart';
import 'package:oronbox/src/features/oobe/oobe_state.dart';
import 'package:oronbox/src/features/resources/services/install_queue_notifier.dart';
import 'package:oronbox/src/features/resources/services/download_queue_notifier.dart';

import '../services/update_reminder_service.dart';
import 'update_reminder_dialog.dart';

class UpdateReminderScheduler extends ConsumerStatefulWidget {
  const UpdateReminderScheduler({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<UpdateReminderScheduler> createState() =>
      _UpdateReminderSchedulerState();
}

class _UpdateReminderSchedulerState
    extends ConsumerState<UpdateReminderScheduler>
    with WidgetsBindingObserver {
  static final _log = getLogger('UpdateReminderScheduler');
  static const _cacheDuration = Duration(hours: 6);
  final _checks =
      <(UpdateReminderKind, String), (DateTime, List<UpdateReminderItem>)>{};
  final _activeIds = <String>{};
  Timer? _timer;
  Timer? _debounce;
  bool _running = false;
  bool _requested = false;
  bool _deviceRequested = false;
  bool _periodicResourceCheck = false;
  bool _foreground = true;
  String? _device;
  int _deviceGeneration = 0;
  DateTime? _messageCheck;
  ({UpdateReminderKind kind, String? device})? _openedUpdate;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _timer = Timer.periodic(const Duration(minutes: 5), (_) => _schedule());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final state = ref.read(deviceManagerProvider);
      _device = state.protocolState == ProtocolState.ready
          ? state.currentDevice?.addr
          : null;
      _schedule(device: true);
      if (SystemNotificationBridge.isSupported) {
        unawaited(_listenForNotificationTaps());
      }
    });
  }

  Future<void> _listenForNotificationTaps() async {
    void open(String location) {
      if (!mounted) return;
      final uri = Uri.tryParse(location);
      if (uri?.path == '/update-reminder' && uri?.hasAuthority == false) {
        final kind = switch (uri!.queryParameters['kind']) {
          'firmware' => UpdateReminderKind.firmware,
          'resources' => UpdateReminderKind.resources,
          'plugins' => UpdateReminderKind.plugins,
          _ => null,
        };
        final device = uri.queryParameters['device'];
        if (kind == null ||
            (kind != UpdateReminderKind.plugins && (device?.isEmpty ?? true))) {
          return;
        }
        _openedUpdate = (kind: kind, device: device);
        final current = ref.read(deviceManagerProvider);
        if (device != null &&
            (current.currentDevice?.addr != device ||
                current.currentDevice?.disconnected != false ||
                current.protocolState != ProtocolState.ready)) {
          ref.read(appRouterProvider).go('/devices/switch');
          final name = uri.queryParameters['name'];
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            final l10n = AppLocalizations.of(context);
            if (l10n != null) {
              appScaffoldMessengerOf(context).showSnackBar(
                SnackBar(
                  content: Text([l10n.deviceConnect, ?name].join(' · ')),
                ),
              );
            }
          });
        }
        _schedule(device: device != null);
      } else if (location == '/devices/firmware') {
        ref.read(appRouterProvider).go('/devices/switch');
      } else if (location == '/resources' ||
          location == '/plugins' ||
          location == '/inbox') {
        ref.read(appRouterProvider).go(location);
      }
    }

    SystemNotificationBridge.setLocationHandler(open);
    try {
      final initial = await SystemNotificationBridge.initialLocation();
      if (initial != null) open(initial);
    } catch (error, stack) {
      _log.warning('Unable to read notification launch', error, stack);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _debounce?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    if (SystemNotificationBridge.isSupported) {
      SystemNotificationBridge.setLocationHandler(null);
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _schedule(device: _foreground && _openedUpdate?.device != null);
  }

  void _schedule({bool device = false}) {
    _deviceRequested |= device;
    _requested = true;
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 2), _run);
  }

  bool get _transfersBusy {
    final state = ref.read(deviceManagerProvider);
    final queue = ref.read(installQueueProvider);
    return state.connecting ||
        ref.read(downloadQueueProvider.notifier).runningTask != null ||
        !queue.loaded ||
        queue.hasActiveTasks;
  }

  Future<void> _run() async {
    if (!mounted || _running || !isOobeCompleted()) return;
    _running = true;
    _requested = false;
    try {
      final service = ref.read(updateReminderServiceProvider);
      final state = ref.read(deviceManagerProvider);
      final device = state.currentDevice;
      final deviceGeneration = _deviceGeneration;
      final opened = _foreground ? _openedUpdate : null;
      if ((_deviceRequested || _periodicResourceCheck) &&
          device != null &&
          state.protocolState == ProtocolState.ready &&
          !device.disconnected &&
          !_transfersBusy) {
        _deviceRequested = false;
        final openedDevice = opened?.device == device.addr ? opened : null;
        if (openedDevice?.kind == UpdateReminderKind.firmware) {
          _openedUpdate = null;
          ref.read(appRouterProvider).go('/devices/firmware');
        }
        final version = state.systemInfo?.firmwareVersion ?? '';
        if (version.isNotEmpty &&
            openedDevice?.kind != UpdateReminderKind.firmware) {
          await _check(
            UpdateReminderKind.firmware,
            '${device.addr}:$version',
            () async =>
                (items: await service.firmware(device.addr), complete: true),
            deviceId: device.addr,
            deviceName: device.name,
            generation: deviceGeneration,
          );
        }
        final openResources =
            openedDevice?.kind == UpdateReminderKind.resources;
        var interruptedByTransfer = false;
        bool canReadInventory() {
          if (!mounted || deviceGeneration != _deviceGeneration) {
            return false;
          }
          if (_transfersBusy) {
            interruptedByTransfer = true;
            return false;
          }
          final current = ref.read(deviceManagerProvider);
          return current.currentDevice?.addr == device.addr &&
              current.currentDevice?.disconnected == false &&
              current.protocolState == ProtocolState.ready;
        }

        if ((openResources || _periodicResourceCheck) && canReadInventory()) {
          final periodicResourceCheck = _periodicResourceCheck;
          _periodicResourceCheck = false;
          await _check(
            UpdateReminderKind.resources,
            device.addr,
            () => service.resources(device.addr, canRead: canReadInventory),
            opened: openResources,
            deviceId: device.addr,
            deviceName: device.name,
            generation: deviceGeneration,
          );
          if (mounted && deviceGeneration == _deviceGeneration) {
            final busy = _transfersBusy;
            if (periodicResourceCheck && (interruptedByTransfer || busy)) {
              _periodicResourceCheck = true;
              if (!busy) _schedule(device: true);
            }
          }
        } else if (mounted &&
            deviceGeneration == _deviceGeneration &&
            _transfersBusy) {
          _deviceRequested = true;
        }
      }
      final openPlugins = opened?.kind == UpdateReminderKind.plugins;
      if (mounted) {
        await _check(
          UpdateReminderKind.plugins,
          '',
          () async => (items: await service.plugins(), complete: true),
          opened: openPlugins,
        );
      }
      if (mounted && SystemNotificationBridge.isSupported) {
        await _checkMessages();
      }
    } finally {
      _running = false;
      if (mounted && _requested) _schedule();
    }
  }

  Future<void> _check(
    UpdateReminderKind kind,
    String key,
    Future<({List<UpdateReminderItem> items, bool complete})> Function() load, {
    bool opened = false,
    String? deviceId,
    String? deviceName,
    int? generation,
  }) async {
    bool valid() =>
        mounted &&
        (deviceId == null ||
            (_device == deviceId && generation == _deviceGeneration));
    try {
      final now = DateTime.now();
      final cached = _checks[(kind, key)];
      final useCache =
          cached != null && now.difference(cached.$1) < _cacheDuration;
      final (items: result, :complete) = useCache
          ? (items: cached.$2, complete: true)
          : await load();
      if (!valid()) return;
      final id = 'update:${kind.name}:${deviceId ?? ''}';
      _checks.removeWhere(
        (entry, value) => now.difference(value.$1) >= _cacheDuration,
      );
      if (!useCache) {
        if (complete) {
          _checks[(kind, key)] = (now, result);
        } else {
          _checks.remove((kind, key));
        }
      }
      final items = result
          .where(
            (item) =>
                (item.available?.call() ?? true) &&
                (opened || !_isHidden(id, item)),
          )
          .toList();
      if (deviceId != null && _transfersBusy) {
        _deviceRequested = true;
        return;
      }
      if (!_foreground) {
        if (items.isNotEmpty) {
          await _notify(kind, id, items, deviceName, deviceId: deviceId);
        }
        return;
      }
      if (opened &&
          (complete || items.isNotEmpty) &&
          _openedUpdate == (kind: kind, device: deviceId)) {
        _openedUpdate = null;
        if (items.isEmpty) {
          final l10n = AppLocalizations.of(context);
          if (l10n != null) {
            appScaffoldMessengerOf(
              context,
            ).showSnackBar(SnackBar(content: Text(l10n.updateReminderChanged)));
          }
        }
      }
      if (items.isEmpty || _activeIds.contains(id)) return;
      _activeIds.add(id);
      void dismiss(List<UpdateReminderItem> remaining, bool silence) {
        _activeIds.remove(id);
        if (!valid()) return;
        for (final item in items) {
          unawaited(
            SharedPrefsService.instance.setString(
              'update_seen:$id:${item.id}',
              '${item.revision}|${_day()}',
            ),
          );
        }
        if (silence) {
          for (final item in remaining) {
            unawaited(
              SharedPrefsService.instance.setString(
                'update_muted:$id:${item.id}',
                item.revision,
              ),
            );
          }
        }
      }

      ref
          .read(globalModalCoordinatorProvider.notifier)
          .enqueue(
            UpdateModalRequest(
              id: id,
              isCurrent: valid,
              onDismiss: () => dismiss(items, false),
              buildDialog: (context, complete) => UpdateReminderDialog(
                kind: kind,
                deviceName: deviceName,
                items: items,
                onDismiss: dismiss,
                onHandled: complete,
              ),
            ),
          );
    } catch (error, stack) {
      _log.warning('Unable to check ${kind.name}', error, stack);
    }
  }

  bool _isHidden(String id, UpdateReminderItem item) {
    final prefs = SharedPrefsService.instance;
    return prefs.getString('update_muted:$id:${item.id}') == item.revision ||
        prefs.getString('update_seen:$id:${item.id}') ==
            '${item.revision}|${_day()}';
  }

  String _day() => DateTime.now().toIso8601String().split('T').first;

  Future<void> _notify(
    UpdateReminderKind kind,
    String id,
    List<UpdateReminderItem> items,
    String? device, {
    required String? deviceId,
  }) async {
    if (!SystemNotificationBridge.isSupported) return;
    final l10n = AppLocalizations.of(context);
    if (l10n == null) return;
    final prefs = SharedPrefsService.instance;
    final unseen = items
        .where(
          (item) =>
              prefs.getString('update_notified:$id:${item.id}') !=
              item.revision,
        )
        .toList();
    if (unseen.isEmpty) return;
    final location = Uri(
      path: '/update-reminder',
      queryParameters: {
        'kind': kind.name,
        if (deviceId != null) 'device': deviceId,
        if (device != null) 'name': device,
      },
    ).toString();
    if (await SystemNotificationBridge.show(
      id: id,
      category: kind.name,
      title: updateReminderTitle(l10n, kind),
      body: [
        if (device != null) device,
        ...unseen.take(4).map((item) => '${item.name} ${item.version}'),
      ].join('\n'),
      location: location,
    )) {
      for (final item in unseen) {
        await prefs.setString('update_notified:$id:${item.id}', item.revision);
      }
    }
  }

  Future<void> _checkMessages() async {
    final account = ref.read(hostAccountsProvider).bandbbs;
    if (!account.signedIn || account.userId?.isNotEmpty != true) return;
    final now = DateTime.now();
    if (_messageCheck != null &&
        now.difference(_messageCheck!) < const Duration(minutes: 5)) {
      return;
    }
    _messageCheck = now;
    try {
      if (ref.read(messageCenterProvider).isLoading) {
        await ref.read(messageCenterProvider.future);
      } else {
        await ref.read(messageCenterProvider.notifier).refresh();
      }
      if (!mounted ||
          ref.read(hostAccountsProvider).bandbbs.userId != account.userId) {
        return;
      }
      final l10n = AppLocalizations.of(context);
      if (l10n == null) return;
      final inbox = ref.read(messageCenterProvider).value;
      final prefs = SharedPrefsService.instance;
      final key = 'inbox_notification_seen:${account.userId}';
      final seen = (prefs.getStringList(key) ?? []).toSet();
      final messages = (inbox?.messages ?? [])
          .where(
            (message) =>
                !message.read &&
                message.id.isNotEmpty &&
                !seen.contains(message.id),
          )
          .toList();
      if (messages.isEmpty ||
          !await SystemNotificationBridge.show(
            id: 'inbox',
            category: 'inbox',
            title: l10n.updateReminderInbox,
            body: l10n.inboxNotificationUnread,
            location: '/inbox',
          )) {
        return;
      }
      seen.addAll(messages.map((message) => message.id));
      await prefs.setStringList(
        key,
        seen.toList().reversed.take(200).toList().reversed.toList(),
      );
    } catch (error, stack) {
      _log.warning('Unable to check message notifications', error, stack);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(deviceMaintenanceTickProvider, (_, next) {
      if (!next.hasValue) return;
      _periodicResourceCheck = true;
      _schedule(device: true);
    });
    ref.listen(
      deviceManagerProvider.select(
        (state) => (
          state.currentDevice?.addr,
          state.protocolState,
          state.systemInfo?.firmwareVersion,
          state.currentDevice?.disconnected,
        ),
      ),
      (before, after) {
        final address = after.$2 == ProtocolState.ready && after.$4 == false
            ? after.$1
            : null;
        if (address != _device) {
          final previous = _device;
          _deviceGeneration++;
          _device = address;
          if (previous != null) {
            _checks.remove((UpdateReminderKind.resources, previous));
            for (final kind in [
              UpdateReminderKind.firmware,
              UpdateReminderKind.resources,
            ]) {
              final id = 'update:${kind.name}:$previous';
              _activeIds.remove(id);
              ref.read(globalModalCoordinatorProvider.notifier).dismiss(id);
            }
          }
        }
        _schedule(device: address != null);
      },
    );
    ref.listen(
      downloadQueueProvider.select(
        (tasks) => tasks.any(
          (task) =>
              task.status == ResourceTaskStatus.downloading ||
              task.status == ResourceTaskStatus.installing,
        ),
      ),
      (_, active) {
        if (!active) _schedule(device: true);
      },
    );
    ref.listen(
      installQueueProvider.select(
        (queue) => (
          busy: !queue.loaded || queue.hasActiveTasks,
          completed: queue.tasks
              .where((task) => task.status == ResourceTaskStatus.completed)
              .length,
        ),
      ),
      (before, after) {
        if (_device case final device?
            when after.completed > (before?.completed ?? 0)) {
          _checks.remove((UpdateReminderKind.resources, device));
        }
        if (!after.busy && before?.busy == true) _schedule(device: true);
      },
    );
    ref.listen(hostAccountsProvider.select((state) => state.bandbbs.userId), (
      _,
      _,
    ) {
      _messageCheck = null;
      _schedule();
    });
    return widget.child;
  }
}
