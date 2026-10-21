import 'dart:convert';

import 'package:ioredis/ioredis.dart';
import 'package:ioredis/src/redis_parser.dart';
import 'package:test/test.dart';

List<int> b(String s) => utf8.encode(s);

void main() {
  group('RedisParser |', () {
    test('simple types', () {
      RedisParser p = RedisParser();
      expect(p.feed(b('+OK\r\n:42\r\n\$3\r\nfoo\r\n\$-1\r\n*-1\r\n')),
          <dynamic>['OK', 42, 'foo', null, null]);
    });

    test('reply split over many chunks, one byte at a time', () {
      RedisParser p = RedisParser();
      List<int> bytes = b('*2\r\n\$5\r\nhello\r\n:-7\r\n');
      List<dynamic> out = <dynamic>[];
      for (int byte in bytes) {
        out.addAll(p.feed(<int>[byte]));
      }
      expect(out, <dynamic>[
        <dynamic>['hello', -7]
      ]);
    });

    test('many replies in one chunk', () {
      RedisParser p = RedisParser();
      expect(p.feed(b('+OK\r\n+OK\r\n\$1\r\na\r\n\$1\r\nb\r\n')),
          <dynamic>['OK', 'OK', 'a', 'b']);
    });

    test('nested arrays', () {
      RedisParser p = RedisParser();
      expect(p.feed(b('*2\r\n\$1\r\n0\r\n*2\r\n*1\r\n:1\r\n*0\r\n')), <dynamic>[
        <dynamic>[
          '0',
          <dynamic>[
            <dynamic>[1],
            <dynamic>[]
          ]
        ]
      ]);
    });

    test('bulk string with \\r\\n inside', () {
      RedisParser p = RedisParser();
      expect(p.feed(b('\$8\r\na\r\nb\r\n\$c\r\n')), <dynamic>['a\r\nb\r\n\$c']);
    });

    test('multi-byte UTF-8 split across chunks', () {
      RedisParser p = RedisParser();
      String text = 'မင်္ဂလာပါ';
      List<int> body = utf8.encode(text);
      List<int> bytes = <int>[...b('\$${body.length}\r\n'), ...body, 13, 10];
      // split in the middle of a multi-byte character
      expect(p.feed(bytes.sublist(0, 7)), isEmpty);
      expect(p.feed(bytes.sublist(7)), <dynamic>[text]);
    });

    test('errors, top level and inside arrays', () {
      RedisParser p = RedisParser();
      List<dynamic> out =
          p.feed(b('-ERR bad\r\n*2\r\n+OK\r\n-WRONGTYPE x\r\n'));
      expect(out[0], isA<RedisError>());
      expect((out[0] as RedisError).message, 'ERR bad');
      expect(out[1][0], 'OK');
      expect((out[1][1] as RedisError).message, 'WRONGTYPE x');
    });
  });
}
