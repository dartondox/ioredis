import 'dart:async';
import 'dart:convert';
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

/// A socket the test controls. It answers SELECT with OK and nothing
/// else, so a GET waits. The test fails it like Dart does on a reset.
class _FakeSocket implements Socket {
  final StreamController<Uint8List> input = StreamController<Uint8List>();
  final Completer<dynamic> _done = Completer<dynamic>();

  /// When false, SELECT gets no answer, so the handshake waits.
  final bool answerSelect;

  _FakeSocket({this.answerSelect = true});

  /// A failed write: Dart reports it on socket.done.
  void failWrite(Object error) => _done.completeError(error);

  /// A failed read: Dart reports it on the stream, then ends the stream.
  void failRead(Object error) {
    input.addError(error);
    input.close();
  }

  @override
  bool setOption(SocketOption option, bool enabled) => true;

  @override
  Future<dynamic> get done => _done.future;

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return input.stream.listen(onData, onError: onError, onDone: onDone);
  }

  @override
  void add(List<int> data) {
    if (answerSelect && utf8.decode(data).contains('SELECT')) {
      input.add(Uint8List.fromList(utf8.encode('+OK\r\n')));
    }
  }

  @override
  void destroy() {
    if (!input.isClosed) input.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// A fake socket like a mock with no `done`: it gives null.
class _NoDoneSocket extends _FakeSocket {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;

  @override
  Future<dynamic> get done => noSuchMethod(Invocation.getter(#done));
}

/// A fake socket whose `done` throws, like a mock with no stub.
class _ThrowingDoneSocket extends _FakeSocket {
  @override
  Future<dynamic> get done =>
      throw NoSuchMethodError.withInvocation(this, Invocation.getter(#done));
}

/// A Redis client on [socket]. A reconnect goes to [good].
Redis _fakeClient(Socket socket, ServerSocket good, List<Object> reported) {
  return Redis(
    RedisOptions(
      port: good.port,
      retryStrategy: (int times) => Duration(milliseconds: 10),
      onError: (dynamic e) => reported.add(e as Object),
    ),
  )..setSocket(socket);
}

Future<ServerSocket> _goodServer() async {
  ServerSocket good = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(good.close);
  good.listen(_answerClient);
  return good;
}

void main() {
  group('one socket failure calls onError once', () {
    SocketException reset = SocketException('Connection reset by peer');

    test('a failed write after connect', () async {
      List<Object> reported = <Object>[];
      _FakeSocket socket = _FakeSocket();
      Redis redis = _fakeClient(socket, await _goodServer(), reported);
      await redis.connect();
      Future<dynamic> get = redis.get('x');
      await Future<void>.delayed(Duration(milliseconds: 20));
      socket.failWrite(reset);
      await expectLater(get, throwsA(same(reset)));
      await Future<void>.delayed(Duration(milliseconds: 200));
      expect(reported, <Object>[same(reset)]);
      expect(await redis.get('x'), 'back', reason: 'reconnected');
      redis.connection.destroy();
    });

    test('a failed read and write after connect', () async {
      List<Object> reported = <Object>[];
      _FakeSocket socket = _FakeSocket();
      Redis redis = _fakeClient(socket, await _goodServer(), reported);
      await redis.connect();
      Future<dynamic> get = redis.get('x');
      await Future<void>.delayed(Duration(milliseconds: 20));
      socket.failWrite(reset);
      socket.failRead(reset);
      await expectLater(get, throwsA(same(reset)));
      await Future<void>.delayed(Duration(milliseconds: 200));
      expect(reported, <Object>[same(reset)]);
      redis.connection.destroy();
    });

    test('a failed write during the handshake', () async {
      List<Object> reported = <Object>[];
      _FakeSocket socket = _FakeSocket(answerSelect: false);
      Redis redis = _fakeClient(socket, await _goodServer(), reported);
      Future<dynamic> get = redis.get('x');
      await Future<void>.delayed(Duration(milliseconds: 20));
      socket.failWrite(reset);
      expect(await get.timeout(Duration(seconds: 2)), 'back');
      expect(reported, hasLength(1));
      expect(reported.single, isA<SocketException>());
      redis.connection.destroy();
    });
  });

  test('setSocket on a connected connection watches the new socket', () async {
    // The test fails on any uncaught error, like an unwatched socket.done.
    List<Object> reported = <Object>[];
    _FakeSocket second = _FakeSocket();
    Redis redis = _fakeClient(_FakeSocket(), await _goodServer(), reported);
    await redis.connect();
    redis.setSocket(second);
    // the next command runs on the new socket, after its handshake
    Future<dynamic> get = redis.get('x');
    await Future<void>.delayed(Duration(milliseconds: 20));
    SocketException reset = SocketException('Connection reset by peer');
    second.failWrite(reset);
    await expectLater(get.timeout(Duration(seconds: 2)), throwsA(same(reset)));
    await Future<void>.delayed(Duration(milliseconds: 100));
    expect(reported, <Object>[same(reset)]);
    expect(await redis.get('x'), 'back', reason: 'reconnected');
    redis.connection.destroy();
  });

  test('setSocket with the socket in use keeps the connection', () async {
    List<Object> reported = <Object>[];
    _FakeSocket socket = _FakeSocket();
    Redis redis = _fakeClient(socket, await _goodServer(), reported);
    await redis.connect();
    redis.setSocket(socket);
    expect(redis.connection.status, RedisConnectionStatus.connected);
    await Future<void>.delayed(Duration(milliseconds: 50));
    expect(reported, isEmpty);
    redis.connection.destroy();
  });

  for (_FakeSocket socket in <_FakeSocket>[
    _NoDoneSocket(),
    _ThrowingDoneSocket(),
  ]) {
    test(
      'a fake socket with no done connects (${socket.runtimeType})',
      () async {
        List<Object> reported = <Object>[];
        Redis redis = _fakeClient(socket, await _goodServer(), reported);
        await redis.connect().timeout(Duration(seconds: 2));
        expect(redis.connection.status, RedisConnectionStatus.connected);
        expect(reported, isEmpty);
        redis.connection.destroy();
      },
    );
  }

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
