import 'dart:async';
import 'dart:io';

import 'package:ioredis/ioredis.dart';
import 'package:ioredis/src/default.dart';
import 'package:ioredis/src/redis_message_encoder.dart';
import 'package:ioredis/src/redis_response.dart';
import 'package:ioredis/src/transformer.dart';

class Redis {
  /// Redis option
  RedisOptions option = defaultRedisOptions;

  Redis([RedisOptions? opt]) {
    if (opt != null) {
      option = opt;
    }
  }

  /// Current active socket;
  Socket? _socket;

  /// Current active socket;
  Stream<dynamic>? _stream;

  /// Total retry count
  int _totalRetry = 0;

  /// Current complete to listen for the response from redis
  Completer<dynamic>? _completer;

  /// Serializer to send the command to redis
  final RedisMessageEncoder _encoder = RedisMessageEncoder();

  /// Current status of redis connection
  RedisConnectionStatus _status = RedisConnectionStatus.disconnected;

  /// Redis connection type
  /// subscriber, publisher or normal
  RedisType _type = RedisType.normal;

  /// To check whether it should reconnect
  /// when socket is manually disconnect.
  bool _shouldReconnect = true;

  /// Listeners of subscribers
  final Map<List<String>, RedisSubscriber> _subscribeListeners =
      <List<String>, RedisSubscriber>{};

