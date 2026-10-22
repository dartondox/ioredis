part of 'redis.dart';

/// Shared builder for [RedisMulti] and [RedisPipeline].
/// It queues commands. Use [call] for any command that has no method here.
/// Results are raw replies (for example HGETALL gives a flat list).
abstract class RedisCommandBatch<T extends RedisCommandBatch<T>> {
  final Redis _redis;

  final List<List<String>> _commands = <List<String>>[];

  RedisCommandBatch(this._redis);

  /// Send the queued commands.
  Future<List<dynamic>> exec();

  T _add(List<String> command) {
    _commands.add(command);
    return this as T;
  }

  /// queue any command. The key prefix is NOT added.
  T call(String command, [List<Object> args = const <Object>[]]) =>
      _add(<String>[command, ..._redis._args(args)]);

  /// set value
  T set(
    String key,
    Object value, [
    String? option,
    dynamic optionValue,
    String? flag,
  ]) => _add(_redis.getCommandToSetData(key, value, option, optionValue, flag));

  /// get value
  T get(String key) => _add(_redis.getCommandToGetData(key));

  /// delete keys
  T del(Object keys) => _add(<String>['DEL', ..._redis._keys(keys)]);

  /// count existing keys
  T exists(Object keys) => _add(<String>['EXISTS', ..._redis._keys(keys)]);

  /// set timeout in seconds
  T expire(String key, int seconds) =>
      _add(<String>['EXPIRE', _redis._key(key), '$seconds']);

  /// time to live in seconds
  T ttl(String key) => _add(<String>['TTL', _redis._key(key)]);

  /// add 1
  T incr(String key) => _add(<String>['INCR', _redis._key(key)]);

  /// add a number
  T incrby(String key, int increment) =>
      _add(<String>['INCRBY', _redis._key(key), '$increment']);

  /// subtract 1
  T decr(String key) => _add(<String>['DECR', _redis._key(key)]);

  /// set hash fields
  T hset(String key, Map<String, Object> data) {
    List<String> args = <String>[];
    data.forEach((String field, Object value) {
      args.addAll(<String>[field, value.toString()]);
    });
    return _add(<String>['HSET', _redis._key(key), ...args]);
  }

  /// get a hash field
  T hget(String key, String field) =>
      _add(<String>['HGET', _redis._key(key), field]);

  /// delete hash fields
  T hdel(String key, Object fields) =>
      _add(<String>['HDEL', _redis._key(key), ..._redis._args(fields)]);

  /// push to list head
  T lpush(String key, Object values) =>
      _add(<String>['LPUSH', _redis._key(key), ..._redis._args(values)]);

  /// push to list tail
  T rpush(String key, Object values) =>
      _add(<String>['RPUSH', _redis._key(key), ..._redis._args(values)]);

  /// add set members
  T sadd(String key, Object members) =>
      _add(<String>['SADD', _redis._key(key), ..._redis._args(members)]);

  /// remove set members
  T srem(String key, Object members) =>
      _add(<String>['SREM', _redis._key(key), ..._redis._args(members)]);

  /// add sorted set members ({member: score})
  T zadd(
    String key,
    Map<String, num> members, {
    bool nx = false,
    bool xx = false,
    bool gt = false,
    bool lt = false,
    bool ch = false,
  }) => _add(
    _redis._zaddCommand(key, members, nx: nx, xx: xx, gt: gt, lt: lt, ch: ch),
  );
}

/// Transaction. All commands run on one connection inside MULTI ... EXEC.
/// The whole block is sent in one write.
class RedisMulti extends RedisCommandBatch<RedisMulti> {
  RedisMulti(super.redis);

  /// exec multi command.
  /// Returns the EXEC result. A command that failed while running is a
  /// [RedisError] item in the result. If a command was rejected before
  /// EXEC (for example wrong arguments), exec throws the EXECABORT [RedisError].
  @override
  Future<List<dynamic>> exec() async {
    List<dynamic> replies = await _redis._sendPipeline(<List<String>>[
      <String>['MULTI'],
      ..._commands,
      <String>['EXEC'],
    ]);
    dynamic result = replies.last;
    if (result is RedisError) throw result;
    if (result is! List) throw RedisError('EXEC returned $result');
    return result;
  }
}

/// Pipeline. All commands are sent in one write on one connection.
class RedisPipeline extends RedisCommandBatch<RedisPipeline> {
  RedisPipeline(super.redis);

  /// Send all commands. Returns replies in order.
  /// A failed command is a [RedisError] item in the result (no throw).
  @override
  Future<List<dynamic>> exec() async {
    return await _redis._sendPipeline(_commands);
  }
}
