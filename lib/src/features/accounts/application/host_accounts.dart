import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:oronbox/src/commands/command_protocol.dart';
import 'package:oronbox/src/core/errors/coded_error.dart';
import 'package:oronbox/src/features/accounts/services/bandbbs_browser_authorization.dart';
import 'package:oronbox/src/features/accounts/services/bandbbs_oauth_callback.dart';
import 'package:flutter/foundation.dart';
import 'package:oronbox/src/host/application_host_provider.dart';

final currentUserRoleProvider = FutureProvider<String>((ref) async {
  final result = await ref
      .watch(applicationHostProvider)
      .execute(const OronBoxCommand(method: 'account.grants'));
  if (!result.ok || result.value is! Map) return 'user';
  return (result.value as Map)['role']?.toString() ?? 'user';
});

class HostAccount {
  const HostAccount({
    required this.provider,
    this.signedIn = false,
    this.username,
    this.userId,
    this.avatarUrl,
    this.syncedDevices = 0,
    this.isBusy = false,
  });

  final String provider;
  final bool signedIn;
  final String? username;
  final String? userId;
  final String? avatarUrl;
  final int syncedDevices;
  final bool isBusy;
  bool get isSignedIn => signedIn;

  factory HostAccount.fromJson(Map<String, Object?> json) => HostAccount(
    provider: json['provider']?.toString() ?? '',
    signedIn: json['signedIn'] == true,
    username: json['username']?.toString(),
    userId: json['userId']?.toString(),
    avatarUrl: json['avatarUrl']?.toString(),
    syncedDevices:
        (json['syncedDevices'] as num?)?.toInt() ??
        (json['importedDevices'] as num?)?.toInt() ??
        0,
  );
}

class HostAccountsState {
  const HostAccountsState({
    this.accounts = const {},
    this.busyProvider,
    this.error,
    this.revision = 0,
    this.noticeCode,
    this.noticeRevision = 0,
  });

  final Map<String, HostAccount> accounts;
  final String? busyProvider;
  final String? error;
  final int revision;
  final String? noticeCode;
  final int noticeRevision;

  HostAccount get xiaomi => _account('xiaomi');
  HostAccount get amazfit => _account('amazfit');
  HostAccount get bandbbs => _account('bandbbs');

  HostAccount _account(String provider) {
    final account = accounts[provider] ?? HostAccount(provider: provider);
    return HostAccount(
      provider: account.provider,
      signedIn: account.signedIn,
      username: account.username,
      userId: account.userId,
      avatarUrl: account.avatarUrl,
      syncedDevices: account.syncedDevices,
      isBusy: busyProvider == provider,
    );
  }

  HostAccountsState copyWith({
    Map<String, HostAccount>? accounts,
    String? busyProvider,
    bool clearBusy = false,
    String? error,
    bool clearError = false,
    int? revision,
    String? noticeCode,
    int? noticeRevision,
  }) => HostAccountsState(
    accounts: accounts ?? this.accounts,
    busyProvider: clearBusy ? null : busyProvider ?? this.busyProvider,
    error: clearError ? null : error ?? this.error,
    revision: revision ?? this.revision,
    noticeCode: noticeCode ?? this.noticeCode,
    noticeRevision: noticeRevision ?? this.noticeRevision,
  );
}

class HostAccountsNotifier extends Notifier<HostAccountsState> {
  StreamSubscription<CommandEvent>? _subscription;
  String? _lastNoticeCode;
  DateTime? _lastNoticeAt;

  @override
  HostAccountsState build() {
    _subscription = ref.watch(applicationHostProvider).events.listen((event) {
      if (event.event == 'account.state' &&
          _replaceAccounts(event.data['state'])) {
        if (event.data['reason'] case final Object reason) {
          _publishNotice(reason.toString());
        }
        return;
      }
      if (event.event == 'account.state' || event.event == 'host.connected') {
        unawaited(refresh());
      }
    });
    ref.onDispose(() => unawaited(_subscription?.cancel()));
    scheduleMicrotask(refresh);
    return const HostAccountsState();
  }

  void _publishNotice(String code) {
    final normalized = code.trim().toLowerCase();
    if (normalized.isEmpty) return;
    final now = DateTime.now();
    if (_lastNoticeCode == normalized &&
        _lastNoticeAt != null &&
        now.difference(_lastNoticeAt!) < const Duration(seconds: 3)) {
      return;
    }
    _lastNoticeCode = normalized;
    _lastNoticeAt = now;
    state = state.copyWith(
      noticeCode: normalized,
      noticeRevision: state.noticeRevision + 1,
    );
  }

  Future<void> refresh() async {
    final value = await _execute(const OronBoxCommand(method: 'account.list'));
    _replaceAccounts(value);
  }

  bool _replaceAccounts(Object? value) {
    if (value is! List) return false;
    final accounts = {
      for (final row in value.whereType<Map>())
        row['provider'].toString(): HostAccount.fromJson(
          row.cast<String, Object?>(),
        ),
    };
    state = state.copyWith(
      accounts: accounts,
      clearError: true,
      revision: state.revision + 1,
    );
    return true;
  }

