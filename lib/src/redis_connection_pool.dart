import 'dart:async';

import 'package:ioredis/ioredis.dart';

/// One pool connection and the time it was last picked.
class _PoolEntry {
  final RedisConnection connection;

  /// Milliseconds on [RedisConnectionPool._clock].
  int lastUsed;

  _PoolEntry(this.connection, this.lastUsed);
}

class RedisConnectionPool {
  /// Main connection to send command
  final RedisConnection mainConnection;

  /// Pool connections, oldest first
  final List<_PoolEntry> _entries = <_PoolEntry>[];

  /// One timer closes idle connections. It is not reset on every command.
  Timer? _idleTimer;

  /// Next entry for round-robin, when all connections are busy
  int _next = 0;

  /// Cheap clock for the last used time (no DateTime per command)
  static final Stopwatch _clock = Stopwatch()..start();

  /// Redis option
  final RedisOptions option;

  /// Class constructor
  RedisConnectionPool(this.option, this.mainConnection);

  /// Send command to connection
  Future<dynamic> sendCommand(List<String> commandList) {
    return getConnection().sendCommand(commandList);
  }

  /// Open pool connections (not the main connection)
  List<RedisConnection> get connections => <RedisConnection>[
    for (_PoolEntry e in _entries) e.connection,
  ];

  /// Destroy all pool connections and stop the idle timer
  void destroyAll() {
    _idleTimer?.cancel();
    _idleTimer = null;
    for (_PoolEntry e in _entries) {
      e.connection.destroy();
    }
    _entries.clear();
  }

  /// Pick a connection to send a command.
  /// 1. the oldest connection that is not blocked (by BRPOP and so on),
  ///    so commands share it and go out together,
  /// 2. else a new connection, while the pool is not full,
  /// 3. else the next connected connection (round-robin),
  /// 4. else the main connection.
  RedisConnection getConnection() {
    int now = _clock.elapsedMilliseconds;
    int count = _entries.length;
    for (int i = 0; i < count; i++) {
      _PoolEntry e = _entries[i];
      RedisConnection c = e.connection;
      if (!c.isBlocked && c.status != RedisConnectionStatus.disconnected) {
        e.lastUsed = now;
        return c;
      }
    }

    if (count < option.maxConnection - 1) {
      RedisConnection conn = RedisConnection(option);
      _entries.add(_PoolEntry(conn, now));
      _idleTimer ??= Timer(option.idleTimeout, _closeIdle);
      return conn;
    }

    for (int i = 0; i < count; i++) {
      _next = _next + 1 < count ? _next + 1 : 0;
      _PoolEntry e = _entries[_next];
      if (e.connection.status == RedisConnectionStatus.connected) {
        e.lastUsed = now;
        return e.connection;
      }
    }

    /// If there is no connection with connected state, use mainConnection
    return mainConnection;
  }

  /// Close connections that were not used for [RedisOptions.idleTimeout]
  /// and wait for nothing. Then wait for the next one that can expire.
  void _closeIdle() {
    _idleTimer = null;
    int now = _clock.elapsedMilliseconds;
    int idle = option.idleTimeout.inMilliseconds;
    int? wait;
    for (int i = _entries.length - 1; i >= 0; i--) {
      _PoolEntry e = _entries[i];
      int left = e.lastUsed + idle - now;
      if (left <= 0 && !e.connection.isBusy) {
        e.connection.destroy();
        _entries.removeAt(i);
      } else {
        // A busy connection is checked again after one more idle time.
        int next = left > 0 ? left : idle;
        if (wait == null || next < wait) wait = next;
      }
    }
    if (_next >= _entries.length) _next = 0;
    if (wait != null) {
      _idleTimer = Timer(Duration(milliseconds: wait), _closeIdle);
    }
  }
}
