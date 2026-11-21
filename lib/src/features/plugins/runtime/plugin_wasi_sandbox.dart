import 'package:oronbox/src/features/plugins/storage/plugin_storage.dart';

Future<Map<String, String>> createPluginWasiPreopens({
  required String pluginId,
  required PluginStorage storage,
}) async {
  const writableRoots = ['/data', '/cache', '/temp'];
  if (storage.nativePath(pluginId, PluginStoragePath.parse('/data')) == null) {
    return {};
  }
  for (final root in writableRoots) {
    await storage.createDirectory(pluginId, PluginStoragePath.parse(root));
  }
  return {
    for (final root in ['/plugin', ...writableRoots])
      root: storage.nativePath(pluginId, PluginStoragePath.parse(root))!,
  };
}
