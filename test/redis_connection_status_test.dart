import 'package:ioredis/src/redis_connection_status.dart';
import 'package:test/test.dart';

void main() {
  test('RedisConnectionStatus', () {
    expect(RedisConnectionStatus.connected.name, 'connected');
    expect(RedisConnectionStatus.disconnected.name, 'disconnected');
    expect(RedisConnectionStatus.connecting.name, 'connecting');
  });
}
