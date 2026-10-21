import 'dart:async';

import 'package:ioredis/ioredis.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  group('connection |', () {
    test('connect, getStatus, disconnect', () async {
      Redis redis = Redis(testOptions());
      expect(redis.connection.getStatus(), 'disconnected');
      await redis.connect();
      expect(redis.connection.getStatus(), 'connected');
      expect(await redis.ping(), 'PONG');
      await redis.disconnect();
      await Future<void>.delayed(Duration(milliseconds: 50));
      expect(redis.connection.getStatus(), 'disconnected');
    });

    test('sendPipeline on the connection and sendCommand on the pool',
        () async {
      Redis redis = prefixedClient('lowlevel');
      String key = '${redis.option.keyPrefix}:k';
      List<dynamic> res = await redis.connection.sendPipeline(<List<String>>[
        <String>['SET', key, 'v'],
        <String>['GET', key],
        <String>['NOT_A_COMMAND'],
      ]);
      expect(res[0], 'OK');
      expect(res[1], 'v');
      expect(res[2], isA<RedisError>());
      expect(await redis.pool.sendCommand(<String>['GET', key]), 'v');
    });

    test('error reply does not break the client, even under load', () async {
      Redis redis = prefixedClient('errload');
      await redis.set('s', 'x');
      List<Future<dynamic>> jobs = <Future<dynamic>>[];
      for (int i = 0; i < 50; i++) {
        jobs.add(redis.lpush('s', 'a').then(
              (int _) => 'no error',
              onError: (Object e) => e,
            ));
        jobs.add(redis.get('s'));
      }
      List<dynamic> res = await Future.wait(jobs);
      for (int i = 0; i < res.length; i += 2) {
        expect(res[i], isA<RedisError>());
        expect((res[i] as RedisError).message, startsWith('WRONGTYPE'));
        expect(res[i + 1], 'x');
      }
      expect(await redis.get('s'), 'x');
    });

    test('reconnects after the server kills the connection', () async {
      List<Object> errors = <Object>[];
      Redis redis = Redis(testOptions())
        ..option.onError = (dynamic e) {
          errors.add(e as Object);
        };
      addTearDown(redis.quit);
      Redis admin = testClient();

      int id = await redis.call('CLIENT', <Object>['ID']);
      expect(await admin.call('CLIENT', <Object>['KILL', 'ID', id]), 1);

      // Wait until the client sees the closed socket and connects again.
      for (int i = 0;
          i < 100 &&
              (errors.isEmpty ||
                  redis.connection.status != RedisConnectionStatus.connected);
          i++) {
        await Future<void>.delayed(Duration(milliseconds: 20));
      }

      expect(await redis.ping(), 'PONG');
      expect(await redis.call('CLIENT', <Object>['ID']), isNot(id));
      expect(errors, isNotEmpty);
    });
  });

  group('concurrency |', () {
    test('200 parallel set/get return the right value to each caller',
        () async {
      Redis redis = prefixedClient('parallel');
      List<Future<dynamic>> sets = <Future<dynamic>>[
        for (int i = 0; i < 200; i++) redis.set('k$i', 'v$i'),
      ];
      expect(await Future.wait(sets), everyElement('OK'));
      List<String?> got = await Future.wait(<Future<String?>>[
        for (int i = 0; i < 200; i++) redis.get('k$i'),
      ]);
      expect(got, <String>[for (int i = 0; i < 200; i++) 'v$i']);
      expect(redis.pool.connections, isNotEmpty);
    });

    test('mixed parallel commands of different types', () async {
      Redis redis = prefixedClient('mixed');
      List<dynamic> res = await Future.wait(<Future<dynamic>>[
        for (int i = 0; i < 50; i++) ...<Future<dynamic>>[
          redis.incr('n$i'),
          redis.hset('h$i', <String, Object>{'f': i}),
          redis.rpush('l$i', <String>['a', 'b']),
          redis.echo('e$i'),
        ],
      ]);
      for (int i = 0; i < 50; i++) {
        expect(res.sublist(i * 4, i * 4 + 4), <dynamic>[1, 1, 2, 'e$i']);
      }
    });
  });

  group('multi |', () {
    test('all batch methods', () async {
      Redis redis = prefixedClient('multiall');
      List<dynamic> res = await redis
          .multi()
          .set('a', '1')
          .incrby('a', 5)
          .decr('a')
          .expire('a', 100)
          .ttl('a')
          .exists(<String>['a', 'none'])
          .hset('h', <String, Object>{'f': 'v', 'g': 'w'})
          .hget('h', 'f')
          .hdel('h', 'g')
          .lpush('l', 'x')
          .rpush('l', <String>['y', 'z'])
          .sadd('s', <String>['1', '2'])
          .srem('s', '1')
          .zadd('z', <String, num>{'m': 1})
          .del(<String>['a', 'h'])
          .exec();
      expect(res, <dynamic>[
        'OK', 6, 5, 1, 100, 1, 2, 'v', 1, 1, 3, 2, 1, 1, 2, //
      ]);
    });

    test('multi stays on one connection while other commands run', () async {
      Redis redis = prefixedClient('multiconc');
      await redis.set('k', 'v');
      List<Future<dynamic>> gets = <Future<dynamic>>[
        for (int i = 0; i < 100; i++) redis.get('k'),
      ];
      Future<List<dynamic>> tx = redis
          .multi()
          .incr('n')
          .call('CLIENT', <Object>['ID'])
          .incr('n')
          .call('CLIENT', <Object>['ID'])
          .get('k')
          .exec();
      gets.addAll(<Future<dynamic>>[
        for (int i = 0; i < 100; i++) redis.get('k'),
      ]);
      List<dynamic> res = await tx;
      expect(await Future.wait(gets), everyElement('v'));
      expect(res[0], 1);
      expect(res[2], 2);
      expect(res[1], res[3]);
      expect(res[4], 'v');
    });

    test('runtime error is an item, queue error throws EXECABORT', () async {
      Redis redis = prefixedClient('multierr');
      await redis.set('str', 'x');
      List<dynamic> res =
          await redis.multi().lpush('str', 'a').incr('n').exec();
      expect(res[0], isA<RedisError>());
      expect((res[0] as RedisError).message, startsWith('WRONGTYPE'));
      expect(res[1], 1);

      await expectLater(
        redis.multi().incr('n').call('NOT_A_COMMAND').exec(),
        throwsA(
          isA<RedisError>().having(
            (RedisError e) => e.message,
            'message',
            startsWith('EXECABORT'),
          ),
        ),
      );
      expect(await redis.get('n'), '1');
      expect(await redis.ping(), 'PONG');
    });
  });

  group('pipeline |', () {
    test('1000 commands come back in order', () async {
      Redis redis = prefixedClient('pipe1000');
      RedisPipeline p = redis.pipeline();
      for (int i = 0; i < 500; i++) {
        p.set('k$i', 'v$i').get('k$i');
      }
      List<dynamic> res = await p.exec();
      expect(res.length, 1000);
      for (int i = 0; i < 500; i++) {
        expect(res[i * 2], 'OK');
        expect(res[i * 2 + 1], 'v$i');
      }
    });

    test('error items do not stop the next commands', () async {
      Redis redis = prefixedClient('pipeerr');
      await redis.set('str', 'x');
      List<dynamic> res = await redis
          .pipeline()
          .lpush('str', 'a')
          .incr('n')
          .call('NOT_A_COMMAND')
          .get('str')
          .exec();
      expect(res[0], isA<RedisError>());
      expect(res[1], 1);
      expect(res[2], isA<RedisError>());
      expect(res[3], 'x');
    });
  });

  group('keyPrefix |', () {
    test('added to keys of every command type, not to values', () async {
      Redis redis = prefixedClient('kp');
      Redis raw = testClient();
      String p = redis.option.keyPrefix;

      await redis.hset('h', <String, Object>{'f': 'v'});
      await redis.rpush('l', <String>['a', 'b']);
      await redis.sadd('s', 'm');
      await redis.zadd('z', <String, num>{'zm': 1});
      await redis.mset(<String, Object>{'m1': 'x', 'm2': 'y'});
      await redis.set('str', 'plain');
      await redis.expire('str', 100);
      await redis.sunionstore('s2', <String>['s']);

      expect(await raw.hget('$p:h', 'f'), 'v');
      expect(await raw.lrange('$p:l', 0, -1), <String>['a', 'b']);
      expect(await raw.smembers('$p:s'), <String>['m']);
      expect(await raw.smembers('$p:s2'), <String>['m']);
      expect(await raw.zscore('$p:z', 'zm'), 1.0);
      expect(await raw.mget(<String>['$p:m1', '$p:m2']), <String>['x', 'y']);
      expect(await raw.get('$p:str'), 'plain');
      expect(await raw.ttl('$p:str'), greaterThan(0));
      expect(await raw.exists(<String>['h', 'l', 's', 'z', 'str']), 0);

      expect(
        await redis.eval('return {KEYS[1], ARGV[1]}', 1, <Object>['k', 'arg']),
        <dynamic>['$p:k', 'arg'],
      );
      List<dynamic> batch =
          await redis.pipeline().get('str').call('GET', <Object>['str']).exec();
      expect(batch, <dynamic>['plain', null]);
    });

    test('not added to channel names', () async {
      String channel = uniquePrefix('kpchan');
      Redis sub = Redis(testOptions(keyPrefix: 'should-not-show'));
      addTearDown(sub.quit);
      Redis pub = testClient();
      Completer<String> got = Completer<String>();
      RedisSubscriber s = await sub.subscribe(channel);
      s.onMessage = (String ch, String? message) {
        got.complete('$ch=$message');
      };
      expect(await pub.publish(channel, 'hi'), 1);
      expect(await got.future.timeout(Duration(seconds: 2)), '$channel=hi');
    });
  });

  group('pub/sub |', () {
    test('publish returns the number of receivers', () async {
      String channel = uniquePrefix('count');
      Redis sub1 = testClient();
      Redis sub2 = testClient();
      Redis psub = testClient();
      Redis pub = testClient();
      Completer<void> done = Completer<void>();
      List<String> got = <String>[];
      void onMessage(String ch, String? message) {
        got.add('$ch=$message');
        if (got.length == 3 && !done.isCompleted) done.complete();
      }

      (await sub1.subscribe(channel)).onMessage = onMessage;
      (await sub2.subscribe(<String>[channel, '$channel:other'])).onMessage =
          onMessage;
      // no onPatternMessage: onMessage is used for pattern messages too
      (await psub.psubscribe('$channel*')).onMessage = onMessage;

      expect(await pub.publish(channel, 'x'), 3);
      await done.future.timeout(Duration(seconds: 2));
      expect(got, everyElement('$channel=x'));
      expect(await pub.publish('$channel:other', 'y'), 2);
      expect(await pub.publish(uniquePrefix('nobody'), 'z'), 0);
    });

    test('subscriber cannot publish', () async {
      Redis sub = testClient();
      await sub.subscribe(uniquePrefix('mode'));
      expect(() => sub.publish('x', 'y'), throwsException);
    });
  });

  group('server |', () {
    test('db option and select', () async {
      String key = uniquePrefix('db');
      Redis db5 = testClient(db: 5);
      Redis other = testClient();
      addTearDown(() => db5.del(key));

      await db5.set(key, 'five');
      expect(await other.get(key), isNull);
      expect(await other.select(5), 'OK');
      expect(await other.get(key), 'five');
      expect(other.option.db, 5);
    });

    test('duplicate uses the same options on a new connection', () async {
      Redis redis = prefixedClient('dup');
      Redis copy = redis.duplicate();
      addTearDown(copy.quit);
      await redis.set('k', 'v');
      expect(await copy.get('k'), 'v');
      expect(copy.option.keyPrefix, redis.option.keyPrefix);
      expect(
        await copy.call('CLIENT', <Object>['ID']),
        isNot(await redis.call('CLIENT', <Object>['ID'])),
      );
    });

    test('info without section, dbsize, time, flushdb', () async {
      // Uses db 15 of the second Redis, so flushdb only clears that db.
      Redis redis = testClient(port: redisPort2, db: 15);
      expect(await redis.info(), contains('# Server'));
      await redis.set(uniquePrefix('flush'), 'x');
      expect(await redis.dbsize(), greaterThan(0));
      await redis.flushdb();
      expect(await redis.dbsize(), 0);
      List<String> t = await redis.time();
      int seconds = int.parse(t[0]);
      int now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      expect((seconds - now).abs(), lessThan(60));
    });

    test('script load, exists and evalsha', () async {
      Redis redis = testClient(port: redisPort2);
      String sha = await redis.script('load', <Object>["return 'hi'"]);
      expect(await redis.evalsha(sha, 0), 'hi');
      expect(await redis.script('EXISTS', <Object>[sha, 'nope']), <int>[1, 0]);
      await expectLater(
        redis.evalsha('0' * 40, 0),
        throwsA(isA<RedisError>()),
      );
    });
  });

  group('blocking |', () {
    test('blpop and brpop return null on timeout', () async {
      Redis redis = prefixedClient('blockempty');
      expect(await redis.blpop('none', 0.1), isNull);
      expect(await redis.brpop(<String>['none', 'none2'], 0.1), isNull);
    });

    test('blpop gets a value pushed by another client', () async {
      Redis redis = prefixedClient('blockpush');
      Redis pusher = testClient();
      String key = '${redis.option.keyPrefix}:q';
      Future<List<String>?> waiting = redis.blpop('q', 5);
      await Future<void>.delayed(Duration(milliseconds: 50));
      expect(await pusher.rpush(key, 'job'), 1);
      expect(await waiting, <String>[key, 'job']);
    });

    test('brpop waits while the same client pushes on the pool', () async {
      Redis redis = prefixedClient('blockpool');
      Future<List<String>?> waiting = redis.brpop('q', 5);
      await Future<void>.delayed(Duration(milliseconds: 50));
      expect(await redis.lpush('q', 'job'), 1);
      expect(await waiting, <String>['${redis.option.keyPrefix}:q', 'job']);
    });
  });
}
