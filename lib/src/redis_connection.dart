import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ioredis/ioredis.dart';
import 'package:ioredis/src/default.dart';
import 'package:ioredis/src/redis_message_encoder.dart';
import 'package:ioredis/src/redis_parser.dart';

/// One command (or one pipeline) that waits for its replies.
class _PendingReply {
  final Completer<dynamic> completer = Completer<dynamic>();

  /// How many replies this entry needs before it is done.
  final int expected;

  /// When true, complete with all replies as a list, errors included.
  final bool isPipeline;

  /// True when this entry holds a blocking command, like BRPOP.
  final bool blocking;

  /// Replies so far. Only used when more than one reply is expected.
  List<dynamic>? replies;

  _PendingReply(this.expected, this.isPipeline, this.blocking);
}

class RedisConnection {
  /// Redis option
  RedisOptions option = defaultRedisOptions;

  /// Current status of redis connection
  RedisConnectionStatus status = RedisConnectionStatus.disconnected;

  /// Current active socket;
  Socket? _redisSocket;

  /// Total retry count
  int _totalRetry = 0;

  /// Commands that wait for a reply, in the order they were sent.
  /// Redis answers in the same order, so the first reply belongs to the first entry.
  final Queue<_PendingReply> _pending = Queue<_PendingReply>();

  /// Parser for the bytes of the current socket
  RedisParser _parser = RedisParser();

  /// Running connect, so many callers wait for the same connect
  Future<void>? _connecting;

  /// Bytes of commands that are not written to the socket yet
  final RedisMessageEncoder _encoder = RedisMessageEncoder();

  /// True when a microtask will write [_encoder] to the socket
  bool _flushScheduled = false;

  /// To check whether it should reconnect
  /// when socket is manually disconnect.
  bool _shouldReconnect = true;

  /// should not throw when disconnect is called programmatically
  bool _shouldThrowErrorOnConnection = true;

  /// Listeners of subscribers
  final Map<List<String>, RedisSubscriber> subscribeListeners =
      <List<String>, RedisSubscriber>{};

  /// Listeners of pattern subscribers, by pattern
  final Map<String, RedisSubscriber> patternListeners =
      <String, RedisSubscriber>{};

  /// True after the first connect worked. A later connect is a reconnect.
  bool _connectedBefore = false;

  bool _keepBytes = false;

  RedisConnection([RedisOptions? opt]) {
    if (opt != null) {
      option = opt;
    }
  }

  /// check connection is free (no command is waiting for a reply)
  bool get isBusy => _pending.isNotEmpty;

  /// True while a blocking command (BLPOP, BRPOP, XREAD BLOCK, WAIT, ...)
  /// waits for its reply. Other commands should use another connection then.
  bool get isBlocked => _blocking > 0;

  /// Number of blocking commands sent and not answered yet
  int _blocking = 0;

  /// Get current connection status
  String getStatus() => status.name;

  /// When true, the parser keeps bulk strings as bytes, so pub/sub
  /// messages keep their exact bytes. Command replies are still `String`.
  /// [Redis.subscribe] and [Redis.psubscribe] turn this on.
  bool get keepBytes => _keepBytes;

  set keepBytes(bool value) {
    _keepBytes = value;
    _parser.keepBytes = value;
  }

  /// Set custom socket
  void setSocket(Socket socket) {
    _redisSocket = socket;
  }

  /// Connect to redis connection
  /// ```
  /// await redis.connect()
  /// ```
  Future<void> connect() {
    _shouldReconnect = true;
    _shouldThrowErrorOnConnection = true;
    return _connecting ??= _connect().whenComplete(_clearConnecting);
  }

  void _clearConnecting() {
    _connecting = null;
  }

  Future<void> _connect() async {
    _totalRetry++;
    try {
      status = RedisConnectionStatus.connecting;

      /// Create new socket if not exist
      if (_redisSocket == null) {
        if (option.secure == true) {
          _redisSocket = await SecureSocket.connect(
            option.host,
            option.port,
            timeout: option.connectTimeout,
            onBadCertificate: option.onBadCertificate,
          );
        } else {
          _redisSocket = await Socket.connect(
            option.host,
            option.port,
            timeout: option.connectTimeout,
          );
        }
      }

      /// Setting socket option to tcp no delay
      /// If tcpNoDelay is enabled, the socket will not buffer data internally,
      /// but instead write each data chunk as an individual TCP packet.
      _redisSocket?.setOption(SocketOption.tcpNoDelay, true);

      /// listening for response
      _listenResponseFromRedis();

      /// Set status as connected
      status = RedisConnectionStatus.connected;

      /// Once socket is connect reset retry count to zero
      _totalRetry = 0;

      /// If username is provided, we need to login before calling other commands
      await _login();

      /// Select database index
      await _selectDatabaseIndex();

      /// After a reconnect, subscribe again to the same channels and patterns
      if (_connectedBefore) await _resubscribe();
      _connectedBefore = true;
    } catch (error) {
      if (error is SocketException) {
        _throwSafeError(_socketError(error.message));
        status = RedisConnectionStatus.disconnected;

        /// If error is SocketException, need to reconnect
        await _reconnect();
      } else {
        /// rethrow application logic errors
        rethrow;
      }
    }
  }

