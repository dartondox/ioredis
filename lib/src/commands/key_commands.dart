part of '../redis.dart';

/// Key commands: DEL, EXISTS, EXPIRE, TTL, SCAN, ...
mixin _KeyCommands on _RedisBase {
  /// Delete a key
  /// ```
  /// await redis.delete('foo');
  /// ```
  Future<void> delete(String key) async {
    await sendCommand(<String>['DEL', _key(key)]);
  }

  /// Delete multiple key
  /// ```
  /// await redis.mdelete(['foo', 'bar']);
  /// ```
  Future<void> mdelete(List<String> keys) async {
    await sendCommand(<String>['DEL', ..._keys(keys)]);
  }

  /// Delete one key or a list of keys. Returns how many were deleted.
  /// ```
  /// int n = await redis.del(['foo', 'bar']);
  /// ```
  Future<int> del(Object keys) async {
    return await sendCommand(<String>['DEL', ..._keys(keys)]);
  }

  /// Delete keys in the background. Returns how many were removed.
  /// ```
  /// int n = await redis.unlink(['foo', 'bar']);
  /// ```
  Future<int> unlink(Object keys) async {
    return await sendCommand(<String>['UNLINK', ..._keys(keys)]);
  }

  /// Count how many of the keys exist.
  /// ```
  /// int n = await redis.exists('foo');
  /// ```
  Future<int> exists(Object keys) async {
    return await sendCommand(<String>['EXISTS', ..._keys(keys)]);
  }

  /// Set a timeout in seconds. Returns 1 if set, 0 if the key does not exist.
  /// ```
  /// await redis.expire('foo', 60);
  /// ```
  Future<int> expire(String key, int seconds) async {
    return await sendCommand(<String>['EXPIRE', _key(key), '$seconds']);
  }

  /// Set a timeout in milliseconds.
  /// ```
  /// await redis.pexpire('foo', 1500);
  /// ```
  Future<int> pexpire(String key, int milliseconds) async {
    return await sendCommand(<String>['PEXPIRE', _key(key), '$milliseconds']);
  }

  /// Expire at a unix time in seconds.
  /// ```
  /// await redis.expireat('foo', 1893456000);
  /// ```
  Future<int> expireat(String key, int unixTimeSeconds) async {
    return await sendCommand(<String>[
      'EXPIREAT',
      _key(key),
      '$unixTimeSeconds',
    ]);
  }

  /// Time to live in seconds. -1 means no timeout, -2 means no key.
  /// ```
  /// int seconds = await redis.ttl('foo');
  /// ```
  Future<int> ttl(String key) async {
    return await sendCommand(<String>['TTL', _key(key)]);
  }

  /// Time to live in milliseconds.
  /// ```
  /// int ms = await redis.pttl('foo');
  /// ```
  Future<int> pttl(String key) async {
    return await sendCommand(<String>['PTTL', _key(key)]);
  }

  /// Remove the timeout of a key.
  /// ```
  /// await redis.persist('foo');
  /// ```
  Future<int> persist(String key) async {
    return await sendCommand(<String>['PERSIST', _key(key)]);
  }

  /// Type of the value: string, list, set, zset, hash, stream or none.
  /// ```
  /// String t = await redis.type('foo');
  /// ```
  Future<String> type(String key) async {
    return await sendCommand(<String>['TYPE', _key(key)]);
  }

  /// Rename a key.
  /// ```
  /// await redis.rename('foo', 'bar');
  /// ```
  Future<String> rename(String key, String newKey) async {
    return await sendCommand(<String>['RENAME', _key(key), _key(newKey)]);
  }

  /// Rename a key only if the new key does not exist.
  /// ```
  /// int done = await redis.renamenx('foo', 'bar');
  /// ```
  Future<int> renamenx(String key, String newKey) async {
    return await sendCommand(<String>['RENAMENX', _key(key), _key(newKey)]);
  }

  /// Find keys by pattern. Like Node ioredis, the key prefix is NOT added
  /// to the pattern, and the returned keys include the prefix.
  /// ```
  /// List<String> keys = await redis.keys('user:*');
  /// ```
  Future<List<String>> keys(String pattern) async {
    return _toStrings(await sendCommand(<String>['KEYS', pattern]));
  }

  /// Iterate keys. Like Node ioredis, the key prefix is NOT added to [match].
  /// ```
  /// RedisScanResult res = await redis.scan(0, match: 'user:*', count: 100);
  /// print(res.cursor); // '0' when done
  /// print(res.items);
  /// ```
  Future<RedisScanResult> scan(
    Object cursor, {
    String? match,
    int? count,
    String? type,
  }) async {
    return _toScanResult(
      await sendCommand(<String>[
        'SCAN',
        cursor.toString(),
        ..._scanOptions(match: match, count: count, type: type),
      ]),
    );
  }

  /// A random key, or null when the database is empty.
  /// ```
  /// String? key = await redis.randomkey();
  /// ```
  Future<String?> randomkey() async {
    return await sendCommand(<String>['RANDOMKEY']);
  }

  /// Copy a key. Returns 1 if copied.
  /// ```
  /// await redis.copy('foo', 'foo2', replace: true);
  /// ```
  Future<int> copy(
    String source,
    String destination, {
    int? db,
    bool replace = false,
  }) async {
    return await sendCommand(<String>[
      'COPY',
      _key(source),
      _key(destination),
      if (db != null) ...<String>['DB', '$db'],
      if (replace) 'REPLACE',
    ]);
  }
}
