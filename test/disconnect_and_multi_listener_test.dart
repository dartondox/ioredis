import 'dart:async';
import 'dart:io';

import 'package:ioredis/ioredis.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  group('disconnect during connect |', () {
    late ServerSocket server;
    late List<Socket> accepted;
    late List<Completer<void>> closed;

    setUp(() async {
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      accepted = <Socket>[];
      closed = <Completer<void>>[];
      server.listen((Socket socket) {
        Completer<void> done = Completer<void>();
        accepted.add(socket);
        closed.add(done);
        // The fake server never replies. It only watches for the close.
        socket.listen(
          (_) {},
          onDone: done.complete,
          onError: (Object _) => done.complete(),
        );
      });
      addTearDown(() async {
        for (Socket s in accepted) {
          s.destroy();
        }
        await server.close();
      });
    });

    Redis fakeClient() {
      // A short timeout: disconnect() waits for the silent server to close.
      Redis redis = Redis(
        RedisOptions(
          port: server.port,
          connectTimeout: const Duration(seconds: 1),
        ),
      );
      addTearDown(redis.connection.destroy);
      return redis;
    }

    test('closes the socket that arrives after disconnect()', () async {
      Redis redis = fakeClient();
      Future<void> connecting = redis.connection.connect();
      Future<void> disconnecting = redis.connection.disconnect();
      await Future.wait(<Future<void>>[connecting, disconnecting]);

      expect(redis.connection.status, RedisConnectionStatus.disconnected);
      expect(accepted, hasLength(1));
      await closed.single.future.timeout(const Duration(seconds: 3));
    });

    test('closes the socket when disconnect() runs in the handshake', () async {
      Redis redis = fakeClient();
      Future<void> connecting = redis.connection.connect();
      while (accepted.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      // The server does not reply, so the client waits in the handshake.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await redis.connection.disconnect();
      await connecting;

      expect(redis.connection.status, RedisConnectionStatus.disconnected);
      await closed.single.future.timeout(const Duration(seconds: 3));
    });

    test('the client can send a command after that', () async {
      Redis redis = testClient();
      Future<void> connecting = redis.connection.connect();
      Future<void> disconnecting = redis.connection.disconnect();
      await Future.wait(<Future<void>>[connecting, disconnecting]);
      expect(redis.connection.status, RedisConnectionStatus.disconnected);

      expect(await redis.ping(), 'PONG');
      expect(redis.connection.status, RedisConnectionStatus.connected);
    });
  });

  group('two subscribers on one channel |', () {
    test('both get the message', () async {
      Redis sub = testClient();
      Redis pub = testClient();
      String channel = uniquePrefix('multi');
      RedisSubscriber a = await sub.subscribe(channel);
      RedisSubscriber b = await sub.subscribe(channel);
      Completer<String?> gotA = Completer<String?>();
      Completer<String?> gotB = Completer<String?>();
      a.onMessage = (String c, String? m) => gotA.complete(m);
      b.onMessage = (String c, String? m) => gotB.complete(m);

      await pub.publish(channel, 'hello');

      expect(await gotA.future.timeout(const Duration(seconds: 3)), 'hello');
      expect(await gotB.future.timeout(const Duration(seconds: 3)), 'hello');
    });
  });
}
