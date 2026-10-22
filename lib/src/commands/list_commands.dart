part of '../redis.dart';

/// List commands: LPUSH, RPOP, LRANGE, BLPOP, ...
mixin _ListCommands on _RedisBase {
  /// Add one value or a list of values to the head. Returns the new length.
  /// ```
  /// await redis.lpush('queue', ['a', 'b']);
  /// ```
  Future<int> lpush(String key, Object values) async {
    return await sendCommand(<String>['LPUSH', _key(key), ..._args(values)]);
  }

  /// Add one value or a list of values to the tail. Returns the new length.
  /// ```
  /// await redis.rpush('queue', 'a');
  /// ```
  Future<int> rpush(String key, Object values) async {
    return await sendCommand(<String>['RPUSH', _key(key), ..._args(values)]);
  }

  /// LPUSH only if the list exists.
  /// ```
  /// await redis.lpushx('queue', 'a');
  /// ```
  Future<int> lpushx(String key, Object values) async {
    return await sendCommand(<String>['LPUSHX', _key(key), ..._args(values)]);
  }

  /// RPUSH only if the list exists.
  /// ```
  /// await redis.rpushx('queue', 'a');
  /// ```
  Future<int> rpushx(String key, Object values) async {
    return await sendCommand(<String>['RPUSHX', _key(key), ..._args(values)]);
  }

  /// Remove from the head. Without [count] returns String?,
  /// with [count] returns `List<String>?` (null when the list is empty).
  /// ```
  /// String? v = await redis.lpop('queue');
  /// List<String>? many = await redis.lpop('queue', 2);
  /// ```
  Future<dynamic> lpop(String key, [int? count]) async {
    return _popResult(
      await sendCommand(<String>[
        'LPOP',
        _key(key),
        if (count != null) '$count',
      ]),
    );
  }

  /// Remove from the tail. Same return types as [lpop].
  /// ```
  /// String? v = await redis.rpop('queue');
  /// ```
  Future<dynamic> rpop(String key, [int? count]) async {
    return _popResult(
      await sendCommand(<String>[
        'RPOP',
        _key(key),
        if (count != null) '$count',
      ]),
    );
  }

  dynamic _popResult(dynamic reply) =>
      reply is List ? List<String>.from(reply) : reply;

  /// Length of the list.
  /// ```
  /// int n = await redis.llen('queue');
  /// ```
  Future<int> llen(String key) async {
    return await sendCommand(<String>['LLEN', _key(key)]);
  }

  /// Values from start to stop (stop is included, -1 is the last).
  /// ```
  /// List<String> all = await redis.lrange('queue', 0, -1);
  /// ```
  Future<List<String>> lrange(String key, int start, int stop) async {
    return _toStrings(
      await sendCommand(<String>['LRANGE', _key(key), '$start', '$stop']),
    );
  }

  /// Value at an index.
  /// ```
  /// String? first = await redis.lindex('queue', 0);
  /// ```
  Future<String?> lindex(String key, int index) async {
    return await sendCommand(<String>['LINDEX', _key(key), '$index']);
  }

  /// Set the value at an index.
  /// ```
  /// await redis.lset('queue', 0, 'x');
  /// ```
  Future<String> lset(String key, int index, Object value) async {
    return await sendCommand(<String>[
      'LSET',
      _key(key),
      '$index',
      value.toString(),
    ]);
  }

  /// Remove [count] copies of value. Returns how many were removed.
  /// ```
  /// await redis.lrem('queue', 0, 'x');
  /// ```
  Future<int> lrem(String key, int count, Object value) async {
    return await sendCommand(<String>[
      'LREM',
      _key(key),
      '$count',
      value.toString(),
    ]);
  }

  /// Keep only values from start to stop.
  /// ```
  /// await redis.ltrim('queue', 0, 99);
  /// ```
  Future<String> ltrim(String key, int start, int stop) async {
    return await sendCommand(<String>['LTRIM', _key(key), '$start', '$stop']);
  }

  /// Insert before or after a pivot value. [position] is 'BEFORE' or 'AFTER'.
  /// ```
  /// await redis.linsert('queue', 'BEFORE', 'b', 'a');
  /// ```
  Future<int> linsert(
    String key,
    String position,
    Object pivot,
    Object value,
  ) async {
    return await sendCommand(<String>[
      'LINSERT',
      _key(key),
      position.toUpperCase(),
      pivot.toString(),
      value.toString(),
    ]);
  }

  /// Move a value from one list to another. [from] and [to] are 'LEFT' or 'RIGHT'.
  /// ```
  /// String? v = await redis.lmove('a', 'b', 'LEFT', 'RIGHT');
  /// ```
  Future<String?> lmove(
    String source,
    String destination,
    String from,
    String to,
  ) async {
    return await sendCommand(<String>[
      'LMOVE',
      _key(source),
      _key(destination),
      from.toUpperCase(),
      to.toUpperCase(),
    ]);
  }

  /// Blocking LPOP. Waits up to [timeout] seconds (0 = forever).
  /// Returns [key, value], or null on timeout. The key includes the prefix.
  /// ```
  /// List<String>? res = await redis.blpop(['q1', 'q2'], 5);
  /// ```
  Future<List<String>?> blpop(Object keys, num timeout) async {
    dynamic reply = await sendCommand(<String>[
      'BLPOP',
      ..._keys(keys),
      '$timeout',
    ]);
    return reply == null ? null : List<String>.from(reply);
  }

  /// Blocking RPOP. Same as [blpop].
  /// ```
  /// List<String>? res = await redis.brpop('q1', 5);
  /// ```
  Future<List<String>?> brpop(Object keys, num timeout) async {
    dynamic reply = await sendCommand(<String>[
      'BRPOP',
      ..._keys(keys),
      '$timeout',
    ]);
    return reply == null ? null : List<String>.from(reply);
  }
}
