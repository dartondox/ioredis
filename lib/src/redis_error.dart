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
