import 'package:ioredis/src/redis_message_encoder.dart';
import 'package:test/test.dart';

RedisMessageEncoder encoder = RedisMessageEncoder();

void main() {
  group('protocol message encoder', () {
    test('string', () {
      List<int> val = encoder.encode(<String>['GET', 'key']);
      expect(true, val.isNotEmpty);
    });

    test('null', () {
      List<int> val = encoder.encode(null);
      expect(true, val.isNotEmpty);
    });

    test('array with strings', () {
      List<int> val = encoder.encode(<String>['SET', 'key', 'value']);
      expect(true, val.isNotEmpty);
    });

    test('array with int mixed', () {
      List<int> val = encoder.encode(<dynamic>['SET', 'key', 1]);
      expect(true, val.isNotEmpty);
    });
  });
}
