import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:oronbox/src/app/app_localizations_delegates.dart';
import 'package:oronbox/src/app/generated/app_localizations.dart';
import 'package:oronbox/src/features/accounts/application/host_accounts.dart';
import 'package:oronbox/src/features/resources/application/creator/creator_workspace_controller.dart';
import 'package:oronbox/src/features/resources/application/oronbox_resource_attributes.dart';
import 'package:oronbox/src/features/resources/domain/creator_workspace.dart';
import 'package:oronbox/src/features/resources/pages/creator/creator_editor_page.dart';
import 'package:oronbox/src/features/resources/pages/creator/creator_shared.dart';

void main() {
  for (final submitted in [false, true]) {
    testWidgets(
      'publication review header follows review availability, submitted=$submitted',
      (tester) async {
        final workspace = CreatorWorkspace(
          resource: const CreatorResource(
            id: 'resource',
            slug: 'resource',
            kind: CreatorResourceKind.quickApp,
            moderationState: 'suspended',
          ),
          review: submitted ? {'id': 'review', 'state': 'pending'} : null,
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              hostAccountsProvider.overrideWith(_Accounts.new),
              oronBoxCreatorResourceAttributesProvider.overrideWith(
                (ref) async => [],
              ),
            ],
            child: MaterialApp(
              localizationsDelegates: appLocalizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: Consumer(
                  builder: (context, ref, _) => CreatorEditorView(
                    workspace: workspace,
                    state: const CreatorWorkspaceState(),
                    controller: CreatorWorkspaceController(),
                    ref: ref,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final l10n = AppLocalizations.of(
          tester.element(find.byType(CreatorEditorView)),
        )!;
        await tester.tap(find.text(l10n.creatorStagePublish));
        await tester.pumpAndSettle();
        expect(
          find.byWidgetPredicate(
            (widget) =>
                widget is CreatorSectionTitle &&
                widget.title == l10n.creatorReviewStatus,
          ),
          submitted ? findsOneWidget : findsNothing,
        );
        expect(find.byType(CreatorModerationNotice), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}

class _Accounts extends HostAccountsNotifier {
  @override
  HostAccountsState build() => const HostAccountsState();
}
