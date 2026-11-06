import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:ioredis/ioredis.dart';
import 'package:test/test.dart';

/// Close every client right after it connects, like a Redis that restarts.
void _dropClient(Socket client) {
  client.destroy();
}

/// A tiny fake Redis. It answers SELECT with OK and GET with "back".
void _answerClient(Socket client) {
  client.listen((List<int> data) {
    String text = String.fromCharCodes(data);
    if (text.contains('SELECT')) client.write('+OK\r\n');
    if (text.contains('GET')) client.write('\$4\r\nback\r\n');
  }, onError: (Object _) {});
}

/// A socket that fails like a socket the server reset during connect.
/// setOption throws a plain OSError, not a SocketException.
class _ResetSocket implements Socket {
  @override
  bool setOption(SocketOption option, bool enabled) {
    throw OSError('Connection reset by peer', 54);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// A socket that the server closes right after connect, before the
/// handshake sends SELECT.
class _ClosedSocket implements Socket {
  @override
  bool setOption(SocketOption option, bool enabled) => true;

  @override
  Future<dynamic> get done => Completer<dynamic>().future;

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    scheduleMicrotask(onDone!);
    return Stream<Uint8List>.empty().listen(null);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  test('a socket closed before the handshake is retried at once', () async {
    ServerSocket good = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(good.close);
    good.listen(_answerClient);

    Redis redis = Redis(
      RedisOptions(
        port: good.port,
        retryStrategy: (int times) => Duration(milliseconds: 10),
        onError: (dynamic _) {},
      ),
    )..setSocket(_ClosedSocket());

    // Before the fix, SELECT waited for the 10 second handshake timeout.
    expect(await redis.get('x').timeout(Duration(seconds: 2)), 'back');
    redis.connection.destroy();
  });

  test('an OSError during connect is retried, not thrown', () async {
    ServerSocket good = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(good.close);
    good.listen(_answerClient);

    List<Object> reported = <Object>[];
    Redis redis = Redis(
      RedisOptions(
        port: good.port,
        retryStrategy: (int times) => Duration(milliseconds: 10),
        onError: (dynamic e) => reported.add(e as Object),
      ),
    )..setSocket(_ResetSocket());

    // The first socket throws OSError. The retry makes a real socket.
    expect(await redis.get('x').timeout(Duration(seconds: 5)), 'back');
    expect(reported.single, isA<SocketException>());
    redis.connection.destroy();
  });

  test('a server that drops every client does not crash the app', () async {
    ServerSocket bad = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    bad.listen(_dropClient);
    int port = bad.port;

    List<Object> uncaught = <Object>[];
    List<Object> reported = <Object>[];
    Redis redis = Redis(
      RedisOptions(
        port: port,
        retryStrategy: (int times) => Duration(milliseconds: 20),
        onError: (dynamic e) => reported.add(e as Object),
      ),
    );

    Completer<dynamic> result = Completer<dynamic>();
    runZonedGuarded(
      () {
        // It keeps retrying while the server drops it (current design).
        redis.get('x').then(result.complete, onError: result.completeError);
      },
      (Object error, StackTrace _) {
        uncaught.add(error);
      },
    );

    // Let it connect and get dropped many times.
    await Future<void>.delayed(Duration(milliseconds: 500));
    expect(uncaught, isEmpty);
    expect(reported, isNotEmpty);
    expect(result.isCompleted, isFalse);

    // The server comes back on the same port. The waiting command works.
    await bad.close();
    ServerSocket good = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      port,
    );
    addTearDown(good.close);
    good.listen(_answerClient);

    expect(await result.future.timeout(Duration(seconds: 5)), 'back');
    expect(redis.connection.status, RedisConnectionStatus.connected);
    expect(uncaught, isEmpty);
    redis.connection.destroy();
  });
}
