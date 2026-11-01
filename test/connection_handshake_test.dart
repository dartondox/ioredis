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

  /// When set, the server writes this to the newest client for every
  /// chunk it gets. The test does not need to reply by hand then.
  String? autoReply;

  void _onClient(Socket socket) {
    clients.add(socket);
    socket.listen(_onData, onError: _ignore, onDone: socket.destroy);
  }

  void _onData(List<int> data) {
    received.write(utf8.decode(data));
    String? text = autoReply;
    if (text != null) clients.last.write(text);
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
  test('the right password logs in with AUTH user password', () async {
    FakeRedis fake = await FakeRedis.start();
    addTearDown(fake.close);
    fake.autoReply = '+OK\r\n';
    RedisConnection conn = RedisConnection(
      RedisOptions.fromUrl(
        'redis://alice:s3cret@127.0.0.1:${fake.server.port}',
      ),
    );
    addTearDown(conn.destroy);

    await conn.connect();
    expect(conn.status, RedisConnectionStatus.connected);
    expect(
      fake.received.toString(),
      contains('*3\r\n\$4\r\nAUTH\r\n\$5\r\nalice\r\n\$6\r\ns3cret\r\n'),
    );
  });

  test('a wrong password fails with the server error message', () async {
    FakeRedis fake = await FakeRedis.start();
    addTearDown(fake.close);
    fake.autoReply = '-WRONGPASS invalid username-password pair\r\n';
    RedisConnection conn = RedisConnection(
      RedisOptions(port: fake.server.port, password: 'wrong'),
    );
    addTearDown(conn.destroy);

    await expectLater(
      conn.connect(),
      throwsA(
        isA<RedisError>().having(
          (RedisError e) => e.message,
          'message',
          contains('WRONGPASS'),
        ),
      ),
    );
    expect(conn.status, RedisConnectionStatus.disconnected);
  });

  test('rediss:// connects over TLS and sends AUTH', () async {
    if (!_hasOpenssl()) {
      markTestSkipped('openssl is not installed');
      return;
    }

    // A self-signed cert, made with openssl for this test only.
    Directory dir = await Directory.systemTemp.createTemp('ioredis_tls');
    addTearDown(() => dir.delete(recursive: true));
    String args =
        'req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost';
    String keyFile = '${dir.path}/key.pem';
    String certFile = '${dir.path}/cert.pem';
    ProcessResult made = await Process.run('openssl', <String>[
      ...args.split(' '),
      '-keyout',
      keyFile,
      '-out',
      certFile,
    ]);
    expect(made.exitCode, 0, reason: '${made.stderr}');

    SecurityContext context = SecurityContext()
      ..useCertificateChain(certFile)
      ..usePrivateKey(keyFile);
    SecureServerSocket server = await SecureServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
      context,
    );
    addTearDown(server.close);
    StringBuffer received = StringBuffer();
    server.listen((SecureSocket socket) {
      socket.listen((List<int> data) {
        received.write(utf8.decode(data));
        socket.write('+OK\r\n');
      }, onError: (Object _) {});
    });

    bool sawBadCert = false;
    RedisConnection conn = RedisConnection(
      RedisOptions.fromUrl(
        'rediss://:secret@127.0.0.1:${server.port}',
        onBadCertificate: (X509Certificate cert) => sawBadCert = true,
      ),
    );
    addTearDown(conn.destroy);

    await conn.connect();
    expect(conn.status, RedisConnectionStatus.connected);
    expect(sawBadCert, isTrue);
    expect(received.toString(), contains('AUTH\r\n\$6\r\nsecret'));
  });

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

  test('a handshake with no reply times out and tries again', () async {
    FakeRedis fake = await FakeRedis.start();
    addTearDown(fake.close);
    List<dynamic> errors = <dynamic>[];
    RedisConnection conn = RedisConnection(
      RedisOptions(
        port: fake.server.port,
        password: 'secret',
        connectTimeout: Duration(milliseconds: 200),
        onError: errors.add,
        retryStrategy: _fastRetry,
      ),
    );
    addTearDown(conn.destroy);

    // The first server never answers AUTH.
    Future<void> connecting = conn.connect();
    await fake.waitFor('AUTH');
    fake.received.clear();

    // After the timeout it gives up on that socket and uses a new one.
    await Future<void>.delayed(Duration(milliseconds: 300));
    await fake.waitForClients(2);
    await fake.waitFor('AUTH');
    await fake.reply('+OK\r\n');
    await fake.waitFor('SELECT');
    await fake.reply('+OK\r\n');
    await connecting;
    expect(conn.status, RedisConnectionStatus.connected);
    expect(errors.whereType<SocketException>(), isNotEmpty);
  });

  test('handshake retries follow the backoff', () async {
    FakeRedis fake = await FakeRedis.start();
    addTearDown(fake.close);
    fake.autoReply = '-LOADING Redis is loading the dataset in memory\r\n';
    List<int> waits = <int>[];
    RedisConnection conn = RedisConnection(
      RedisOptions(
        port: fake.server.port,
        password: 'secret',
        onError: _ignoreError,
        retryStrategy: (int times) {
          waits.add(times);
          return Duration(milliseconds: times * 20);
        },
      ),
    );
    addTearDown(conn.destroy);

    unawaited(conn.connect());
    await Future<void>.delayed(Duration(milliseconds: 500));

    // Waits are 20, 40, 60 ... ms, so about 6 tries fit in 500 ms.
    expect(waits.take(3), <int>[1, 2, 3]);
    expect(fake.clients.length, inInclusiveRange(3, 10));
  });

  test('many handshake retries do not grow the stack', () async {
    FakeRedis fake = await FakeRedis.start();
    addTearDown(fake.close);
    fake.autoReply = '-LOADING Redis is loading the dataset in memory\r\n';
    RedisConnection conn = RedisConnection(
      RedisOptions(
        port: fake.server.port,
        password: 'secret',
        onError: _ignoreError,
        retryStrategy: _noWait,
      ),
    );
    addTearDown(conn.destroy);

    Future<void> connecting = conn.connect();
    for (int i = 0; i < 2000 && fake.clients.length < 2000; i++) {
      await Future<void>.delayed(Duration(milliseconds: 5));
    }
    expect(fake.clients.length, greaterThanOrEqualTo(2000));

    // Now the server is ready. The connect must finish without an error.
    fake.autoReply = '+OK\r\n';
    await connecting;
    expect(conn.status, RedisConnectionStatus.connected);
  });

  test('disconnect during a retry wait stops the retries', () async {
    FakeRedis fake = await FakeRedis.start();
    addTearDown(fake.close);
    fake.autoReply = '-LOADING Redis is loading the dataset in memory\r\n';
    RedisConnection conn = RedisConnection(
      RedisOptions(
        port: fake.server.port,
        password: 'secret',
        onError: _ignoreError,
        retryStrategy: _slowRetry,
      ),
    );
    addTearDown(conn.destroy);

    Future<void> connecting = conn.connect();
    await fake.waitFor('AUTH');
    await Future<void>.delayed(Duration(milliseconds: 50));

    // The connection now waits 200 ms before it tries again.
    await conn.disconnect();
    fake.autoReply = '+OK\r\n';
    await connecting;
    await Future<void>.delayed(Duration(milliseconds: 400));

    expect(fake.clients.length, 1);
    expect(conn.status, RedisConnectionStatus.disconnected);
  });
}

bool _hasOpenssl() {
  try {
    return Process.runSync('openssl', <String>['version']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}

void _ignoreError(dynamic error) {}

Duration _noWait(int times) => Duration.zero;

Duration _slowRetry(int times) => Duration(milliseconds: 200);

Duration _fastRetry(int times) => Duration(milliseconds: 10);
