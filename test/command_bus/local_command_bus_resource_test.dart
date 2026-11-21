import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oronbox/src/app/generated/app_localizations_en.dart';
import 'package:oronbox/src/app/utils/error_localization.dart';
import 'package:oronbox/src/command_bus/local_command_bus.dart';
import 'package:oronbox/src/commands/command_protocol.dart';
import 'package:oronbox/src/core/services/shared_prefs_service.dart';
import 'package:oronbox/src/data/astrobox/astrobox_repo_resource_provider.dart';
import 'package:oronbox/src/data/community/community_source.dart';
import 'package:oronbox/src/device/core/event_bus.dart';
import 'package:oronbox/src/features/accounts/models/mi_account_models.dart';
import 'package:oronbox/src/features/accounts/services/bandbbs_auth_service.dart';
import 'package:oronbox/src/features/accounts/services/mi_account_service.dart';
import 'package:oronbox/src/features/devices/controllers/device_manager.dart';
import 'package:oronbox/src/features/resources/application/command_resource_catalog.dart';
import 'package:oronbox/src/features/resources/application/resource_catalog_providers.dart';
import 'package:oronbox/src/features/resources/domain/resource_catalog.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  test('resource transport failures retain usable errors across the command boundary', () async {
    SharedPreferences.setMockInitialValues({});
    await SharedPrefsService.instance.init();
    final root = await Directory.systemTemp.createTemp(
      'oronbox-resource-commands-',
    );
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) async => root.path,
    );
    final dio = Dio();
    var failure = DioException(
      requestOptions: RequestOptions(),
      error: const SocketException('Failed host lookup'),
    );
    dio.interceptors.add(
      InterceptorsWrapper(onRequest: (_, handler) => handler.reject(failure)),
    );
    final container = ProviderContainer(
      overrides: [
        deviceManagerProvider.overrideWith(_Devices.new),
        bandBbsAuthProvider.overrideWith(_Auth.new),
        miAccountServiceProvider.overrideWithValue(_MiAccount()),
        localCommunityCatalogProviderForSource(CommunitySourceId.astroboxRepo)
            .overrideWithValue(AstroBoxRepoCatalog(dio: dio)),
      ],
    );
    final bus = LocalCommandBus(container);
    try {
      final l10n = AppLocalizationsEn();
      for (final entry in [
        (
          DioExceptionType.unknown,
          const SocketException('Failed host lookup'),
          'network_error',
          l10n.errorNetworkUnavailable,
        ),
        (DioExceptionType.unknown, null, 'internal', l10n.errorOperationFailed),
        (
          DioExceptionType.connectionError,
          null,
          'network_error',
          l10n.errorNetworkUnavailable,
        ),
        (
          DioExceptionType.unknown,
          const HandshakeException('Certificate verification failed'),
          'certificate_error',
          l10n.errorCertificateVerificationFailed,
        ),
        (
          DioExceptionType.unknown,
          const FormatException('Invalid JSON'),
          'invalid_response',
          l10n.errorInvalidRequest,
        ),
        (
          DioExceptionType.connectionTimeout,
          null,
          'request_timeout',
          l10n.errorRequestTimeout,
        ),
        (
          DioExceptionType.cancel,
          null,
          'cancelled',
          l10n.errorOperationCancelled,
        ),
      ]) {
        failure = DioException(
          requestOptions: RequestOptions(
            path: 'https://example.com/index_v2.csv?token=private',
          ),
          type: entry.$1,
          error: entry.$2,
        );
        final result = await bus.execute(
          const OronBoxCommand(
            method: 'resource.list',
            params: {'source': 'astrobox-repo'},
          ),
        );
        final decoded = CommandResult.fromJson(
          (jsonDecode(jsonEncode(result.toJson())) as Map)
              .cast<String, Object?>(),
        );
        expect(decoded.error?.code, entry.$3);
        expect(localizedErrorMessage(l10n, decoded.error), entry.$4);
        expect(jsonEncode(decoded.toJson()), isNot(contains('private')));
      }
      final catalog = CommandResourceCatalog(
        host: bus,
        sourceId: CommunitySourceId.astroboxRepo,
      );
      await expectLater(
        catalog.getPage(const CommunityResourceQuery()),
        throwsA(
          isA<CommandError>().having(
            (error) => localizedErrorMessage(l10n, error),
            'visible error',
            l10n.errorOperationCancelled,
          ),
        ),
      );
    } finally {
      await bus.close();
      container.dispose();
      dio.close(force: true);
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      await root.delete(recursive: true);
    }
  });
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
  @override
  Future<void> restoreCredentials() async {}
}

class _MiAccount extends Fake implements MiAccountService {
  @override
  Future<MiAccountToken?> loadStoredToken() async => null;
}
