import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:ioredis/ioredis.dart';
import 'package:ioredis/src/default.dart';
import 'package:ioredis/src/redis_connection_pool.dart';
import 'package:ioredis/src/redis_response.dart';

part 'commands/key_commands.dart';
part 'commands/string_commands.dart';
part 'commands/hash_commands.dart';
part 'commands/list_commands.dart';
part 'commands/set_commands.dart';
part 'commands/sorted_set_commands.dart';
part 'commands/server_commands.dart';
part 'redis_multi_command.dart';

/// Result of SCAN, HSCAN, SSCAN and ZSCAN.
/// [cursor] is '0' when the scan is done.
/// [items] is a flat list (field, value, ... for HSCAN and member, score, ... for ZSCAN).
typedef RedisScanResult = ({String cursor, List<String> items});

/// Shared helpers for the command mixins.
abstract class _RedisBase {
  RedisOptions get option;

  /// send command to connection
  Future<dynamic> sendCommand(List<String> commandList);

  /// add the key prefix to one key
  String _key(String key) =>
      option.keyPrefix.isNotEmpty ? '${option.keyPrefix}:$key' : key;

  /// add the key prefix to one key or a list of keys
  List<String> _keys(Object keys) => _args(keys).map(_key).toList();

  /// one value or a list of values to a list of strings
  List<String> _args(Object? values) {
    if (values is Iterable) {
      return values.map((dynamic v) => v.toString()).toList();
    }
    return <String>[values.toString()];
  }

  /// get command to set data to redis
  List<String> getCommandToSetData(
    String key,
    Object value, [
    String? option,
    dynamic optionValue,
    String? flag,
  ]) {
    List<String> command = <String>['SET', _key(key), value.toString()];
    if (option != null) command.add(option.toUpperCase());
    if (optionValue != null) command.add(optionValue.toString());
    if (flag != null) command.add(flag.toUpperCase());
    return command;
  }

  /// get command to get data from redis
  List<String> getCommandToGetData(String key) {
    return <String>['GET', _key(key)];
  }

  List<String> _zaddCommand(
    String key,
    Map<String, num> members, {
    bool nx = false,
    bool xx = false,
    bool gt = false,
    bool lt = false,
    bool ch = false,
  }) {
    List<String> command = <String>['ZADD', _key(key)];
    if (nx) command.add('NX');
    if (xx) command.add('XX');
    if (gt) command.add('GT');
    if (lt) command.add('LT');
    if (ch) command.add('CH');
    members.forEach((String member, num score) {
      command.addAll(<String>[score.toString(), member]);
    });
    return command;
  }

  List<String> _scanOptions({String? match, int? count, String? type}) {
    return <String>[
      if (match != null) ...<String>['MATCH', match],
      if (count != null) ...<String>['COUNT', count.toString()],
      if (type != null) ...<String>['TYPE', type],
    ];
  }

  RedisScanResult _toScanResult(dynamic reply) {
    List<dynamic> list = reply as List<dynamic>;
    return (cursor: list[0] as String, items: List<String>.from(list[1]));
  }

  List<String> _toStrings(dynamic reply) =>
      reply == null ? <String>[] : List<String>.from(reply);

  /// Redis sends floats as strings, also 'inf' and '-inf'.
  double _toDouble(String value) {
    switch (value) {
      case 'inf':
      case '+inf':
        return double.infinity;
      case '-inf':
        return double.negativeInfinity;
    }
    return double.parse(value);
  }
}

