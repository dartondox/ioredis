import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:ioredis/ioredis.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  group('disconnect during connect |', () {
    late ServerSocket server;
    late List<Socket> accepted;
    late List<Completer<void>> closed;

    /// Runs when the fake server gets bytes from the client.
    void Function(Socket socket)? onData;

    setUp(() async {
      onData = null;
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      accepted = <Socket>[];
      closed = <Completer<void>>[];
      server.listen((Socket socket) {
        Completer<void> done = Completer<void>();
        accepted.add(socket);
        closed.add(done);
        socket.listen(
          (_) => onData?.call(socket),
          onDone: () {
            done.complete();
            socket.destroy();
          },
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

    /// A long connectTimeout, so a socket that is never closed by the
    /// client stays open for the whole test.
    Redis fakeClient({String? password}) {
      Redis redis = Redis(
        RedisOptions(
          port: server.port,
          password: password,
          connectTimeout: const Duration(seconds: 30),
        ),
      );
      addTearDown(redis.connection.destroy);
      return redis;
    }

    Future<void> waitAccepted() async {
      while (accepted.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    test('closes the socket that arrives after disconnect()', () async {
      Redis redis = fakeClient();
      Future<void> connecting = redis.connection.connect();
      Future<void> disconnecting = redis.connection.disconnect();
      await Future.wait(<Future<void>>[connecting, disconnecting]);

      expect(redis.connection.status, RedisConnectionStatus.disconnected);
      expect(accepted, hasLength(1));
      await closed.single.future.timeout(const Duration(seconds: 2));
    });

    test('closes the socket when disconnect() runs in the handshake', () async {
      // AUTH is sent, and the server never replies.
      Redis redis = fakeClient(password: 'secret');
      Future<void> connecting = redis.connection.connect();
      await waitAccepted();
      onData = null;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      // The server never closes, so do not wait for it: close from the
      // server side after the client has started to close.
      Future<void> disconnecting = redis.connection.disconnect();
      await closed.single.future.timeout(const Duration(seconds: 2));
      await Future.wait(<Future<void>>[connecting, disconnecting]);

      expect(redis.connection.status, RedisConnectionStatus.disconnected);
    });

    test('closes the socket when disconnect() comes before the AUTH reply '
        'is read', () async {
      Redis redis = fakeClient(password: 'secret');
      Future<void>? disconnecting;
      // The reply is sent right after disconnect() starts, so the
      // handshake ends with +OK while the client is disconnecting.
      onData = (Socket socket) {
        disconnecting = redis.connection.disconnect();
        socket.write('+OK\r\n');
      };
      await redis.connection.connect().timeout(const Duration(seconds: 5));
      await disconnecting!.timeout(const Duration(seconds: 5));

      expect(redis.connection.status, RedisConnectionStatus.disconnected);
      await closed.single.future.timeout(const Duration(seconds: 2));
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

    test('a callback that throws does not stop the other one', () async {
      List<Object> errors = <Object>[];
      Redis sub = Redis(
        RedisOptions(
          host: redisHost,
          port: redisPort,
          onError: (dynamic e) => errors.add(e as Object),
        ),
      );
      addTearDown(sub.quit);
      Redis pub = testClient();
      String channel = uniquePrefix('throws');
      RedisSubscriber a = await sub.subscribe(channel);
      RedisSubscriber b = await sub.subscribe(channel);
      Completer<String?> gotB = Completer<String?>();
      a.onMessage = (String c, String? m) => throw StateError('boom');
      b.onMessage = (String c, String? m) => gotB.complete(m);

      await pub.publish(channel, 'hello');

      expect(await gotB.future.timeout(const Duration(seconds: 3)), 'hello');
      expect(errors, hasLength(1));
      expect(errors.single, isA<StateError>());
    });

    test(
      'a throwing pattern callback goes to onError, commands still work',
      () async {
        List<Object> errors = <Object>[];
        Redis sub = Redis(
          RedisOptions(
            host: redisHost,
            port: redisPort,
            onError: (dynamic e) => errors.add(e as Object),
          ),
        );
        addTearDown(sub.quit);
        Redis pub = testClient();
        String channel = uniquePrefix('pthrows');
        RedisSubscriber ps = await sub.psubscribe('$channel*');
        Completer<void> bytesDone = Completer<void>();
        ps.onPatternMessage = (String p, String c, String? m) =>
            throw StateError('boom');
        // The bytes callback of the same subscriber must still run.
        ps.onPatternMessageBytes = (String p, String c, Uint8List m) =>
            bytesDone.complete();

        await pub.publish('${channel}x', 'hello');
        await bytesDone.future.timeout(const Duration(seconds: 3));
        Object reply =
            await sub.connection
                    .sendCommand(<String>['PING'])
                    .timeout(const Duration(seconds: 3))
                as Object;

        expect(reply, isNotNull);
        expect(errors, hasLength(1));
        expect(errors.single, isA<StateError>());
      },
    );
  });
}
