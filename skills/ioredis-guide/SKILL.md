---
name: ioredis-guide
description: Use when you connect to Redis from Dart with the ioredis package. Covers connecting (options, redis:// URL, TLS, auth, db, key prefix), commands, pipelines, MULTI transactions, pub/sub, reconnect and error handling.
---

# ioredis guide

`ioredis` is a standalone Redis client for Dart (not tied to Dox). One `Redis` object shares a connection, sends commands in one write when they start in the same event-loop turn (auto-pipelining), and opens pool connections only when a blocking command waits. It connects again by itself after a lost connection.

## Install

```yaml
dependencies:
  ioredis: ^3.2.0
```

```dart
import 'package:ioredis/ioredis.dart';
```

Connect is lazy. `await redis.connect()` is optional. The first command connects.

## Connect

```dart
Redis redis = Redis(); // 127.0.0.1:6379

Redis redis = Redis(RedisOptions(
  host: '127.0.0.1',
  port: 6379,
  username: 'app',
  password: 'secret',
  db: 1,
  keyPrefix: 'myapp',
));

// from a URL
Redis redis = Redis(RedisOptions.fromUrl('rediss://user:pass@example.com:6380/2'));
```

| Option | Default | Meaning |
| --- | --- | --- |
| `host` / `port` | `127.0.0.1` / `6379` | server |
| `username` / `password` | `null` | AUTH. A user with no password sends no AUTH. |
| `db` | `0` | database index |
| `secure` | `false` | TLS |
| `onBadCertificate` | `null` | return `true` to accept a bad certificate. With `null`, a bad certificate aborts. |
| `keyPrefix` | `''` | `keyPrefix: 'foo'` makes `set('bar', ...)` send `SET foo:bar` |
| `connectTimeout` | 10 s | socket connect and handshake |
| `retryStrategy` | `min(50 * times, 2000)` ms | wait time before each reconnect |
| `onError` | `null` | handler for connection errors |
| `maxConnection` | `10` | most connections, main one included |
| `idleTimeout` | 10 s | close an unused pool connection after this |

`RedisOptions.fromUrl`:

- `rediss://` turns on TLS.
- The db is the path (`/2`) or `?db=2`. The path wins.
- Encode special characters in user and password with percent signs. `redis://:pass@host` has a password and no user.
- It throws `ArgumentError` for another scheme and `FormatException` for a bad URL, port or db. Messages hide the password.
- Other options are named arguments: `RedisOptions.fromUrl(url, keyPrefix: 'app', onError: ...)`.

Close with `await redis.quit()` (sends QUIT, closes all connections) or `await redis.disconnect()`.

Check the connection state with `redis.connection.status` (`RedisConnectionStatus.connected`, `disconnected`, `connecting`).

## Commands

Values can be `String` or numbers. Replies: integers are `int`, strings are `String`, missing values are `null`, arrays are `List<dynamic>`, float replies (`incrbyfloat`, `hincrbyfloat`, `zincrby`, `zscore`) are `double`.

```dart
// strings
await redis.set('k', 'v');
await redis.set('k', 'v', 'EX', 10);
await redis.set('k', 'v', 'NX');             // null when the key exists
String? value = await redis.get('k');
List<String?> many = await redis.mget(['a', 'b']);
await redis.mset({'a': 1, 'b': 2});
await redis.incr('n');                        // also incrby, decr, decrby, incrbyfloat

// keys
await redis.del(['a', 'b']);                  // delete('a') and mdelete([...]) also work
await redis.exists('a');                      // 0 or 1
await redis.expire('a', 60);                  // also pexpire, expireat, persist, ttl, pttl
List<String> keys = await redis.keys('user:*');
RedisScanResult res = await redis.scan(0, match: 'user:*', count: 100);
// res.cursor is '0' when done, res.items has the keys

// hashes
await redis.hset('user:1', {'name': 'Ann', 'age': 30});
Map<String, String> user = await redis.hgetall('user:1');
await redis.hget('user:1', 'name');

// lists
await redis.rpush('q', ['a', 'b']);
await redis.lpop('q');
await redis.lrange('q', 0, -1);
List<String>? item = await redis.blpop(['q'], 5); // [key, value] or null after 5 s

// sets
await redis.sadd('tags', ['a', 'b']);
await redis.smembers('tags');

// sorted sets
await redis.zadd('board', {'ann': 10, 'bob': 7.5});
await redis.zrange('board', 0, -1, withScores: true);
await redis.zscore('board', 'ann');           // double

// server
await redis.ping();                           // 'PONG'
await redis.select(1);                        // all connections of this client switch
await redis.flushdb();
```

More commands exist for each type (hscan, sscan, zscan, lmove, zpopmin, getex, and others). Check `lib/src/commands/` before you write a raw command.

Any other command, with `call()` (key prefix is NOT added) or `sendCommand()`:

```dart
await redis.call('GEOADD', ['places', 13.361389, 38.115556, 'Palermo']);
await redis.sendCommand(['GET', 'key']);
```

Lua scripts:

```dart
await redis.eval("return redis.call('GET', KEYS[1])", 1, ['foo']);
String sha = await redis.script('LOAD', ["return 'hi'"]);
await redis.evalsha(sha, 0);
```

The first `numKeys` items are keys and get the prefix.

## Pipeline

Sends all commands in one write with no MULTI. The result is a list in order. A failed command is a `RedisError` item in the list, not a throw.

```dart
List<dynamic> results = await redis
    .pipeline()
    .set('key', 'value')
    .get('key')
    .call('PING')
    .exec();
// ['OK', 'value', 'PONG']
```

## Transaction (MULTI)

Runs inside MULTI ... EXEC on one connection.

```dart
List<dynamic> result = await redis
    .multi()
    .set('key', 'value')
    .incr('counter')
    .call('HSET', ['hash', 'field', 'value'])
    .get('key')
    .exec();
```

- A command that fails while running is a `RedisError` item in the result.
- If Redis rejects a command before EXEC, `exec()` throws the EXECABORT `RedisError`.
- `multi()` and `pipeline()` have `call()` plus these typed methods only: `set`, `get`, `del`, `exists`, `expire`, `ttl`, `incr`, `incrby`, `decr`, `hset`, `hget`, `hdel`, `lpush`, `rpush`, `sadd`, `srem`, `zadd`. Use `call()` for anything else. Results are raw replies.

## Pub/Sub

A subscribing client is locked to subscribe mode. Use a separate client to publish and run commands. `duplicate()` makes one with the same options.

```dart
Redis sub = Redis();
Redis pub = sub.duplicate();

RedisSubscriber chat = await sub.subscribe('chat');
chat.onMessage = (String channel, String? message) {
  print('$channel: $message');
};

RedisSubscriber news = await sub.psubscribe('news.*');
news.onPatternMessage = (String pattern, String channel, String? message) {};

await pub.publish('chat', 'hello');

await sub.unsubscribe('chat');    // no argument: all channels
await sub.punsubscribe('news.*'); // no argument: all patterns
```

- Binary: `publish()` takes a `String` or `Uint8List`. Use `onMessageBytes` and `onPatternMessageBytes` to get the exact bytes. A subscriber can have both a text and a bytes callback.
- If `onPatternMessage` is not set, `onMessage` is called for pattern messages.
- Channel names and patterns do NOT get `keyPrefix`.
- After a lost connection, the client reconnects and subscribes again to the same channels and patterns.

## Errors and reconnect

```dart
try {
  await redis.lpush('a-string-key', 'x');
} on RedisError catch (e) {
  print(e.message); // WRONGTYPE Operation against a key holding the wrong kind of value
}
```

- An error reply from Redis throws `RedisError` (has `message`). The connection keeps working.
- A socket problem (host down, `Redis is not connected`) throws `SocketException` from the command.
- Connection errors while the client reconnects do not throw to your app. They go to `RedisOptions.onError`. With no `onError`, they are printed. Set `onError` in production to log them.
- On a lost connection the client waits `retryStrategy(times)`, then tries again, forever, until `disconnect()` or `quit()`. A wrong password (AUTH or SELECT error) does not retry. The next command connects again and gets the error.

```dart
Redis redis = Redis(RedisOptions(
  onError: (dynamic error) => log.warning('redis: $error'),
  retryStrategy: (int times) => Duration(milliseconds: (times * 100).clamp(100, 5000)),
));
```

## Gotchas

- `await` every command. A command you do not await still runs, but its error is lost.
- Do not send normal commands on a client that has called `subscribe()`. Use `duplicate()`.
- `keyPrefix` is added to key arguments only. It is NOT added to `keys()` and `scan()` patterns, to channels, or to `call()`/`sendCommand()`.
- `select(n)` changes `option.db`, and `duplicate()` shares the same options object, so a duplicate also uses the new db for new connections.
- `set(key, value, 'EX', 10)` takes the options as extra positional arguments, like Node ioredis.
- `RedisSetOption` is deprecated and unused.
- Blocking commands (`blpop`, `brpop`, `blmove`) take a pool connection, so other commands do not wait. Keep `maxConnection` large enough.
- Tests need Redis on port 6379 and 8379 (`REDIS_HOST`, `REDIS_PORT`, `REDIS_PORT_2`).
