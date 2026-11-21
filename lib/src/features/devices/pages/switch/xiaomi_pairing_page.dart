import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:oronbox/src/app/generated/app_localizations.dart';
import 'package:oronbox/src/app/widgets/page_container.dart';
import 'package:oronbox/src/app/widgets/dialog_helper.dart';
import 'package:oronbox/src/app/widgets/qr_scanner_page.dart';
import 'package:oronbox/src/app/utils/error_localization.dart';
import 'package:oronbox/src/app/widgets/sys_app_bar.dart';
import 'package:oronbox/src/core/models/bt_models.dart';
import 'package:oronbox/src/core/models/device.dart';
import 'package:oronbox/src/core/utils/layout.dart';
import 'package:oronbox/src/device/core/device_state.dart';
import 'package:oronbox/src/device/xiaomi/protocol/crypto/miwear_crypto.dart';
import 'package:oronbox/src/device/xiaomi/protocol/generated/wear_account.pb.dart';
import 'package:oronbox/src/device/xiaomi/systems/bind_system.dart';
import 'package:oronbox/src/features/accounts/models/mi_account_models.dart';
import 'package:oronbox/src/features/accounts/services/mi_account_service.dart';
import 'package:oronbox/src/features/accounts/widgets/mi_account_login_dialog.dart';
import 'package:oronbox/src/features/devices/controllers/device_manager.dart';
import 'package:oronbox/src/features/devices/services/xiaomi_device_binding.dart';
import 'package:oronbox/src/features/devices/utils/device_address.dart';

class _RestartAfterLogin implements Exception {
  const _RestartAfterLogin();
}

enum _Stage {
  connecting,
  binding,
  device,
  code,
  authenticating,
  complete,
  failed,
}

Future<void> offerXiaomiRebind(BuildContext context, MiWearState device) async {
  final accepted = await OronBoxDialog.show<bool>(
    context: context,
    builder: (dialogContext) {
      final l10n = AppLocalizations.of(dialogContext)!;
      return AlertDialog(
        title: Text(l10n.pairingRebind),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.pairingTitle),
          ),
        ],
      );
    },
  );
  if (accepted != true || !context.mounted) return;
  await context.push<bool>(
    '/devices/pair',
    extra: device.copyWith(authkey: null, appDeviceId: null, bindingOob: null),
  );
}

class XiaomiPairingPage extends ConsumerStatefulWidget {
  const XiaomiPairingPage({super.key, required this.device});
  final MiWearState device;

  @override
  ConsumerState<XiaomiPairingPage> createState() => _XiaomiPairingPageState();
}

class _XiaomiPairingPageState extends ConsumerState<XiaomiPairingPage> {
  late final DeviceManager _manager;
  late final String _appDeviceId;
  _Stage _stage = _Stage.connecting;
  bool _running = false;
  int _step = 0;
  VerifyMode? _bindingMode;
  String? _code;
  Object? _failure;
  XiaomiBindingCredential? _recoveryCredential;
  XiaomiOnlineBinding? _onlineBinding;
  Completer<bool>? _confirmation;

