import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:oronbox/src/app/generated/app_localizations.dart';
import 'package:oronbox/src/app/widgets/dialog_helper.dart';

bool _silencedThisSession = false;
bool _isDialogShowing = false;

/// Checks whether the user has muted the unsupported Wasm dialog for this session.
bool get isWasmUnsupportedAlertSilenced => _silencedThisSession;

/// Resets the session mute state (primarily for testing).
@visibleForTesting
void resetWasmUnsupportedAlertSilencedForTesting() {
  _silencedThisSession = false;
  _isDialogShowing = false;
}

/// Displays a standard AlertDialog informing the user that Wasm is unavailable on Android 8.
Future<void> showWasmUnsupportedDialogIfNeeded() async {
  if (_silencedThisSession || _isDialogShowing) return;

  final context = OronBoxDialog.observer.currentContext;
  if (context == null || !context.mounted) return;

  _isDialogShowing = true;
  try {
    var dontShowAgain = false;
    await OronBoxDialog.show<void>(
      context: context,
      clickMaskDismiss: false,
      builder: (dialogContext) {
        final l10n = AppLocalizations.of(dialogContext)!;
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: Text(l10n.wasmUnsupportedTitle),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l10n.wasmUnsupportedMessage),
                  const SizedBox(height: 8),
                  CheckboxListTile(
                    value: dontShowAgain,
                    onChanged: (value) {
                      setState(() {
                        dontShowAgain = value ?? false;
                      });
                    },
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: Text(l10n.doNotShowAgainThisSession),
                    dense: true,
                  ),
                ],
              ),
              actions: [
                FilledButton(
                  onPressed: () {
                    if (dontShowAgain) {
                      _silencedThisSession = true;
                    }
                    Navigator.of(dialogContext).pop();
                  },
                  child: Text(l10n.announcementAcknowledge),
                ),
              ],
            );
          },
        );
      },
    );
  } finally {
    _isDialogShowing = false;
  }
}
