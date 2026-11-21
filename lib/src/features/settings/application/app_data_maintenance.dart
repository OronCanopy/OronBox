import 'dart:async';

import 'package:uuid/uuid.dart';
import 'package:oronbox/src/commands/command_protocol.dart';
import 'package:oronbox/src/features/devices/health/health_store.dart';
import 'package:oronbox/src/core/storage/app_data_directory.dart';
import 'package:oronbox/src/device/core/device_state.dart'
    show ProtocolException;
import 'package:oronbox/src/device/zeppos/app_side/zeppos_app_side_storage.dart';
import 'package:oronbox/src/features/devices/controllers/device_manager.dart';

/// Stops writers while another engine snapshots or restores local app data.
class AppDataMaintenance {
  AppDataMaintenance({
    required this.deviceManager,
    required this.initialize,
    required this.stopRuntimes,
    required this.reload,
  });
  static const leaseDuration = Duration(seconds: 30);
  final DeviceManager deviceManager;
  final Future<void> Function() initialize, stopRuntimes, reload;
  String? _token;
  Timer? _leaseCheck;
  Future<void>? _ending;
  bool _beginning = false;
  bool _closed = false;
  bool owns(String token) => _token == token;
  final _calls = <Future<void>>{};

  bool get active => _token != null;

  void _reset() {
    final token = _token;
    _token = null;
    _leaseCheck?.cancel();
    _leaseCheck = null;
    ZeppOsLocalDataGuard.active = false;
    if (token != null) {
      HealthStore.resumeForOwner(token);
    }
  }

  void _checkLeaseLater(String token) {
    _leaseCheck = Timer(leaseDuration, () async {
      try {
        final lease = await openAppDataDirectory(
          'storage/maintenance/app-data',
        );
        await lease.tryExclusive(() async {
          if (!_closed && owns(token)) await end(token);
        });
      } catch (_) {
        // A storage error cannot establish that the lease has been abandoned.
      } finally {
        if (!_closed && owns(token)) _checkLeaseLater(token);
      }
    });
  }

  Future<T> hostCall<T>(Future<T> Function() action) async {
    if (active) throw StateError('Data maintenance is active');
    final completion = Completer<void>();
    _calls.add(completion.future);
    try {
      return await action();
    } finally {
      completion.complete();
      _calls.remove(completion.future);
    }
  }

  Future<String> begin() async {
    await initialize();
    if (_closed || active) throw StateError('Data maintenance is unavailable');
    final token = const Uuid().v4();
    _token = token;
    _beginning = true;
    ZeppOsLocalDataGuard.active = true;
    try {
      await stopRuntimes();
      List<int> appIds;
      try {
        appIds = (await deviceManager.zeppOsAppSideSessions())
            .map((session) => session.appId)
            .toList();
      } on UnsupportedError {
        appIds = [];
      } on ProtocolException {
        appIds = [];
      }
      for (final id in appIds) {
        await deviceManager.stopZeppOsAppSide(id);
      }
      await Future.wait(_calls.toList()).timeout(const Duration(seconds: 15));
      await ZeppOsSettingsCoordinator.instance.settle();
      await HealthStore.pauseForOwner(token, deviceManager.waitForHealthSync);
      if (_closed) throw StateError('Data maintenance is unavailable');
      _checkLeaseLater(token);
      return token;
    } catch (_) {
      _reset();
      rethrow;
    } finally {
      _beginning = false;
    }
  }

  Future<void> dispose() async {
    _closed = true;
    _leaseCheck?.cancel();
    try {
      await _ending;
    } catch (_) {}
    final token = _token;
    if (token == null || _beginning) return;
    try {
      final lease = await openAppDataDirectory('storage/maintenance/app-data');
      await lease.tryExclusive(() async {
        if (owns(token)) _reset();
      });
    } catch (_) {
      // Leave the owner's guard in place if the lease cannot be inspected.
    }
  }

  Future<void> end(String token) {
    if (!owns(token)) {
      return Future.error(StateError('Invalid data maintenance owner'));
    }
    return _ending ??= _end(token).whenComplete(() => _ending = null);
  }

  Future<void> _end(String token) async {
    try {
      if (!_closed) {
        await deviceManager.reloadSavedDevices();
        if (!_closed) await reload();
      }
    } finally {
      if (owns(token)) _reset();
    }
  }
}

/// Acquires host data maintenance, runs [action] under exclusive lock, then releases it.
Future<T> runWithAppDataMaintenance<T>(
  OronBoxCommandBus host,
  Future<T> Function() action,
) async {
  final acquired = await host.execute(
    const OronBoxCommand(method: 'appdata.maintenance.begin'),
  );
  if (!acquired.ok || acquired.value is! String) {
    throw StateError('Unable to acquire data maintenance');
  }
  final token = acquired.value as String;
  var ended = false;
  Future<void> end() async {
    if (ended) return;
    final released = await host.execute(
      OronBoxCommand(
        method: 'appdata.maintenance.end',
        params: {'token': token},
      ),
    );
    if (!released.ok) {
      throw StateError('Unable to release data maintenance');
    }
    ended = true;
  }

  try {
    final lease = await openAppDataDirectory('storage/maintenance/app-data');
    return await lease.exclusive(() async {
      final valid = await host.execute(
        OronBoxCommand(
          method: 'appdata.maintenance.validate',
          params: {'token': token},
        ),
      );
      if (!valid.ok || valid.value != true) {
        throw StateError('Data maintenance ownership changed');
      }
      try {
        return await action();
      } finally {
        await end();
      }
    });
  } finally {
    if (!ended) {
      try {
        await end();
      } catch (_) {}
    }
  }
}
