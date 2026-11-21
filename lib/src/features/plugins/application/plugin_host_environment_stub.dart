import 'dart:ui';
import 'dart:typed_data';

Future<void> writePluginInstallBytes(String path, Uint8List bytes) async =>
    throw UnsupportedError(
      'platform_capability_unavailable: Native install files',
    );

String pluginHostPlatform() => 'web';

String pluginHostArchitecture() => 'unknown';

String pluginHostVersion() => 'unknown';

String pluginHostHostname() => 'unknown';

String pluginHostLocale() => PlatformDispatcher.instance.locale.toString();
