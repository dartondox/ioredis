import 'dart:async';
import 'dart:collection';
import 'dart:io';

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

  final List<dynamic> replies = <dynamic>[];

  _PendingReply(this.expected, this.isPipeline);
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

  /// Serializer to send the command to redis
  final RedisMessageEncoder _encoder = RedisMessageEncoder();

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

  RedisConnection([RedisOptions? opt]) {
    if (opt != null) {
      option = opt;
    }
  }

  /// check connection is free (no command is waiting for a reply)
  bool get isBusy => _pending.isNotEmpty;

  /// Get current connection status
  String getStatus() => status.name;

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
    } catch (error) {
      if (error is SocketException) {
        _throwSafeError(
          SocketException(
            error.message,
            address: InternetAddress(option.host),
            port: option.port,
          ),
        );
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
    _parser = RedisParser();
    _redisSocket?.listen(_onData, onError: _onSocketError, onDone: _onDone);
  }

  /// Parse new bytes and hand every complete reply to its owner
  void _onData(List<int> data) {
    for (dynamic reply in _parser.feed(data)) {
      if (_dispatchPushMessage(reply)) continue;
      if (_pending.isEmpty) continue;

      _PendingReply entry = _pending.first;
      entry.replies.add(reply);
      if (entry.replies.length < entry.expected) continue;

      _pending.removeFirst();
      if (entry.isPipeline) {
        entry.completer.complete(entry.replies);
      } else if (reply is RedisError) {
        entry.completer.completeError(reply);
      } else {
        entry.completer.complete(reply);
      }
    }
  }

  /// Send pub/sub messages to the listeners.
  /// Returns true when the reply was a pub/sub message.
  bool _dispatchPushMessage(dynamic reply) {
    if (reply is! List || reply.isEmpty) return false;

    if (reply[0] == 'message' &&
        reply.length == 3 &&
        subscribeListeners.isNotEmpty) {
      String channel = reply[1];
      RedisSubscriber? cb = _findSubscribeListener(channel);
      cb?.onMessage?.call(channel, reply[2]);
      return true;
    }

    if (reply[0] == 'pmessage' &&
        reply.length == 4 &&
        patternListeners.isNotEmpty) {
      String pattern = reply[1];
      String channel = reply[2];
      RedisSubscriber? cb = patternListeners[pattern];
      if (cb?.onPatternMessage != null) {
        cb!.onPatternMessage!(pattern, channel, reply[3]);
      } else {
        cb?.onMessage?.call(channel, reply[3]);
      }
      return true;
    }
    return false;
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
    status = RedisConnectionStatus.disconnected;

    SocketException error = SocketException(
      'Redis disconnected',
      address: InternetAddress(option.host),
      port: option.port,
    );
    _failPending(error);
    _throwSafeError(error);
    if (_shouldReconnect) {
      await connect();
    }
  }

  /// Fail every waiting command, so no caller waits forever
  void _failPending(Object error) {
    while (_pending.isNotEmpty) {
      _pending.removeFirst().completer.completeError(error);
    }
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
      await Future<void>.delayed((option.retryStrategy ??
          defaultRedisOptions.retryStrategy!)(_totalRetry));
      await _connect();
    }
  }

  /// Send redis command and wait for its reply.
  /// An error reply from redis throws [RedisError].
  /// ```
  /// await redis.sendCommand(['SET', 'foo', 'bar']);
  /// await redis.sendCommand(['GET', 'foo']);
  /// ```
  Future<dynamic> sendCommand(List<String> commandList) {
    return _send(
      <List<String>>[commandList],
      _expectedReplies(commandList),
      isPipeline: false,
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
    return await _send(commands, commands.length, isPipeline: true);
  }

  Future<dynamic> _send(
    List<List<String>> commands,
    int expected, {
    required bool isPipeline,
  }) async {
    if (status != RedisConnectionStatus.connected) {
      await connect();
    }
    Socket? socket = _redisSocket;
    if (socket == null) {
      throw SocketException(
        'Redis is not connected',
        address: InternetAddress(option.host),
        port: option.port,
      );
    }
    _PendingReply entry = _PendingReply(expected, isPipeline);
    _pending.add(entry);

    List<int> bytes = <int>[];
    for (List<String> command in commands) {
      bytes.addAll(_encoder.encode(command));
    }
    socket.add(bytes);
    return entry.completer.future;
  }

  /// SUBSCRIBE a b c gets one reply per channel. Other commands get one reply.
  int _expectedReplies(List<String> commandList) {
    String name = commandList.first.toUpperCase();
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
