part of '../redis.dart';

/// Set commands: SADD, SMEMBERS, SINTER, ...
mixin _SetCommands on _RedisBase {
  /// Add one member or a list of members. Returns how many were added.
  /// ```
  /// await redis.sadd('tags', ['a', 'b']);
  /// ```
  Future<int> sadd(String key, Object members) async {
    return await sendCommand(<String>['SADD', _key(key), ..._args(members)]);
  }

  /// Remove one member or a list of members. Returns how many were removed.
  /// ```
  /// await redis.srem('tags', 'a');
  /// ```
  Future<int> srem(String key, Object members) async {
    return await sendCommand(<String>['SREM', _key(key), ..._args(members)]);
  }

  /// All members.
  /// ```
  /// List<String> tags = await redis.smembers('tags');
  /// ```
  Future<List<String>> smembers(String key) async {
    return _toStrings(await sendCommand(<String>['SMEMBERS', _key(key)]));
  }

  /// Returns 1 if the member is in the set.
  /// ```
  /// int found = await redis.sismember('tags', 'a');
  /// ```
  Future<int> sismember(String key, Object member) async {
    return await sendCommand(<String>[
      'SISMEMBER',
      _key(key),
      member.toString(),
    ]);
  }

  /// 1 or 0 for each member.
  /// ```
  /// List<int> found = await redis.smismember('tags', ['a', 'z']);
  /// ```
  Future<List<int>> smismember(String key, List<Object> members) async {
    return List<int>.from(
      await sendCommand(<String>['SMISMEMBER', _key(key), ..._args(members)]),
    );
  }

  /// Number of members.
  /// ```
  /// int n = await redis.scard('tags');
  /// ```
  Future<int> scard(String key) async {
    return await sendCommand(<String>['SCARD', _key(key)]);
  }

  /// Remove random members. Without [count] returns String?,
  /// with [count] returns List<String>.
  /// ```
  /// String? one = await redis.spop('tags');
  /// ```
  Future<dynamic> spop(String key, [int? count]) async {
    dynamic reply = await sendCommand(<String>[
      'SPOP',
      _key(key),
      if (count != null) '$count',
    ]);
    return reply is List ? List<String>.from(reply) : reply;
  }

  /// Random members without removing them. Same return types as [spop].
  /// ```
  /// List<String> some = await redis.srandmember('tags', 2);
  /// ```
  Future<dynamic> srandmember(String key, [int? count]) async {
    dynamic reply = await sendCommand(<String>[
      'SRANDMEMBER',
      _key(key),
      if (count != null) '$count',
    ]);
    return reply is List ? List<String>.from(reply) : reply;
  }

  /// Move a member to another set. Returns 1 if moved.
  /// ```
  /// await redis.smove('tags', 'old-tags', 'a');
  /// ```
  Future<int> smove(String source, String destination, Object member) async {
    return await sendCommand(<String>[
      'SMOVE',
      _key(source),
      _key(destination),
      member.toString(),
    ]);
  }

  /// Members in all sets.
  /// ```
  /// List<String> both = await redis.sinter(['a', 'b']);
  /// ```
  Future<List<String>> sinter(Object keys) async {
    return _toStrings(await sendCommand(<String>['SINTER', ..._keys(keys)]));
  }

  /// Members in any set.
  /// ```
  /// List<String> any = await redis.sunion(['a', 'b']);
  /// ```
  Future<List<String>> sunion(Object keys) async {
    return _toStrings(await sendCommand(<String>['SUNION', ..._keys(keys)]));
  }

  /// Members of the first set that are not in the others.
  /// ```
  /// List<String> diff = await redis.sdiff(['a', 'b']);
  /// ```
  Future<List<String>> sdiff(Object keys) async {
    return _toStrings(await sendCommand(<String>['SDIFF', ..._keys(keys)]));
  }

  /// Store SINTER in [destination]. Returns its size.
  /// ```
  /// await redis.sinterstore('out', ['a', 'b']);
  /// ```
  Future<int> sinterstore(String destination, Object keys) async {
    return await sendCommand(<String>[
      'SINTERSTORE',
      _key(destination),
      ..._keys(keys),
    ]);
  }

  /// Store SUNION in [destination]. Returns its size.
  /// ```
  /// await redis.sunionstore('out', ['a', 'b']);
  /// ```
  Future<int> sunionstore(String destination, Object keys) async {
    return await sendCommand(<String>[
      'SUNIONSTORE',
      _key(destination),
      ..._keys(keys),
    ]);
  }

  /// Store SDIFF in [destination]. Returns its size.
  /// ```
  /// await redis.sdiffstore('out', ['a', 'b']);
  /// ```
  Future<int> sdiffstore(String destination, Object keys) async {
    return await sendCommand(<String>[
      'SDIFFSTORE',
      _key(destination),
      ..._keys(keys),
    ]);
  }

  /// Iterate members.
  /// ```
  /// RedisScanResult res = await redis.sscan('tags', 0, count: 100);
  /// ```
  Future<RedisScanResult> sscan(
    String key,
    Object cursor, {
    String? match,
    int? count,
  }) async {
    return _toScanResult(
      await sendCommand(<String>[
        'SSCAN',
        _key(key),
        cursor.toString(),
        ..._scanOptions(match: match, count: count),
      ]),
    );
  }
}
