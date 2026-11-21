import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:oronbox/src/core/logging/diagnostic_event.dart';

void main() {
  test('diagnostic records survive JSON serialization', () {
    final record = DiagnosticEvent(
      time: DateTime.utc(2026, 7, 17),
      level: Level.WARNING,
      source: 'Plugin.reader',
      process: DiagnosticProcess.backend,
      pluginId: 'reader',
      runtime: 'js',
      message: 'failed to open file',
      fields: const {'operation': 'file.pick'},
    );

    final restored = DiagnosticEvent.fromJson(record.toJson());
    expect(restored.level, Level.WARNING);
    expect(restored.scope, 'plugin:reader');
    expect(restored.runtime, 'js');
    expect(restored.fields, {'operation': 'file.pick'});
    expect(restored.format(), contains('[plugin:reader]'));
    expect(restored.format(), contains('operation=file.pick'));
  });
}
