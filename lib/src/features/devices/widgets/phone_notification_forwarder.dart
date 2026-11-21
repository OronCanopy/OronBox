import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:oronbox/src/core/logging/logging_service.dart';
import 'package:oronbox/src/device/core/device_state.dart';
import 'package:oronbox/src/device/core/phone_notification.dart';
import 'package:oronbox/src/features/devices/controllers/device_manager.dart';
import 'package:oronbox/src/features/devices/services/device_notification_preferences.dart';

class PhoneNotificationForwarder extends ConsumerStatefulWidget {
  const PhoneNotificationForwarder({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<PhoneNotificationForwarder> createState() =>
      _PhoneNotificationForwarderState();
}

class _PhoneNotificationForwarderState
    extends ConsumerState<PhoneNotificationForwarder> {
  static final _log = getLogger('PhoneNotificationForwarder');
  StreamSubscription<void>? _subscription;
  final _sent = <String, PhoneNotification>{};
  int _generation = 0;

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  Future<void> _forward(
    Map<String, Object?> raw,
    String address,
    int generation,
  ) async {
    if (!mounted || _generation != generation) return;
    final device = ref.read(deviceManagerProvider);
    if (device.currentDevice?.addr != address ||
        device.protocolState != ProtocolState.ready) {
      return;
    }
    final preferences = ref.read(
      deviceNotificationPreferencesProvider(address),
    );
    final key = raw['key'];
    if (!preferences.enabled || key is! String) return;
    final removed = raw['removed'] == true;
    final package = raw['package'];
    if (package is! String) return;
    final previous = _sent[key];
    if ((removed && previous == null) ||
        (!removed && !preferences.apps.contains(package))) {
      return;
    }
    final item = removed
        ? previous!
        : PhoneNotification(
            key: key,
            package: package,
            appName: raw['appName']?.toString() ?? package,
            title: raw['title']?.toString() ?? '',
            body: raw['body']?.toString() ?? '',
            timestamp: DateTime.fromMillisecondsSinceEpoch(
              (raw['timestamp'] as num?)?.toInt() ??
                  DateTime.now().millisecondsSinceEpoch,
            ),
          );
    if (!removed &&
        previous?.title == item.title &&
        previous?.body == item.body) {
      return;
    }
    try {
      if (await ref
              .read(deviceManagerProvider.notifier)
              .forwardPhoneNotification(address, item, removed: removed) &&
          mounted &&
          _generation == generation) {
        if (removed) {
          _sent.remove(key);
        } else {
          if (_sent.length >= 128 && !_sent.containsKey(key)) {
            _sent.remove(_sent.keys.first);
          }
          _sent[key] = item;
        }
      }
    } catch (error) {
      _log.warning('Unable to forward phone notification', error.runtimeType);
    }
  }

  String? _activeAddress;

  @override
  Widget build(BuildContext context) {
    if (!PhoneNotifications.isSupported) return widget.child;
    final active = ref.watch(
      deviceManagerProvider.select(
        (state) => state.protocolState == ProtocolState.ready
            ? state.currentDevice?.addr
            : null,
      ),
    );
    final enabled =
        active != null &&
        ref.watch(
          deviceNotificationPreferencesProvider(active)
              .select((value) => value.enabled),
        );
    final address = enabled ? active : null;
    if (address != _activeAddress) {
      _activeAddress = address;
      final generation = ++_generation;
      _sent.clear();
      final previous = _subscription;
      _subscription = null;
      unawaited(() async {
        await previous?.cancel();
        if (!mounted || generation != _generation || address == null) return;
        _subscription = PhoneNotifications.events
            .asyncMap((event) => _forward(event, address, generation))
            .listen(
              null,
              onError: (Object error) =>
                  _log.warning('Notification stream failed', error.runtimeType),
            );
      }());
    }
    return widget.child;
  }
}
