import 'dart:async';
import 'dart:io';

import 'package:ioredis/ioredis.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  group('Redis |', () {
    test('race request', () async {
      Redis redis = prefixedClient('race');
      redis.option.idleTimeout = Duration(seconds: 3);

      await redis.set('key1', 'redis1');
      await redis.set('key2', 'redis2');
      await redis.set('key3', 'redis3');

      List<dynamic> results = await Future.wait(<Future<dynamic>>[
        redis.get('key1'),
        redis.get('key2'),
        redis.get('key3'),
      ]);

      expect(results, <String>['redis1', 'redis2', 'redis3']);
    });

    test('keyPrefix', () async {
      Redis redis = prefixedClient('prefix');
      Redis raw = testClient();
      String prefix = redis.option.keyPrefix;

      await redis.set('foo', 'redis1');
      expect(await redis.get('foo'), 'redis1');
      expect(await raw.get('$prefix:foo'), 'redis1');

      await redis.delete('foo');
      expect(await raw.get('$prefix:foo'), isNull);
    });

    test('utf8', () async {
      Redis redis = prefixedClient('utf8', port: redisPort2);
      await redis.set('dox', 'မင်္ဂလာပါ');
      expect(await redis.get('dox'), 'မင်္ဂလာပါ');
    });

    test('multi', () async {
      Redis redis = prefixedClient('oldmulti');
      List<dynamic> result = await redis
          .multi()
          .set('foo', 'bar')
          .set('bar', 'foo')
          .get('foo')
          .get('bar')
          .exec();

      expect(result, <String>['OK', 'OK', 'bar', 'foo']);
    });

    test('custom socket', () async {
      Redis redis = prefixedClient('socket');
      redis.setSocket(await Socket.connect(redisHost, redisPort));
      await redis.set('dox', 'redis');
      expect(await redis.get('dox'), 'redis');
    });

    test('values that start with RESP type bytes', () async {
      Redis redis = prefixedClient('resp', port: redisPort2);

      await redis.set('dox', '\$Dox Framework');
      await redis.set('dox2', '*framework');

      expect(await redis.get('dox'), '\$Dox Framework');
      expect(await redis.get('dox2'), '*framework');
    });

    test('different db', () async {
      String key = uniquePrefix('db');
      Redis db1 = testClient(port: redisPort2);
      Redis db2 = testClient(port: redisPort2, db: 2);
      addTearDown(() async {
        await db1.del(key);
        await db2.del(key);
      });

      await db1.set(key, 'value1');
      await db2.set(key, 'value2');

      expect(await db1.get(key), 'value1');
      expect(await db2.get(key), 'value2');
    });

    test('duplicate', () async {
      Redis db1 = prefixedClient('dup', port: redisPort2);
      Redis db2 = db1.duplicate();
      addTearDown(db2.quit);

      await db1.set('dox', 'value1');
      await db2.set('dox', 'value2');

      expect(await db1.get('dox'), 'value2');
      expect(await db2.get('dox'), 'value2');
    });

    test('pub/sub', () async {
      String channel = uniquePrefix('chat');
      Redis sub = testClient(port: redisPort2);
      Redis pub = sub.duplicate();
      addTearDown(pub.quit);
      List<String> got = <String>[];
      Completer<void> done = Completer<void>();

      RedisSubscriber subscriber1 = await sub.subscribe(<String>['$channel:1']);
      subscriber1.onMessage = (String channel, String? message) {
        got.add('$channel=$message');
      };

      RedisSubscriber subscriber2 = await sub.subscribe('$channel:2');
      subscriber2.onMessage = (String channel, String? message) {
        got.add('$channel=$message');
        done.complete();
      };

      await pub.publish('$channel:1', 'hi');
      await pub.publish('$channel:2', 'hello');
      await done.future.timeout(Duration(seconds: 2));

      expect(got, <String>['$channel:1=hi', '$channel:2=hello']);
    });

    test('MGET', () async {
      Redis redis = prefixedClient('mget', port: redisPort2);

      await redis.set('A', '-AA');
      await redis.set('B', '+BB');
      await redis.set('C', 'CC');
      List<String?> res = await redis.mget(<String>['A', 'B', 'C', 'D']);
      expect(res, <String?>['-AA', '+BB', 'CC', null]);
    });

    test('expiry time', () async {
      Redis redis = prefixedClient('expiry', port: redisPort2);

      await redis.set('something', 'Dox Framework', 'PX', 300);
      expect(await redis.get('something'), 'Dox Framework');

      await Future<void>.delayed(Duration(milliseconds: 500));
      expect(await redis.get('something'), isNull);
    });
  });
}
