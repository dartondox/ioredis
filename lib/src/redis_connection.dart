import 'dart:async';
import 'dart:io';

import 'package:ioredis/ioredis.dart';
import 'package:ioredis/src/default.dart';
import 'package:ioredis/src/redis_message_encoder.dart';
import 'package:ioredis/src/transformer.dart';

class RedisConnection {
  /// Redis option
  RedisOptions option = defaultRedisOptions;

  /// Current status of redis connection
  RedisConnectionStatus status = RedisConnectionStatus.disconnected;

  /// Current active socket;
  Socket? _redisSocket;

  /// Current active socket;
  Stream<dynamic>? _stream;

  /// Total retry count
  int _totalRetry = 0;

  /// Current complete to listen for the response from redis
  Completer<dynamic>? _completer;

  /// Serializer to send the command to redis
  final RedisMessageEncoder _encoder = RedisMessageEncoder();

  /// To check whether it should reconnect
  /// when socket is manually disconnect.
  bool _shouldReconnect = true;

  /// should not throw when disconnect is called programmatically
  bool _shouldThrowErrorOnConnection = true;

  /// check connection is free
  bool isBusy = false;

  /// Listeners of subscribers
  final Map<List<String>, RedisSubscriber> subscribeListeners =
      <List<String>, RedisSubscriber>{};

  RedisConnection([RedisOptions? opt]) {
    if (opt != null) {
      option = opt;
    }
  }

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
  Future<void> connect() async {
    _totalRetry++;
    try {
      status = RedisConnectionStatus.connecting;

      /// Create new socket if not exist
      if (_redisSocket == null) {
        if (option.secure == true) {
          _redisSocket = await SecureSocket.connect(option.host, option.port,
              timeout: option.connectTimeout);
        } else {
          _redisSocket = await Socket.connect(option.host, option.port,
              timeout: option.connectTimeout);
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
          SocketException(error.message,
              address: InternetAddress(option.host), port: option.port),
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

  /// Listen response from redis and sent to completer ro callback.
  /// onDone callback is use to listen redis disconnect to reconnect
  void _listenResponseFromRedis() {
    Stream<String>? s = _redisSocket?.transform<String>(transformer);
    _stream = s?.transform<dynamic>(redisResponseTransformer);

    _stream?.listen((dynamic packet) {
      /// If packet is from pub/sub
      if (packet is List && packet.isNotEmpty && packet[0] == 'message') {
        String channel = packet[1];
        String message = packet[2];
        RedisSubscriber? cb = _findSubscribeListener(channel);

        if (cb?.onMessage != null) {
          cb?.onMessage!(channel, message);
        }
      } else {
        if (_completer?.isCompleted == false) {
          _completer?.complete(packet);
          _completer = null;
        }
      }
    }, onDone: () async {
      /// Destroy existing socket
      /// and setting null to create again on reconnect
      _redisSocket?.destroy();
      _redisSocket = null;

      _throwSafeError(
        SocketException('Redis disconnected',
            address: InternetAddress(option.host), port: option.port),
      );
      await _reconnect();
    });
  }

  /// Disconnect redis connection
  Future<void> disconnect() async {
    _shouldReconnect = false;
    _shouldThrowErrorOnConnection = false;
    await _redisSocket?.close();
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
      await Future<void>.delayed(option.retryStrategy!(_totalRetry));
      await connect();
    }
  }

  /// Send redis command
  /// ```
  /// await redis.sendCommand(['SET', 'foo', 'bar']);
  /// await redis.sendCommand(['GET', 'foo']);
  /// ```
  Future<dynamic> _sendCommand(List<String> commandList) async {
    try {
      if (status == RedisConnectionStatus.disconnected) {
        await connect();
      }
      // for the synchronous operations, execute one after another in a sequential manner
      // send new command only if the response is completed from redis
      while (true) {
        if (_completer == null || _completer?.isCompleted == true) {
          _completer = Completer<dynamic>();
          _redisSocket?.add(_encoder.encode(commandList));
          break;
        }
        await _completer?.future;
      }
      return await _completer?.future;
    } catch (error) {
      print(error.toString());
      return null;
    }
  }

  /// Send redis command
  /// ```
  /// await redis.sendCommand(['SET', 'foo', 'bar']);
  /// await redis.sendCommand(['GET', 'foo']);
  /// ```
  Future<dynamic> sendCommand(List<String> commandList) async {
    isBusy = true;
    dynamic value = await _sendCommand(commandList);
    isBusy = false;
    return value;
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
      return await _sendCommand(commands);
    }
  }

  /// Select database index
  Future<dynamic> _selectDatabaseIndex() async {
    return await _sendCommand(<String>['SELECT', option.db.toString()]);
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
