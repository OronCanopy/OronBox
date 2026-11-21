import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

final _fixtureDirectory = _resolveFixtureDirectory();

Uint8List readWasmAbpFixture(String name) =>
    File.fromUri(_fixtureDirectory.resolve(name)).readAsBytesSync();

Uri _resolveFixtureDirectory() {
  final config = File('.dart_tool/package_config.json').absolute;
  final json = jsonDecode(config.readAsStringSync()) as Map<String, dynamic>;
  final packages = (json['packages'] as List).cast<Map<String, dynamic>>();
  for (final package in packages) {
    if (package['name'] == 'wasm_abp') {
      final root = config.uri.resolve(package['rootUri'] as String);
      return root.resolve('native/tests/fixtures/');
    }
  }
  throw StateError('The package configuration does not contain wasm_abp');
}
