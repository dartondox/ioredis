import 'dart:async';
import 'dart:io';

import 'package:ioredis/ioredis.dart';
import 'package:ioredis/src/default.dart';
import 'package:ioredis/src/redis_connection_pool.dart';
import 'package:ioredis/src/redis_response.dart';

class Redis {
  late RedisConnection connection;

  late RedisOptions option = defaultRedisOptions;

  late RedisConnectionPool pool;

  /// Redis client type
  /// subscriber, publisher or normal set and get
  RedisType redisClientType = RedisType.normal;

  Redis([RedisOptions? opt]) {
    if (opt != null) {
      option = opt;
    }
    connection = RedisConnection(option);
    pool = RedisConnectionPool(option, connection);
  }

  /// Set custom socket
  Redis setSocket(Socket socket) {
    connection.setSocket(socket);
    return this;
  }

  /// Connect to redis connection
  /// This call can be optional. If it function did not invoke initially,
  /// it will get call on first redis command.
  Future<void> connect() async {
    await connection.connect();
  }

  /// Disconnect to redis connection
  Future<void> disconnect() async {
    await connection.disconnect();
  }

  /// Duplicate new redis connection
  Redis duplicate() {
    return Redis(option);
  }

  /// Set key value to redis
  /// ```
  /// await redis.set('foo', 'bar');
  /// ```
  Future<dynamic> set(String key, String value,
      [String? option, dynamic optionValue]) async {
    List<String> commands = <String>[
      'SET',
      _setPrefixInKeys(<String>[key]).first,
      value.toString()
    ];
    if (option != null && optionValue != null) {
      commands.addAll(<String>[option.toUpperCase(), optionValue.toString()]);
    }
    String? val = await sendCommand(commands);
    if (!RedisResponse.ok(val)) {
      throw Exception(val);
    }
  }

  /// Get value of a key
  /// ```
  /// await redis.get('foo');
  /// ```
  Future<String?> get(String key) async {
    return await sendCommand(<String>[
      'GET',
      _setPrefixInKeys(<String>[key]).first
    ]);
  }

  /// Get value of a key
  /// ```
  /// await redis.get('foo');
  /// ```
  Future<List<String?>> mget(List<String> keys) async {
    return await sendCommand(<String>['MGET', ..._setPrefixInKeys(keys)]);
  }

  /// Delete a key
  /// ```
  /// await redis.get('foo');
  /// ```
  Future<void> delete(String key) async {
    await sendCommand(<String>[
      'DEL',
      _setPrefixInKeys(<String>[key]).first
    ]);
  }

  /// Delete multiple key
  /// ```
  /// await redis.get('foo');
  /// ```
  Future<void> mdelete(List<String> keys) async {
    await sendCommand(<String>['DEL', ..._setPrefixInKeys(keys)]);
  }

  /// flush all they data from currently selected DB
  /// ```
  /// await redis.flushdb();
  /// ```
  Future<void> flushdb() async {
    await sendCommand(<String>['FLUSHDB']);
  }

  /// Subscribe to channel
  /// ```
  /// RedisSubscriber subscriber = await redis.subscribe('channel');
  /// RedisSubscriber subscriber = await redis.subscribe(['channel', 'chat']);
  ///
  /// subscriber.onMessage = (String channel,String? message) {
  ///
  /// }
  /// ```
  Future<RedisSubscriber> subscribe(Object channel) async {
    if (redisClientType == RedisType.publisher) {
      throw Exception('cannot subscribe and publish on same connection');
    }
    redisClientType = RedisType.subscriber;
    RedisSubscriber cb = RedisSubscriber();
    if (channel is String) {
      await sendCommand(<String>['SUBSCRIBE', channel]);
      connection.subscribeListeners[<String>[channel]] = cb;
    } else if (channel is List<String>) {
      await sendCommand(<String>['SUBSCRIBE', ...channel]);
      connection.subscribeListeners[channel] = cb;
    } else {
      throw Exception('Invalid type for channel');
    }
    return cb;
  }

  /// Publish message to a channel
  /// ```
  /// await redis.publish('chat', 'hello')
  /// ```
  Future<void> publish(String channel, String message) async {
    if (redisClientType == RedisType.subscriber) {
      throw Exception('cannot subscribe and publish on same connection');
    }
    redisClientType = RedisType.publisher;
    await sendCommand(<String>['PUBLISH', channel, message]);
  }

  /// send command to connection
  Future<dynamic> sendCommand(List<String> commandList) async {
    if (connection.isBusy == false || redisClientType != RedisType.normal) {
      return connection.sendCommand(commandList);
    }
    return pool.sendCommand(commandList);
  }

  /// setting keys prefix before setting or getting values
  List<String> _setPrefixInKeys(List<String> keys) {
    return keys
        .map((String k) =>
            option.keyPrefix.isNotEmpty ? '${option.keyPrefix}:$k' : k)
        .toList();
  }
}
