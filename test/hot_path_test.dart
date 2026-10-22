import 'dart:async';

import 'package:ioredis/ioredis.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  group('auto-pipelining |', () {
    test(
      'many callers with many commands in flight get their own replies',
      () async {
        Redis redis = prefixedClient('autopipe');
        Future<List<dynamic>> caller(int id) async {
          List<dynamic> got = <dynamic>[];
          for (int i = 0; i < 50; i++) {
            // Many commands in the same turn, then wait for all of them.
            List<dynamic> res = await Future.wait(<Future<dynamic>>[
              redis.incr('c$id'),
              redis.set('k$id:$i', 'v$id:$i'),
              redis.get('k$id:$i'),
              redis.echo('e$id:$i'),
            ]);
            got.addAll(res);
          }
          return got;
        }

        List<List<dynamic>> all = await Future.wait(<Future<List<dynamic>>>[
          for (int id = 0; id < 40; id++) caller(id),
        ]);
        for (int id = 0; id < 40; id++) {
          expect(all[id], <dynamic>[
            for (int i = 0; i < 50; i++) ...<dynamic>[
              i + 1,
              'OK',
              'v$id:$i',
              'e$id:$i',
            ],
          ]);
        }
      },
    );

    test(
      'error reply in the middle of a batch only fails its own caller',
      () async {
        Redis redis = prefixedClient('autopipeerr');
        await redis.set('s', 'text');
        List<Future<dynamic>> futures = <Future<dynamic>>[
          redis.echo('a'),
          redis.incr('s'),
          redis.echo('b'),
        ];
        expect(await futures[0], 'a');
        await expectLater(futures[1], throwsA(isA<RedisError>()));
        expect(await futures[2], 'b');
      },
    );

    test('1 MB value is written and read back', () async {
      Redis redis = prefixedClient('bigvalue');
      String value = List<String>.generate(
        1 << 20,
        (int i) => '${i % 10}',
      ).join();
      List<dynamic> res = await Future.wait(<Future<dynamic>>[
        redis.set('big', value),
        redis.get('big'),
        redis.echo('after'),
      ]);
      expect(res[0], 'OK');
      expect(res[1], value);
      expect(res[2], 'after');
    });
  });

  group('pool selection |', () {
    test('commands share the main connection when nothing blocks', () async {
      Redis redis = prefixedClient('poolshare');
      await Future.wait(<Future<dynamic>>[
        for (int i = 0; i < 100; i++) redis.set('k$i', 'v$i'),
      ]);
      expect(redis.pool.connections, isEmpty);
    });

    test('a blocking command moves other commands to the pool', () async {
      Redis redis = prefixedClient('poolblock');
      Future<List<String>?> waiting = redis.blpop('q', 2);
      await Future<void>.delayed(Duration(milliseconds: 50));
      expect(redis.connection.isBlocked, isTrue);
      expect(await redis.echo('a'), 'a');
      expect(await redis.echo('b'), 'b');
      // Both went to the same pool connection.
      expect(redis.pool.connections.length, 1);
      await redis.rpush('q', 'job');
      expect(await waiting, isNotNull);
      expect(redis.connection.isBlocked, isFalse);
    });

    test(
      'pool reuses a free connection and uses round-robin when full',
      () async {
        RedisOptions opt = testOptions()..maxConnection = 3;
        Redis redis = Redis(opt);
        Redis pusher = testClient();
        addTearDown(redis.quit);
        String key = uniquePrefix('rr');

        RedisConnection a = redis.pool.getConnection();
        expect(await a.sendCommand(<String>['PING']), 'PONG');
        expect(redis.pool.getConnection(), same(a));
        Future<dynamic> blockA = a.sendCommand(<String>[
          'BLPOP',
          '$key:a',
          '2',
        ]);
        RedisConnection b = redis.pool.getConnection();
        expect(b, isNot(same(a)));
        Future<dynamic> blockB = b.sendCommand(<String>[
          'BLPOP',
          '$key:b',
          '2',
        ]);
        await Future<void>.delayed(Duration(milliseconds: 50));

        // Pool is full (maxConnection - 1) and all are blocked: round-robin.
        List<RedisConnection> picked = <RedisConnection>[
          for (int i = 0; i < 4; i++) redis.pool.getConnection(),
        ];
        expect(redis.pool.connections.length, 2);
        expect(
          picked.where((RedisConnection c) => identical(c, a)),
          hasLength(2),
        );
        expect(
          picked.where((RedisConnection c) => identical(c, b)),
          hasLength(2),
        );

        await pusher.rpush('$key:a', 'x');
        await pusher.rpush('$key:b', 'y');
        await blockA;
        await blockB;
        expect(redis.pool.getConnection(), same(a));
      },
    );

    test('idle pool connections are closed, busy ones are kept', () async {
      Redis redis = prefixedClient('idle');
      redis.option.idleTimeout = Duration(milliseconds: 300);
      Redis pusher = testClient();
      String key = '${redis.option.keyPrefix}:q';

      expect(await redis.pool.sendCommand(<String>['PING']), 'PONG');
      expect(redis.pool.connections.length, 1);
      await Future<void>.delayed(Duration(milliseconds: 700));
      expect(redis.pool.connections, isEmpty);

      // A connection that waits for a reply is not closed.
      Future<dynamic> waiting = redis.pool.sendCommand(<String>[
        'BLPOP',
        key,
        '5',
      ]);
      await Future<void>.delayed(Duration(milliseconds: 700));
      expect(redis.pool.connections.length, 1);
      await pusher.rpush(key, 'job');
      expect(await waiting, <String>[key, 'job']);
      await Future<void>.delayed(Duration(milliseconds: 1000));
      expect(redis.pool.connections, isEmpty);
    });
  });
}
