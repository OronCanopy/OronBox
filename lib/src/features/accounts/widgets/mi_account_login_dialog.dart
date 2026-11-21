import 'package:oronbox/src/app/widgets/app_scaffold_messenger.dart';
import 'package:oronbox/src/app/widgets/app_checkbox_tile.dart';

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:oronbox/src/app/generated/app_localizations.dart';
import 'package:oronbox/src/app/utils/error_localization.dart';
import 'package:oronbox/src/features/accounts/application/host_accounts.dart';
import 'package:oronbox/src/features/accounts/models/mi_account_models.dart';
import 'package:oronbox/src/features/accounts/services/mi_account_two_factor_resolver.dart';

Future<void> showMiAccountLoginDialog(BuildContext context) async {
  final syncedDevices = await showDialog<int>(
    context: context,
    builder: (_) => const MiAccountLoginDialog(),
  );
  if (!context.mounted || syncedDevices == null) return;
  appScaffoldMessengerOf(context).showSnackBar(
    SnackBar(
      content: Text(
        AppLocalizations.of(context)!
            .settingsMiAccountSyncedDevices(syncedDevices),
      ),
    ),
  );
}

class MiAccountLoginDialog extends ConsumerStatefulWidget {
  const MiAccountLoginDialog({super.key});

  @override
  ConsumerState<MiAccountLoginDialog> createState() =>
      _MiAccountLoginDialogState();
}

class _MiAccountLoginDialogState extends ConsumerState<MiAccountLoginDialog> {
  late final HostAccountsNotifier _accounts;
  final _username = TextEditingController();
  final _password = TextEditingController();
  MiAccountRegion _region = MiAccountRegion.cn;
  bool _remember = false;
  bool _ready = false;
  bool _running = false;
  bool _obscurePassword = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _accounts = ref.read(hostAccountsProvider.notifier);
    unawaited(_loadCredentials());
  }

  Future<void> _loadCredentials() async {
    try {
      final credentials = await _accounts.rememberedCredentials('xiaomi');
      if (!mounted) return;
      _remember = credentials['remember'] == true;
      if (_remember) {
        _username.text = credentials['username']?.toString() ?? '';
        _password.text = credentials['password']?.toString() ?? '';
      }
    } catch (error) {
      if (mounted) _error = error;
    } finally {
      if (mounted) setState(() => _ready = true);
    }
  }

  Future<void> _submit() async {
    if (_running) return;
    final l10n = AppLocalizations.of(context)!;
    final username = _username.text.trim();
    final password = _password.text;
    if (username.isEmpty || password.isEmpty) {
      setState(() => _error = l10n.settingsMiAccountMissingCredentials);
      return;
    }
    setState(() {
      _running = true;
      _error = null;
    });
    try {
      HostAccount account;
      try {
        account = await _accounts.loginXiaomi(
          username: username,
          password: password,
          region: _region.tag,
        );
      } on HostTwoFactorRequired catch (challenge) {
        if (!mounted) return;
        final cookieHeader = await resolveMiAccountTwoFactor(
          context,
          Uri.parse(challenge.url),
        );
        if (!mounted) return;
        account = await _accounts.completeXiaomiTwoFactor(
          challenge: challenge,
          cookieHeader: cookieHeader,
          region: _region.tag,
        );
      }
      if (!mounted) return;
      await _accounts.saveCredentials(
        provider: 'xiaomi',
        remember: _remember,
        username: username,
        password: password,
        userId: account.userId ?? '',
      );
      if (mounted) _close(account.syncedDevices);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _signOut() async {
    setState(() {
      _running = true;
      _error = null;
    });
    try {
      await _accounts.logout('xiaomi');
      await _accounts.saveCredentials(
        provider: 'xiaomi',
        remember: false,
        username: '',
        password: '',
      );
      if (mounted) _close();
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  void _close([int? result]) {
    final route = ModalRoute.of(context)!;
    final navigator = Navigator.of(context);
    if (route.isCurrent) {
      navigator.pop(result);
    } else {
      navigator.removeRoute(route, result);
    }
  }

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final signedIn = ref.watch(hostAccountsProvider).xiaomi.isSignedIn;
    return AlertDialog(
      title: Text(l10n.settingsMiAccountLoginTitle),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: !_ready
            ? const SizedBox(
                height: 80,
                child: Center(child: CircularProgressIndicator()),
              )
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DropdownButtonFormField<MiAccountRegion>(
                      isExpanded: true,
                      initialValue: _region,
                      decoration: InputDecoration(
                        labelText: l10n.settingsMiAccountRegion,
                        prefixIcon: const Icon(Icons.public_outlined),
                      ),
                      items: MiAccountRegion.values.map((region) {
                        return DropdownMenuItem(
                          value: region,
                          child: Text(region.localizedName(l10n)),
                        );
                      }).toList(),
                      onChanged: _running
                          ? null
                          : (value) {
                              if (value != null) {
                                setState(() => _region = value);
                              }
                            },
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _username,
                      enabled: !_running,
                      keyboardType: TextInputType.emailAddress,
                      decoration: InputDecoration(
                        labelText: l10n.settingsMiAccountUsername,
                        prefixIcon: const Icon(Icons.account_circle_outlined),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _password,
                      enabled: !_running,
                      obscureText: _obscurePassword,
                      decoration: InputDecoration(
                        labelText: l10n.settingsMiAccountPassword,
                        prefixIcon: const Icon(Icons.lock_outline),
                        suffixIcon: IconButton(
                          onPressed: _running
                              ? null
                              : () => setState(
                                  () => _obscurePassword = !_obscurePassword,
                                ),
                          icon: Icon(
                            _obscurePassword
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                          ),
                        ),
                      ),
                      onSubmitted: (_) => _submit(),
                    ),
                    const SizedBox(height: 8),
                    AppCheckboxTile(
                      value: _remember,
                      onChanged: _running
                          ? null
                          : (value) =>
                                setState(() => _remember = value ?? false),
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: Text(l10n.settingsMiAccountRememberCredentials),
                    ),
                    if (_running) ...[
                      const SizedBox(height: 20),
                      const LinearProgressIndicator(),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        localizedErrorMessage(l10n, _error),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
      ),
      actions: [
        if (signedIn)
          TextButton(
            onPressed: _running ? null : _signOut,
            child: Text(l10n.bandBbsLogout),
          ),
        TextButton(
          onPressed: _running ? null : () => _close(),
          child: Text(l10n.settingsCancel),
        ),
        FilledButton(
          onPressed: !_ready || _running ? null : _submit,
          child: Text(l10n.settingsMiAccountLoginAndSync),
        ),
      ],
    );
  }
}
