import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const _channel = MethodChannel('org.oroncanopy.oronbox/background_tasks');

bool get _isMobile =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

class BackgroundTaskHandle {
  const BackgroundTaskHandle(this.id);
  final int? id;

  Future<void> end() async {
    if (id == null || !_isMobile) return;
    await _channel.invokeMethod<void>('end', {'id': id});
  }
}

final StreamController<Set<int>> _expirations =
    StreamController<Set<int>>.broadcast(
      onListen: () => _channel.setMethodCallHandler((call) async {
        if (call.method == 'expired') {
          final ids = (call.arguments as Map)['ids'] as List;
          _expirations.add(ids.cast<int>().toSet());
        }
      }),
    );

Stream<Set<int>> get backgroundTaskExpirations =>
    _isMobile ? _expirations.stream : const Stream.empty();

Future<BackgroundTaskHandle> beginBackgroundTask(
  String label, {
  bool plugin = false,
}) async {
  if (!_isMobile) {
    return const BackgroundTaskHandle(null);
  }
  final id = await _channel.invokeMethod<int>(
    plugin ? 'beginPlugin' : 'begin',
    {'label': label},
  );
  return BackgroundTaskHandle(id);
}
