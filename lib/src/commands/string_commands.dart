part of '../redis.dart';

/// String commands: SET, GET, INCR, APPEND, ...
mixin _StringCommands on _RedisBase {
  /// Set key value to redis.
  /// Returns 'OK', or null when NX/XX stops the write,
  /// or the old value when GET is used.
  /// ```
  /// await redis.set('foo', 'bar');
  /// await redis.set('foo', 'bar', 'EX', 10);
  /// await redis.set('foo', 'bar', 'NX');
  /// await redis.set('foo', 'bar', 'EX', 10, 'NX');
  /// String? old = await redis.set('foo', 'baz', 'GET');
  /// ```
  Future<dynamic> set(
    String key,
    Object value, [
    String? option,
    dynamic optionValue,
    String? flag,
  ]) async {
    return await sendCommand(
      getCommandToSetData(key, value, option, optionValue, flag),
    );
  }

  /// Get value of a key
  /// ```
  /// await redis.get('foo');
  /// ```
  Future<String?> get(String key) async {
    return await sendCommand(getCommandToGetData(key));
  }

  /// Get values of many keys
  /// ```
  /// await redis.mget(['foo', 'bar']);
  /// ```
  Future<List<String?>> mget(List<String> keys) async {
    return List<String?>.from(
      await sendCommand(<String>['MGET', ..._keys(keys)]),
    );
  }

  /// Set only if the key does not exist. Returns 1 if set.
  /// ```
  /// await redis.setnx('foo', 'bar');
  /// ```
  Future<int> setnx(String key, Object value) async {
    return await sendCommand(<String>['SETNX', _key(key), value.toString()]);
  }

  /// Set with a timeout in seconds.
  /// ```
  /// await redis.setex('foo', 10, 'bar');
  /// ```
  Future<String> setex(String key, int seconds, Object value) async {
    return await sendCommand(<String>[
      'SETEX',
      _key(key),
      '$seconds',
      value.toString(),
    ]);
  }

  /// Set with a timeout in milliseconds.
  /// ```
  /// await redis.psetex('foo', 1500, 'bar');
  /// ```
  Future<String> psetex(String key, int milliseconds, Object value) async {
    return await sendCommand(<String>[
      'PSETEX',
      _key(key),
      '$milliseconds',
      value.toString(),
    ]);
  }

  /// Set a new value and return the old one.
  /// ```
  /// String? old = await redis.getset('foo', 'new');
  /// ```
  Future<String?> getset(String key, Object value) async {
    return await sendCommand(<String>['GETSET', _key(key), value.toString()]);
  }

  /// Get the value and delete the key.
  /// ```
  /// String? v = await redis.getdel('foo');
  /// ```
  Future<String?> getdel(String key) async {
    return await sendCommand(<String>['GETDEL', _key(key)]);
  }

  /// Get the value and change its timeout. Use one option.
  /// ```
  /// String? v = await redis.getex('foo', ex: 60);
  /// String? v2 = await redis.getex('foo', persist: true);
  /// ```
  Future<String?> getex(
    String key, {
    int? ex,
    int? px,
    int? exat,
    int? pxat,
    bool persist = false,
  }) async {
    return await sendCommand(<String>[
      'GETEX',
      _key(key),
      if (ex != null) ...<String>['EX', '$ex'],
      if (px != null) ...<String>['PX', '$px'],
      if (exat != null) ...<String>['EXAT', '$exat'],
      if (pxat != null) ...<String>['PXAT', '$pxat'],
      if (persist) 'PERSIST',
    ]);
  }

  /// Set many keys.
  /// ```
  /// await redis.mset({'foo': 'bar', 'count': 1});
  /// ```
  Future<String> mset(Map<String, Object> data) async {
    return await sendCommand(<String>['MSET', ..._keyValueArgs(data)]);
  }

  /// Set many keys only if none of them exist. Returns 1 if set.
  /// ```
  /// await redis.msetnx({'foo': 'bar', 'baz': 'qux'});
  /// ```
  Future<int> msetnx(Map<String, Object> data) async {
    return await sendCommand(<String>['MSETNX', ..._keyValueArgs(data)]);
  }

  List<String> _keyValueArgs(Map<String, Object> data) {
    List<String> args = <String>[];
    data.forEach((String key, Object value) {
      args.addAll(<String>[_key(key), value.toString()]);
    });
    return args;
  }

  /// Add 1. Returns the new value.
  /// ```
  /// int n = await redis.incr('counter');
  /// ```
  Future<int> incr(String key) async {
    return await sendCommand(<String>['INCR', _key(key)]);
  }

  /// Add a number. Returns the new value.
  /// ```
  /// int n = await redis.incrby('counter', 5);
  /// ```
  Future<int> incrby(String key, int increment) async {
    return await sendCommand(<String>['INCRBY', _key(key), '$increment']);
  }

  /// Add a float. Returns the new value.
  /// ```
  /// double n = await redis.incrbyfloat('price', 1.5);
  /// ```
  Future<double> incrbyfloat(String key, num increment) async {
    return _toDouble(
      await sendCommand(<String>['INCRBYFLOAT', _key(key), '$increment']),
    );
  }

  /// Subtract 1. Returns the new value.
  /// ```
  /// int n = await redis.decr('counter');
  /// ```
  Future<int> decr(String key) async {
    return await sendCommand(<String>['DECR', _key(key)]);
  }

  /// Subtract a number. Returns the new value.
  /// ```
  /// int n = await redis.decrby('counter', 5);
  /// ```
  Future<int> decrby(String key, int decrement) async {
    return await sendCommand(<String>['DECRBY', _key(key), '$decrement']);
  }

  /// Append to the value. Returns the new length.
  /// ```
  /// int len = await redis.append('foo', 'more');
  /// ```
  Future<int> append(String key, Object value) async {
    return await sendCommand(<String>['APPEND', _key(key), value.toString()]);
  }

  /// Length of the value in bytes.
  /// ```
  /// int len = await redis.strlen('foo');
  /// ```
  Future<int> strlen(String key) async {
    return await sendCommand(<String>['STRLEN', _key(key)]);
  }

  /// Part of the value, by byte index (end is included).
  /// ```
  /// String part = await redis.getrange('foo', 0, 2);
  /// ```
  Future<String> getrange(String key, int start, int end) async {
    return await sendCommand(<String>['GETRANGE', _key(key), '$start', '$end']);
  }

  /// Overwrite part of the value at a byte offset. Returns the new length.
  /// ```
  /// await redis.setrange('foo', 6, 'Redis');
  /// ```
  Future<int> setrange(String key, int offset, Object value) async {
    return await sendCommand(<String>[
      'SETRANGE',
      _key(key),
      '$offset',
      value.toString(),
    ]);
  }
}
