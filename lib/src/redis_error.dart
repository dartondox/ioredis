/// An error reply from Redis, like `ERR wrong number of arguments`.
/// ```
/// try {
///   await redis.call('NOT_A_COMMAND');
/// } on RedisError catch (e) {
///   print(e.message);
/// }
/// ```
class RedisError implements Exception {
  /// Error text sent by Redis, without the leading `-`.
  final String message;

  const RedisError(this.message);

  @override
  String toString() => 'RedisError: $message';
}

/// A command got no reply within [RedisOptions.commandTimeout].
/// The message never holds the command arguments.
class RedisTimeoutError extends RedisError {
  const RedisTimeoutError(super.message);

  @override
  String toString() => 'RedisTimeoutError: $message';
}

/// [RedisOptions.maxQueuedCommands] commands already wait for a
/// connection, so this command was not queued.
class RedisQueueFullError extends RedisError {
  const RedisQueueFullError(super.message);

  @override
  String toString() => 'RedisQueueFullError: $message';
}
