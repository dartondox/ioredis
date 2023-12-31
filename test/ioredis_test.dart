import 'dart:io';

import 'package:ioredis/ioredis.dart';
import 'package:test/test.dart';

void main() {
  group('Redis |', () {
    test('race request', () async {
      Redis redis = Redis(RedisOptions(
        idleTimeout: Duration(seconds: 3),
      ));

      await redis.set('key1', 'redis1');
      await redis.set('key2', 'redis2');
      await redis.set('key3', 'redis3');

      List<Future<dynamic>> operations = <Future<dynamic>>[
        redis.get('key1'),
        redis.get('key2'),
        redis.get('key3'),
      ];

      List<dynamic> results = await Future.wait(operations);

      expect(results.first, 'redis1');
      expect(results.last, 'redis3');
      expect(results.length, 3);
    });

    test('keyPrefix', () async {
      Redis redis = Redis(RedisOptions(keyPrefix: 'dox'));

      await redis.set('foo', 'redis1');
      String? s1 = await redis.get('key1');

      expect(s1, 'redis1');

      Redis redis2 = Redis();
      String? s2 = await redis2.get('dox:foo');

      expect(s2, 'redis1');

      expect(s1, s2);

      await redis.delete('foo');

      String? s3 = await redis2.get('dox:foo');

      expect(s3, null);
    });

    test('ut8f', () async {
      Redis redis = Redis(RedisOptions(
        port: 8379,
      ));
      await redis.set('dox', 'မင်္ဂလာပါ');
      String? data = await redis.get('dox');
      expect(data, 'မင်္ဂလာပါ');
    });

    test('multi', () async {
      Redis redis = Redis();
      List<dynamic> result = await redis
          .multi()
          .set('foo', 'bar')
          .set('bar', 'foo')
          .get('foo')
          .get('bar')
          .exec();

      expect(<String>['OK', 'OK', 'bar', 'foo'], result);
    });

    test('custom socket', () async {
      Redis redis = Redis();
      redis.setSocket(await Socket.connect('127.0.0.1', 6379));
      await redis.set('dox', 'redis');
      String? data = await redis.get('dox');
      expect(data, 'redis');
    });

    test('test', () async {
      Redis redis = Redis(RedisOptions(port: 8379));

      await redis.set('dox', '\$Dox Framework');
      await redis.set('dox2', '*framework');

      String? data1 = await redis.get('dox');
      String? data2 = await redis.get('dox2');

      expect(data1, '\$Dox Framework');
      expect(data2, '*framework');
    });

    test('different db', () async {
      Redis db1 = Redis(RedisOptions(port: 8379));
      Redis db2 = Redis(RedisOptions(port: 8379, db: 2));

      await db1.set('dox', 'value1');
      await db2.set('dox', 'value2');

      String? data1 = await db1.get('dox');
      String? data2 = await db2.get('dox');

      expect(true, data1 != data2);
    });

    test('duplicate', () async {
      Redis db1 = Redis(RedisOptions(port: 8379));
      Redis db2 = db1.duplicate();

      await db1.set('dox', 'value1');
      await db2.set('dox', 'value2');

      String? data1 = await db1.get('dox');
      String? data2 = await db2.get('dox');

      expect(data1, data2);
    });

    test('pub/sub', () async {
      Redis sub = Redis(RedisOptions(port: 8379));

      RedisSubscriber subscriber1 = await sub.subscribe(<String>['chat1']);
      subscriber1.onMessage = (String channel, String? message) {
        print(channel);
        print(message);
      };

      RedisSubscriber subscriber2 = await sub.subscribe('chat2');
      subscriber2.onMessage = (String channel, String? message) {
        print(channel);
        print(message);
      };

      Redis pub = sub.duplicate();
      await pub.publish('chat1', 'hi');
      await pub.publish('chat2', 'hello');

      await Future<void>.delayed(Duration(seconds: 1));
    });

    test('MGET', () async {
      Redis redis = Redis(
        RedisOptions(
          port: 8379,
        ),
      );

      await redis.set('A', '-AA');
      await redis.set('B', '+BB');
      await redis.set('C', 'CC');
      List<String?> res = await redis.mget(<String>['A', 'B', 'C', 'D']);
      expect(<String?>['-AA', '+BB', 'CC', null], res);
    });

    test('test expiry time', () async {
      Redis redis = Redis(
        RedisOptions(
          port: 8379,
        ),
      );

      await redis.set(
        'something',
        'Dox Framework',
        'EX',
        Duration(seconds: 2).inSeconds,
      );

      await Future<void>.delayed(Duration(seconds: 1));

      String? data = await redis.get('something');

      expect(data, 'Dox Framework');

      await Future<void>.delayed(Duration(seconds: 3));

      String? data2 = await redis.get('something');

      expect(data2, null);
    });
  });
}
