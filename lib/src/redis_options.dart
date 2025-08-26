import 'dart:io';

class RedisOptions {
  /// timeout value for socket connection
  final Duration connectTimeout;

  /// use secure socket
  final bool secure;

  /// retry strategy defaults to
  /// `min(50 * times, 2000)`
  final Duration Function(int)? retryStrategy;

  /// redis username
  final String? username;

  /// redis password
  final String? password;

  /// redis host
  String host;

  /// redis port
  int port;

  /// database index defaults to 0
  int db;

  /// error handler
  void Function(dynamic)? onError;

  /// key prefix
  /// ```
  /// Redis fooRedis = new Redis(RedisOption(keyPrefix: 'foo'));
  /// fooRedis.set("bar", "baz"); // Actually sends SET foo:bar baz
  /// ```
  String keyPrefix;

  /// maximum connection pool, default to 10;
  int maxConnection;

  /// timeout duration of idle connection in the pool, default to 10s
  Duration idleTimeout;

  /// An optional callback for handling server SSL certificate validation.
  ///
  /// This function is invoked if the server presents a certificate that is
  /// considered invalid or untrusted by the system.
  ///
  /// The function must return `true` to accept the certificate and continue
  /// the connection, or `false` to reject it and abort the connection attempt.
  ///
  /// If this callback is `null`, any invalid certificate will automatically
  /// cause the connection to be aborted.
  bool Function(X509Certificate)? onBadCertificate;

  RedisOptions({
    this.keyPrefix = '',
    this.host = '127.0.0.1',
    this.port = 6379,
    this.secure = false,
    this.connectTimeout = const Duration(seconds: 10),
    this.username,
    this.password,
    this.db = 0,
    this.retryStrategy,
    this.onError,
    this.maxConnection = 10,
    this.idleTimeout = const Duration(seconds: 10),
    this.onBadCertificate,
  });
}

class RedisSetOption {}
