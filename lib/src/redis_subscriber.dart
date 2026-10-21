typedef RedisSubscriberCallback = void Function(
  String channel,
  String? message,
);

typedef RedisPatternSubscriberCallback = void Function(
  String pattern,
  String channel,
  String? message,
);

class RedisSubscriber {
  /// listen for new message on the subscriber
  RedisSubscriberCallback? onMessage;

  /// listen for new message on a pattern subscriber (psubscribe).
  /// If this is not set, [onMessage] is called instead.
  RedisPatternSubscriberCallback? onPatternMessage;
}
