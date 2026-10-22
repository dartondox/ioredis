import 'dart:io';
import 'dart:math';

import 'package:ioredis/ioredis.dart';
import 'package:test/test.dart';

/// Redis host for tests. Set REDIS_HOST to change it.
final String redisHost = Platform.environment['REDIS_HOST'] ?? '127.0.0.1';

/// First Redis port. Set REDIS_PORT to change it.
final int redisPort = int.parse(Platform.environment['REDIS_PORT'] ?? '6379');

/// Second Redis port. Set REDIS_PORT_2 to change it.
final int redisPort2 = int.parse(
  Platform.environment['REDIS_PORT_2'] ?? '8379',
);

/// Options that point to the test Redis.
RedisOptions testOptions({String keyPrefix = '', int? port, int db = 0}) {
  return RedisOptions(
    host: redisHost,
    port: port ?? redisPort,
    keyPrefix: keyPrefix,
    db: db,
  );
}

/// Unique key prefix per test, so tests do not touch each other.
String uniquePrefix(String name) => 'iotest:$name:${Random().nextInt(1 << 32)}';

/// Client without a prefix. It is closed after the test.
Redis testClient({int? port, int db = 0}) {
  Redis redis = Redis(testOptions(port: port, db: db));
  addTearDown(redis.quit);
  return redis;
}

/// Client with a unique prefix. Its keys are removed and it is closed
/// after the test.
Redis prefixedClient(String name, {int? port}) {
  String prefix = uniquePrefix(name);
  Redis redis = Redis(testOptions(keyPrefix: prefix, port: port));
  addTearDown(() async {
    List<String> keys = await redis.keys('$prefix:*');
    if (keys.isNotEmpty) await redis.call('DEL', keys);
    await redis.quit();
  });
  return redis;
}
