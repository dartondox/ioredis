import 'dart:io';

class RedisOptions {
  /// timeout for the socket connect, and again for the handshake
  /// (AUTH, SELECT and SUBSCRIBE again after a reconnect)
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

  /// Make options from a `redis://` or `rediss://` URL.
  ///
  /// `rediss://` turns on TLS. The URL gives the host, port, user,
  /// password and db. Missing parts use the normal defaults.
  /// ```
  /// RedisOptions.fromUrl('rediss://user:pass@example.com:6380/2');
  /// ```
  /// The user and password may be percent-encoded. Use `redis://:pass@host`
  /// to send a password without a user. Other options are named arguments.
  ///
  /// Throws [ArgumentError] for any other scheme, and [FormatException]
  /// when the db is not a number.
  factory RedisOptions.fromUrl(
    String url, {
    String keyPrefix = '',
    Duration connectTimeout = const Duration(seconds: 10),
    Duration Function(int)? retryStrategy,
    void Function(dynamic)? onError,
    int maxConnection = 10,
    Duration idleTimeout = const Duration(seconds: 10),
    bool Function(X509Certificate)? onBadCertificate,
  }) {
    Uri uri = Uri.parse(url);
    if (uri.scheme != 'redis' && uri.scheme != 'rediss') {
      throw ArgumentError.value(
        url,
        'url',
        'must start with redis:// or rediss://',
      );
    }

    String? username;
    String? password;
    if (uri.userInfo.isNotEmpty) {
      int colon = uri.userInfo.indexOf(':');
      String user = colon == -1
          ? uri.userInfo
          : uri.userInfo.substring(0, colon);
      if (user.isNotEmpty) username = Uri.decodeComponent(user);
      if (colon != -1) {
        password = Uri.decodeComponent(uri.userInfo.substring(colon + 1));
      }
    }

    String path = uri.path.startsWith('/') ? uri.path.substring(1) : uri.path;

    return RedisOptions(
      host: uri.host.isEmpty ? '127.0.0.1' : uri.host,
      port: uri.hasPort ? uri.port : 6379,
      secure: uri.scheme == 'rediss',
      username: username,
      password: password,
      db: path.isEmpty ? 0 : int.parse(path),
      keyPrefix: keyPrefix,
      connectTimeout: connectTimeout,
      retryStrategy: retryStrategy,
      onError: onError,
      maxConnection: maxConnection,
      idleTimeout: idleTimeout,
      onBadCertificate: onBadCertificate,
    );
  }
}

@Deprecated('Not used. Will be removed in the next major version.')
class RedisSetOption {}
