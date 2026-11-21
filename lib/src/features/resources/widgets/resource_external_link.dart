import 'package:oronbox/src/app/widgets/app_scaffold_messenger.dart';
import 'package:material_ui/material_ui.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:oronbox/src/app/generated/app_localizations.dart';
import 'package:oronbox/src/app/widgets/dialog_helper.dart';
import 'package:oronbox/src/data/community/community_source.dart';
import 'package:oronbox/src/features/resources/domain/community_resource.dart';

enum _ExternalLinkAction { openInOronBox, openExternally }

ResourceRef? astroBoxResourceRefFromUri(Uri uri) {
  final host = uri.host.toLowerCase();
  if ((uri.scheme != 'https' && uri.scheme != 'http') ||
      (host != 'astrobox.online' && host != 'www.astrobox.online') ||
      uri.path != '/open' ||
      uri.queryParameters['source']?.toLowerCase() != 'resv2' ||
      uri.queryParameters['provider']?.toLowerCase() != 'officialv2') {
    return null;
  }
  final id = uri.queryParameters['id']?.trim() ?? '';
  return id.isEmpty
      ? null
      : ResourceRef(source: CommunitySourceId.astroboxRepo, id: id);
}

Future<void> openResourceExternalLink(BuildContext context, Uri uri) async {
  final l10n = AppLocalizations.of(context)!;
  final internalRef = astroBoxResourceRefFromUri(uri);
  final action = await OronBoxDialog.show<_ExternalLinkAction>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(l10n.externalLinkTitle),
      content: Text(
        '${l10n.externalLinkDescription(uri.toString())}'
        '${internalRef == null ? '' : '\n\n${l10n.externalLinkAstroBoxResourceHint}'}',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: Text(l10n.cancel),
        ),
        if (internalRef != null)
          TextButton(
            onPressed: () =>
                Navigator.pop(dialogContext, _ExternalLinkAction.openInOronBox),
            child: Text(l10n.viewInOronBox),
          ),
        FilledButton(
          onPressed: () =>
              Navigator.pop(dialogContext, _ExternalLinkAction.openExternally),
          child: Text(l10n.continueToWebsite),
        ),
      ],
    ),
  );
  if (!context.mounted) return;
  switch (action) {
    case _ExternalLinkAction.openInOronBox:
      final ref = internalRef!;
      final location = Uri(
        pathSegments: ['resources', 'detail', ref.id],
        queryParameters: {'source': ref.source.storageKey},
      );
      context.push('/$location');
    case _ExternalLinkAction.openExternally:
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    case null:
      return;
  }
}

bool isAstroBoxResourcePurchaseRequired(Object? error) {
  final message = error?.toString() ?? '';
  return message.contains('astrobox_purchase_required');
}

Future<void> showAstroBoxResourcePurchaseDialog(
  BuildContext context,
  ResourceRef resource,
) async {
  final l10n = AppLocalizations.of(context)!;
  final openExternally = await OronBoxDialog.show<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      icon: const Icon(Icons.lock_outline),
      title: Text(l10n.resourceAstroBoxPurchaseTitle),
      content: Text(l10n.resourceAstroBoxPurchaseMessage),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: Text(l10n.resourceAstroBoxPurchaseAction),
        ),
        FilledButton.icon(
          onPressed: () => Navigator.pop(dialogContext, true),
          icon: const Icon(Icons.open_in_new),
          label: Text(l10n.openExternally),
        ),
      ],
    ),
  );
  if (openExternally != true || !context.mounted) return;
  final uri = Uri.https('astrobox.online', '/open', {
    'source': 'resv2',
    'id': resource.id,
    'provider': 'OfficialV2',
  });
  try {
    if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return;
  } catch (_) {
    // Some platforms throw when no browser can handle the URL.
  }
  if (context.mounted) {
    appScaffoldMessengerOf(context)
        .showSnackBar(SnackBar(content: Text(l10n.externalOpenFailed)));
  }
}
