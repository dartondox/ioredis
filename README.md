# ioredis

Redis client for dart.

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

## Pool connection

```dart 
Redis redis = new Redis(RedisOptions(maxConnection: 10));
String? value = await redis.get('key');
```

## Pipelining

```dart
Redis redis = new Redis();
List<dynamic> result = await redis.multi()
    .set('key', 'value')
    .set('key2', 'value2')
    .get('key')
    .get('key2')
    .exec()

// result => ['OK', 'OK', 'value', 'value2']
```
