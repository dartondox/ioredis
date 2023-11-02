enum RedisConnectionStatus {
  connected('connected'),
  disconnected('disconnected'),
  connecting('connecting');

  final String name;
  const RedisConnectionStatus(this.name);
}