class Redis extends _RedisBase
    with
        _KeyCommands,
        _StringCommands,
        _HashCommands,
        _ListCommands,
        _SetCommands,
        _SortedSetCommands,
        _ServerCommands {
  late RedisConnection connection;

  @override
  /// Own copy of the default options, so select() on one client
  /// does not change other clients.
  late RedisOptions option = RedisOptions(
    retryStrategy: defaultRedisOptions.retryStrategy,
  );

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

  /// Send QUIT, then close the connection and the pool connections.
  /// ```
  /// await redis.quit();
  /// ```
  Future<String> quit() async {
    pool.destroyAll();
    return await connection.quit();
  }

  /// Change the database for this client. All open connections switch,
  /// and new pool connections use it too.
  /// Note: it changes `option.db`, so a client made with [duplicate]
  /// (which shares the options) also uses it for new connections.
  /// ```
  /// await redis.select(1);
  /// ```
  Future<String> select(int db) async {
    option.db = db;
    List<RedisConnection> open =
        <RedisConnection>[connection, ...pool.connections]
            .where(
              (RedisConnection c) =>
                  c.status == RedisConnectionStatus.connected,
            )
            .toList();
    for (RedisConnection c in open) {
      await c.sendCommand(<String>['SELECT', '$db']);
    }
    return 'OK';
  }

  /// Send any command. Arguments are sent as they are.
  /// The key prefix is NOT added. Error replies throw [RedisError].
  /// ```
  /// await redis.call('GEOADD', ['places', 13.361389, 38.115556, 'Palermo']);
  /// String? v = await redis.call('GET', ['foo']);
  /// ```
  Future<dynamic> call(
    String command, [
    List<Object> args = const <Object>[],
  ]) async {
    return await sendCommand(<String>[command, ..._args(args)]);
  }

  /// multi commands. All commands run on one connection inside MULTI/EXEC.
  /// Returns the EXEC result. A command that failed inside the transaction
  /// is a [RedisError] item in the result.
  /// ```
  /// List<dynamic> result = await redis.multi()
  ///      .set('foo', 'bar')
  ///      .incr('counter')
  ///      .call('HSET', ['hash', 'f', 'v'])
  ///      .exec();
  /// ```
  RedisMulti multi() {
    return RedisMulti(this);
  }

  /// Pipeline. Queue commands, then send them all in one write on one
  /// connection. Results come back in the same order.
  /// A failed command is a [RedisError] item in the result.
  /// ```
  /// List<dynamic> result = await redis.pipeline()
  ///      .set('foo', 'bar')
  ///      .get('foo')
  ///      .exec();
  /// ```
  RedisPipeline pipeline() {
    return RedisPipeline(this);
  }

  /// Subscribe to channel
  /// ```
  /// RedisSubscriber subscriber = await redis.subscribe('channel');
  /// RedisSubscriber subscriber = await redis.subscribe(['channel', 'chat']);
  ///
  /// subscriber.onMessage = (String channel,String? message) {
  ///
  /// }
  ///
  /// // binary messages, like msgpack
  /// subscriber.onMessageBytes = (String channel, Uint8List message) {
  ///
  /// }
  /// ```
  Future<RedisSubscriber> subscribe(Object channel) async {
    if (redisClientType == RedisType.publisher) {
      throw Exception('cannot subscribe and publish on same connection');
    }
    List<String> channels;
    if (channel is String) {
      channels = <String>[channel];
    } else if (channel is List<String>) {
      channels = channel;
    } else {
      throw Exception('Invalid type for channel');
    }
    redisClientType = RedisType.subscriber;
    // Keep message bytes as they are, for onMessageBytes.
    connection.keepBytes = true;
    RedisSubscriber cb = RedisSubscriber();
    // add the listener first, so no message is lost
    connection.subscribeListeners[channels] = cb;
    await sendCommand(<String>['SUBSCRIBE', ...channels]);
    return cb;
  }

  /// Subscribe to channels by pattern
  /// ```
  /// RedisSubscriber sub = await redis.psubscribe('news.*');
  /// sub.onPatternMessage = (String pattern, String channel, String? message) {
  ///   print('$channel: $message');
  /// };
  /// ```
  Future<RedisSubscriber> psubscribe(Object pattern) async {
    if (redisClientType == RedisType.publisher) {
      throw Exception('cannot subscribe and publish on same connection');
    }
    List<String> patterns = _args(pattern);
    redisClientType = RedisType.subscriber;
    // Keep message bytes as they are, for onMessageBytes.
    connection.keepBytes = true;
    RedisSubscriber cb = RedisSubscriber();
    for (String p in patterns) {
      connection.patternListeners[p] = cb;
    }
    await sendCommand(<String>['PSUBSCRIBE', ...patterns]);
    return cb;
  }

  /// Unsubscribe from channels. Without channels, unsubscribe from all.
  /// ```
  /// await redis.unsubscribe('chat');
  /// await redis.unsubscribe();
  /// ```
  Future<void> unsubscribe([Object? channel]) async {
    List<String> channels = channel == null
        ? connection.subscribeListeners.keys
              .expand((List<String> c) => c)
              .toList()
        : _args(channel);
    await sendCommand(<String>['UNSUBSCRIBE', ...channels]);

    Map<List<String>, RedisSubscriber> listeners =
        Map<List<String>, RedisSubscriber>.of(connection.subscribeListeners);
    connection.subscribeListeners.clear();
    listeners.forEach((List<String> key, RedisSubscriber cb) {
      List<String> left = key
          .where((String c) => !channels.contains(c))
          .toList();
      if (left.isNotEmpty) connection.subscribeListeners[left] = cb;
    });
    _resetClientTypeIfNoSubscription();
  }

  /// Unsubscribe from patterns. Without patterns, unsubscribe from all.
  /// ```
  /// await redis.punsubscribe('news.*');
  /// ```
  Future<void> punsubscribe([Object? pattern]) async {
    List<String> patterns = pattern == null
        ? connection.patternListeners.keys.toList()
        : _args(pattern);
    await sendCommand(<String>['PUNSUBSCRIBE', ...patterns]);
    for (String p in patterns) {
      connection.patternListeners.remove(p);
    }
    _resetClientTypeIfNoSubscription();
  }

  void _resetClientTypeIfNoSubscription() {
    if (connection.subscribeListeners.isEmpty &&
        connection.patternListeners.isEmpty) {
      redisClientType = RedisType.normal;
      connection.keepBytes = false;
    }
  }

  /// Publish message to a channel. Returns how many clients got it.
  /// The message is a `String` or a `Uint8List`. Bytes are sent as they
  /// are, so binary data (like msgpack) is not changed.
  /// ```
  /// await redis.publish('chat', 'hello')
  /// await redis.publish('chat', Uint8List.fromList([0x93, 0xa7]))
  /// ```
  Future<int> publish(String channel, Object message) async {
    if (message is! String && message is! Uint8List) {
      throw ArgumentError.value(
        message,
        'message',
        'must be a String or a Uint8List',
      );
    }
    if (redisClientType == RedisType.subscriber) {
      throw Exception('cannot subscribe and publish on same connection');
    }
    redisClientType = RedisType.publisher;
    return await _pickConnection().sendCommand(<Object>[
      'PUBLISH',
      channel,
      message,
    ]);
  }

  /// send command to connection
  @override
  Future<dynamic> sendCommand(List<String> commandList) {
    return _pickConnection().sendCommand(commandList);
  }

  /// send many commands in one write on one connection
  Future<List<dynamic>> _sendPipeline(List<List<String>> commands) async {
    return await _pickConnection().sendPipeline(commands);
  }

  RedisConnection _pickConnection() {
    // Commands share the main connection and go out together
    // (auto-pipelining). Only a blocking command, like BRPOP, makes the
    // others use the pool, so they do not wait behind it.
    if (!connection.isBlocked || redisClientType != RedisType.normal) {
      return connection;
    }
    return pool.getConnection();
  }
}
