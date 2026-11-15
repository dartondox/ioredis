import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:ioredis/src/redis_message_encoder.dart';
import 'package:test/test.dart';

RedisMessageEncoder encoder = RedisMessageEncoder();

String enc(Object? value) => utf8.decode(encoder.encode(value));

/// Simple reference encoder: the bytes the encoder must write.
List<int> ref(Object? value) {
  List<int> out = <int>[];
  void bulk(List<int> data) {
    out
      ..addAll(ascii.encode('\$${data.length}\r\n'))
      ..addAll(data)
      ..addAll(<int>[13, 10]);
  }

  if (value is String) {
    bulk(utf8.encode(value));
  } else if (value is int) {
    out.addAll(ascii.encode(':$value\r\n'));
  } else if (value == null) {
    out.addAll(ascii.encode('\$-1\r\n'));
  } else if (value is List) {
    out.addAll(ascii.encode('*${value.length}\r\n'));
    for (Object? v in value) {
      if (v is String) {
        bulk(utf8.encode(v));
      } else if (v is Uint8List) {
        bulk(v);
      } else if (v is int) {
        bulk(utf8.encode(v.toString()));
      } else {
        out.addAll(ref(v));
      }
    }
  }
  return out;
}

/// Encode [values] one after the other in one encoder and compare with
/// the reference bytes.
void expectSame(List<Object?> values) {
  RedisMessageEncoder e = RedisMessageEncoder();
  List<int> want = <int>[];
  for (Object? v in values) {
    e.write(v);
    want.addAll(ref(v));
  }
  expect(e.takeBytes(), want);
}

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

  group('encoder bytes match the reference', () {
    List<String> texts = <String>[
      '',
      'hello',
      'é', // 2 bytes
      'ü' * 7,
      '€', // 3 bytes
      '😀', // 4 bytes
      'မင်္ဂလာပါ',
      'a😀b€cé',
      'abcမ' * 40,
      'x' * 9 + 'é', // 10 units, 11 bytes
      'é' * 5, // 5 units, 10 bytes: the header gets one more digit
      'မ' * 4, // 4 units, 12 bytes
      'မ' * 34, // 34 units, 102 bytes
    ];

    test('strings, alone and in arrays', () {
      for (String t in texts) {
        expectSame(<Object?>[t]);
        expectSame(<Object?>[
          <Object>['SET', t, t],
        ]);
      }
    });

    test('lone surrogates give the same bytes as utf8.encode', () {
      expectSame(<Object?>[
        <String>[
          '\uD800',
          '\uDC00',
          'a\uD800b',
          'a\uDC00\uD800b',
          '\uD83D',
          'é\uD83D',
          '😀\uD83D',
          '\uD83D😀',
          '\uDE00\uD83D',
        ],
      ]);
    });

    test('long strings grow the buffer in the middle of a character', () {
      // Different start offsets, so a 2, 3 or 4 byte character falls on
      // the old end of the buffer when it grows.
      for (int pad = 0; pad < 8; pad++) {
        for (String c in <String>['é', 'မ', '😀']) {
          String long = 'a' * (4090 - pad) + c * 3000;
          expectSame(<Object?>[
            <String>['SET', 'k' * pad, long],
            <String>['GET', long],
          ]);
        }
      }
    });

    test('binary arguments, ints and null', () {
      expectSame(<Object?>[
        <Object>[
          'SET',
          Uint8List.fromList(<int>[0, 255, 13, 10, 128]),
          Uint8List(0),
          Uint8List(70000),
          0,
          -7,
          1234567890123,
        ],
        0,
        -1234,
        9007199254740993,
        null,
      ]);
    });

    test('a big pipeline', () {
      List<Object?> commands = <Object?>[];
      for (int i = 0; i < 2000; i++) {
        commands.add(<String>['SET', 'key:$i', i.isEven ? 'v' * i : 'မ' * i]);
      }
      expectSame(commands);
    });

    test('truncate after a failed encode keeps earlier bytes', () {
      RedisMessageEncoder e = RedisMessageEncoder();
      e.write(<String>['SET', 'a', 'é' * 3000]);
      int start = e.length;
      expect(
        () => e.write(<Object>['SET', 'b' * 5000, 'မ' * 2000, Object()]),
        throwsException,
      );
      e.truncate(start);
      e.write(<String>['GET', 'ü']);
      expect(e.takeBytes(), <int>[
        ...ref(<String>['SET', 'a', 'é' * 3000]),
        ...ref(<String>['GET', 'ü']),
      ]);
    });

    test('works again after a large buffer is dropped', () {
      RedisMessageEncoder e = RedisMessageEncoder();
      List<String> big = <String>['SET', 'k', 'v' * (1 << 20)];
      e.write(big);
      expect(e.takeBytes(), ref(big));
      e.write(<String>['SET', 'k', 'é' * 10]);
      expect(e.takeBytes(), ref(<String>['SET', 'k', 'é' * 10]));
    });
  });

  group('long strings and memory', () {
    test('one non-ASCII char near the start and the end keeps memory low', () {
      String big = 'é${'a' * (10 * 1024 * 1024)}é';
      RedisMessageEncoder e = RedisMessageEncoder();
      e.write(big);
      int size = e.length;
      expect(e.debugCapacity, lessThan(size * 1.5));
      expect(e.takeBytes(), ref(big));
    });

    test('pairs and lone surrogates across the threshold', () {
      for (int len in <int>[4090, 4096, 4097, 4100, 9000]) {
        for (int at = len - 3; at <= len + 1; at++) {
          String pair = String.fromCharCodes(<int>[0xd83d, 0xde00]);
          for (String odd in <String>[pair, '\ud83d', '\ude00', '€']) {
            String s = 'é${'a' * (at - 1)}$odd${'b' * 10}';
            expectSame(<Object?>[s]);
            expectSame(<Object?>[
              <Object?>['SET', s],
            ]);
          }
        }
      }
    });

    test('random strings match utf8.encode', () {
      Random r = Random(42);
      List<String> parts = <String>[
        'a',
        'z',
        '0',
        ' ',
        'é',
        'ß',
        '€',
        '日',
        '\u{1F600}',
        '\ud83d',
        '\ude00',
      ];
      String make(int count) {
        StringBuffer b = StringBuffer();
        for (int i = 0; i < count; i++) {
          b.write(parts[r.nextInt(parts.length)]);
        }
        return b.toString();
      }

      RedisMessageEncoder e = RedisMessageEncoder();
      for (int i = 0; i < 4000; i++) {
        String s = make(r.nextInt(40));
        e.write(s);
        expect(e.takeBytes(), ref(s), reason: 'units: ${s.codeUnits}');
      }
      for (int i = 0; i < 300; i++) {
        String s = make(4090 + r.nextInt(200));
        e.write(<Object?>[s]);
        expect(e.takeBytes(), ref(<Object?>[s]));
      }
    });
  });
}
