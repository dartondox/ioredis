import 'dart:async';

import 'package:ioredis/ioredis.dart';

/// Needs Redis on 127.0.0.1:6379.
Future<void> main() async {
  Redis redis = Redis(); // 127.0.0.1:6379, change with RedisOptions

  // set and get
  await redis.set('example:name', 'ioredis', 'EX', 60);
  print(await redis.get('example:name')); // ioredis

  // hash
  await redis.hset('example:user', <String, Object>{'name': 'Ann', 'age': 30});
  print(await redis.hgetall('example:user')); // {name: Ann, age: 30}

  // pipeline: many commands in one write
  List<dynamic> results = await redis
      .pipeline()
      .incr('example:counter')
      .incr('example:counter')
      .get('example:counter')
      .exec();
  print(results); // [1, 2, 2] on a fresh key

  // pub/sub: a subscriber needs its own connection
  Redis subscriber = redis.duplicate();
  Completer<void> received = Completer<void>();
  RedisSubscriber sub = await subscriber.subscribe('example:chat');
  sub.onMessage = (String channel, String? message) {
    print('$channel: $message');
    received.complete();
  };
  await redis.publish('example:chat', 'hello');
  await received.future;

  await redis.del(<String>['example:name', 'example:user', 'example:counter']);
  await subscriber.quit();
  await redis.quit();
}
