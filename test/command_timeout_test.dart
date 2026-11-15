import 'dart:async';
import 'dart:io';

import 'package:ioredis/ioredis.dart';
import 'package:test/test.dart';

/// A fake Redis. It answers SELECT with OK. [onCommand] decides the reply
/// for every other chunk: return the reply text, or null for no reply.
class _Server {
  final ServerSocket server;
  final List<Socket> clients = <Socket>[];
  String? Function(String text) onCommand;

  _Server(this.server, this.onCommand) {
    server.listen(_onClient);
  }

  static Future<_Server> start(String? Function(String text) onCommand) async {
    _Server s = _Server(
      await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
      onCommand,
    );
    addTearDown(s.close);
    return s;
  }

  int get port => server.port;

  void _onClient(Socket socket) {
    clients.add(socket);
    socket.listen(
      (List<int> data) {
        String text = String.fromCharCodes(data);
        if (text.contains('SELECT')) {
          socket.write('+OK\r\n');
          return;
        }
        String? reply = onCommand(text);
        if (reply != null) socket.write(reply);
      },
      onError: (Object _) {},
      onDone: socket.destroy,
    );
  }

  Future<void> close() async {
    for (Socket c in clients) {
      c.destroy();
    }
    await server.close();
  }
}

/// A port where nothing listens.
Future<int> _freePort() async {
  ServerSocket s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  int port = s.port;
  await s.close();
  return port;
}

Redis _client(
  int port, {
  Duration? commandTimeout = RedisOptions.defaultCommandTimeout,
  int? maxQueuedCommands = RedisOptions.defaultMaxQueuedCommands,
  Duration connectTimeout = const Duration(seconds: 2),
}) {
  Redis redis = Redis(
    RedisOptions(
      port: port,
      commandTimeout: commandTimeout,
      maxQueuedCommands: maxQueuedCommands,
      connectTimeout: connectTimeout,
      retryStrategy: (int _) => const Duration(milliseconds: 20),
      onError: (dynamic _) {},
    ),
  );
  addTearDown(redis.connection.destroy);
  return redis;
}

const Duration _timeout = Duration(milliseconds: 200);

