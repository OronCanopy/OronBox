import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

Future<void> writePluginInstallBytes(String path, Uint8List bytes) async {
  await File(path).writeAsBytes(bytes, flush: true);
}

String pluginHostPlatform() => Platform.operatingSystem;

String pluginHostArchitecture() {
  final abi = Abi.current().toString().toLowerCase();
  if (abi.contains('arm64')) return 'aarch64';
  if (abi.contains('x64')) return 'x86_64';
  if (abi.contains('ia32')) return 'x86';
  if (abi.contains('riscv64')) return 'riscv64';
  if (abi.contains('arm')) return 'arm';
  return abi;
}

String pluginHostVersion() => Platform.operatingSystemVersion;

String pluginHostHostname() => Platform.localHostname;

String pluginHostLocale() => Platform.localeName.replaceAll('_', '-');
