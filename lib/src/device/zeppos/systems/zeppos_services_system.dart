import 'dart:async';
import 'dart:typed_data';

import 'package:oronbox/src/device/core/system.dart';
import 'package:oronbox/src/device/zeppos/zeppos_device_component.dart';

class ZeppOsServicesSystem extends System {
  static const endpoint = 0x0000;
  static const _getList = 0x03;
  static const _returnList = 0x04;

  Completer<Map<int, bool>>? _pending;
  Map<int, bool>? _services;

  Map<int, bool>? get supportedServices => _services;

  Future<Map<int, bool>> fetchSupportedServices() async {
    final cached = _services;
    if (cached != null) return cached;
    if (_pending != null) return _pending!.future;
    final completer = Completer<Map<int, bool>>();
    _pending = completer;
    try {
      await entity.getRequired<ZeppOsDeviceComponent>().sendToEndpoint(
        endpoint,
        Uint8List.fromList(const [_getList]),
      );
      return await completer.future.timeout(const Duration(seconds: 8));
    } finally {
      if (identical(_pending, completer)) _pending = null;
    }
  }

  void handlePayload(Uint8List payload) {
    if (payload.length < 3 || payload[0] != _returnList) return;
    final count = payload[1] | (payload[2] << 8);
    if (payload.length < 3 + count * 3) return;
    final services = <int, bool>{};
    var offset = 3;
    for (var i = 0; i < count; i += 1) {
      final endpoint = payload[offset] | (payload[offset + 1] << 8);
      services[endpoint] = payload[offset + 2] == 1;
      offset += 3;
    }
    _services = Map.unmodifiable(services);
    final pending = _pending;
    if (pending != null && !pending.isCompleted) pending.complete(_services!);
  }

  @override
  void onData(Uint8List data) {}
}
