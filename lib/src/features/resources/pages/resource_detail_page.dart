import 'package:oronbox/src/app/widgets/app_scaffold_messenger.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:oronbox/src/app/generated/app_localizations.dart';
import 'package:oronbox/src/device/xiaomi/xiaomi_device_catalog.dart';
import 'package:oronbox/src/app/theme/app_theme.dart';
import 'package:oronbox/src/app/utils/error_localization.dart';
import 'package:oronbox/src/app/widgets/app_state_view.dart';
import 'package:oronbox/src/app/widgets/horizontal_scroller.dart';
import 'package:oronbox/src/app/widgets/network_img_layer.dart';
import 'package:oronbox/src/app/widgets/page_container.dart';
import 'package:oronbox/src/app/widgets/sys_app_bar.dart';
import 'package:oronbox/src/core/constants/style_constants.dart';
import 'package:oronbox/src/core/providers/app_settings_providers.dart';
import 'package:oronbox/src/data/community/community_source.dart';
import 'package:oronbox/src/features/devices/controllers/device_manager.dart';
import 'package:oronbox/src/features/accounts/application/host_accounts.dart';
import 'package:oronbox/src/features/accounts/services/oronbox_coin_service.dart';
import 'package:oronbox/src/features/resources/application/comments/oronbox_comments.dart';
import 'package:oronbox/src/features/resources/application/resource_catalog_providers.dart';
import 'package:oronbox/src/features/resources/controllers/resource_filter_controller.dart';
import 'package:oronbox/src/features/resources/domain/community_resource.dart';
import 'package:oronbox/src/features/resources/services/download_queue_notifier.dart';
import 'package:oronbox/src/features/resources/widgets/community_html_content.dart';
import 'package:oronbox/src/features/resources/widgets/resource_detail_header.dart';
import 'package:oronbox/src/features/resources/widgets/resource_detail_actions.dart';
import 'package:oronbox/src/features/resources/widgets/resource_external_link.dart';
import 'package:oronbox/src/features/settings/pages/feedback_page.dart';

import 'package:oronbox/src/app/widgets/markdown_style_sheet.dart';

part 'comment_thread_page.dart';

class ResourceDetailPage extends ConsumerStatefulWidget {
  const ResourceDetailPage({
    super.key,
    required this.resource,
    this.targetCommentId = '',
  });
  final CommunityResource resource;
  final String targetCommentId;

  @override
  ConsumerState<ResourceDetailPage> createState() => _ResourceDetailPageState();
}

class _ResourceDetailPageState extends ConsumerState<ResourceDetailPage> {
  Animation<double>? _entryAnimation;
  bool _entered = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final animation = ModalRoute.of(context)?.animation;
    if (identical(animation, _entryAnimation)) return;
    _entryAnimation?.removeStatusListener(_onEntryStatus);
    _entryAnimation = animation;
    _entered = animation == null || animation.isCompleted;
    animation?.addStatusListener(_onEntryStatus);
  }

  void _onEntryStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && !_entered) {
      setState(() => _entered = true);
    }
  }

  @override
  void dispose() {
    _entryAnimation?.removeStatusListener(_onEntryStatus);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final resource = widget.resource;
    final l10n = AppLocalizations.of(context)!;
    final detail = ref.watch(communityResourceDetailProvider(resource.ref));
    final visibleResource = _entered ? detail.value ?? resource : resource;
    return Scaffold(
      appBar: SysAppBar(secondary: true, title: Text(l10n.resourceDetails)),
      body: ListView(
        padding: EdgeInsets.only(
          bottom: bottomContentPadding(context, extra: 24),
        ),
        children: [
          ResourceDetailHeader(
            resource: visibleResource,
            mediaResource: resource.iconUrl != null || resource.coverUrl != null
                ? resource
                : visibleResource,
            animateCover: resource.coverUrl != null,
            animateIcon: resource.iconUrl != null,
          ),
          if (_entered)
            detail.when(
              loading: () => const PageContainer(
                padding: EdgeInsets.symmetric(
                  horizontal: StyleConstants.pagePadding,
                  vertical: 20,
                ),
                child: _DelayedLoadingIndicator(),
              ),
              error: (error, _) => PageContainer(
                padding: const EdgeInsets.all(StyleConstants.pagePadding),
                child: ErrorStateView(
                  message: localizedErrorMessage(l10n, error),
                  onRetry: () => ref.invalidate(
                    communityResourceDetailProvider(resource.ref),
                  ),
                ),
              ),
              data: (value) => _DetailContent(
                detail: value,
                targetCommentId: widget.targetCommentId,
              ),
            ),
        ],
      ),
    );
  }
}

