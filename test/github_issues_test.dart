import 'package:ioredis/ioredis.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  String prefix = uniquePrefix('issues');
  Redis redis = Redis(testOptions());

  tearDownAll(() async {
    List<String> keys = await redis.keys('$prefix:*');
    if (keys.isNotEmpty) await redis.call('DEL', keys);
    await redis.quit();
  });

  group('issue #10 (large reply split over TCP chunks) |', () {
    test('issue #10: SMEMBERS on a set with 5000 members', () async {
      String key = '$prefix:bigset';
      List<String> members = <String>[
        for (int i = 0; i < 5000; i++)
          i % 3 == 0 ? 'မင်္ဂလာပါ-$i' : 'member-$i',
      ];
      expect(await redis.sadd(key, members), 5000);
      List<String> result = await redis.smembers(key);
      expect(result.length, 5000);
      expect(result.toSet(), members.toSet());
    });

    test('issue #10: large LRANGE and MGET', () async {
      String listKey = '$prefix:biglist';
      List<String> values = <String>[
        for (int i = 0; i < 5000; i++) 'မင်္ဂလာပါ value $i ${'x' * 20}',
      ];
      await redis.rpush(listKey, values);
      expect(await redis.lrange(listKey, 0, -1), values);

      Map<String, Object> data = <String, Object>{
        for (int i = 0; i < 3000; i++) '$prefix:k$i': 'မင်္ဂလာပါ $i',
      };
      await redis.mset(data);
      List<String?> got = await redis.mget(data.keys.toList());
      expect(got, data.values.toList());
    });
  });

  group('issue #8 (GEOSEARCH nested arrays) |', () {
    test('issue #8: GEOSEARCH WITHCOORD WITHDIST via sendCommand and call',
        () async {
      String key = '$prefix:locations';
      await redis.call('GEOADD', <Object>[
        key,
        24.34, 24.5, 'a', //
        24.35, 24.51, 'b',
        24.30, 24.45, 'c',
      ]);
      List<String> command = <String>[
        'GEOSEARCH', key, 'FROMLONLAT', '24.34', '24.5', //
        'BYRADIUS', '1000', 'km', 'ASC', 'COUNT', '1', 'WITHCOORD', 'WITHDIST',
      ];

      for (dynamic reply in <dynamic>[
        await redis.sendCommand(command),
        await redis.call(command.first, command.sublist(1)),
      ]) {
        expect(reply, isA<List<dynamic>>());
        expect(reply.length, 1);
        List<dynamic> item = reply[0];
        expect(item[0], 'a');
        expect(double.parse(item[1]), lessThan(0.01));
        List<dynamic> coord = item[2];
        expect(coord.length, 2);
        expect(double.parse(coord[0]), closeTo(24.34, 0.0001));
        expect(double.parse(coord[1]), closeTo(24.5, 0.0001));
      }
    });

    test('issue #8: GEORADIUS with Palermo and Catania', () async {
      String key = '$prefix:places';
      expect(
          await redis.call('GEOADD', <Object>[
            key,
            13.361389, 38.115556, 'Palermo', //
            15.087269, 37.502669, 'Catania',
          ]),
          2);
      List<dynamic> reply = await redis.call('GEORADIUS',
          <Object>[key, 15, 37, 200, 'km', 'WITHDIST', 'WITHCOORD', 'ASC']);
      expect(reply.length, 2);
      expect(reply[0][0], 'Catania');
      expect(double.parse(reply[0][1]), closeTo(56.4413, 0.01));
      expect(double.parse(reply[0][2][0]), closeTo(15.087269, 0.0001));
      expect(reply[1][0], 'Palermo');
      expect(double.parse(reply[1][1]), closeTo(190.4424, 0.01));
      expect(double.parse(reply[1][2][1]), closeTo(38.115556, 0.0001));
    });
  });
}
