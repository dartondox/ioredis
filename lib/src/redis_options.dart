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
  /// to send a password without a user. A user with no password is kept in
  /// [username], but no AUTH is sent, because AUTH needs a password.
  ///
  /// The db comes from the path (`/2`) or from `?db=2`. The path wins.
  /// Other query params are ignored. Other options are named arguments.
  ///
  /// Throws [ArgumentError] for any other scheme, and [FormatException]
  /// for a bad URL, port or db. Error messages hide the user and password.
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
    // The URL can hold a password, so errors only show a redacted copy.
    String safeUrl = url.replaceFirst(RegExp(r'//.*@'), '//***@');
    Uri uri;
    try {
      uri = Uri.parse(url);
    } on FormatException {
      throw FormatException('Invalid Redis URL: $safeUrl');
    }
    if (uri.scheme != 'redis' && uri.scheme != 'rediss') {
      throw ArgumentError.value(
        safeUrl,
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
      try {
        if (user.isNotEmpty) username = Uri.decodeComponent(user);
        if (colon != -1) {
          password = Uri.decodeComponent(uri.userInfo.substring(colon + 1));
        }
      } catch (_) {
        throw FormatException('Invalid user or password in $safeUrl');
      }
    }

    String path = uri.path.startsWith('/') ? uri.path.substring(1) : uri.path;
    String dbText = path.isEmpty ? (uri.queryParameters['db'] ?? '') : path;
    int? db = dbText.isEmpty ? 0 : int.tryParse(dbText);
    if (db == null) throw FormatException('Invalid db in $safeUrl');

    return RedisOptions(
      host: uri.host.isEmpty ? '127.0.0.1' : uri.host,
      port: uri.hasPort ? uri.port : 6379,
      secure: uri.scheme == 'rediss',
      username: username,
      password: password,
      db: db,
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