  Future<HostAccount> loginAmazfit({
    required String username,
    required String password,
  }) => _mutate(
    'amazfit',
    OronBoxCommand(
      method: 'account.login',
      params: {
        'provider': 'amazfit',
        'username': username,
        'password': password,
      },
    ),
  );

  Future<HostAccount> loginXiaomi({
    required String username,
    required String password,
    String? region,
  }) => _mutate(
    'xiaomi',
    OronBoxCommand(
      method: 'account.login',
      params: {
        'provider': 'xiaomi',
        'username': username,
        'password': password,
        if (region != null && region.isNotEmpty) 'region': region,
      },
    ),
  );

  Future<HostAccount> completeXiaomiTwoFactor({
    required HostTwoFactorRequired challenge,
    required String cookieHeader,
    String? region,
  }) => _mutate(
    'xiaomi',
    OronBoxCommand(
      method: 'account.xiaomi.complete',
      params: {
        'url': challenge.url,
        'deviceId': challenge.deviceId,
        'cookieHeader': cookieHeader,
        if (region != null && region.isNotEmpty) 'region': region,
      },
    ),
  );

  Future<void> startBandBbsLogin() async {
    reserveBandBbsAuthorization();
    try {
      await _mutate(
        'bandbbs',
        const OronBoxCommand(
          method: 'account.login',
          params: {'provider': 'bandbbs'},
        ),
      );
    } catch (_) {
      cancelBandBbsAuthorization();
      rethrow;
    }
  }

  Future<void> startBandBbsPublishingAuthorization() async {
    reserveBandBbsAuthorization();
    state = state.copyWith(busyProvider: 'bandbbs', clearError: true);
    try {
      await _execute(const OronBoxCommand(method: 'account.bandbbs.publish'));
      state = state.copyWith(clearBusy: true);
    } catch (error) {
      cancelBandBbsAuthorization();
      state = state.copyWith(clearBusy: true, error: error.toString());
      rethrow;
    }
  }

  Future<bool> handleBandBbsCallback(Uri uri) async {
    if (!isBandBbsOAuthCallback(uri, webLocation: kIsWeb ? Uri.base : null)) {
      return false;
    }
    await _mutate(
      'bandbbs',
      OronBoxCommand(
        method: 'account.bandbbs.callback',
        params: {'uri': uri.toString()},
      ),
    );
    return true;
  }

  Future<void> logout(String provider) async {
    await _mutate(
      provider,
      OronBoxCommand(method: 'account.logout', params: {'provider': provider}),
    );
  }

  Future<Map<String, Object?>> rememberedCredentials(String provider) async {
    final value = await _execute(
      OronBoxCommand(
        method: 'account.credentials.get',
        params: {'provider': provider},
      ),
    );
    return (value as Map).cast<String, Object?>();
  }

  Future<void> saveCredentials({
    required String provider,
    required bool remember,
    required String username,
    required String password,
    String? userId,
  }) async {
    await _execute(
      OronBoxCommand(
        method: 'account.credentials.set',
        params: {
          'provider': provider,
          'remember': remember,
          'username': username,
          'password': password,
          if (userId != null) 'userId': userId,
        },
      ),
    );
  }

  Future<HostAccount> _mutate(String provider, OronBoxCommand command) async {
    state = state.copyWith(busyProvider: provider, clearError: true);
    try {
      final value = await _execute(command);
      final account = HostAccount.fromJson(
        (value as Map).cast<String, Object?>(),
      );
      state = state.copyWith(
        accounts: {...state.accounts, account.provider: account},
        clearBusy: true,
      );
      return account;
    } catch (error) {
      state = state.copyWith(clearBusy: true, error: error.toString());
      rethrow;
    }
  }

  Future<Object?> _execute(OronBoxCommand command) async {
    final result = await ref.read(applicationHostProvider).execute(command);
    if (!result.ok) {
      if (result.error?.code == 'two_factor_required') {
        final details = (result.error?.details as Map).cast<String, Object?>();
        throw HostTwoFactorRequired(
          url: details['url']!.toString(),
          deviceId: details['deviceId']!.toString(),
        );
      }
      throw HostCommandException.fromCommand(result.error!);
    }
    return result.value;
  }
}

class HostCommandException implements CodedError {
  const HostCommandException({
    required this.code,
    required this.message,
    this.details,
  });

  factory HostCommandException.fromCommand(CommandError error) =>
      HostCommandException(
        code: error.code,
        message: error.message,
        details: error.details,
      );

  @override
  final String code;
  @override
  final String message;
  @override
  final Object? details;

  @override
  String toString() => '$code: $message';
}

class HostTwoFactorRequired implements Exception {
  const HostTwoFactorRequired({required this.url, required this.deviceId});
  final String url;
  final String deviceId;
}

final hostAccountsProvider =
    NotifierProvider<HostAccountsNotifier, HostAccountsState>(
      HostAccountsNotifier.new,
    );