  /// Listen response from redis and sent to completer or callback.
  /// onDone callback is use to listen redis disconnect to reconnect
  void _listenResponseFromRedis() {
    _parser = RedisParser()..keepBytes = _keepBytes;
    _redisSocket?.listen(_onData, onError: _onSocketError, onDone: _onDone);
  }

  /// Parse new bytes and hand every complete reply to its owner
  void _onData(List<int> data) {
    List<dynamic> replies = _parser.feed(data);
    for (int i = 0; i < replies.length; i++) {
      dynamic reply = replies[i];
      if (reply is List && _dispatchPushMessage(reply)) continue;
      if (_pending.isEmpty) continue;
      if (_keepBytes) reply = _bytesToText(reply);

      _PendingReply entry = _pending.first;
      if (entry.expected > 1 || entry.isPipeline) {
        List<dynamic> got = entry.replies ??= <dynamic>[];
        got.add(reply);
        if (got.length < entry.expected) continue;
        _takeFirst();
        if (entry.isPipeline) {
          entry.completer.complete(got);
          continue;
        }
      } else {
        _takeFirst();
      }
      if (reply is RedisError) {
        entry.completer.completeError(reply);
      } else {
        entry.completer.complete(reply);
      }
    }
  }

  /// Send pub/sub messages to the listeners.
  /// Returns true when the reply was a pub/sub message.
  /// With [keepBytes], the parts of the reply are bytes. Names are made
  /// `String` here, and the message stays bytes until a callback needs it.
  bool _dispatchPushMessage(List<dynamic> reply) {
    if (reply.isEmpty) return false;
    dynamic kind = reply[0];
    if (kind is Uint8List) kind = _text(kind);

    if (kind == 'message' &&
        reply.length == 3 &&
        subscribeListeners.isNotEmpty) {
      String channel = _text(reply[1]);
      RedisSubscriber? cb = _findSubscribeListener(channel);
      if (cb == null) return true;
      dynamic message = reply[2];
      cb.onMessageBytes?.call(channel, _bytes(message));
      cb.onMessage?.call(channel, _textOrNull(message));
      return true;
    }

    if (kind == 'pmessage' &&
        reply.length == 4 &&
        patternListeners.isNotEmpty) {
      String pattern = _text(reply[1]);
      String channel = _text(reply[2]);
      RedisSubscriber? cb = patternListeners[pattern];
      if (cb == null) return true;
      dynamic message = reply[3];
      if (cb.onPatternMessageBytes != null) {
        cb.onPatternMessageBytes!(pattern, channel, _bytes(message));
      } else {
        cb.onMessageBytes?.call(channel, _bytes(message));
      }
      if (cb.onPatternMessage != null) {
        cb.onPatternMessage!(pattern, channel, _textOrNull(message));
      } else {
        cb.onMessage?.call(channel, _textOrNull(message));
      }
      return true;
    }
    return false;
  }

  /// Decode bytes as UTF-8. Bad bytes become U+FFFD, it never throws.
  String _text(dynamic value) => value is Uint8List
      ? utf8.decode(value, allowMalformed: true)
      : value as String;

  String? _textOrNull(dynamic value) => value == null ? null : _text(value);

  /// A copy of the message bytes, so the caller can keep it safely.
  Uint8List _bytes(dynamic value) {
    if (value is Uint8List) return Uint8List.fromList(value);
    return utf8.encode(value as String? ?? '');
  }

  /// Turn bytes into `String` in a command reply, also inside arrays.
  dynamic _bytesToText(dynamic reply) {
    if (reply is Uint8List) return _text(reply);
    if (reply is List) {
      for (int i = 0; i < reply.length; i++) {
        reply[i] = _bytesToText(reply[i]);
      }
    }
    return reply;
  }

