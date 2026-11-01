import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ioredis/ioredis.dart';
import 'package:test/test.dart';

/// A fake Redis server. It keeps all bytes it got, so a test can check
/// which commands were sent and when. The test writes the replies.
class FakeRedis {
  final ServerSocket server;
  final StringBuffer received = StringBuffer();

  /// Every client that connected, oldest first.
  final List<Socket> clients = <Socket>[];

  FakeRedis(this.server) {
    server.listen(_onClient);
  }

  static Future<FakeRedis> start() async {
    return FakeRedis(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0));
  }

  void _onClient(Socket socket) {
    clients.add(socket);
    socket.listen(_onData, onError: _ignore);
  }

  void _onData(List<int> data) {
    received.write(utf8.decode(data));
  }

  void _ignore(Object error) {}

  /// Wait until the server got [text].
  Future<void> waitFor(String text) async {
    for (int i = 0; i < 200 && !received.toString().contains(text); i++) {
      await Future<void>.delayed(Duration(milliseconds: 5));
    }
    expect(received.toString(), contains(text));
  }

  /// Wait until [count] clients have connected.
  Future<void> waitForClients(int count) async {
    for (int i = 0; i < 200 && clients.length < count; i++) {
      await Future<void>.delayed(Duration(milliseconds: 5));
    }
    expect(clients.length, count);
  }

  /// Write [text] to the newest client.
  Future<void> reply(String text) async {
    await waitForClients(clients.isEmpty ? 1 : clients.length);
    clients.last.write(text);
  }

  /// Close the newest client, like a network drop.
  void drop() {
    received.clear();
    clients.last.destroy();
  }

  Future<void> close() async {
    for (Socket socket in clients) {
      socket.destroy();
    }
    await server.close();
  }
}

void main() {
  test('commands wait until AUTH and SELECT are done', () async {
    FakeRedis fake = await FakeRedis.start();
    addTearDown(fake.close);
    RedisConnection conn = RedisConnection(
      RedisOptions(port: fake.server.port, password: 'secret', db: 3),
    );
    addTearDown(conn.destroy);

    Future<void> connecting = conn.connect();
    await fake.waitFor('AUTH');

    // Another caller sends a command while AUTH is not answered yet.
    Future<dynamic> get = conn.sendCommand(<String>['GET', 'k']);
    await Future<void>.delayed(Duration(milliseconds: 50));
    expect(conn.status, RedisConnectionStatus.connecting);
    expect(fake.received.toString(), isNot(contains('GET')));

    await fake.reply('+OK\r\n');
    await fake.waitFor('SELECT');
    await Future<void>.delayed(Duration(milliseconds: 50));
    expect(conn.status, RedisConnectionStatus.connecting);
    expect(fake.received.toString(), isNot(contains('GET')));

    await fake.reply('+OK\r\n');
    await connecting;
    expect(conn.status, RedisConnectionStatus.connected);

    // GET is sent only after SELECT, so it runs on database 3.
    await fake.waitFor('GET');
    String sent = fake.received.toString();
    expect(sent.indexOf('SELECT'), lessThan(sent.indexOf('GET')));
    await fake.reply('\$1\r\nv\r\n');
    expect(await get, 'v');
  });

  test('failed AUTH throws and does not go to connected', () async {
    FakeRedis fake = await FakeRedis.start();
    addTearDown(fake.close);
    RedisConnection conn = RedisConnection(
      RedisOptions(port: fake.server.port, password: 'wrong', db: 3),
    );
    addTearDown(conn.destroy);

    Future<void> connecting = conn.connect();
    Future<void> getFails = expectLater(
      conn.sendCommand(<String>['GET', 'k']),
      throwsA(isA<RedisError>()),
    );
    await fake.waitFor('AUTH');
    await fake.reply('-WRONGPASS invalid password\r\n');

    await expectLater(connecting, throwsA(isA<RedisError>()));
    await getFails;
    expect(conn.status, RedisConnectionStatus.disconnected);
    await Future<void>.delayed(Duration(milliseconds: 50));
    expect(fake.received.toString(), isNot(contains('SELECT')));
    expect(fake.received.toString(), isNot(contains('GET')));
  });

  test('failed AUTH on reconnect goes to onError, not a crash', () async {
    FakeRedis fake = await FakeRedis.start();
    addTearDown(fake.close);
    List<dynamic> errors = <dynamic>[];
    RedisConnection conn = RedisConnection(
      RedisOptions(
        port: fake.server.port,
        password: 'secret',
        onError: errors.add,
      ),
    );
    addTearDown(conn.destroy);

    Future<void> connecting = conn.connect();
    await fake.waitFor('AUTH');
    await fake.reply('+OK\r\n');
    await fake.waitFor('SELECT');
    await fake.reply('+OK\r\n');
    await connecting;

    // The password is changed on the server, then the network drops.
    fake.drop();
    await fake.waitForClients(2);
    await fake.waitFor('AUTH');
    await fake.reply('-WRONGPASS invalid username-password pair\r\n');

    await Future<void>.delayed(Duration(milliseconds: 100));
    expect(errors.whereType<RedisError>(), isNotEmpty);
    expect(conn.status, RedisConnectionStatus.disconnected);

    // A wrong password does not fix itself, so there is no retry.
    expect(fake.clients.length, 2);
  });

  test('a short AUTH problem on reconnect retries until it works', () async {
    FakeRedis fake = await FakeRedis.start();
    addTearDown(fake.close);
    List<dynamic> errors = <dynamic>[];
    RedisConnection conn = RedisConnection(
      RedisOptions(
        port: fake.server.port,
        password: 'secret',
        onError: errors.add,
        retryStrategy: _fastRetry,
      ),
    );
    addTearDown(conn.destroy);
    // A subscriber sends no commands, so only a retry can bring it back.
    conn.subscribeListeners[<String>['news']] = RedisSubscriber();

    Future<void> connecting = conn.connect();
    await fake.waitFor('AUTH');
    await fake.reply('+OK\r\n');
    await fake.waitFor('SELECT');
    await fake.reply('+OK\r\n');
    await connecting;

    // The server restarts and is still loading its data.
    fake.drop();
    await fake.waitForClients(2);
    await fake.waitFor('AUTH');
    fake.received.clear();
    await fake.reply('-LOADING Redis is loading the dataset in memory\r\n');

    // It tries again on a new socket, and this time it works.
    await fake.waitForClients(3);
    await fake.waitFor('AUTH');
    await fake.reply('+OK\r\n');
    await fake.waitFor('SELECT');
    await fake.reply('+OK\r\n');
    await fake.waitFor('SUBSCRIBE');
    await fake.reply('*3\r\n\$9\r\nsubscribe\r\n\$4\r\nnews\r\n:1\r\n');
    await Future<void>.delayed(Duration(milliseconds: 50));
    expect(conn.status, RedisConnectionStatus.connected);
    expect(errors.whereType<RedisError>(), isNotEmpty);
  });
}

Duration _fastRetry(int times) => Duration(milliseconds: 10);
