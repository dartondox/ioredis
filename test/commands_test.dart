import 'dart:async';

import 'package:ioredis/ioredis.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  group('errors |', () {
    test(
      'error reply throws RedisError and connection keeps working',
      () async {
        Redis redis = prefixedClient('errors');
        await expectLater(
          redis.call('NOT_A_COMMAND'),
          throwsA(isA<RedisError>()),
        );
        await redis.set('s', 'x');
        await expectLater(redis.lpush('s', 'a'), throwsA(isA<RedisError>()));
        expect(await redis.get('s'), 'x');
        expect(await redis.ping(), 'PONG');
      },
    );
  });

  group('call |', () {
    test('call sends any command without prefix', () async {
      Redis redis = prefixedClient('call');
      String prefix = redis.option.keyPrefix;
      expect(await redis.call('SET', <Object>['$prefix:raw', 5]), 'OK');
      expect(await redis.get('raw'), '5');
      expect(await redis.call('INCRBY', <Object>['$prefix:raw', 2]), 7);
    });
  });

  group('keys |', () {
    test('key commands use prefix', () async {
      Redis redis = prefixedClient('keys');
      String prefix = redis.option.keyPrefix;
      await redis.mset(<String, Object>{'a': 1, 'b': 2, 'c': 3});
      expect(await redis.exists(<String>['a', 'b', 'zz']), 2);
      expect(await redis.del(<String>['a']), 1);
      expect(await redis.unlink('b'), 1);
      expect(await redis.type('c'), 'string');
      expect(await redis.ttl('c'), -1);
      expect(await redis.expire('c', 100), 1);
      expect(await redis.ttl('c'), greaterThan(90));
      expect(await redis.pttl('c'), greaterThan(90000));
      expect(await redis.persist('c'), 1);
      expect(await redis.pexpire('c', 100000), 1);
      expect(await redis.expireat('c', 4102444800), 1);
      expect(await redis.rename('c', 'd'), 'OK');
      await redis.set('e', 'x');
      expect(await redis.renamenx('d', 'e'), 0);
      expect(await redis.copy('d', 'f'), 1);
      expect(await redis.copy('d', 'f', replace: true), 1);
      expect((await redis.keys('$prefix:*'))..sort(), <String>[
        '$prefix:d',
        '$prefix:e',
        '$prefix:f',
      ]);
      expect(await redis.randomkey(), isNotNull);

      List<String> scanned = <String>[];
      String cursor = '0';
      do {
        RedisScanResult res = await redis.scan(
          cursor,
          match: '$prefix:*',
          count: 100,
          type: 'string',
        );
        scanned.addAll(res.items);
        cursor = res.cursor;
      } while (cursor != '0');
      expect(scanned.toSet().length, 3);

      // old API still works
      await redis.delete('d');
      await redis.mdelete(<String>['e', 'f']);
      expect(await redis.exists(<String>['d', 'e', 'f']), 0);
    });
  });

  group('strings |', () {
    test('string commands', () async {
      Redis redis = prefixedClient('strings');
      expect(await redis.set('k', 'v'), 'OK');
      expect(await redis.set('k', 'v2', 'NX'), isNull);
      expect(await redis.set('k', 'v2', 'XX'), 'OK');
      expect(await redis.set('k', 'v3', 'GET'), 'v2');
      expect(await redis.set('k', 'v4', 'EX', 100, 'XX'), 'OK');
      expect(await redis.set('k', 'v5', 'KEEPTTL'), 'OK');
      expect(await redis.ttl('k'), greaterThan(0));
      expect(await redis.setnx('k', 'x'), 0);
      expect(await redis.setex('ex', 100, 'x'), 'OK');
      expect(await redis.psetex('px', 100000, 'x'), 'OK');
      expect(await redis.getset('k', 'new'), 'v5');
      expect(await redis.getex('k', ex: 50), 'new');
      expect(await redis.getex('k', persist: true), 'new');
      expect(await redis.getdel('k'), 'new');
      expect(await redis.get('k'), isNull);
      expect(await redis.mset(<String, Object>{'a': 'x', 'b': 'y'}), 'OK');
      expect(await redis.msetnx(<String, Object>{'a': 'z', 'c': 'w'}), 0);
      expect(await redis.mget(<String>['a', 'b', 'c']), <String?>[
        'x',
        'y',
        null,
      ]);
      expect(await redis.incr('n'), 1);
      expect(await redis.incrby('n', 10), 11);
      expect(await redis.decr('n'), 10);
      expect(await redis.decrby('n', 3), 7);
      expect(await redis.incrbyfloat('n', 0.5), 7.5);
      expect(await redis.append('s', 'Hello'), 5);
      expect(await redis.append('s', ' World'), 11);
      expect(await redis.strlen('s'), 11);
      expect(await redis.getrange('s', 0, 4), 'Hello');
      expect(await redis.setrange('s', 6, 'Redis'), 11);
      expect(await redis.get('s'), 'Hello Redis');
    });
  });

  group('hashes |', () {
    test('hash commands', () async {
      Redis redis = prefixedClient('hashes');
      expect(
        await redis.hset('h', <String, Object>{'name': 'Ann', 'age': 30}),
        2,
      );
      expect(await redis.hsetnx('h', 'name', 'Bob'), 0);
      expect(await redis.hget('h', 'name'), 'Ann');
      expect(await redis.hmget('h', <String>['name', 'nope']), <String?>[
        'Ann',
        null,
      ]);
      expect(await redis.hgetall('h'), <String, String>{
        'name': 'Ann',
        'age': '30',
      });
      expect(await redis.hgetall('missing'), <String, String>{});
      expect(await redis.hexists('h', 'age'), 1);
      expect((await redis.hkeys('h'))..sort(), <String>['age', 'name']);
      expect((await redis.hvals('h'))..sort(), <String>['30', 'Ann']);
      expect(await redis.hlen('h'), 2);
      expect(await redis.hincrby('h', 'age', 1), 31);
      expect(await redis.hincrbyfloat('h', 'score', 1.5), 1.5);
      expect(await redis.hstrlen('h', 'name'), 3);
      RedisScanResult res = await redis.hscan('h', 0, match: 'n*');
      expect(res.cursor, '0');
      expect(res.items, <String>['name', 'Ann']);
      expect(await redis.hdel('h', <String>['name', 'age']), 2);
    });
  });

  group('lists |', () {
    test('list commands', () async {
      Redis redis = prefixedClient('lists');
      expect(await redis.rpush('l', <String>['b', 'c']), 2);
      expect(await redis.lpush('l', 'a'), 3);
      expect(await redis.lpushx('none', 'a'), 0);
      expect(await redis.rpushx('l', 'd'), 4);
      expect(await redis.lrange('l', 0, -1), <String>['a', 'b', 'c', 'd']);
      expect(await redis.llen('l'), 4);
      expect(await redis.lindex('l', 1), 'b');
      expect(await redis.lset('l', 1, 'B'), 'OK');
      expect(await redis.linsert('l', 'BEFORE', 'B', 'x'), 5);
      expect(await redis.lrem('l', 0, 'x'), 1);
      expect(await redis.lpop('l'), 'a');
      expect(await redis.rpop('l', 2), <String>['d', 'c']);
      expect(await redis.lpop('none'), isNull);
      await redis.rpush('l', <String>['1', '2', '3']);
      expect(await redis.ltrim('l', 0, 1), 'OK');
      expect(await redis.lmove('l', 'l2', 'LEFT', 'RIGHT'), 'B');
      expect(await redis.blpop(<String>['empty', 'l2'], 1), <String>[
        '${redis.option.keyPrefix}:l2',
        'B',
      ]);
      expect(await redis.brpop('empty', 0.1), isNull);
    });
  });

  group('sets |', () {
    test('set commands', () async {
      Redis redis = prefixedClient('sets');
      expect(await redis.sadd('a', <String>['1', '2', '3']), 3);
      expect(await redis.sadd('b', <String>['2', '3', '4']), 3);
      expect((await redis.smembers('a'))..sort(), <String>['1', '2', '3']);
      expect(await redis.sismember('a', '1'), 1);
      expect(await redis.smismember('a', <Object>['1', '9']), <int>[1, 0]);
      expect(await redis.scard('a'), 3);
      expect((await redis.sinter(<String>['a', 'b']))..sort(), <String>[
        '2',
        '3',
      ]);
      expect((await redis.sunion(<String>['a', 'b'])).length, 4);
      expect(await redis.sdiff(<String>['a', 'b']), <String>['1']);
      expect(await redis.sinterstore('i', <String>['a', 'b']), 2);
      expect(await redis.sunionstore('u', <String>['a', 'b']), 4);
      expect(await redis.sdiffstore('d', <String>['a', 'b']), 1);
      expect(await redis.smove('a', 'b', '1'), 1);
      expect(await redis.srem('b', '1'), 1);
      expect(await redis.srandmember('a'), isA<String>());
      expect(await redis.srandmember('a', 2), hasLength(2));
      expect(await redis.spop('a'), isA<String>());
      expect(await redis.spop('a', 5), hasLength(1));
      RedisScanResult res = await redis.sscan('u', 0);
      expect(res.items.length, 4);
    });
  });

  group('sorted sets |', () {
    test('sorted set commands', () async {
      Redis redis = prefixedClient('zsets');
      expect(await redis.zadd('z', <String, num>{'a': 1, 'b': 2, 'c': 3.5}), 3);
      expect(
        await redis.zadd('z', <String, num>{'a': 0}, gt: true, ch: true),
        0,
      );
      expect(
        await redis.zadd('z', <String, num>{'a': 5}, xx: true, ch: true),
        1,
      );
      expect(await redis.zadd('z', <String, num>{'d': 9}, nx: true), 1);
      expect(await redis.zscore('z', 'c'), 3.5);
      expect(await redis.zscore('z', 'none'), isNull);
      expect(await redis.zincrby('z', 1, 'b'), 3.0);
      expect(await redis.zcard('z'), 4);
      expect(await redis.zcount('z', '(3', '+inf'), 3);
      expect(await redis.zrank('z', 'b'), 0);
      expect(await redis.zrevrank('z', 'b'), 3);
      expect(await redis.zrank('z', 'none'), isNull);
      expect(await redis.zrange('z', 0, -1), <String>['b', 'c', 'a', 'd']);
      expect(await redis.zrange('z', 0, 0, withScores: true), <String>[
        'b',
        '3',
      ]);
      expect(await redis.zrevrange('z', 0, 1), <String>['d', 'a']);
      expect(
        await redis.zrangebyscore('z', 3.5, '+inf', offset: 1, count: 1),
        <String>['a'],
      );
      expect(
        await redis.zrevrangebyscore('z', '+inf', 5, withScores: true),
        <String>['d', '9', 'a', '5'],
      );
      expect(await redis.zpopmin('z'), <String>['b', '3']);
      expect(await redis.zpopmax('z', 1), <String>['d', '9']);
      RedisScanResult res = await redis.zscan('z', 0);
      expect(res.items, <String>['c', '3.5', 'a', '5']);
      expect(await redis.zremrangebyrank('z', 0, 0), 1);
      expect(await redis.zremrangebyscore('z', '-inf', 10), 1);
      expect(await redis.zadd('z', <String, num>{'x': 1}), 1);
      expect(await redis.zrem('z', <String>['x']), 1);
    });
  });

  group('server |', () {
    test('server and connection commands', () async {
      Redis redis = prefixedClient('server');
      expect(await redis.ping(), 'PONG');
      expect(await redis.ping('hi'), 'hi');
      expect(await redis.echo('မင်္ဂလာပါ'), 'မင်္ဂလာပါ');
      expect(await redis.dbsize(), isA<int>());
      expect(await redis.info('server'), contains('redis_version'));
      expect(await redis.time(), hasLength(2));

      Redis other = Redis(testOptions());
      expect(await other.select(3), 'OK');
      await other.set('selectkey', 'db3');
      expect(await redis.get('selectkey'), isNull);
      expect(await other.get('selectkey'), 'db3');
      await other.del('selectkey');
      expect(await other.quit(), 'OK');
    });
  });

  group('scripting |', () {
    test('eval, evalsha, script load', () async {
      Redis redis = prefixedClient('script');
      await redis.set('foo', 'bar');
      String lua = "return {KEYS[1], redis.call('GET', KEYS[1]), ARGV[1]}";
      expect(await redis.eval(lua, 1, <Object>['foo', 7]), <dynamic>[
        '${redis.option.keyPrefix}:foo',
        'bar',
        '7',
      ]);
      String sha = await redis.script('LOAD', <Object>[lua]);
      expect(await redis.evalsha(sha, 1, <Object>['foo', 8]), <dynamic>[
        '${redis.option.keyPrefix}:foo',
        'bar',
        '8',
      ]);
      expect(await redis.script('EXISTS', <Object>[sha]), <dynamic>[1]);
      await expectLater(
        redis.eval("return redis.error_reply('boom')", 0),
        throwsA(isA<RedisError>()),
      );
    });
  });

  group('pub/sub |', () {
    test('subscribe, psubscribe, unsubscribe, punsubscribe', () async {
      Redis sub = Redis(testOptions());
      Redis pub = Redis(testOptions());
      String ch = uniquePrefix('ch');
      List<String> got = <String>[];
      Completer<void> twoMessages = Completer<void>();

      RedisSubscriber s = await sub.subscribe(<String>['$ch:a', '$ch:b']);
      s.onMessage = (String channel, String? message) {
        got.add('$channel=$message');
      };
      RedisSubscriber ps = await sub.psubscribe('$ch:p.*');
      ps.onPatternMessage = (String pattern, String channel, String? message) {
        got.add('$pattern|$channel=$message');
        if (!twoMessages.isCompleted) twoMessages.complete();
      };

      expect(await pub.publish('$ch:a', 'one'), 1);
      expect(await pub.publish('$ch:p.x', 'two'), 1);
      await twoMessages.future.timeout(Duration(seconds: 2));
      expect(got, <String>['$ch:a=one', '$ch:p.*|$ch:p.x=two']);

      await sub.unsubscribe('$ch:a');
      expect(await pub.publish('$ch:a', 'gone'), 0);
      expect(await pub.publish('$ch:b', 'still'), 1);
      await sub.punsubscribe();
      expect(await pub.publish('$ch:p.x', 'gone'), 0);
      await sub.unsubscribe();
      // back to normal mode
      expect(await sub.ping(), 'PONG');
      await sub.quit();
      await pub.quit();
    });
  });

  group('multi and pipeline |', () {
    test('multi runs on one connection and returns EXEC result', () async {
      Redis redis = prefixedClient('multi');
      await redis.set('str', 'x');
      List<dynamic> res = await redis
          .multi()
          .set('a', '1')
          .incr('a')
          .lpush('str', 'boom')
          .hset('h', <String, Object>{'f': 'v'})
          .call('PING')
          .get('a')
          .exec();
      expect(res[0], 'OK');
      expect(res[1], 2);
      expect(res[2], isA<RedisError>());
      expect(res[3], 1);
      expect(res[4], 'PONG');
      expect(res[5], '2');
    });

    test('multi throws EXECABORT when a command is rejected', () async {
      Redis redis = prefixedClient('multiabort');
      await expectLater(
        redis.multi().set('a', '1').call('NOT_A_COMMAND').exec(),
        throwsA(isA<RedisError>()),
      );
      expect(await redis.get('a'), isNull);
    });

    test('multi works while the main connection is busy', () async {
      Redis redis = prefixedClient('multibusy');
      List<Future<dynamic>> jobs = <Future<dynamic>>[
        for (int i = 0; i < 20; i++) redis.multi().incr('n').incr('n').exec(),
      ];
      List<dynamic> results = await Future.wait(jobs);
      for (dynamic r in results) {
        expect((r as List<dynamic>)[1], (r[0] as int) + 1);
      }
      expect(await redis.get('n'), '40');
    });

    test('pipeline returns results in order with errors inline', () async {
      Redis redis = prefixedClient('pipeline');
      List<dynamic> res = await redis
          .pipeline()
          .set('a', 'x')
          .get('a')
          .call('NOT_A_COMMAND')
          .zadd('z', <String, num>{'m': 1})
          .sadd('s', <String>['1', '2'])
          .exists(<String>['a', 's'])
          .exec();
      expect(res[0], 'OK');
      expect(res[1], 'x');
      expect(res[2], isA<RedisError>());
      expect(res[3], 1);
      expect(res[4], 2);
      expect(res[5], 2);
      expect(await redis.pipeline().exec(), <dynamic>[]);
    });
  });
}
