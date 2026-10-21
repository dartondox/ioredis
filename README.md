# ioredis

Redis client for dart.

> **2.0.0-alpha is a prerelease.** The API can still change before 2.0.0.
> It has breaking changes from 1.x. See [CHANGELOG.md](CHANGELOG.md).

## Install

```yaml
dependencies:
  ioredis: ^2.0.0-alpha.1
```

## Features

- Support Pub/Sub
- Support pool connection by default
- Support auto reconnect on failed
- Support retry strategy
- Support selectable database

## Basic Usage

```dart
/// Create a new redis instance
Redis redis = new Redis();
Redis redis = new Redis(RedisOptions(host: '127.0.0.1', port: 6379));

/// Set value
await redis.set('key', value);

/// Set value with expiry time
await redis.set('key', value, 'EX', 10);

/// Get value
String? value = await redis.get('key');

/// Get multiple values
List<String?> value = await redis.mget(['key1', 'key2']);
```

## Create an instance

```dart
Redis redis = new Redis();
Redis redis = new Redis(RedisOptions(host: '127.0.0.1', port: 6379));
Redis redis = new Redis(
    RedisOptions(
        username: 'root', 
        password: 'password',
        db: 1,
    ),
);
```

## Duplicate

```dart
Redis redis = new Redis();
Redis duplicatedRedis = redis.duplicate();
```

## Pub/Sub

```dart
Redis subClient = new Redis();
Redis pubClient = subClient.duplicate();

RedisSubscriber subscriber = await subClient.subscribe('chat')
subscriber.onMessage = (String channel, String? message) {
    print(channel, message);
}

await pubClient.publish('chat', 'hello');

// pattern subscribe
RedisSubscriber news = await subClient.psubscribe('news.*');
news.onPatternMessage = (String pattern, String channel, String? message) {
    print('$channel $message');
};

await subClient.unsubscribe('chat');   // no argument: all channels
await subClient.punsubscribe('news.*'); // no argument: all patterns
```

## Delete

```dart
Redis redis = new Redis();
await redis.delete('key')
await redis.mdelete(['key1', 'key2'])
```

## Flushdb

```dart
Redis redis = new Redis();
await redis.flushdb()
```

## Send command

```dart 
Redis redis = new Redis();
await redis.sendCommand(['GET', 'key'])
```

## Any command with call()

`call()` sends any command, like `redis.call` in Node ioredis.
Arguments can be strings or numbers. The key prefix is NOT added.

```dart
await redis.call('GEOADD', ['places', 13.361389, 38.115556, 'Palermo']);
List<dynamic> res = await redis.call('GEORADIUS', ['places', 15, 37, 200, 'km', 'WITHDIST']);
```

## Errors

An error reply from Redis throws `RedisError`. The connection keeps working.

```dart
try {
  await redis.lpush('a-string-key', 'x');
} on RedisError catch (e) {
  print(e.message); // WRONGTYPE Operation against a key holding the wrong kind of value
}
```

## Reply types

- Integer replies are `int`.
- Strings are `String`. Missing values are `null`.
- Arrays are `List<dynamic>` and can be nested.
- Float replies (`incrbyfloat`, `hincrbyfloat`, `zincrby`, `zscore`) are `double`.

## Keys

```dart
await redis.del(['a', 'b']);          // 2
await redis.exists('a');              // 0
await redis.expire('a', 60);          // also pexpire, expireat, persist
await redis.ttl('a');                 // also pttl
await redis.type('a');                // 'string'
await redis.rename('a', 'b');         // also renamenx, copy, unlink, randomkey
List<String> keys = await redis.keys('user:*');
RedisScanResult res = await redis.scan(0, match: 'user:*', count: 100);
print(res.cursor); // '0' when done
print(res.items);
```

The key prefix is added to every key argument. Like Node ioredis,
it is NOT added to `keys()` and `scan()` patterns, and NOT to channel names.

## Strings

```dart
await redis.set('k', 'v', 'EX', 10);
await redis.set('k', 'v', 'NX');            // null when the key exists
await redis.set('k', 'v', 'EX', 10, 'NX');
String? old = await redis.set('k', 'v2', 'GET');
await redis.mset({'a': 1, 'b': 2});         // also msetnx
await redis.incr('n');                       // also incrby, decr, decrby, incrbyfloat
await redis.append('k', 'more');             // also strlen, getrange, setrange
await redis.getdel('k');                     // also getset, getex, setnx, setex, psetex
```

