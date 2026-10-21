part of '../redis.dart';

/// Sorted set commands: ZADD, ZRANGE, ZSCORE, ...
mixin _SortedSetCommands on _RedisBase {
  /// Add members with scores ({member: score}).
  /// Returns how many were added (or changed, with [ch]).
  /// ```
  /// await redis.zadd('board', {'ann': 10, 'bob': 7.5});
  /// await redis.zadd('board', {'ann': 20}, gt: true, ch: true);
  /// ```
  Future<int> zadd(
    String key,
    Map<String, num> members, {
    bool nx = false,
    bool xx = false,
    bool gt = false,
    bool lt = false,
    bool ch = false,
  }) async {
    return await sendCommand(
      _zaddCommand(key, members, nx: nx, xx: xx, gt: gt, lt: lt, ch: ch),
    );
  }

  /// Remove one member or a list of members.
  /// ```
  /// await redis.zrem('board', 'ann');
  /// ```
  Future<int> zrem(String key, Object members) async {
    return await sendCommand(<String>['ZREM', _key(key), ..._args(members)]);
  }

  /// Score of a member, or null.
  /// ```
  /// double? score = await redis.zscore('board', 'ann');
  /// ```
  Future<double?> zscore(String key, String member) async {
    String? reply = await sendCommand(<String>['ZSCORE', _key(key), member]);
    return reply == null ? null : _toDouble(reply);
  }

  /// Add to a member score. Returns the new score.
  /// ```
  /// double score = await redis.zincrby('board', 5, 'ann');
  /// ```
  Future<double> zincrby(String key, num increment, String member) async {
    return _toDouble(
      await sendCommand(<String>['ZINCRBY', _key(key), '$increment', member]),
    );
  }

  /// Number of members.
  /// ```
  /// int n = await redis.zcard('board');
  /// ```
  Future<int> zcard(String key) async {
    return await sendCommand(<String>['ZCARD', _key(key)]);
  }

  /// Number of members with a score between min and max.
  /// min and max can be numbers or strings like '-inf' or '(5'.
  /// ```
  /// int n = await redis.zcount('board', 5, '+inf');
  /// ```
  Future<int> zcount(String key, Object min, Object max) async {
    return await sendCommand(<String>['ZCOUNT', _key(key), '$min', '$max']);
  }

  /// Rank (low to high, from 0), or null.
  /// ```
  /// int? rank = await redis.zrank('board', 'ann');
  /// ```
  Future<int?> zrank(String key, String member) async {
    return await sendCommand(<String>['ZRANK', _key(key), member]);
  }

  /// Rank (high to low, from 0), or null.
  /// ```
  /// int? rank = await redis.zrevrank('board', 'ann');
  /// ```
  Future<int?> zrevrank(String key, String member) async {
    return await sendCommand(<String>['ZREVRANK', _key(key), member]);
  }

  /// Members by rank, low to high.
  /// With [withScores] the list is [member, score, member, score, ...].
  /// ```
  /// List<String> top = await redis.zrange('board', 0, -1, withScores: true);
  /// ```
  Future<List<String>> zrange(
    String key,
    int start,
    int stop, {
    bool withScores = false,
  }) async {
    return _toStrings(
      await sendCommand(<String>[
        'ZRANGE',
        _key(key),
        '$start',
        '$stop',
        if (withScores) 'WITHSCORES',
      ]),
    );
  }

  /// Members by rank, high to low. Same as [zrange].
  /// ```
  /// List<String> top = await redis.zrevrange('board', 0, 2);
  /// ```
  Future<List<String>> zrevrange(
    String key,
    int start,
    int stop, {
    bool withScores = false,
  }) async {
    return _toStrings(
      await sendCommand(<String>[
        'ZREVRANGE',
        _key(key),
        '$start',
        '$stop',
        if (withScores) 'WITHSCORES',
      ]),
    );
  }

  /// Members with a score between min and max, low to high.
  /// ```
  /// List<String> m = await redis.zrangebyscore('board', 0, '+inf',
  ///     withScores: true, offset: 0, count: 10);
  /// ```
  Future<List<String>> zrangebyscore(
    String key,
    Object min,
    Object max, {
    bool withScores = false,
    int? offset,
    int? count,
  }) async {
    return _toStrings(
      await sendCommand(<String>[
        'ZRANGEBYSCORE',
        _key(key),
        '$min',
        '$max',
        ..._rangeOptions(withScores, offset, count),
      ]),
    );
  }

  /// Members with a score between max and min, high to low.
  /// ```
  /// List<String> m = await redis.zrevrangebyscore('board', '+inf', 0);
  /// ```
  Future<List<String>> zrevrangebyscore(
    String key,
    Object max,
    Object min, {
    bool withScores = false,
    int? offset,
    int? count,
  }) async {
    return _toStrings(
      await sendCommand(<String>[
        'ZREVRANGEBYSCORE',
        _key(key),
        '$max',
        '$min',
        ..._rangeOptions(withScores, offset, count),
      ]),
    );
  }

  List<String> _rangeOptions(bool withScores, int? offset, int? count) {
    return <String>[
      if (withScores) 'WITHSCORES',
      if (offset != null || count != null) ...<String>[
        'LIMIT',
        '${offset ?? 0}',
        '${count ?? -1}',
      ],
    ];
  }

  /// Remove members by rank. Returns how many were removed.
  /// ```
  /// await redis.zremrangebyrank('board', 0, 9);
  /// ```
  Future<int> zremrangebyrank(String key, int start, int stop) async {
    return await sendCommand(<String>[
      'ZREMRANGEBYRANK',
      _key(key),
      '$start',
      '$stop',
    ]);
  }

  /// Remove members by score. Returns how many were removed.
  /// ```
  /// await redis.zremrangebyscore('board', '-inf', 5);
  /// ```
  Future<int> zremrangebyscore(String key, Object min, Object max) async {
    return await sendCommand(<String>[
      'ZREMRANGEBYSCORE',
      _key(key),
      '$min',
      '$max',
    ]);
  }

  /// Remove and return the lowest members: [member, score, ...].
  /// ```
  /// List<String> low = await redis.zpopmin('board');
  /// ```
  Future<List<String>> zpopmin(String key, [int? count]) async {
    return _toStrings(
      await sendCommand(<String>[
        'ZPOPMIN',
        _key(key),
        if (count != null) '$count',
      ]),
    );
  }

  /// Remove and return the highest members: [member, score, ...].
  /// ```
  /// List<String> high = await redis.zpopmax('board', 2);
  /// ```
  Future<List<String>> zpopmax(String key, [int? count]) async {
    return _toStrings(
      await sendCommand(<String>[
        'ZPOPMAX',
        _key(key),
        if (count != null) '$count',
      ]),
    );
  }

  /// Iterate members. items is [member, score, member, score, ...].
  /// ```
  /// RedisScanResult res = await redis.zscan('board', 0);
  /// ```
  Future<RedisScanResult> zscan(
    String key,
    Object cursor, {
    String? match,
    int? count,
  }) async {
    return _toScanResult(
      await sendCommand(<String>[
        'ZSCAN',
        _key(key),
        cursor.toString(),
        ..._scanOptions(match: match, count: count),
      ]),
    );
  }
}
