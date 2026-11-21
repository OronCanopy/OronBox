class PluginWebSockets {
  PluginWebSockets({required Future<void> Function(String, String) emit});

  Future<Object?> handle(String method, List<Object?> args) async =>
      throw UnsupportedError('platform_capability_unavailable: WebSocket');

  Future<void> close() async {}
}