  @override
  void initState() {
    super.initState();
    _manager = ref.read(deviceManagerProvider.notifier);
    _appDeviceId =
        widget.device.appDeviceId ??
        generateRandomBytes(16)
            .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
            .join();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_pair());
    });
  }

  @override
  void dispose() {
    _answer(false);
    if (_running) unawaited(_manager.cancelXiaomiPairing(widget.device.addr));
    super.dispose();
  }

  void _show(_Stage stage) {
    if (!mounted) return;
    setState(() {
      _stage = stage;
      switch (stage) {
        case _Stage.connecting:
          _step = 0;
        case _Stage.binding || _Stage.device || _Stage.code:
          _step = 1;
        case _Stage.authenticating || _Stage.complete:
          _step = 2;
        case _Stage.failed:
          break;
      }
    });
  }

  Future<bool> _ask(_Stage stage, [String? code]) {
    if (!mounted) return Future.value(false);
    _code = code;
    final confirmation = _confirmation = Completer<bool>();
    _show(stage);
    return confirmation.future.timeout(
      const Duration(seconds: 60),
      onTimeout: () => false,
    );
  }

  void _answer(bool confirmed) {
    final pending = _confirmation;
    _confirmation = null;
    if (pending != null && !pending.isCompleted) pending.complete(confirmed);
    if (confirmed) _show(_Stage.binding);
  }

  Future<MiAccountToken> _ensureAccount({
    bool restartAfterLogin = false,
  }) async {
    final accounts = ref.read(miAccountServiceProvider);
    final existing = await accounts.loadStoredToken();
    if (existing != null && existing.isValid) return existing;
    if (!mounted) throw StateError('Pairing page closed');
    await showMiAccountLoginDialog(context);
    final token = await accounts.loadStoredToken();
    if (token == null || !token.isValid) throw const MiAccountSessionExpired();
    if (restartAfterLogin) throw const _RestartAfterLogin();
    return token;
  }

  Future<String?> _readOob(String deviceMac) async {
    if (!mounted) return null;
    final value = await showQrScannerPage(
      context,
      title: AppLocalizations.of(context)!.scanQrCode,
    );
    final link = Uri.tryParse(value ?? '');
    if (link == null ||
        !deviceAddressEquals(link.queryParameters['btmac'], deviceMac)) {
      return null;
    }
    final code = link.queryParameters['oob'];
    return code == 'null' ? null : code;
  }

  Future<void> _pair({bool useAccountKey = false}) async {
    if (_running) return;
    _running = true;
    _failure = null;
    _bindingMode = _onlineBinding == null ? null : VerifyMode.SERVER_PSK;
    _show(
      useAccountKey || (_onlineBinding != null && _recoveryCredential == null)
          ? _Stage.binding
          : _Stage.connecting,
    );
    final device = widget.device;
    try {
      Future<void> attempt() async {
        if (useAccountKey ||
            (_onlineBinding != null && _recoveryCredential == null)) {
          if (!mounted) return;
          final accounts = ref.read(miAccountServiceProvider);
          final token = await _ensureAccount();
          final onlineBinding = _onlineBinding;
          if (onlineBinding != null && token.userId != onlineBinding.userId) {
            throw const MiAccountSessionExpired();
          }
          final credential = await findXiaomiAccountCredential(
            accounts,
            token,
            onlineBinding?.mac ?? device.addr,
          );
          if (!mounted) return;
          if (credential == null) {
            _failure = AppLocalizations.of(context)!.errorContentNotFound;
            _show(_Stage.failed);
            return;
          }
          _recoveryCredential = credential;
          _show(_Stage.connecting);
        }
        if (!mounted) return;
        await _manager.pairXiaomi(
          device.addr,
          device.name,
          device.authkey ?? '',
          XiaomiBindingInteraction(
            ensureAccount: () => _ensureAccount(restartAfterLogin: true),
            confirmCode: (code) => _ask(_Stage.code, code),
            requestOob: _readOob,
            waitForDevice: () => _show(_Stage.device),
            authenticating: () => _show(_Stage.authenticating),
            binding: (mode) {
              _bindingMode = mode;
              _show(_Stage.binding);
            },
            rememberCredential: (credential) =>
                _recoveryCredential = credential,
            onlineBindingCompleted: (binding) => _onlineBinding = binding,
            locale: Localizations.localeOf(context).toLanguageTag(),
            appDeviceId: _appDeviceId,
            oob: device.bindingOob,
          ),
          connectType: device.connectType,
          recoveryCredential: _recoveryCredential,
          removeBondBeforeConnect: _recoveryCredential == null ? true : null,
          allowBinding: _onlineBinding == null,
        );
      }

      try {
        await attempt();
      } on _RestartAfterLogin {
        if (!mounted) return;
        _show(_Stage.connecting);
        await attempt();
      } on MiAccountSessionExpired {
        if (!mounted) return;
        final accounts = ref.read(miAccountServiceProvider);
        final current = await accounts.loadStoredToken();
        if (current != null && current.isValid) rethrow;
        if (!mounted) return;
        await showMiAccountLoginDialog(context);
        if (!mounted) return;
        final renewed = await accounts.loadStoredToken();
        if (renewed == null || !renewed.isValid) rethrow;
        await attempt();
      }
      if (!mounted || _stage == _Stage.failed) return;
      final state = ref.read(deviceManagerProvider);
      final ready =
          state.protocolState == ProtocolState.ready &&
          deviceAddressEquals(state.currentDevice?.addr, device.addr);
      _failure = ready ? null : state.error;
      _show(ready ? _Stage.complete : _Stage.failed);
    } catch (error) {
      _failure = error;
      _show(_Stage.failed);
    } finally {
      _running = false;
      _answer(false);
    }
  }

  String _failureMessage(AppLocalizations l10n) {
    final error = _failure;
    if (error is XiaomiBindRejected) {
      if (error.code == Account_ErrorCode.HAVE_BOUND) {
        return l10n.pairingAlreadyBound;
      }
      if (error.code == Account_ErrorCode.CANCEL) return l10n.cancel;
    }
    if (error is MiAccountSessionExpired) {
      return l10n.settingsMiAccountLoginTitle;
    }
    return localizedErrorMessage(l10n, error);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final waitingForAnswer = _stage == _Stage.code;
    final message = switch (_stage) {
      _Stage.connecting => l10n.pairingConnecting,
      _Stage.binding => null,
      _Stage.device => l10n.pairingConfirmOnDevice,
      _Stage.code => l10n.pairingCompareCode,
      _Stage.authenticating => null,
      _Stage.complete => l10n.pairingSuccess,
      _Stage.failed => l10n.connectFailed,
    };
    return Scaffold(
      appBar: SysAppBar(secondary: true, title: Text(l10n.pairingTitle)),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final compact = !useWideLayout(constraints.maxWidth);
          final image = SvgPicture.asset(
            widget.device.illustrationAsset(),
            width: compact ? 120 : 150,
            height: compact ? 120 : 150,
            colorFilter: ColorFilter.mode(
              theme.colorScheme.onSurface,
              BlendMode.srcIn,
            ),
          );
          final name = Text(
            widget.device.localizedName(Localizations.localeOf(context)),
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          );
          return CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: PageContainer(
                  safeArea: false,
                  child: compact
                      ? Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [image, const SizedBox(height: 16), name],
                        )
                      : Row(
                          children: [
                            Expanded(child: name),
                            const SizedBox(width: 32),
                            image,
                          ],
                        ),
                ),
              ),
              SliverFillRemaining(
                hasScrollBody: false,
                child: PageContainer(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final (index, title) in [
                        l10n.pairingConnectStep,
                        _bindingMode == VerifyMode.APP_LOCAL
                            ? l10n.pairingLocalStep
                            : l10n.pairingAccountStep,
                        l10n.pairingAuthStep,
                      ].indexed)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (index == _step &&
                                  _stage != _Stage.failed &&
                                  _stage != _Stage.complete)
                                const SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              else
                                Icon(
                                  index == _step && _stage == _Stage.failed
                                      ? Icons.error_outline
                                      : index == 1 &&
                                            _step > 1 &&
                                            _bindingMode == null
                                      ? Icons.remove_circle_outline
                                      : index < _step ||
                                            _stage == _Stage.complete
                                      ? Icons.check_circle_outline
                                      : Icons.radio_button_unchecked,
                                  size: 18,
                                ),
                              const SizedBox(width: 8),
                              Flexible(child: Text(title)),
                            ],
                          ),
                        ),
                      if (message != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(message, textAlign: TextAlign.center),
                        ),
                      if (_stage == _Stage.failed && _failure != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          _failureMessage(l10n),
                          textAlign: TextAlign.center,
                        ),
                      ],
                      if (_stage == _Stage.code && _code != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(
                            _code!,
                            style: theme.textTheme.headlineMedium,
                          ),
                        ),
                      const SizedBox(height: 24),
                      if (waitingForAnswer)
                        Wrap(
                          spacing: 12,
                          children: [
                            TextButton(
                              onPressed: () => _answer(false),
                              child: Text(l10n.cancel),
                            ),
                            FilledButton(
                              onPressed: () => _answer(true),
                              child: Text(l10n.creatorConfirm),
                            ),
                          ],
                        ),
                      if (_stage == _Stage.complete)
                        FilledButton(
                          onPressed: () => context.go('/devices'),
                          child: Text(l10n.creatorDeviceSelectionDone),
                        ),
                      if (_stage == _Stage.failed)
                        Wrap(
                          spacing: 12,
                          children: [
                            TextButton(
                              onPressed: () => _pair(useAccountKey: true),
                              child: Text(l10n.settingsMiAccountLoginAndSync),
                            ),
                            TextButton(
                              onPressed: () => context.pop(true),
                              child: Text(l10n.pairingUseExistingKey),
                            ),
                            FilledButton(
                              onPressed: _pair,
                              child: Text(l10n.retry),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
