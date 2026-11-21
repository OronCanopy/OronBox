import 'dart:ffi';
import 'dart:io';

String releasePlatform() => Platform.operatingSystem;
String releaseArchitecture() {
  final abi = Abi.current().toString();
  if (abi.contains('arm64')) return 'arm64';
  if (abi.contains('x64')) return Platform.isMacOS ? 'x86_64' : 'amd64';
  return '';
}
