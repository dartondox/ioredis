part of '../redis.dart';

/// Server, connection and scripting commands.
mixin _ServerCommands on _RedisBase {
  /// flush all they data from currently selected DB
  /// ```
  /// await redis.flushdb();
  /// ```
  Future<void> flushdb() async {
    await sendCommand(<String>['FLUSHDB']);
  }

  /// Delete all keys in all databases.
  /// ```
  /// await redis.flushall();
  /// ```
  Future<String> flushall() async {
    return await sendCommand(<String>['FLUSHALL']);
  }

  /// Returns 'PONG', or the message.
  /// ```
  /// String pong = await redis.ping();
  /// ```
  Future<String> ping([String? message]) async {
    return await sendCommand(<String>['PING', if (message != null) message]);
  }

  /// Returns the message.
  /// ```
  /// String hi = await redis.echo('hi');
  /// ```
  Future<String> echo(String message) async {
    return await sendCommand(<String>['ECHO', message]);
  }

  /// Number of keys in the current database.
  /// ```
  /// int n = await redis.dbsize();
  /// ```
  Future<int> dbsize() async {
    return await sendCommand(<String>['DBSIZE']);
  }

  /// Server info text.
  /// ```
  /// String info = await redis.info('server');
  /// ```
  Future<String> info([String? section]) async {
    return await sendCommand(<String>['INFO', if (section != null) section]);
  }

  /// Server time: [unix seconds, microseconds].
  /// ```
  /// List<String> t = await redis.time();
  /// ```
  Future<List<String>> time() async {
    return _toStrings(await sendCommand(<String>['TIME']));
  }

  /// Run a Lua script. The first [numKeys] items of [keysAndArgs] are keys
  /// and get the key prefix. The rest are arguments.
  /// ```
  /// dynamic r = await redis.eval(
  ///     "return redis.call('GET', KEYS[1])", 1, ['foo']);
  /// ```
  Future<dynamic> eval(
    String script,
    int numKeys, [
    List<Object> keysAndArgs = const <Object>[],
  ]) async {
    return await sendCommand(<String>[
      'EVAL',
      script,
      ..._scriptArgs(numKeys, keysAndArgs),
    ]);
  }

  /// Run a script loaded with `script('LOAD', ...)`, by its SHA1.
  /// ```
  /// dynamic r = await redis.evalsha(sha, 1, ['foo']);
  /// ```
  Future<dynamic> evalsha(
    String sha1,
    int numKeys, [
    List<Object> keysAndArgs = const <Object>[],
  ]) async {
    return await sendCommand(<String>[
      'EVALSHA',
      sha1,
      ..._scriptArgs(numKeys, keysAndArgs),
    ]);
  }

  List<String> _scriptArgs(int numKeys, List<Object> keysAndArgs) {
    List<String> args = <String>['$numKeys'];
    for (int i = 0; i < keysAndArgs.length; i++) {
      String value = keysAndArgs[i].toString();
      args.add(i < numKeys ? _key(value) : value);
    }
    return args;
  }

  /// SCRIPT subcommands: LOAD, EXISTS, FLUSH.
  /// ```
  /// String sha = await redis.script('LOAD', ["return 'hi'"]);
  /// ```
  Future<dynamic> script(
    String subcommand, [
    List<Object> args = const <Object>[],
  ]) async {
    return await sendCommand(<String>[
      'SCRIPT',
      subcommand.toUpperCase(),
      ..._args(args),
    ]);
  }
}
