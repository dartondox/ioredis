typedef RedisSubscriberCallback = void Function(
    String channel, String? message);

class RedisSubscriber {
  /// listen for new message on the subscriber
  RedisSubscriberCallback? onMessage;
}
