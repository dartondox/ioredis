class RedisOptions {
  final Duration connectTimeout;

  final bool secure;

  final Duration Function(int)? retryStrategy;

  final String? username;

  final String? password;

  String host;

  int port;

  int db;

  void Function(dynamic)? onError;

  RedisOptions({
    this.host = '127.0.0.1',
    this.port = 6379,
    this.secure = false,
    this.connectTimeout = const Duration(seconds: 10),
    this.username,
    this.password,
    this.db = 1,
    this.retryStrategy,
    this.onError,
  });
}

class RedisSetOption {}
