import 'dart:math';

import 'package:ioredis/ioredis.dart';

RedisOptions defaultRedisOptions = RedisOptions(
  retryStrategy: (int times) {
    return min(times * 50, 2000);
  },
);
