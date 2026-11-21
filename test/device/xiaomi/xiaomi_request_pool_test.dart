import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:oronbox/src/device/xiaomi/protocol/generated/wear.pb.dart'
    as pb;
import 'package:oronbox/src/device/xiaomi/protocol/commands/xiaomi_request_pool.dart';

void main() {
  test(
    'clearing the pool isolates old cleanup from a new owner of the same key',
    () async {
      final pool = XiaomiRequestPool(sendPacket: (_) async {});
      final cancel = StreamController<void>.broadcast(sync: true);
      final packet = pb.WearPacket(type: pb.WearPacket_Type.SYSTEM, id: 1);
      Future<int> request() => pool.request<int>(
        packet: packet,
        typeMatcher: (_) => true,
        responseMapper: (value) => value.id,
        cancellation: cancel.stream,
      );
      final first = request();
      final cleared = expectLater(first, throwsA(isA<Exception>()));
      pool.clear();
      final replacement = request();
      await cleared;
      pool.onPacket(packet);
      expect(await replacement.timeout(const Duration(milliseconds: 100)), 1);
      await cancel.close();
    },
  );

  test(
    'protobuf plugin requests match type and ID and reject a concurrent owner',
    () async {
      final pool = XiaomiRequestPool(sendPacket: (_) async {});
      final cancel = StreamController<void>.broadcast(sync: true);
      final request = pb.WearPacket(type: pb.WearPacket_Type.SYSTEM, id: 1);
      var completed = false;
      final result = pool
          .request<pb.WearPacket>(
            packet: request,
            typeMatcher: (response) =>
                response.type == request.type && response.id == request.id,
            responseMapper: (response) => response,
            cancellation: cancel.stream,
          )
          .then((value) {
            completed = true;
            return value;
          });
      await expectLater(
        pool.request<int>(
          packet: request,
          typeMatcher: (_) => true,
          responseMapper: (_) => 0,
          cancellation: cancel.stream,
        ),
        throwsA(isA<Exception>()),
      );
      pool.onPacket(pb.WearPacket(type: pb.WearPacket_Type.MASS, id: 1));
      pool.onPacket(pb.WearPacket(type: pb.WearPacket_Type.SYSTEM, id: 2));
      await Future<void>.delayed(Duration.zero);
      expect(completed, false);
      pool.onPacket(request);
      expect((await result).writeToBuffer(), request.writeToBuffer());
      expect(cancel.hasListener, false);
      await cancel.close();
      pool.clear();
    },
  );

  test('routes one response to only one matching request', () async {
    final pool = XiaomiRequestPool(sendPacket: (_) async {});
    final request = pb.WearPacket(type: pb.WearPacket_Type.MASS, id: 1);

    Future<int> sendRequest() => pool.request<int>(
      packet: request,
      typeMatcher: (_) => true,
      responseMapper: (packet) => packet.id,
    );

    final first = sendRequest();
    final second = sendRequest();
    await Future<void>.delayed(Duration.zero);

    pool.onPacket(pb.WearPacket(type: pb.WearPacket_Type.MASS, id: 42));

    expect(await first, 42);
    final secondResult = second
        .then<int?>((value) => value)
        .catchError((_) => null);
    expect(
      await secondResult.timeout(
        const Duration(milliseconds: 20),
        onTimeout: () => -1,
      ),
      -1,
    );

    pool.clear();
    await secondResult;
  });

  test(
    'cancelling a plugin request discards its late response before key reuse',
    () async {
      final pool = XiaomiRequestPool(sendPacket: (_) async {});
      final cancel = StreamController<void>.broadcast(sync: true);
      final packet = pb.WearPacket(type: pb.WearPacket_Type.SYSTEM, id: 1);
      final first = pool.request<int>(
        packet: packet,
        typeMatcher: (_) => true,
        responseMapper: (value) => value.id,
        cancellation: cancel.stream,
      );
      final cancelled = expectLater(first, throwsA(isA<Exception>()));
      cancel.add(null);
      await cancelled;
      await cancel.close();
      await expectLater(
        pool.request<int>(
          packet: packet,
          typeMatcher: (_) => true,
          responseMapper: (value) => value.id,
        ),
        throwsA(isA<Exception>()),
      );
      pool.onPacket(packet);
      final second = pool.request<int>(
        packet: packet,
        typeMatcher: (_) => true,
        responseMapper: (value) => value.id,
      );
      await Future<void>.delayed(Duration.zero);
      pool.onPacket(pb.WearPacket(type: pb.WearPacket_Type.SYSTEM, id: 42));
      expect(await second, 42);
    },
  );

  test(
    'plugin cancellation completes while the transport send is pending',
    () async {
      final sent = Completer<void>();
      final cancel = StreamController<void>.broadcast(sync: true);
      final pool = XiaomiRequestPool(sendPacket: (_) => sent.future);
      final result = pool.request<int>(
        packet: pb.WearPacket(type: pb.WearPacket_Type.SYSTEM, id: 1),
        typeMatcher: (_) => true,
        responseMapper: (packet) => packet.id,
        cancellation: cancel.stream,
      );
      final cancelled = expectLater(
        result.timeout(const Duration(milliseconds: 100)),
        throwsA(isNot(isA<TimeoutException>())),
      );
      cancel.add(null);
      try {
        await cancelled;
        expect(cancel.hasListener, false);
      } finally {
        sent.complete();
        pool.clear();
        await cancel.close();
      }
    },
  );

  test('removes a slot when sending the request fails', () async {
    var fail = true;
    final pool = XiaomiRequestPool(
      sendPacket: (_) async {
        if (fail) {
          fail = false;
          throw StateError('send failed');
        }
      },
    );
    final packet = pb.WearPacket(type: pb.WearPacket_Type.MASS, id: 1);

    await expectLater(
      pool.request<int>(
        packet: packet,
        typeMatcher: (_) => true,
        responseMapper: (value) => value.id,
      ),
      throwsA(isA<StateError>()),
    );

    final next = pool.request<int>(
      packet: packet,
      typeMatcher: (_) => true,
      responseMapper: (value) => value.id,
    );
    await Future<void>.delayed(Duration.zero);
    pool.onPacket(pb.WearPacket(type: pb.WearPacket_Type.MASS, id: 42));

    expect(await next, 42);
  });
}
