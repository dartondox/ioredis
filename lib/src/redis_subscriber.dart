import 'dart:typed_data';

typedef RedisSubscriberCallback =
    void Function(String channel, String? message);

typedef RedisPatternSubscriberCallback =
    void Function(String pattern, String channel, String? message);

typedef RedisBytesSubscriberCallback =
    void Function(String channel, Uint8List message);

typedef RedisPatternBytesSubscriberCallback =
    void Function(String pattern, String channel, Uint8List message);

class RedisSubscriber {
  /// listen for new message on the subscriber
  RedisSubscriberCallback? onMessage;

  /// listen for new message on a pattern subscriber (psubscribe).
  /// If this is not set, [onMessage] is called instead.
  RedisPatternSubscriberCallback? onPatternMessage;

  /// Like [onMessage], but the message is the exact bytes that were
  /// published. Use it for binary data, like msgpack.
  /// It can be set together with [onMessage]. Then both are called.
  RedisBytesSubscriberCallback? onMessageBytes;

  /// Like [onPatternMessage], but the message is the exact bytes.
  /// If this is not set, [onMessageBytes] is called instead.
  RedisPatternBytesSubscriberCallback? onPatternMessageBytes;
}
