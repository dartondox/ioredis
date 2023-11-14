import 'dart:io';

import 'package:ioredis/ioredis.dart';
import 'package:test/test.dart';

void main() {
  group('Redis |', () {
    test('race request', () async {
      Redis redis = Redis();

      await redis.set('key1', 'redis1');
      await redis.set('key2', 'redis2');

      List<Future<dynamic>> operations = <Future<dynamic>>[
        redis.get('key1'),
        redis.get('key2'),
      ];

      List<dynamic> results = await Future.wait(operations);
      expect(results.length, 2);
    });

    test('ut8f', () async {
      Redis redis = Redis(RedisOptions(
        port: 8379,
      ));
      await redis.set('dox', 'မင်္ဂလာပါ');
      String? data = await redis.get('dox');
      expect(data, 'မင်္ဂလာပါ');
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

    test('response', () {
      // Redis redis = Redis(option: RedisOptions(host: '127.0.0.1', port: 6379));
      // print(redis.response('+OK\r\n'));
      // print(redis.response('-ERR Something went wrong\r\n'));
      // print(redis.response('\$6\r\nfoobar\r\n'));
      // print(redis.response(':42\r\n'));
      // print(redis._response('*3\r\n\$3\r\nfoo\r\n\$3\r\nbar\r\n\$3\r\nbar\r\n'));
    });
  });
}
