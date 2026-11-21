import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:oronbox/src/app/app_localizations_delegates.dart';
import 'package:oronbox/src/app/generated/app_localizations.dart';
import 'package:oronbox/src/app/theme/app_theme.dart';
import 'package:oronbox/src/core/services/shared_prefs_service.dart';
import 'package:oronbox/src/data/community/community_source.dart';
import 'package:oronbox/src/features/accounts/application/host_accounts.dart';
import 'package:oronbox/src/features/accounts/services/bandbbs_auth_service.dart';
import 'package:oronbox/src/features/devices/controllers/device_manager.dart';
import 'package:oronbox/src/features/resources/application/oronbox_resource_attributes.dart';
import 'package:oronbox/src/features/resources/application/resource_catalog_providers.dart';
import 'package:oronbox/src/features/resources/domain/community_resource.dart';
import 'package:oronbox/src/features/resources/domain/resource_catalog.dart';
import 'package:oronbox/src/features/resources/pages/resource_library_view.dart';
import 'package:oronbox/src/features/resources/widgets/bandbbs_resource_card.dart';
import 'package:oronbox/src/features/resources/widgets/resource_card.dart';
import 'package:oronbox/src/features/resources/widgets/resource_media_hero.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Catalog extends CommunityResourceCatalog {
  @override
  CommunitySourceId get sourceId => CommunitySourceId.oronBox;
  @override
  String get displayName => 'OronBox';
  @override
  CommunityCatalogCapabilities get capabilities =>
      const CommunityCatalogCapabilities();
  @override
  Future<CommunityResourcePage> getPage(CommunityResourceQuery query) async =>
      CommunityResourcePage(
        items: List.generate(
          4,
          (i) => CommunityResource(
            ref: ResourceRef(source: sourceId, id: '$i'),
            name: 'Resource $i',
            type: CommunityResourceType.quickApp,
            paidType: CommunityPaidType.free,
            authors: const [],
            supportedDevices: const {},
          ),
        ),
        page: 0,
        hasMore: false,
      );
  @override
  Future<List<CommunityResourceDevice>> getDevices() async => [];
  @override
  Future<CommunityResourceDetail> getDetail(ResourceRef ref) =>
      throw UnimplementedError();
  @override
  Future<CommunityResourceDownloadResult> download(
    CommunityDownloadRequest request,
  ) => throw UnimplementedError();
  @override
  Future<int?> probeDownloadSize(CommunityResourceFile file) async => null;
}

class _SignedOutHost extends HostAccountsNotifier {
  @override
  HostAccountsState build() => const HostAccountsState();
}

class _Devices extends LocalDeviceManager {
  @override
  DeviceManagerState build() => const DeviceManagerState();
}

class _BandBbsAuth extends BandBbsAuthNotifier {
  @override
  BandBbsAuthState build() => BandBbsAuthState.empty;
}

void main() {
  testWidgets(
    'layout switch stays visible and continues from the displayed position',
    (tester) async {
      SharedPreferences.setMockInitialValues({'resource_grid_view': true});
      await SharedPrefsService.instance.init();
      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            deviceManagerProvider.overrideWith(_Devices.new),
            bandBbsAuthProvider.overrideWith(_BandBbsAuth.new),
            selectedCommunitySourceProvider.overrideWithValue(
              CommunitySourceId.oronBox,
            ),
            communityCatalogProvider.overrideWithValue(_Catalog()),
            communitySourcesProvider.overrideWith(
              (ref) => Stream.value([CommunitySourceId.oronBox]),
            ),
            oronBoxResourceAttributesProvider.overrideWith((ref) async => []),
            hostAccountsProvider.overrideWith(_SignedOutHost.new),
          ],
          child: MaterialApp(
            theme: AppTheme.light,
            locale: const Locale('zh'),
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(body: ResourceLibraryView()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final original = tester.getRect(find.byType(ResourceCard).first);
      await tester.tap(find.byIcon(Icons.view_list));
      await tester.pump();
      final switched = tester.getRect(find.byType(BandBbsResourceCard).first);
      expect(switched.left, closeTo(original.left, .1));
      expect(switched.top, closeTo(original.top, .1));
      expect(switched.width, closeTo(original.width, .1));
      expect(switched.height, closeTo(original.height, .1));
      for (var i = 0; i < 5; i++) {
        for (final hero in find.byType(ResourceMediaHero).evaluate()) {
          hero.visitAncestorElements((element) {
            final widget = element.widget;
            if (widget is Opacity) expect(widget.opacity, greaterThan(0));
            return true;
          });
        }
        await tester.pump(const Duration(milliseconds: 24));
      }
      final midway = tester.getRect(find.byType(BandBbsResourceCard).first);
      await tester.tap(find.byIcon(Icons.grid_view));
      await tester.pump();
      final reversed = tester.getRect(find.byType(ResourceCard).first);
      expect(reversed.top, closeTo(midway.top, .1));
      expect(reversed.width, closeTo(midway.width, .1));
      expect(reversed.height, closeTo(midway.height, .1));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tester.getRect(find.byType(ResourceCard).first), original);
    },
  );
}