  /// Send SUBSCRIBE and PSUBSCRIBE again for all listeners.
  Future<void> _resubscribe() async {
    List<String> channels = subscribeListeners.keys
        .expand((List<String> c) => c)
        .toList();
    if (channels.isNotEmpty) {
      await sendCommand(<String>['SUBSCRIBE', ...channels]);
    }
    List<String> patterns = patternListeners.keys.toList();
    if (patterns.isNotEmpty) {
      await sendCommand(<String>['PSUBSCRIBE', ...patterns]);
    }
  }

  void _onSocketError(Object error) {
    _throwSafeError(error);
    _failPending(error);
  }

  Future<void> _onDone() async {
    /// Destroy existing socket
    /// and setting null to create again on reconnect
    _redisSocket?.destroy();
    _redisSocket = null;
    _encoder.clear();
    status = RedisConnectionStatus.disconnected;

    SocketException error = _socketError('Redis disconnected');
    _failPending(error);
    _throwSafeError(error);
    if (_shouldReconnect) {
      await connect();
    }
  }

  /// Fail every waiting command, so no caller waits forever
  void _failPending(Object error) {
    while (_pending.isNotEmpty) {
      _takeFirst().completer.completeError(error);
    }
  }

  _PendingReply _takeFirst() {
    _PendingReply entry = _pending.removeFirst();
    if (entry.blocking) _blocking--;
    return entry;
  }

  /// Disconnect redis connection
  Future<void> disconnect() async {
    _shouldReconnect = false;
    _shouldThrowErrorOnConnection = false;
    await _redisSocket?.close();
  }

  /// Send QUIT, then close the connection without reconnect
  Future<dynamic> quit() async {
    if (status != RedisConnectionStatus.connected) {
      await connect();
    }
    // Set the flags first. Redis closes the socket right after the reply.
    _shouldReconnect = false;
    _shouldThrowErrorOnConnection = false;
    dynamic reply = await sendCommand(<String>['QUIT']);
    await disconnect();
    return reply;
  }

  /// Disconnect redis connection
  void destroy() async {
    _shouldReconnect = false;
    _shouldThrowErrorOnConnection = false;
    _redisSocket?.destroy();
  }

  /// Handle connection reconnect
  Future<void> _reconnect() async {
    if (_shouldReconnect) {
      await Future<void>.delayed(
        (option.retryStrategy ?? defaultRedisOptions.retryStrategy!)(
          _totalRetry,
        ),
      );
      await _connect();
    }
  }

  /// Send redis command and wait for its reply.
  /// Each argument is a `String` or a `Uint8List` (sent as raw bytes).
  /// An error reply from redis throws [RedisError].
  /// ```
  /// await redis.sendCommand(['SET', 'foo', 'bar']);
  /// await redis.sendCommand(['GET', 'foo']);
  /// ```
  Future<dynamic> sendCommand(List<Object> commandList) {
    return _send(
      commandList,
      null,
      _expectedReplies(commandList),
      _isBlocking(commandList),
    );
  }

  /// Send many commands in one write and wait for all replies.
  /// Error replies do not throw. They are [RedisError] items in the result.
  /// ```
  /// List<dynamic> res = await connection.sendPipeline([
  ///   ['SET', 'foo', 'bar'],
  ///   ['GET', 'foo'],
  /// ]);
  /// ```
  Future<List<dynamic>> sendPipeline(List<List<String>> commands) async {
    if (commands.isEmpty) return <dynamic>[];
    // Inside MULTI a blocking command does not block.
    bool blocking = false;
    if (commands.first.isEmpty ||
        commands.first.first.toUpperCase() != 'MULTI') {
      for (List<String> c in commands) {
        if (_isBlocking(c)) blocking = true;
      }
    }
    return await _send(null, commands, commands.length, blocking);
  }

  /// Send one command, or many commands as one pipeline.
  /// Commands sent in the same event-loop turn are written together.
  Future<dynamic> _send(
    List<Object>? command,
    List<List<String>>? pipeline,
    int expected,
    bool blocking,
  ) {
    if (blocking) _blocking++;
    if (status != RedisConnectionStatus.connected || _redisSocket == null) {
      return _connectThenSend(command, pipeline, expected, blocking);
    }
    return _enqueue(command, pipeline, expected, blocking);
  }

