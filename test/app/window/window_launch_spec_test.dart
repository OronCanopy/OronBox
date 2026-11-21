import 'package:flutter_test/flutter_test.dart';
import 'package:oronbox/src/app/window/window_launch_spec.dart';

void main() {
  test('window role parser isolates secondary window targets', () {
    final debug = WindowLaunchSpec.parse(const ['--window', 'debug']);
    final plugin = WindowLaunchSpec.parse(const [
      '--window',
      'plugin',
      '--plugin-id',
      'reader',
    ]);

    expect(debug.role, OronBoxWindowRole.debug);
    expect(plugin.role, OronBoxWindowRole.plugin);
    expect(plugin.targetId, 'reader');

    final multiWindowDebug = WindowLaunchSpec.parse(const [
      'multi_window',
      '1',
      '{"role":"debug"}',
    ]);
    expect(multiWindowDebug.role, OronBoxWindowRole.debug);
    expect(multiWindowDebug.windowId, '1');

    final multiWindowPlugin = WindowLaunchSpec.parse(const [
      'multi_window',
      '2',
      '{"role":"plugin","targetId":"reader"}',
    ]);
    expect(multiWindowPlugin.role, OronBoxWindowRole.plugin);
    expect(multiWindowPlugin.targetId, 'reader');
    expect(multiWindowPlugin.windowId, '2');
  });
}
