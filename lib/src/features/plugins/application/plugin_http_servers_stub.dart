class PluginHttpServers {
  PluginHttpServers({
    required Future<String> Function(String, List<Object?>) call,
  });
  Future<Object?> handle(String method, List<Object?> args) async =>
      throw UnsupportedError(
        'Local HTTP servers are unavailable on this platform',
      );
  Future<void> close() async {}
}