  Future<dynamic> _enqueue(
    List<Object>? command,
    List<List<String>>? pipeline,
    int expected,
    bool blocking,
  ) {
    _PendingReply entry = _PendingReply(expected, pipeline != null, blocking);
    _pending.add(entry);
    if (command != null) {
      _encoder.write(command);
    } else {
      for (int i = 0; i < pipeline!.length; i++) {
        _encoder.write(pipeline[i]);
      }
    }
    // Auto-pipelining: write once, after the code of this turn is done.
    if (!_flushScheduled) {
      _flushScheduled = true;
      scheduleMicrotask(_flush);
    }
    return entry.completer.future;
  }

  Future<dynamic> _connectThenSend(
    List<Object>? command,
    List<List<String>>? pipeline,
    int expected,
    bool blocking,
  ) async {
    try {
      await connect();
      if (_redisSocket == null) {
        throw _socketError('Redis is not connected');
      }
    } catch (_) {
      if (blocking) _blocking--;
      rethrow;
    }
    return _enqueue(command, pipeline, expected, blocking);
  }

  /// Write all queued command bytes in one socket write.
  void _flush() {
    _flushScheduled = false;
    if (_encoder.length == 0) return;
    Socket? socket = _redisSocket;
    if (socket == null) {
      _encoder.clear();
      return;
    }
    try {
      socket.add(_encoder.takeBytes());
    } catch (error) {
      _failPending(error);
    }
  }

  /// Blocking commands can wait a long time for their reply.
  bool _isBlocking(List<Object> command) {
    if (command.isEmpty) return false;
    Object name = command.first;
    if (name is! String || name.length < 4) return false;
    int c = name.codeUnitAt(0) | 0x20; // lower case
    if (c != 0x62 && c != 0x77 && c != 0x78) return false; // b w x
    switch (name.toUpperCase()) {
      case 'BLPOP':
      case 'BRPOP':
      case 'BRPOPLPUSH':
      case 'BLMOVE':
      case 'BLMPOP':
      case 'BZPOPMIN':
      case 'BZPOPMAX':
      case 'BZMPOP':
      case 'WAIT':
      case 'WAITAOF':
        return true;
      case 'XREAD':
      case 'XREADGROUP':
        for (Object arg in command) {
          if (arg is String && arg.toUpperCase() == 'BLOCK') return true;
        }
    }
    return false;
  }

  /// SUBSCRIBE a b c gets one reply per channel. Other commands get one reply.
  int _expectedReplies(List<Object> commandList) {
    Object first = commandList.first;
    // Only names of 9 to 12 letters can be one of these.
    if (first is! String || first.length < 9 || first.length > 12) return 1;
    String name = first;
    name = name.toUpperCase();
    if (name == 'SUBSCRIBE' ||
        name == 'PSUBSCRIBE' ||
        name == 'UNSUBSCRIBE' ||
        name == 'PUNSUBSCRIBE') {
      return commandList.length > 1 ? commandList.length - 1 : 1;
    }
    return 1;
  }

  /// Get subscribe listener callback related to the channel
  RedisSubscriber? _findSubscribeListener(String channel) {
    List<List<String>> channelsLists = subscribeListeners.keys.toList();
    channelsLists = channelsLists
        .where((List<String> element) => element.contains(channel))
        .toList();
    if (channelsLists.isNotEmpty) {
      List<String>? channels = channelsLists.first;
      return subscribeListeners[channels];
    }
    return null;
  }

  /// Login to redis
  Future<dynamic> _login() async {
    String? username = option.username;
    String? password = option.password;
    if (password != null) {
      List<String> commands = username != null
          ? <String>['AUTH', username, password]
          : <String>['AUTH', password];
      return await sendCommand(commands);
    }
  }

  /// Select database index
  Future<dynamic> _selectDatabaseIndex() async {
    return await sendCommand(<String>['SELECT', option.db.toString()]);
  }

  /// Build a SocketException for this connection.
  /// option.host can be a hostname like `localhost` or `redis`.
  /// InternetAddress() only takes an IP address and throws for a hostname,
  /// so use tryParse. It gives null for a hostname.
  SocketException _socketError(String message) {
    return SocketException(
      message,
      address: InternetAddress.tryParse(option.host),
      port: option.port,
    );
  }

  /// Safely throw error
  /// If redis connection error,
  /// stop throwing error to prevent application crash.
  /// If onError is provided in redisOptions, it will be call to onError,
  /// else error will log safely.
  void _throwSafeError(dynamic err) {
    if (!_shouldThrowErrorOnConnection) return;
    void Function(dynamic)? onError = option.onError;
    if (onError != null) {
      onError(err);
    } else {
      print(err.toString());
    }
  }
}
