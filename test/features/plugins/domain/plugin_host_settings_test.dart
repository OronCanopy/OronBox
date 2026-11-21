import 'package:flutter_test/flutter_test.dart';
import 'package:oronbox/src/features/plugins/domain/plugin_host_settings.dart';

void main() {
  test('legacy explicit background choices retain their intent', () {
    expect(
      PluginHostSettings.fromJson({'background': true}).background,
      PluginBackgroundMode.continuous,
    );
    expect(
      PluginHostSettings.fromJson({'background': false}).background,
      PluginBackgroundMode.forbidden,
    );
  });

  test('all background modes survive serialization', () {
    for (final mode in PluginBackgroundMode.values) {
      final settings = PluginHostSettings(background: mode, autoStart: true);
      final restored = PluginHostSettings.fromJson(settings.toJson());
      expect(restored.background, mode);
      expect(restored.autoStart, true);
    }
  });
}