## Hashes

```dart
await redis.hset('user:1', {'name': 'Ann', 'age': 30});
Map<String, String> user = await redis.hgetall('user:1');
await redis.hget('user:1', 'name');
await redis.hincrby('user:1', 'age', 1);
// also hsetnx, hmget, hdel, hexists, hkeys, hvals, hlen, hincrbyfloat, hstrlen, hscan
```

## Lists

```dart
await redis.rpush('q', ['a', 'b']);
await redis.lpop('q');                // 'a'
await redis.lpop('q', 2);             // ['b']
await redis.lrange('q', 0, -1);
List<String>? item = await redis.blpop(['q'], 5); // [key, value] or null
// also lpushx, rpushx, rpop, llen, lindex, lset, lrem, ltrim, linsert, lmove, brpop
```

## Sets

```dart
await redis.sadd('tags', ['a', 'b']);
await redis.smembers('tags');
await redis.sismember('tags', 'a');   // 1
// also srem, smismember, scard, spop, srandmember, smove,
// sinter, sunion, sdiff, sinterstore, sunionstore, sdiffstore, sscan
```

## Sorted sets

```dart
await redis.zadd('board', {'ann': 10, 'bob': 7.5});
await redis.zadd('board', {'ann': 20}, gt: true, ch: true);
await redis.zrange('board', 0, -1, withScores: true); // ['bob', '7.5', 'ann', '20']
await redis.zscore('board', 'ann');   // 20.0
// also zrem, zincrby, zcard, zcount, zrank, zrevrank, zrevrange,
// zrangebyscore, zrevrangebyscore, zremrangebyrank, zremrangebyscore,
// zpopmin, zpopmax, zscan
```

## Server

```dart
await redis.ping();       // 'PONG'
await redis.echo('hi');
await redis.select(1);    // all connections of this client switch
await redis.dbsize();
await redis.info('server');
await redis.time();
await redis.flushall();
await redis.quit();       // QUIT, then disconnect
```

## Scripting

```dart
await redis.eval("return redis.call('GET', KEYS[1])", 1, ['foo']);
String sha = await redis.script('LOAD', ["return 'hi'"]);
await redis.evalsha(sha, 0);
```

The first `numKeys` items are keys and get the key prefix.

## Pool connection

```dart 
Redis redis = new Redis(RedisOptions(maxConnection: 10));
String? value = await redis.get('key');
```

## Transaction (multi)

All commands run inside MULTI ... EXEC on one connection, sent in one write.
`exec()` returns the EXEC result. If one command fails while running,
its item is a `RedisError` (no throw). If Redis rejects a command before
EXEC, `exec()` throws the EXECABORT `RedisError`.

```dart
Redis redis = new Redis();
List<dynamic> result = await redis.multi()
    .set('key', 'value')
    .incr('counter')
    .call('HSET', ['hash', 'field', 'value']) // any command
    .get('key')
    .exec();

// result => ['OK', 1, 1, 'value']
```

## Pipeline

All commands are sent in one write on one connection, without MULTI.
Results come back in order. Errors are `RedisError` items in the result.

```dart
List<dynamic> result = await redis.pipeline()
    .set('key', 'value')
    .get('key')
    .call('PING')
    .exec();

// result => ['OK', 'value', 'PONG']
```

`multi()` and `pipeline()` have `call()` plus these typed methods:
set, get, del, exists, expire, ttl, incr, incrby, decr, hset, hget, hdel,
lpush, rpush, sadd, srem, zadd. Results are raw replies.

## Running tests

The tests need two Redis servers: one on port 6379 and one on port 8379.

```sh
redis-server --port 8379 --daemonize yes --save '' --appendonly no
dart test
redis-cli -p 8379 shutdown nosave
```

You can change the host and ports with env vars:

- `REDIS_HOST` (default `127.0.0.1`)
- `REDIS_PORT` (default `6379`)
- `REDIS_PORT_2` (default `8379`)
