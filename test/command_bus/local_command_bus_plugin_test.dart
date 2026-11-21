import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oronbox/src/command_bus/local_command_bus.dart';
import 'package:oronbox/src/commands/command_protocol.dart';
import 'package:oronbox/src/core/services/shared_prefs_service.dart';
import 'package:oronbox/src/device/core/event_bus.dart';
import 'package:oronbox/src/features/accounts/models/mi_account_models.dart';
import 'package:oronbox/src/features/accounts/services/bandbbs_auth_service.dart';
import 'package:oronbox/src/features/accounts/services/mi_account_service.dart';
import 'package:oronbox/src/features/devices/controllers/device_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/wasm_abp_fixtures.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a waiting plugin operation allows closing through the command bus',
    () async {
      SharedPreferences.setMockInitialValues({});
      await SharedPrefsService.instance.init();
      final root = await Directory.systemTemp.createTemp(
        'oronbox-plugin-commands-',
      );
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      final reachedCache = Completer<void>();
      final cacheGate = Completer<void>();
      var holdCache = false;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'getApplicationCacheDirectory' && holdCache) {
          if (!reachedCache.isCompleted) reachedCache.complete();
          await cacheGate.future;
        }
        return root.path;
      });
      final container = ProviderContainer(
        overrides: [
          deviceManagerProvider.overrideWith(_Devices.new),
          bandBbsAuthProvider.overrideWith(_Auth.new),
          miAccountServiceProvider.overrideWithValue(_MiAccount()),
        ],
      );
      final bus = LocalCommandBus(container);
      Future<CommandResult>? opening;
      Future<CommandResult>? closing;
      try {
        final bytes = readWasmAbpFixture('ui_notification.wasm');
        final manifest = utf8.encode(
          jsonEncode({
            'id': 'org.example.commands',
            'name': 'Commands',
            'version': '1',
            'entry': 'plugin.wasm',
            'api_level': 4,
          }),
        );
        final archive = Archive()
          ..addFile(ArchiveFile('manifest.json', manifest.length, manifest))
          ..addFile(ArchiveFile('plugin.wasm', bytes.length, bytes));
        final installed = await bus.execute(
          OronBoxCommand(
            method: 'plugin.install',
            params: {'bytes': ZipEncoder().encode(archive)},
          ),
        );
        expect(installed.ok, isTrue, reason: installed.error?.toString());
        holdCache = true;
        opening = bus.execute(
          const OronBoxCommand(
            method: 'plugin.open',
            params: {'id': 'org.example.commands'},
          ),
        );
        await reachedCache.future.timeout(const Duration(seconds: 3));
        closing = bus.execute(
          const OronBoxCommand(
            method: 'plugin.close',
            params: {'id': 'org.example.commands'},
          ),
        );
        final closed = await closing.timeout(const Duration(seconds: 1));
        expect(closed.ok, isTrue, reason: closed.error?.toString());
        cacheGate.complete();
        expect((await opening).ok, isFalse);
      } finally {
        if (!cacheGate.isCompleted) cacheGate.complete();
        await opening;
        await closing;
        await bus.close();
        container.dispose();
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
        await root.delete(recursive: true);
      }
    },
  );
}

class _Devices extends LocalDeviceManager {
  @override
  DeviceManagerState build() => const DeviceManagerState();
  @override
  Stream<DeviceEvent> get deviceEvents => const Stream.empty();
  @override
  Future<void> disconnect([String? addr]) async {}
}

class _Auth extends BandBbsAuthNotifier {
  @override
  BandBbsAuthState build() => BandBbsAuthState.empty;
}

class _MiAccount extends Fake implements MiAccountService {
  @override
  Future<MiAccountToken?> loadStoredToken() async => null;
}
