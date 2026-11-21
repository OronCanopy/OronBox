import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:oronbox/src/device/core/phone_notification.dart';
import 'package:oronbox/src/device/core/system.dart';
import 'package:oronbox/src/device/zeppos/zeppos_device_component.dart';

import 'zeppos_services_system.dart';

class ZeppOsNotificationSystem extends System {
  static const endpoint = 0x001e;
  ({int version, bool pictures, bool key})? _capabilities;
  Completer<({int version, bool pictures, bool key})?>? _pending;
  bool _unsupported = false;

  Future<bool> send(PhoneNotification item, {required bool removed}) async {
    if (_unsupported) return false;
    final capabilities = _capabilities ?? await _loadCapabilities();
    if (capabilities == null || entity.isDisposed) return false;
    final header = ByteData(7)
      ..setUint8(0, 0x03)
      ..setUint32(1, item.id, Endian.little)
      ..setUint8(5, 0xfa)
      ..setUint8(6, removed ? 0x02 : 0x00);
    final packet = BytesBuilder()..add(header.buffer.asUint8List());
    if (removed) {
      packet.add(Uint8List(5));
    } else {
      final body = String.fromCharCodes(item.body.runes.take(512));
      for (final part in [item.package, item.title, body, item.appName]) {
        packet.add(utf8.encode(part.replaceAll('\u0000', '')));
        packet.addByte(0);
      }
      packet.addByte(0);
      if (capabilities.version >= 5) packet.addByte(0);
      if (capabilities.pictures) packet.addByte(0);
      if (capabilities.key) {
        packet.add(utf8.encode(item.key.replaceAll('\u0000', '')));
        packet.addByte(0);
      }
    }
    await _write(packet.takeBytes());
    return true;
  }

  Future<({int version, bool pictures, bool key})?> _loadCapabilities() async {
    if (_pending case final pending?) return pending.future;
    final completer = _pending =
        Completer<({int version, bool pictures, bool key})?>();
    try {
      final services = await entity
          .system<ZeppOsServicesSystem>()
          ?.fetchSupportedServices();
      if (services == null || !services.containsKey(endpoint)) {
        _unsupported = true;
        completer.complete(null);
        return null;
      }
      await _write(Uint8List.fromList(const [0x01]));
      return await completer.future.timeout(
        const Duration(seconds: 4),
        onTimeout: () {
          if (!completer.isCompleted) completer.complete(null);
          return null;
        },
      );
    } finally {
      if (!completer.isCompleted) completer.complete(null);
      _pending = null;
    }
  }

  Future<void> _write(Uint8List bytes) => entity
      .getRequired<ZeppOsDeviceComponent>()
      .sendToEndpoint(endpoint, bytes, encrypted: true);

  void handlePayload(Uint8List data) {
    if (data.length < 2 || data.first != 0x02) return;
    final version = data[1];
    if (version < 4 || data.length < 6) return;
    var offset = 6;
    if (data[5] != 0) {
      if (data.length < 8) return;
      offset = 8 + (data[6] | (data[7] << 8));
    }
    if (data.length < offset || (version >= 5 && data.length < offset + 2)) {
      return;
    }
    _capabilities = (
      version: version,
      pictures: version >= 5 && data[offset] != 0,
      key: version >= 5 && data[offset + 1] != 0,
    );
    final pending = _pending;
    if (pending != null && !pending.isCompleted) {
      pending.complete(_capabilities);
    }
  }

  @override
  Future<void> dispose() async {
    final pending = _pending;
    if (pending != null && !pending.isCompleted) pending.complete(null);
    await super.dispose();
  }

  @override
  void onData(Uint8List data) {}
}
