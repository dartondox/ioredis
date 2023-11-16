import 'package:ioredis/ioredis.dart';

class RedisMulti {
  final Redis _redis;

  final List<List<String>> _commands = <List<String>>[];

  RedisMulti(this._redis);

  /// set value
  RedisMulti set(String key, String value,
      [String? option, dynamic optionValue]) {
    _commands.add(_redis.getCommandToSetData(key, value, option, optionValue));
    return this;
  }

  /// get value
  RedisMulti get(String key) {
    _commands.add(_redis.getCommandToGetData(key));
    return this;
  }

  /// exec multi command
  Future<List<dynamic>> exec() async {
    await _redis.sendCommand(<String>['MULTI']);
    for (List<String> command in _commands) {
      await _redis.sendCommand(command);
    }
    return await _redis.sendCommand(<String>['EXEC']);
  }
}