void main() {
  group('commandTimeout', () {
    test('a command fails when nothing listens on the port', () async {
      Redis redis = _client(await _freePort(), commandTimeout: _timeout);
      Stopwatch watch = Stopwatch()..start();
      Object? error;
      try {
        await redis.set('k', 'secret-value');
      } catch (e) {
        error = e;
      }
      expect(error, isA<RedisTimeoutError>());
      expect(error, isA<RedisError>());
      expect(error.toString(), isNot(contains('secret-value')));
      expect(watch.elapsedMilliseconds, lessThan(1000));
    });

    test('a timed-out command leaves the wait queue', () async {
      // With room for one command, a second one only fits when the first
      // one left the queue.
      Redis redis = _client(
        await _freePort(),
        commandTimeout: _timeout,
        maxQueuedCommands: 1,
      );
      await expectLater(redis.get('a'), throwsA(isA<RedisTimeoutError>()));
      await expectLater(redis.get('b'), throwsA(isA<RedisTimeoutError>()));
      expect(redis.connection.isBusy, isFalse);
    });

    test('a sent command fails when the server never replies', () async {
      _Server server = await _Server.start((String _) => null);
      Redis redis = _client(server.port, commandTimeout: _timeout);
      await redis.connect();
      Future<dynamic> a = redis.get('a');
      Future<dynamic> b = redis.get('b');
      await expectLater(a, throwsA(isA<RedisTimeoutError>()));
      await expectLater(b, throwsA(isA<RedisTimeoutError>()));
      expect(redis.connection.isBusy, isFalse);
    });

    test('a server that never answers the handshake', () async {
      ServerSocket silent = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      List<Socket> sockets = <Socket>[];
      silent.listen(sockets.add);
      addTearDown(() async {
        for (Socket s in sockets) {
          s.destroy();
        }
        await silent.close();
      });
      Redis redis = _client(silent.port, commandTimeout: _timeout);
      await expectLater(redis.get('a'), throwsA(isA<RedisTimeoutError>()));
    });

    test('commands work again after the server answers again', () async {
      bool answer = false;
      _Server server = await _Server.start(
        (String _) => answer ? '\$4\r\nback\r\n' : null,
      );
      Redis redis = _client(server.port, commandTimeout: _timeout);
      await expectLater(redis.get('a'), throwsA(isA<RedisTimeoutError>()));
      answer = true;
      expect(await redis.get('a'), 'back');
      // The timed-out connection was dropped, then a new one was made.
      expect(server.clients.length, 2);
    });

    test('a late reply does not go to the next command', () async {
      int calls = 0;
      late _Server server;
      server = await _Server.start((String _) {
        calls++;
        if (calls == 1) {
          Socket first = server.clients.last;
          Timer(const Duration(milliseconds: 400), () {
            // The client closed this socket, so the write may fail.
            try {
              first.write('\$4\r\nlate\r\n');
            } catch (_) {}
          });
          return null;
        }
        return '\$4\r\nnext\r\n';
      });
      Redis redis = _client(server.port, commandTimeout: _timeout);
      await expectLater(redis.get('a'), throwsA(isA<RedisTimeoutError>()));
      expect(await redis.get('b'), 'next');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(await redis.get('c'), 'next');
    });

    test('a MULTI batch fails once, as a whole', () async {
      _Server server = await _Server.start((String _) => null);
      Redis redis = _client(server.port, commandTimeout: _timeout);
      await expectLater(
        redis.multi().set('a', '1').incr('b').exec(),
        throwsA(isA<RedisTimeoutError>()),
      );
      await expectLater(
        redis.pipeline().get('a').get('b').exec(),
        throwsA(isA<RedisTimeoutError>()),
      );
    });

    test('blocking commands are not timed out', () async {
      late _Server server;
      server = await _Server.start((String text) {
        Socket client = server.clients.last;
        Timer(const Duration(milliseconds: 400), () {
          client.write(':1\r\n');
        });
        return null;
      });
      Redis redis = _client(server.port, commandTimeout: _timeout);
      await redis.connect();
      List<List<String>> commands = <List<String>>[
        <String>['BLPOP', 'q', '0'],
        <String>['BRPOP', 'q', '0'],
        <String>['BLMOVE', 'a', 'b', 'LEFT', 'RIGHT', '0'],
        <String>['BZPOPMIN', 'z', '0'],
        <String>['XREAD', 'BLOCK', '0', 'STREAMS', 's', r'$'],
        <String>['WAIT', '1', '0'],
      ];
      for (List<String> c in commands) {
        expect(await redis.connection.sendCommand(c), 1, reason: c.first);
      }
      // Nothing was dropped.
      expect(server.clients.length, 1);
      // XREAD without BLOCK is a normal command, so it times out.
      await expectLater(
        redis.connection.sendCommand(<String>['XREAD', 'STREAMS', 's', '0']),
        throwsA(isA<RedisTimeoutError>()),
      );
    });

    test('a slow but healthy command works under the default', () async {
      late _Server server;
      server = await _Server.start((String text) {
        Socket client = server.clients.last;
        Timer(const Duration(milliseconds: 500), () {
          client.write('\$4\r\nslow\r\n');
        });
        return null;
      });
      Redis redis = _client(server.port);
      expect(await redis.get('a'), 'slow');
    });

    for (String kind in <String>['SUBSCRIBE', 'PSUBSCRIBE']) {
      test('a $kind connection is never timed out', () async {
        bool pattern = kind == 'PSUBSCRIBE';
        late _Server server;
        server = await _Server.start((String text) {
          if (!text.contains(kind)) return null;
          Socket client = server.clients.last;
          // The subscribe reply itself comes after the timeout.
          Timer(const Duration(milliseconds: 400), () {
            client.write(
              pattern
                  ? '*3\r\n\$10\r\npsubscribe\r\n\$3\r\nch*\r\n:1\r\n'
                  : '*3\r\n\$9\r\nsubscribe\r\n\$2\r\nch\r\n:1\r\n',
            );
          });
          Timer(const Duration(milliseconds: 800), () {
            client.write(
              pattern
                  ? '*4\r\n\$8\r\npmessage\r\n\$3\r\nch*\r\n\$2\r\nch\r\n\$2\r\nhi\r\n'
                  : '*3\r\n\$7\r\nmessage\r\n\$2\r\nch\r\n\$2\r\nhi\r\n',
            );
          });
          return null;
        });
        Redis redis = _client(server.port, commandTimeout: _timeout);
        RedisSubscriber sub = pattern
            ? await redis.psubscribe('ch*')
            : await redis.subscribe('ch');
        Completer<String?> got = Completer<String?>();
        sub.onMessage = (String channel, String? message) {
          got.complete(message);
        };
        expect(await got.future, 'hi');
        expect(server.clients.length, 1);
      });
    }
  });

  group('maxQueuedCommands', () {
    test('refuses a command when the queue is full', () async {
      Redis redis = _client(await _freePort(), maxQueuedCommands: 2);
      Future<dynamic> a = redis.get('a');
      Future<dynamic> b = redis.get('b');
      await expectLater(redis.get('c'), throwsA(isA<RedisQueueFullError>()));
      // The two queued ones still wait. disconnect() fails them.
      await redis.disconnect();
      await expectLater(a, throwsA(isA<SocketException>()));
      await expectLater(b, throwsA(isA<SocketException>()));
    });
  });

  group('defaults', () {
    test('limits are on by default', () {
      RedisOptions o = RedisOptions();
      expect(o.commandTimeout, const Duration(seconds: 10));
      expect(o.maxQueuedCommands, 10000);
      RedisOptions u = RedisOptions.fromUrl('redis://localhost');
      expect(u.commandTimeout, const Duration(seconds: 10));
      expect(u.maxQueuedCommands, 10000);
    });

    for (Duration? off in <Duration?>[null, Duration.zero]) {
      test('commandTimeout $off turns it off', () async {
        Redis redis = _client(
          await _freePort(),
          commandTimeout: off,
          maxQueuedCommands: null,
        );
        bool done = false;
        Future<dynamic> a = redis.get('a').whenComplete(() => done = true);
        await Future<void>.delayed(const Duration(milliseconds: 500));
        expect(done, isFalse);
        await redis.disconnect();
        await expectLater(a, throwsA(isA<SocketException>()));
      });
    }
  });

  group('bad bytes from the server', () {
    test('drop the connection instead of crashing', () async {
      int calls = 0;
      _Server server = await _Server.start((String _) {
        calls++;
        return calls == 1 ? '!bad\r\n' : '\$4\r\nback\r\n';
      });
      Redis redis = _client(server.port);
      await expectLater(
        redis.get('a'),
        throwsA(
          isA<SocketException>().having(
            (SocketException e) => e.message,
            'message',
            contains('Bad reply'),
          ),
        ),
      );
      expect(await redis.get('a'), 'back');
    });
  });
}
