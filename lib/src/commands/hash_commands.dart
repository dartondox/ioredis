part of '../redis.dart';

/// Hash commands: HSET, HGET, HGETALL, ...
mixin _HashCommands on _RedisBase {
  /// Set fields of a hash. Returns how many fields were added.
  /// ```
  /// await redis.hset('user:1', {'name': 'Ann', 'age': 30});
  /// ```
  Future<int> hset(String key, Map<String, Object> data) async {
    List<String> args = <String>[];
    data.forEach((String field, Object value) {
      args.addAll(<String>[field, value.toString()]);
    });
    return await sendCommand(<String>['HSET', _key(key), ...args]);
  }

  /// Set a field only if it does not exist. Returns 1 if set.
  /// ```
  /// await redis.hsetnx('user:1', 'name', 'Ann');
  /// ```
  Future<int> hsetnx(String key, String field, Object value) async {
    return await sendCommand(<String>[
      'HSETNX',
      _key(key),
      field,
      value.toString(),
    ]);
  }

  /// Get one field.
  /// ```
  /// String? name = await redis.hget('user:1', 'name');
  /// ```
  Future<String?> hget(String key, String field) async {
    return await sendCommand(<String>['HGET', _key(key), field]);
  }

  /// Get many fields.
  /// ```
  /// List<String?> v = await redis.hmget('user:1', ['name', 'age']);
  /// ```
  Future<List<String?>> hmget(String key, List<String> fields) async {
    return List<String?>.from(
      await sendCommand(<String>['HMGET', _key(key), ...fields]),
    );
  }

  /// Get all fields and values.
  /// ```
  /// Map<String, String> user = await redis.hgetall('user:1');
  /// ```
  Future<Map<String, String>> hgetall(String key) async {
    List<String> list = _toStrings(
      await sendCommand(<String>['HGETALL', _key(key)]),
    );
    Map<String, String> result = <String, String>{};
    for (int i = 0; i + 1 < list.length; i += 2) {
      result[list[i]] = list[i + 1];
    }
    return result;
  }

  /// Delete one field or a list of fields. Returns how many were removed.
  /// ```
  /// await redis.hdel('user:1', ['name', 'age']);
  /// ```
  Future<int> hdel(String key, Object fields) async {
    return await sendCommand(<String>['HDEL', _key(key), ..._args(fields)]);
  }

  /// Returns 1 if the field exists.
  /// ```
  /// int found = await redis.hexists('user:1', 'name');
  /// ```
  Future<int> hexists(String key, String field) async {
    return await sendCommand(<String>['HEXISTS', _key(key), field]);
  }

  /// All field names.
  /// ```
  /// List<String> fields = await redis.hkeys('user:1');
  /// ```
  Future<List<String>> hkeys(String key) async {
    return _toStrings(await sendCommand(<String>['HKEYS', _key(key)]));
  }

  /// All values.
  /// ```
  /// List<String> values = await redis.hvals('user:1');
  /// ```
  Future<List<String>> hvals(String key) async {
    return _toStrings(await sendCommand(<String>['HVALS', _key(key)]));
  }

  /// Number of fields.
  /// ```
  /// int n = await redis.hlen('user:1');
  /// ```
  Future<int> hlen(String key) async {
    return await sendCommand(<String>['HLEN', _key(key)]);
  }

  /// Add a number to a field. Returns the new value.
  /// ```
  /// int age = await redis.hincrby('user:1', 'age', 1);
  /// ```
  Future<int> hincrby(String key, String field, int increment) async {
    return await sendCommand(<String>[
      'HINCRBY',
      _key(key),
      field,
      '$increment',
    ]);
  }

  /// Add a float to a field. Returns the new value.
  /// ```
  /// double score = await redis.hincrbyfloat('user:1', 'score', 0.5);
  /// ```
  Future<double> hincrbyfloat(String key, String field, num increment) async {
    return _toDouble(
      await sendCommand(<String>[
        'HINCRBYFLOAT',
        _key(key),
        field,
        '$increment',
      ]),
    );
  }

  /// Length of a field value in bytes.
  /// ```
  /// int len = await redis.hstrlen('user:1', 'name');
  /// ```
  Future<int> hstrlen(String key, String field) async {
    return await sendCommand(<String>['HSTRLEN', _key(key), field]);
  }

  /// Iterate fields. items is [field, value, field, value, ...].
  /// ```
  /// RedisScanResult res = await redis.hscan('user:1', 0, match: 'n*');
  /// ```
  Future<RedisScanResult> hscan(
    String key,
    Object cursor, {
    String? match,
    int? count,
  }) async {
    return _toScanResult(
      await sendCommand(<String>[
        'HSCAN',
        _key(key),
        cursor.toString(),
        ..._scanOptions(match: match, count: count),
      ]),
    );
  }
}
