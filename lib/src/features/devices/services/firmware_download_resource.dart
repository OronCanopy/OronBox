import 'package:oronbox/src/data/community/community_source.dart';
import 'package:oronbox/src/features/resources/domain/community_resource.dart';

import 'firmware_catalog.dart';

CommunityResourceDetail firmwareDownloadResource(
  FirmwareRelease release,
  FirmwarePackage package,
  String codename,
) {
  return CommunityResourceDetail(
    ref: ResourceRef(
      source: CommunitySourceId.astroboxRepo,
      id: package.fileName,
    ),
    name: package.fileName,
    type: CommunityResourceType.firmware,
    paidType: CommunityPaidType.free,
    authors: const [],
    supportedDevices: codename.isEmpty ? const {} : {codename},
    content: const CommunityResourceContent(
      format: ResourceContentFormat.plainText,
      value: '',
    ),
    files: [
      CommunityResourceFile(
        id: package.fileName,
        fileName: package.fileName,
        version: release.version,
        downloadUrl: package.downloadUrl,
        size: package.size,
      ),
    ],
    version: release.version,
    summary: release.releaseNotes ?? '',
    canDownload: true,
  );
}