class _DelayedLoadingIndicator extends StatefulWidget {
  const _DelayedLoadingIndicator();

  @override
  State<_DelayedLoadingIndicator> createState() =>
      _DelayedLoadingIndicatorState();
}

class _DelayedLoadingIndicatorState extends State<_DelayedLoadingIndicator> {
  Timer? _timer;
  var _visible = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(milliseconds: 500), () {
      if (mounted) setState(() => _visible = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: const Duration(milliseconds: 160),
    child: _visible
        ? const LinearProgressIndicator(key: ValueKey('detail-progress'))
        : const SizedBox.shrink(key: ValueKey('detail-progress-delay')),
  );
}

class _DetailContent extends ConsumerStatefulWidget {
  const _DetailContent({required this.detail, required this.targetCommentId});
  final CommunityResourceDetail detail;
  final String targetCommentId;

  @override
  ConsumerState<_DetailContent> createState() => _DetailContentState();
}

class _DetailContentState extends ConsumerState<_DetailContent> {
  bool _accessNoticeShowing = false;

  CommunityResourceDetail get detail => widget.detail;
  String get targetCommentId => widget.targetCommentId;

  @override
  Widget build(BuildContext context) {
    ref.listen(downloadQueueProvider, (previous, next) {
      if (_accessNoticeShowing || ModalRoute.of(context)?.isCurrent == false) {
        return;
      }
      for (final task in next) {
        if (task.resource.ref != detail.ref ||
            task.status != ResourceTaskStatus.failed ||
            !isAstroBoxResourcePurchaseRequired(task.error)) {
          continue;
        }
        final old = previous?.where((item) => item.id == task.id).firstOrNull;
        if (old?.status == task.status && old?.error == task.error) continue;
        _accessNoticeShowing = true;
        unawaited(
          showAstroBoxResourcePurchaseDialog(
            context,
            detail.ref,
          ).whenComplete(() => _accessNoticeShowing = false),
        );
        break;
      }
    });
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    final deviceState = ref.watch(deviceManagerProvider);
    final current = deviceState.currentDevice;
    final currentCodename = normalizeXiaomiWearableCodename(current?.codename);
    final isBandBbs = detail.ref.source == CommunitySourceId.bandbbs;
    final isHuami = detail.ref.source == CommunitySourceId.huamiAppStore;
    final deviceSource = isHuami
        ? ref.read(deviceManagerProvider.notifier).currentZeppOsDeviceSource
        : null;
    final previews = isBandBbs
        ? detail.previewImages
              .where(
                (image) => !detail.content.value.contains(image.url.toString()),
              )
              .toList()
        : detail.previewImages;
    return PageContainer(
      padding: const EdgeInsets.all(StyleConstants.pagePadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (detail.summary.isNotEmpty &&
              detail.summary != detail.content.value) ...[
            Text(
              detail.summary,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
          ],
          if (!isBandBbs &&
              (isHuami
                  ? deviceSource != null
                  : currentCodename.isNotEmpty)) ...[
            ResourceCompatibility(
              detail: detail,
              codename: deviceSource?.toString() ?? currentCodename,
            ),
            const SizedBox(height: 12),
          ],
          ResourceDetailActions(
            detail: detail,
            currentCodename: currentCodename,
            secondaryActions: detail.ref.source == CommunitySourceId.oronBox
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(child: _CoinButton(resource: detail)),
                      const SizedBox(width: 8),
                      Flexible(
                        child: FilledButton.tonalIcon(
                          onPressed: () => showFeedbackComposer(
                            context,
                            target: FeedbackTarget(
                              type: FeedbackTargetType.resource,
                              source: detail.ref.source.name,
                              id: detail.ref.id,
                              name: detail.name,
                              url:
                                  detail.links.firstOrNull?.url.toString() ??
                                  '',
                            ),
                          ),
                          icon: const Icon(Icons.flag_outlined),
                          label: Text(
                            l10n.report,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(0, 36),
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            visualDensity: VisualDensity.compact,
                            backgroundColor: theme
                                .colorScheme
                                .surfaceContainerHighest
                                .withValues(alpha: .62),
                            foregroundColor: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  )
                : null,
          ),
          if (detail.collectionName?.isNotEmpty == true) ...[
            const SizedBox(height: 12),
            InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: detail.collectionId?.isNotEmpty == true
                  ? () => context.push(
                      '/resources/collection/${detail.collectionId}',
                      extra: CommunityResource(
                        ref: ResourceRef(
                          source: CommunitySourceId.oronBox,
                          id: detail.collectionId!,
                        ),
                        name: detail.collectionName ?? '',
                        type: detail.type,
                        paidType: detail.paidType,
                        authors: detail.authors,
                        supportedDevices: detail.supportedDevices,
                        iconUrl: detail.iconUrl,
                        coverUrl: detail.coverUrl,
                        summary: detail.summary,
                        isCollection: true,
                      ),
                    )
                  : null,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: context.appSelectionContainer.withValues(alpha: .5),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.folder_outlined,
                      size: 16,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      l10n.resourceFromCollection(detail.collectionName!),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (detail.links.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final link in detail.links)
                  TextButton.icon(
                    onPressed: () =>
                        openResourceExternalLink(context, link.url),
                    icon: const Icon(Icons.link_outlined),
                    label: Text(link.title),
                  ),
              ],
            ),
          ],
          if (previews.isNotEmpty && !isBandBbs) ...[
            const SizedBox(height: 24),
            _PreviewGallery(previews: previews),
          ],
          if (detail.content.value.trim().isNotEmpty) ...[
            const SizedBox(height: 24),
            Text(
              AppLocalizations.of(context)!.description,
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            switch (detail.content.format) {
              ResourceContentFormat.markdown => MarkdownBody(
                data: detail.content.value,
                selectable: true,
                styleSheet: markdownStyleSheetFromTheme(theme).copyWith(
                  p: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurface,
                    height: 1.55,
                  ),
                ),
                onTapLink: (_, href, _) {
                  final uri = Uri.tryParse(href ?? '');
                  if (uri != null &&
                      (uri.scheme == 'https' || uri.scheme == 'http')) {
                    openResourceExternalLink(context, uri);
                  }
                },
              ),
              ResourceContentFormat.html => CommunityHtmlContent(
                html: detail.content.value,
                baseUri: detail.content.baseUri,
                onOpenLink: (uri) => openResourceExternalLink(context, uri),
              ),
              ResourceContentFormat.plainText => SelectableText(
                detail.content.value,
                style: theme.textTheme.bodyLarge,
              ),
            },
          ],
          if (previews.isNotEmpty && isBandBbs) ...[
            const SizedBox(height: 24),
            _PreviewGallery(previews: previews),
          ],
          if (detail.ref.source == CommunitySourceId.oronBox &&
              ref.watch(appSettingsProvider).clean.commentsEnabled) ...[
            const SizedBox(height: 28),
            _CommentsSection(
              resourceId: detail.ref.id,
              targetCommentId: targetCommentId,
            ),
          ],
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

class _CoinButton extends ConsumerStatefulWidget {
  const _CoinButton({required this.resource});

  final CommunityResource resource;

  @override
  ConsumerState<_CoinButton> createState() => _CoinButtonState();
}

class _CoinButtonState extends ConsumerState<_CoinButton> {
  var _sending = false;

  Future<void> _send(int remaining) async {
    if (remaining <= 0 || _sending) return;
    final l10n = AppLocalizations.of(context)!;
    final count = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.resourceCoinDialogTitle),
        content: Text(l10n.resourceCoinDialogMessage),
        actions: [
          TextButton(onPressed: () => context.pop(), child: Text(l10n.cancel)),
          if (remaining >= 1)
            TextButton(
              onPressed: () => context.pop(1),
              child: Text(l10n.resourceCoinOne),
            ),
          if (remaining >= 2)
            FilledButton(
              onPressed: () => context.pop(2),
              child: Text(l10n.resourceCoinTwo),
            ),
        ],
      ),
    );
    if (count == null || _sending) return;
    setState(() => _sending = true);
    try {
      await ref
          .read(oronBoxCoinServiceProvider)
          .coin(widget.resource.ref.id, count);
      if (!mounted) return;
      appScaffoldMessengerOf(context)
          .showSnackBar(SnackBar(content: Text(l10n.resourceCoinSuccess)));
      ref.invalidate(communityResourceDetailProvider(widget.resource.ref));
      ref.invalidate(oronBoxMyCoinsProvider(widget.resource.ref.id));
      ref.read(resourceRefreshProvider.notifier).refresh();
    } catch (error) {
      if (!mounted) return;
      appScaffoldMessengerOf(context).showSnackBar(
        SnackBar(content: Text(localizedErrorMessage(l10n, error))),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    final isSignedIn = ref.watch(
      hostAccountsProvider.select((state) => state.bandbbs.isSignedIn),
    );
    final myCoins = ref.watch(oronBoxMyCoinsProvider(widget.resource.ref.id));
    final voted = myCoins.value ?? 0;
    final statusLoading = isSignedIn && myCoins.isLoading;
    final statusError = isSignedIn && myCoins.hasError;
    final statusKnown = isSignedIn && myCoins.hasValue;
    final locked = statusKnown && voted >= 2;
    final canCoin =
        statusKnown && !statusLoading && !statusError && !_sending && !locked;
    final canRetry = statusError && !_sending;
    return Tooltip(
      message: !isSignedIn
          ? l10n.resourceCoinNotSignedIn
          : statusError
          ? l10n.errorCoinStatusUnavailable
          : '',
      child: FilledButton.icon(
        onPressed: canCoin
            ? () => _send(2 - voted)
            : canRetry
            ? () =>
                  ref.invalidate(oronBoxMyCoinsProvider(widget.resource.ref.id))
            : null,
        icon: _sending || statusLoading
            ? const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : statusError
            ? const Icon(Icons.refresh)
            : const Icon(Icons.toll_outlined),
        label: Text(
          !isSignedIn
              ? l10n.resourceCoinNotSignedIn
              : statusError
              ? l10n.refresh
              : voted > 0
              ? l10n.resourceCoinVoted
              : l10n.resourceCoin,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 36),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          visualDensity: VisualDensity.compact,
          backgroundColor: !isSignedIn || (voted > 0 && statusKnown)
              ? theme.colorScheme.surfaceContainerHighest
              : null,
          foregroundColor: !isSignedIn || (voted > 0 && statusKnown)
              ? theme.colorScheme.onSurfaceVariant
              : null,
          disabledBackgroundColor: theme.colorScheme.surfaceContainerHighest,
          disabledForegroundColor: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _CommentsSection extends ConsumerStatefulWidget {
  const _CommentsSection({
    required this.resourceId,
    required this.targetCommentId,
  });
  final String resourceId;
  final String targetCommentId;

  @override
  ConsumerState<_CommentsSection> createState() => _CommentsSectionState();
}

class _CommentsSectionState extends ConsumerState<_CommentsSection> {
  final _controller = TextEditingController();
  final _deletingCommentIds = <String>{};
  List<OronBoxComment> _comments = const [];
  bool _loading = true;
  bool _sending = false;
  bool _hasMore = true;
  int _commentPage = 0;
  int _commentRequest = 0;
  String _commentCursor = '';
  String? _replyTo;
  Object? _error;
  final _targetCommentKey = GlobalKey();
  bool _targetRevealed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load({bool more = false}) async {
    final request = ++_commentRequest;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await ref
          .read(oronBoxCommentsApiProvider)
          .listPage(
            widget.resourceId,
            page: more ? _commentPage + 1 : 1,
            size: 20,
            before: more ? _commentCursor : '',
          );
      if (!mounted || request != _commentRequest) return;
      setState(() {
        _comments = more
            ? [
                ...{
                  for (final c in [..._comments, ...page.items]) c.id: c,
                }.values,
              ]
            : page.items;
        _commentPage = more ? _commentPage + 1 : 1;
        _hasMore = page.hasMore;
        _commentCursor = page.nextCursor;
        _loading = false;
      });
      _revealTargetComment();
    } catch (error) {
      if (!mounted || request != _commentRequest) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  Future<void> _openThread(String id) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            CommentThreadPage(resourceId: widget.resourceId, commentId: id),
      ),
    );
    if (mounted) await _load();
  }

  void _revealTargetComment() {
    if (_targetRevealed || widget.targetCommentId.isEmpty) return;
    _targetRevealed = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_openThread(widget.targetCommentId));
    });
  }

  Key? _commentKey(OronBoxComment comment) =>
      comment.id == widget.targetCommentId ? _targetCommentKey : null;

  Future<bool> _send({required ValueChanged<String> onError}) async {
    final body = _controller.text.trim();
    if (body.isEmpty || _sending) return false;
    setState(() => _sending = true);
    try {
      final comment = await ref
          .read(oronBoxCommentsApiProvider)
          .create(widget.resourceId, body, parentId: _replyTo ?? '');
      if (!mounted) return false;
      if (comment.moderationAction == 'block') {
        onError(AppLocalizations.of(context)!.commentBlocked);
        return false;
      }
      setState(() {
        _replyTo = null;
        _controller.clear();
      });
      await _load();
      return true;
    } catch (error) {
      if (!mounted) return false;
      onError(localizedErrorMessage(AppLocalizations.of(context)!, error));
      return false;
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _compose({String? parentId}) async {
    final l10n = AppLocalizations.of(context)!;
    setState(() => _replyTo = parentId);
    var dialogBusy = false;
    String? dialogError;
    final sent = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          return AlertDialog(
            title: Text(
              parentId == null ? l10n.commentHint : l10n.commentReplying,
            ),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: TextField(
                controller: _controller,
                enabled: !dialogBusy,
                autofocus: true,
                maxLength: 2000,
                minLines: 3,
                maxLines: 10,
                keyboardType: TextInputType.multiline,
                decoration: InputDecoration(
                  hintText: l10n.commentHint,
                  errorText: dialogError,
                  errorMaxLines: 4,
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: dialogBusy
                    ? null
                    : () => Navigator.pop(dialogContext, false),
                child: Text(l10n.cancel),
              ),
              FilledButton.icon(
                onPressed: dialogBusy
                    ? null
                    : () async {
                        setDialogState(() => dialogBusy = true);
                        setDialogState(() => dialogError = null);
                        final success = await _send(
                          onError: (message) {
                            if (dialogContext.mounted) {
                              setDialogState(() => dialogError = message);
                            }
                          },
                        );
                        if (!dialogContext.mounted) return;
                        if (success) {
                          Navigator.pop(dialogContext, true);
                        } else {
                          setDialogState(() => dialogBusy = false);
                        }
                      },
                icon: dialogBusy
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send_outlined),
                label: Text(parentId == null ? l10n.commentHint : l10n.reply),
              ),
            ],
          );
        },
      ),
    );
    if (sent != true && mounted) setState(() => _replyTo = null);
  }

  Future<void> _delete(OronBoxComment comment) async {
    if (_deletingCommentIds.contains(comment.id)) return;
    setState(() => _deletingCommentIds.add(comment.id));
    try {
      await ref.read(oronBoxCommentsApiProvider).delete(comment.id);
      await _load();
    } finally {
      if (mounted) setState(() => _deletingCommentIds.remove(comment.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    ref.listen(
      hostAccountsProvider.select(
        (value) => (value.bandbbs.isSignedIn, value.bandbbs.userId),
      ),
      (previous, next) {
        setState(() {
          _comments = const [];
          _replyTo = null;
          _controller.clear();
        });
        unawaited(_load());
      },
    );
    final auth = ref.watch(hostAccountsProvider).bandbbs;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                l10n.comments,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            FilledButton.tonalIcon(
              onPressed: auth.isSignedIn
                  ? () => _compose()
                  : () => context.push('/settings/bandbbs'),
              icon: Icon(auth.isSignedIn ? Icons.edit_outlined : Icons.login),
              label: Text(
                auth.isSignedIn ? l10n.commentHint : l10n.commentLoginRequired,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (_loading && _comments.isEmpty)
          const Center(child: CircularProgressIndicator())
        else if (_error != null && _comments.isEmpty)
          TextButton.icon(
            onPressed: _load,
            icon: const Icon(Icons.refresh),
            label: Text(l10n.retry),
          )
        else if (_comments.isEmpty)
          EmptyStateView(
            compact: true,
            icon: Icons.chat_bubble_outline,
            title: l10n.commentEmpty,
          )
        else
          for (final comment in _comments) ...[
            _CommentTile(
              key: _commentKey(comment),
              comment: comment,
              ownUserId: int.tryParse(auth.userId ?? ''),
              canModerate: false,
              deleting: _deletingCommentIds.contains(comment.id),
              onReply: comment.deleted
                  ? null
                  : () => _compose(parentId: comment.id),
              onDelete: () => _delete(comment),
              replies: [
                for (final reply in comment.replies)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(4),
                      onTap: () => _openThread(reply.id),
                      child: Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: reply.username,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: theme.colorScheme.onSurface,
                              ),
                            ),
                            if (reply.replyToUsername.isNotEmpty &&
                                reply.replyToUsername != comment.username) ...[
                              TextSpan(
                                text:
                                    ' ${l10n.commentReplyTarget(reply.replyToUsername)}',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                            TextSpan(
                              text: ': ${reply.body}',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                if (comment.replyCount > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(4),
                      onTap: () => _openThread(comment.id),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            l10n.commentViewReplies(comment.replyCount),
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(width: 2),
                          Icon(
                            Icons.chevron_right,
                            size: 14,
                            color: theme.colorScheme.primary,
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ],
        if (_hasMore && _comments.isNotEmpty)
          TextButton(
            onPressed: _loading ? null : () => _load(more: true),
            child: Text(l10n.loadMore),
          ),
      ],
    );
  }
}

class _CommentTile extends StatelessWidget {
  const _CommentTile({
    super.key,
    required this.comment,
    required this.ownUserId,
    required this.canModerate,
    required this.deleting,
    this.isReply = false,
    this.onReply,
    required this.onDelete,
    this.replies = const [],
  });
  final OronBoxComment comment;
  final int? ownUserId;
  final bool canModerate;
  final bool deleting;
  final bool isReply;
  final VoidCallback? onReply;
  final VoidCallback onDelete;
  final List<Widget> replies;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final own = ownUserId == comment.bandBbsUserId;
    final date = comment.createdAt.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    final theme = Theme.of(context);
    final header = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        CircleAvatar(
          radius: isReply ? 14 : 18,
          backgroundImage: comment.avatarUrl.isEmpty
              ? null
              : NetworkImage(comment.avatarUrl),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                comment.username,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                l10n.bandBbsIdLabel(comment.bandBbsUserId),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        Text(
          '${two(date.year % 100)}-${two(date.month)}-${two(date.day)} ${two(date.hour)}:${two(date.minute)}',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );

    final actions = Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        if (onReply != null)
          IconButton(
            tooltip: l10n.reply,
            visualDensity: VisualDensity.compact,
            onPressed: onReply,
            icon: const Icon(Icons.reply_outlined, size: 19),
          ),
        if (!comment.deleted && (own || canModerate))
          IconButton(
            tooltip: l10n.delete,
            visualDensity: VisualDensity.compact,
            onPressed: deleting ? null : onDelete,
            icon: deleting
                ? const SizedBox.square(
                    dimension: 17,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.delete_outline, size: 19),
          )
        else
          IconButton(
            tooltip: l10n.report,
            visualDensity: VisualDensity.compact,
            onPressed: () => showFeedbackComposer(
              context,
              target: FeedbackTarget(
                type: FeedbackTargetType.comment,
                source: 'comment',
                id: comment.id,
                name: comment.username,
              ),
            ),
            icon: const Icon(Icons.flag_outlined, size: 19),
          ),
      ],
    );

    final markdown = MarkdownBody(
      data: comment.deleted ? l10n.commentDeletedPlaceholder : comment.body,
      selectable: true,
      styleSheet: markdownStyleSheetFromTheme(theme).copyWith(
        p: theme.textTheme.bodyMedium,
        pPadding: EdgeInsets.zero,
        blockSpacing: 4,
      ),
      onTapLink: (_, href, _) {
        final uri = Uri.tryParse(href ?? '');
        if (uri != null && uri.hasScheme) {
          openResourceExternalLink(context, uri);
        }
      },
    );

    final subRepliesBox = replies.isEmpty
        ? null
        : DecoratedBox(
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainer,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: replies,
              ),
            ),
          );

    final content = Padding(
      padding: EdgeInsets.all(isReply ? 10 : 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          if (comment.replyToUsername.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              l10n.commentReplyTarget(comment.replyToUsername),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ],
          const SizedBox(height: 8),
          markdown,
          if (subRepliesBox != null) ...[
            const SizedBox(height: 10),
            subRepliesBox,
          ],
          actions,
        ],
      ),
    );
    if (isReply) {
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: content,
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(16),
        ),
        child: content,
      ),
    );
  }
}

class _PreviewGallery extends StatelessWidget {
  const _PreviewGallery({required this.previews});
  final List<CommunityResourceImage> previews;

  static const _height = 240.0;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          AppLocalizations.of(context)!.preview,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 10),
        HorizontalScroller(
          height: _height,
          spacing: 12,
          children: [
            for (final image in previews)
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: _sized(image)
                    ? NetworkImgLayer(
                        src: image.url.toString(),
                        width: _height * _aspectOf(image),
                        height: _height,
                        fit: BoxFit.contain,
                      )
                    : NetworkImgAutoWidth(
                        src: image.url.toString(),
                        height: _height,
                      ),
              ),
          ],
        ),
      ],
    );
  }

  bool _sized(CommunityResourceImage image) =>
      image.width != null && image.height != null && image.height! > 0;

  double _aspectOf(CommunityResourceImage image) {
    final width = image.width;
    final height = image.height;
    if (width == null || height == null || height <= 0) return 3 / 2;
    return width / height;
  }
}
