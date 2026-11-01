import 'package:ioredis/ioredis.dart';
import 'package:test/test.dart';

void main() {
  group('RedisOptions.fromUrl', () {
    test('reads host, port, user, password and db', () {
      RedisOptions o = RedisOptions.fromUrl('redis://bob:pa%40ss@cache:6380/4');
      expect(o.host, 'cache');
      expect(o.port, 6380);
      expect(o.username, 'bob');
      expect(o.password, 'pa@ss');
      expect(o.db, 4);
      expect(o.secure, isFalse);
    });

    test('uses defaults for missing parts', () {
      RedisOptions o = RedisOptions.fromUrl('redis://');
      expect(o.host, '127.0.0.1');
      expect(o.port, 6379);
      expect(o.username, isNull);
      expect(o.password, isNull);
      expect(o.db, 0);
    });

    test('password without a user', () {
      RedisOptions o = RedisOptions.fromUrl('redis://:secret@localhost');
      expect(o.username, isNull);
      expect(o.password, 'secret');
    });

    test('rediss:// turns on TLS', () {
      RedisOptions o = RedisOptions.fromUrl('rediss://example.com/1');
      expect(o.secure, isTrue);
      expect(o.host, 'example.com');
      expect(o.db, 1);
    });

    test('passes the other options through', () {
      RedisOptions o = RedisOptions.fromUrl(
        'redis://localhost',
        keyPrefix: 'app',
        maxConnection: 3,
      );
      expect(o.keyPrefix, 'app');
      expect(o.maxConnection, 3);
    });

    test('rejects other schemes and a bad db', () {
      expect(() => RedisOptions.fromUrl('http://x'), throwsArgumentError);
      expect(
        () => RedisOptions.fromUrl('redis://x/abc'),
        throwsFormatException,
      );
    });
  });
}
