import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:oronbox/src/core/logging/logging_service.dart';
import 'package:oronbox/src/core/network/dio_provider.dart';
import 'package:oronbox/src/core/network/github_release.dart';
import 'package:oronbox/src/core/network/oronbox_metadata_client.dart';
import 'package:oronbox/src/device/core/device_kind.dart';
import 'package:oronbox/src/device/xiaomi/xiaomi_device_catalog.dart';

class FirmwareCatalogQuery {
  const FirmwareCatalogQuery({
    required this.kind,
    required this.codename,
    required this.model,
    required this.currentVersion,
    this.productDevice,
  });

  final DeviceKind kind;
  final String? codename;
  final String model;
  final String currentVersion;
  final String? productDevice;
}

class FirmwareRelease {
  const FirmwareRelease({
    required this.version,
    required this.fullPackage,
    required this.product,
    this.incrementalPackages = const [],
    this.releaseNotes,
  });

  final String version;
  final String product;
  final FirmwarePackage fullPackage;
  final List<FirmwarePackage> incrementalPackages;
  final String? releaseNotes;

  // Keep the full-package accessors convenient for callers that do not need
  // to choose between package types (for example, a manual full download).
  Uri get downloadUrl => fullPackage.downloadUrl;
  String get fileName => fullPackage.fileName;
  int? get size => fullPackage.size;
  String? get sha256 => fullPackage.sha256;

  FirmwarePackage packageFor(String currentVersion) {
    final normalized = normalizeFirmwareVersion(currentVersion);
    if (normalized.isEmpty) return fullPackage;
    return incrementalPackages.firstWhere(
      (package) =>
          normalizeFirmwareVersion(package.fromVersion ?? '') == normalized,
      orElse: () => fullPackage,
    );
  }
}

class FirmwarePackage {
  const FirmwarePackage({
    required this.downloadUrl,
    required this.fileName,
    this.size,
    this.sha256,
    this.fromVersion,
  });

  final Uri downloadUrl;
  final String fileName;
  final int? size;
  final String? sha256;

  /// The source firmware version for an incremental package. A full package
  /// has no source version.
  final String? fromVersion;

  bool get isIncremental => fromVersion != null;
}

abstract interface class FirmwareCatalog {
  Future<List<FirmwareRelease>> findUpdates(FirmwareCatalogQuery query);
}

class FirmwareCatalogUnavailable implements Exception {
  const FirmwareCatalogUnavailable();
}

class DeviceFirmwareCatalog implements FirmwareCatalog {
  DeviceFirmwareCatalog(Dio dio) : _metadata = OronBoxMetadataClient(dio);

  static final _log = getLogger('DeviceFirmwareCatalog');

  final OronBoxMetadataClient _metadata;

  @override
  Future<List<FirmwareRelease>> findUpdates(FirmwareCatalogQuery query) async {
    if (query.kind == DeviceKind.zepp) {
      // TODO(collaborator): Provide a ZeppOS firmware catalog implementation.
      throw const FirmwareCatalogUnavailable();
    }

    final products = _resolveProducts(query);
    _log.info(
      'firmware lookup model="${query.model}" productDevice="${query.productDevice ?? ''}" '
      'codename="${query.codename ?? ''}" products=${products.join(',')}',
    );
    if (products.isEmpty) return const [];
    for (var page = 1; ; page++) {
      final payload = jsonDecode(
        await _metadata.get('firmware/xiaomi/catalog?page=$page'),
      ) as Map<String, dynamic>;
      final releases = _matchingReleases(payload['releases'] as List, products);
      if (releases.isNotEmpty || payload['has_next'] != true) return releases;
    }
  }

