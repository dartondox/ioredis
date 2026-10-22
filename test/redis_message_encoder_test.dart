import 'dart:convert';

import 'package:ioredis/src/redis_message_encoder.dart';
import 'package:test/test.dart';

RedisMessageEncoder encoder = RedisMessageEncoder();

String enc(Object? value) => utf8.decode(encoder.encode(value));

void main() {
  group('protocol message encoder', () {
    test('string', () {
      expect(enc(<String>['GET', 'key']), '*2\r\n\$3\r\nGET\r\n\$3\r\nkey\r\n');
    });

    test('null', () {
      expect(enc(null), '\$-1\r\n');
    });

    test('array with strings', () {
      expect(
        enc(<String>['SET', 'key', 'value']),
        '*3\r\n\$3\r\nSET\r\n\$3\r\nkey\r\n\$5\r\nvalue\r\n',
      );
    });

    test('array with int mixed', () {
      expect(
        enc(<dynamic>['SET', 'key', 1]),
        '*3\r\n\$3\r\nSET\r\n\$3\r\nkey\r\n\$1\r\n1\r\n',
      );
    });

    test('integers', () {
      expect(enc(0), ':0\r\n');
      expect(enc(-1234), ':-1234\r\n');
      expect(enc(9007199254740993), ':9007199254740993\r\n');
    });

    test('utf8 length is in bytes', () {
      expect(enc(<String>['မ']), '*1\r\n\$3\r\nမ\r\n');
    });

    test('many commands in one buffer, big values grow it', () {
      RedisMessageEncoder e = RedisMessageEncoder();
      String big = 'y' * 100000;
      e.write(<String>['PING']);
      e.write(<String>['SET', 'k', big]);
      String out = utf8.decode(e.takeBytes());
      expect(
        out,
        '*1\r\n\$4\r\nPING\r\n*3\r\n\$3\r\nSET\r\n\$1\r\nk\r\n\$100000\r\n$big\r\n',
      );
      expect(e.length, 0);
    });
  });
}
