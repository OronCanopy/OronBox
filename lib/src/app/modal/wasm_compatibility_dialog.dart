import 'package:material_ui/material_ui.dart';
import 'package:oronbox/src/app/generated/app_localizations.dart';
import 'package:oronbox/src/app/widgets/app_scaffold_messenger.dart';
import 'package:oronbox/src/core/logging/logging_service.dart';

import 'global_modal_models.dart';

class WasmCompatibilityDialog extends StatefulWidget {
  const WasmCompatibilityDialog({
    super.key,
    required this.modal,
    required this.onComplete,
  });

  final WasmCompatibilityModalRequest modal;
  final VoidCallback onComplete;

  @override
  State<WasmCompatibilityDialog> createState() =>
      _WasmCompatibilityDialogState();
}

class _WasmCompatibilityDialogState extends State<WasmCompatibilityDialog> {
  bool _busy = false;
  bool _testing = false;

  Future<void> _finish(bool test) async {
    setState(() {
      _busy = true;
      _testing = test;
    });
    try {
      if (test) {
        await widget.modal.test();
      } else {
        await widget.modal.defer();
      }
      if (!mounted) return;
      widget.onComplete();
      widget.modal.onComplete(test);
      if (test) {
        appScaffoldMessengerOf(context).showSnackBar(
          SnackBar(
            content: Text(
              AppLocalizations.of(context)!.wasmCompatibilityPassed,
            ),
          ),
        );
      }
      Navigator.of(context).pop();
    } catch (error, stack) {
      getLogger('WasmCompatibility')
          .warning('Compatibility action failed', error, stack);
      if (!mounted) return;
      appScaffoldMessengerOf(context).showSnackBar(
        SnackBar(
          content: Text(
            AppLocalizations.of(context)!.wasmCompatibilityTestFailed,
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: Text(l10n.wasmCompatibilityTitle),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.wasmCompatibilityMessage),
                if (_busy) ...[
                  const SizedBox(height: 16),
                  const LinearProgressIndicator(),
                  if (_testing) ...[
                    const SizedBox(height: 8),
                    Text(l10n.wasmCompatibilityTesting),
                  ],
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => _finish(false),
            child: Text(l10n.wasmCompatibilityDefer),
          ),
          FilledButton(
            onPressed: _busy ? null : () => _finish(true),
            child: Text(l10n.wasmCompatibilityStart),
          ),
        ],
      ),
    );
  }
}
