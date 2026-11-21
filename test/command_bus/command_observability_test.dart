import 'package:flutter_test/flutter_test.dart';
import 'package:oronbox/src/command_bus/command_observability.dart';

void main() {
  test('command log summaries exclude credentials and payload content', () {
    expect(
      safeCommandLogParams({
        'resource': 'resource-id',
        'fileName': '/private/path/preview.png',
        'bytes': [1, 2, 3],
        'accessToken': 'secret-token',
        'authkey': 'secret-authkey',
        'description': 'private creator content',
      }),
      {'resource': 'resource-id', 'fileName': 'preview.png'},
    );
    expect(
      safeCommandLogParams({
        'command': {
          'method': 'creator.upload',
          'params': {
            'bytes': [1, 2, 3],
            'path': '/private/file',
          },
        },
      }),
      {'command': 'creator.upload'},
    );
  });
}