  /// Connect to redis connection
  /// ```
  /// await redis.connect()
  /// ```
  Future<void> connect() async {
    _totalRetry++;
    try {
      _status = RedisConnectionStatus.connecting;

      /// Create new socket if not exist
      if (_socket == null) {
        if (option.secure == true) {
          _socket = await SecureSocket.connect(option.host, option.port,
              timeout: option.connectTimeout);
        } else {
          _socket = await Socket.connect(option.host, option.port,
              timeout: option.connectTimeout);
        }
      }

      /// Setting socket option to tcp no delay
      /// If tcpNoDelay is enabled, the socket will not buffer data internally,
      /// but instead write each data chunk as an individual TCP packet.
      _socket?.setOption(SocketOption.tcpNoDelay, true);

      /// listening for response
      _listenResponseFromRedis();

      /// Set status as connected
      _status = RedisConnectionStatus.connected;

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
        _status = RedisConnectionStatus.disconnected;

        /// If error is SocketException, need to reconnect
        await _reconnect();
      } else {
        /// rethrow application logic errors
        rethrow;
      }
    }
  }

  /// Get current connection status
  String getStatus() => _status.name;

  /// Get stream to listen new message
  Stream<dynamic> getStream() {
    if (_stream == null) {
      throw Exception('Steam not found');
    }
    return _stream!;
  }

  /// Disconnect redis connection
  Future<void> disconnect() async {
    _shouldReconnect = false;
    await _socket?.close();
  }

  /// Duplicate new redis connection
  Redis duplicate() {
    return Redis(option);
  }

  /// Set custom socket
  Redis setSocket(Socket socket) {
    _socket = socket;
    return this;
  }

  /// Send redis command
  /// ```
  /// await redis.sendCommand(['SET', 'foo', 'bar']);
  /// await redis.sendCommand(['GET', 'foo']);
  /// ```
  Future<dynamic> sendCommand(List<String> commandList) async {
    try {
      if (_status == RedisConnectionStatus.disconnected) {
        await connect();
      }
      // for the synchronous operations, execute one after another in a sequential manner
      // send new command only if the response is completed from redis
      while (true) {
        if (_completer == null || _completer?.isCompleted == true) {
          _completer = Completer<dynamic>();
          _socket?.add(_encoder.encode(commandList));
          break;
        }
        await Future<void>.delayed(Duration(milliseconds: 1));
      }
      return await _completer?.future;
    } catch (error) {
      print(error.toString());
      return null;
    }
  }

  /// Set key value to redis
  /// ```
  /// await redis.set('foo', 'bar');
  /// ```
  Future<dynamic> set(String key, String value,
      [String? option, dynamic optionValue]) async {
    List<String> commands = <String>['SET', key, value.toString()];
    if (option != null && optionValue != null) {
      commands.addAll(<String>[option.toUpperCase(), optionValue.toString()]);
    }
    String? val = await sendCommand(commands);
    if (!RedisResponse.ok(val)) {
      throw Exception(val);
    }
  }

  /// Get value of a key
  /// ```
  /// await redis.get('foo');
  /// ```
  Future<String?> get(String key) async {
    return await sendCommand(<String>['GET', key]);
  }

  /// Get value of a key
  /// ```
  /// await redis.get('foo');
  /// ```
  Future<List<String?>> mget(List<String> keys) async {
    return await sendCommand(<String>['MGET', ...keys]);
  }

  /// Delete a key
  /// ```
  /// await redis.get('foo');
  /// ```
  Future<void> delete(String key) async {
    await sendCommand(<String>['DEL', key]);
  }

  /// Delete multiple key
  /// ```
  /// await redis.get('foo');
  /// ```
  Future<void> mdelete(List<String> key) async {
    await sendCommand(<String>['DEL', ...key]);
  }

  /// Delete multiple key
  /// ```
  /// await redis.get('foo');
  /// ```
  Future<void> flushdb() async {
    await sendCommand(<String>['FLUSHDB']);
  }

  /// Subscribe to channel
  /// ```
  /// RedisSubscriber subscriber = await redis.subscribe('channel');
  /// RedisSubscriber subscriber = await redis.subscribe(['channel', 'chat']);
  ///
  /// subscriber.onMessage = (String channel,String? message) {
  ///
  /// }
  /// ```
  Future<RedisSubscriber> subscribe(Object channel) async {
    if (_type == RedisType.publisher) {
      throw Exception('cannot subscribe and publish on same connection');
    }
    _type = RedisType.subscriber;
    RedisSubscriber cb = RedisSubscriber();
    if (channel is String) {
      await sendCommand(<String>['SUBSCRIBE', channel]);
      _subscribeListeners[<String>[channel]] = cb;
    } else if (channel is List<String>) {
      await sendCommand(<String>['SUBSCRIBE', ...channel]);
      _subscribeListeners[channel] = cb;
    } else {
      throw Exception('Invalid type for channel');
    }
    return cb;
  }

  /// Publish message to a channel
  /// ```
  /// await redis.publish('chat', 'hello')
  /// ```
  Future<void> publish(String channel, String message) async {
    if (_type == RedisType.subscriber) {
      throw Exception('cannot subscribe and publish on same connection');
    }
    _type = RedisType.publisher;
    await sendCommand(<String>['PUBLISH', channel, message]);
  }

  /// Handle connection reconnect
  Future<void> _reconnect() async {
    if (_shouldReconnect) {
      await Future<void>.delayed(option.retryStrategy!(_totalRetry));
      await connect();
    }
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
    void Function(dynamic)? onError = option.onError;
    if (onError != null) {
      onError(err);
    } else {
      print(err.toString());
    }
  }

  /// Listen response from redis and sent to completer ro callback.
  /// onDone callback is use to listen redis disconnect to reconnect
  void _listenResponseFromRedis() {
    Stream<String>? s = _socket?.transform<String>(transformer);
    _stream = s?.transform<dynamic>(redisResponseTransformer);

    _stream?.listen((dynamic packet) {
      /// If packet is from pub/sub
      if (packet is List && packet[0] == 'message') {
        String channel = packet[1];
        String message = packet[2];
        RedisSubscriber? cb = _findSubscribeListener(channel);

        if (cb != null && cb.onMessage != null) {
          cb.onMessage!(channel, message);
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
      _socket?.destroy();
      _socket = null;

      _throwSafeError(
        SocketException('Redis disconnected',
            address: InternetAddress(option.host), port: option.port),
      );
      await _reconnect();
    });
  }

  /// Get subscribe listener callback related to the channel
  RedisSubscriber? _findSubscribeListener(String channel) {
    List<List<String>> channelsLists = _subscribeListeners.keys.toList();
    channelsLists = channelsLists
        .where((List<String> element) => element.contains(channel))
        .toList();
    if (channelsLists.isNotEmpty) {
      List<String>? channels = channelsLists.first;
      return _subscribeListeners[channels];
    }
    return null;
  }
}
