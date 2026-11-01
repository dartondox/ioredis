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
  final Completer<Socket> client = Completer<Socket>();

  FakeRedis(this.server) {
    server.listen(_onClient);
  }

  static Future<FakeRedis> start() async {
    return FakeRedis(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0));
  }

  void _onClient(Socket socket) {
    if (!client.isCompleted) client.complete(socket);
    socket.listen(_onData);
  }

  void _onData(List<int> data) {
    received.write(utf8.decode(data));
  }

  /// Wait until the server got [text].
  Future<void> waitFor(String text) async {
    for (int i = 0; i < 200 && !received.toString().contains(text); i++) {
      await Future<void>.delayed(Duration(milliseconds: 5));
    }
    expect(received.toString(), contains(text));
  }

  Future<void> reply(String text) async {
    (await client.future).write(text);
  }

  Future<void> close() async {
    if (client.isCompleted) (await client.future).destroy();
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
}
