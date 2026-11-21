import 'dart:async';

import 'package:dio/dio.dart';
import 'package:oronbox/src/core/constants/oronbox_server.dart';
import 'package:oronbox/src/core/logging/logging_service.dart';
import 'package:oronbox/src/data/astrobox/astrobox_repo_resource_provider.dart';
import 'package:oronbox/src/data/astrobox/models/astrobox_models.dart';
import 'package:oronbox/src/data/community/community_source.dart';
import 'package:oronbox/src/features/resources/domain/community_resource.dart';

class InstalledResourceVersion {
  const InstalledResourceVersion(this.kind, this.id, this.versionCode);

  final String kind;
  final String id;
  final int versionCode;

  Map<String, Object> toJson() => {
    'kind': kind,
    'package_id': id,
    'version_code': versionCode,
  };
}

class ResourceUpdateCandidate {
  const ResourceUpdateCandidate({
    required this.ref,
    required this.fileId,
    required this.package,
    required this.name,
    required this.version,
    required this.versionCode,
    this.sha256 = '',
    this.purchaseRequired = false,
  });

  final ResourceRef ref;
  final String fileId;
  final InstalledResourceVersion package;
  final String name;
  final String version;
  final int versionCode;
  final String sha256;
  final bool purchaseRequired;
}

class InstalledResourceUpdates {
  const InstalledResourceUpdates(this.dio, this.astrobox);

  final Dio dio;
  final AstroBoxRepoCatalog astrobox;
  static final _log = getLogger('InstalledResourceUpdates');

  Future<({List<ResourceUpdateCandidate> items, bool complete})> find(
    String device,
    List<InstalledResourceVersion> installed,
  ) async {
    if (device.isEmpty || installed.isEmpty) {
      return (items: const <ResourceUpdateCandidate>[], complete: true);
    }
    var complete = true;
    final sources = await Future.wait(
      [
        _oronbox(device, installed),
        _astrobox(device, installed, onFailure: () => complete = false),
      ].map((request) async {
        try {
          return await request;
        } catch (error, stack) {
          complete = false;
          _log.warning('Unable to check resource source', error, stack);
          return const <ResourceUpdateCandidate>[];
        }
      }),
    );
    return (
      items: sources.expand((items) => items).toList(),
      complete: complete,
    );
  }

  Future<List<ResourceUpdateCandidate>> _oronbox(
    String device,
    List<InstalledResourceVersion> installed,
  ) async {
    final result = <ResourceUpdateCandidate>[];
    final byPackage = {
      for (final item in installed) (item.kind, item.id): item,
    };
    for (var start = 0; start < installed.length; start += 128) {
      final response = await dio.post<Map<String, dynamic>>(
        '$oronBoxServerBaseUrl/api/v1/resources/update-check',
        data: {
          'device': device,
          'installed': installed
              .skip(start)
              .take(128)
              .map((item) => item.toJson())
              .toList(),
        },
      );
      for (final row
          in (response.data?['updates'] as List? ?? []).whereType<Map>()) {
        final package = byPackage[(row['kind'], row['package_id'])];
        final version = row['version_code'];
        if (package == null ||
            version is! int ||
            version <= package.versionCode ||
            row['resource_id'] is! String ||
            row['file_id'] is! String) {
          continue;
        }
        result.add(
          ResourceUpdateCandidate(
            ref: ResourceRef(
              source: CommunitySourceId.oronBox,
              id: row['resource_id'] as String,
            ),
            fileId: row['file_id'] as String,
            package: package,
            name: row['name']?.toString() ?? package.id,
            purchaseRequired: row['paid_type'] == 'force_paid',
            version: row['version']?.toString() ?? '',
            versionCode: version,
            sha256: row['sha256']?.toString().trim().toLowerCase() ?? '',
          ),
        );
      }
    }
    return result;
  }

  Future<List<ResourceUpdateCandidate>> _astrobox(
    String device,
    List<InstalledResourceVersion> installed, {
    required void Function() onFailure,
  }) async {
    await astrobox.refreshUpdateIndex();
    final items = installed.iterator;
    final result = <ResourceUpdateCandidate>[];
    Future<void> load() async {
      while (items.moveNext()) {
        final package = items.current;
        try {
          final manifest = await astrobox.findUpdateManifest(package.id);
          if (manifest == null || manifest.item.id != package.id) continue;
          if (package.kind == 'watchface'
              ? manifest.item.restype != AstroBoxResourceType.watchface
              : manifest.item.restype != AstroBoxResourceType.quickApp) {
            continue;
          }
          final downloads = manifest.downloads;
          final key = downloads.containsKey(device) ? device : 'default';
          final file = downloads[key];
          final version = file?.versionCode;
          if (file == null ||
              version == null ||
              version <= package.versionCode) {
            continue;
          }
          final resource = ResourceRef(
            source: CommunitySourceId.astroboxRepo,
            id: package.id,
          );
          final requiresPurchase = astroBoxManifestUsesCreatorFeatures(manifest)
              ? (await astrobox.getDetail(resource)).files
                    .any((file) => file.id == key && file.purchaseRequired)
              : manifest.item.paidType == AstroBoxPaidType.forcePaid;
          result.add(
            ResourceUpdateCandidate(
              ref: resource,
              fileId: key,
              package: package,
              name: manifest.item.name,
              version: file.version,
              versionCode: version,
              sha256: file.sha256?.trim().toLowerCase() ?? '',
              purchaseRequired: requiresPurchase,
            ),
          );
        } catch (error, stack) {
          onFailure();
          _log.warning(
            'Unable to check AstroBox resource ${package.id}',
            error,
            stack,
          );
        }
      }
    }

    await Future.wait(List.generate(4, (_) => load()));
    return result;
  }
}