  List<FirmwareRelease> _matchingReleases(
    List rawReleases,
    List<String> products,
  ) {
    final releasesByProduct = <String, List<FirmwareRelease>>{};
    for (final raw in rawReleases) {
      if (raw is! Map) continue;
      final release = GitHubRelease.fromJson(raw.cast<String, Object?>());
      final name = release.name;
      final parts = name.split(RegExp(r'\s+'));
      final product = parts.first.toLowerCase();
      if (parts.length < 2 || !products.contains(product)) continue;
      final version = normalizeFirmwareVersion(parts[1]);
      if (version.isEmpty) continue;

      final assets = release.assets
          .where((asset) => asset.name.toLowerCase().endsWith('.bin'))
          .toList(growable: false);
      final fullAsset = _selectFullAsset(assets);
      final fullPackage = _packageFromAsset(fullAsset);
      if (fullPackage == null) continue;
      final incrementalPackages = assets
          .map(_incrementalPackageFromAsset)
          .whereType<FirmwarePackage>()
          .toList(growable: false);
      releasesByProduct
          .putIfAbsent(product, () => [])
          .add(
            FirmwareRelease(
              version: version,
              fullPackage: fullPackage,
              product: product,
              incrementalPackages: incrementalPackages,
              releaseNotes: release.body,
            ),
          );
    }
    for (final product in products) {
      final releases = releasesByProduct[product];
      if (releases == null || releases.isEmpty) continue;
      releases.sort((a, b) => compareFirmwareVersions(b.version, a.version));
      return releases;
    }
    return const [];
  }

  List<String> _resolveProducts(FirmwareCatalogQuery query) {
    final registered = XiaomiDeviceCatalog.instance.find(
      model: query.model,
      product: query.productDevice,
    );
    if (registered != null && registered.product.isNotEmpty) {
      return [registered.product.trim().toLowerCase()];
    }

    final productDevice = query.productDevice?.trim().toLowerCase() ?? '';
    if (productDevice.contains('.watch.')) return [productDevice];
    final model = query.model.trim().toLowerCase();
    if (model.contains('.watch.')) return [model];
    final codename = query.codename?.trim().toLowerCase();
    if (codename == null || codename.isEmpty) return const [];
    if (codename.contains('.watch.')) return [codename];
    final identity = xiaomiWearableIdentityForCodename(codename);
    return (identity?.aliases ?? const <String>[])
        .map((alias) => alias.trim().toLowerCase())
        .where((alias) => alias.contains('.watch.'))
        .toSet()
        .toList(growable: false);
  }

  GitHubReleaseAsset? _selectFullAsset(List<GitHubReleaseAsset> assets) {
    for (final asset in assets) {
      if (asset.name.toLowerCase().contains('_full_')) {
        return asset;
      }
    }
    return null;
  }

  FirmwarePackage? _packageFromAsset(GitHubReleaseAsset? asset) {
    if (asset == null) return null;
    final downloadUrl = Uri.tryParse(asset.downloadUrl);
    if (downloadUrl == null) return null;
    return FirmwarePackage(
      downloadUrl: downloadUrl,
      fileName: asset.name,
      size: asset.size,
      sha256: asset.digest?.replaceFirst('sha256:', ''),
    );
  }

  FirmwarePackage? _incrementalPackageFromAsset(GitHubReleaseAsset asset) {
    final fromVersion = _incrementalSourceVersion(asset.name);
    if (fromVersion == null) return null;
    final package = _packageFromAsset(asset);
    if (package == null) return null;
    return FirmwarePackage(
      downloadUrl: package.downloadUrl,
      fileName: package.fileName,
      size: package.size,
      sha256: package.sha256,
      fromVersion: fromVersion,
    );
  }

  String? _incrementalSourceVersion(String fileName) {
    final match = RegExp(
      r'_from_v([^_]+)_incremental_',
      caseSensitive: false,
    ).firstMatch(fileName);
    if (match == null) return null;
    final version = normalizeFirmwareVersion(match.group(1) ?? '');
    return version.isEmpty ? null : version;
  }
}

int compareFirmwareVersions(String left, String right) {
  final a = normalizeFirmwareVersion(left)
      .split('.')
      .map((part) => int.tryParse(part) ?? 0)
      .toList();
  final b = normalizeFirmwareVersion(right)
      .split('.')
      .map((part) => int.tryParse(part) ?? 0)
      .toList();
  final length = a.length > b.length ? a.length : b.length;
  for (var index = 0; index < length; index++) {
    final result = (index < a.length ? a[index] : 0).compareTo(
      index < b.length ? b[index] : 0,
    );
    if (result != 0) return result;
  }
  return 0;
}

String normalizeFirmwareVersion(String value) => value
    .trim()
    .toLowerCase()
    .replaceFirst(RegExp(r'^v'), '')
    .split(RegExp(r'[^0-9.]'))
    .first;

final firmwareCatalogProvider = Provider<FirmwareCatalog>(
  (ref) => DeviceFirmwareCatalog(ref.watch(appDioProvider)),
);
