import 'dart:async';

import 'package:ioredis/ioredis.dart';
import 'package:ioredis/src/redis_response.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// SUBSCRIBE a b waits for two replies. When Redis rejects the whole
/// command it sends one error only. The client must fail, not hang.
void main() {
  group('subscribe error |', () {
    late Redis admin;
    late Redis user;
    late String name;

    setUp(() async {
      admin = testClient();
      name = uniquePrefix('nochannels').replaceAll(':', '_');
      // A user with all commands and keys, but only the channels that
      // start with "<name>.ok".
      await admin.call('ACL', <String>[
        'SETUSER',
        name,
        'on',
        '>pass',
        '~*',
        '+@all',
        'resetchannels',
        '&$name.ok*',
      ]);
      user = Redis(
        RedisOptions(
          host: redisHost,
          port: redisPort,
          username: name,
          password: 'pass',
        ),
      );
      addTearDown(() async {
        await user.disconnect();
        await admin.call('ACL', <String>['DELUSER', name]);
      });
    });

    test('subscribe with two channels throws NOPERM', () async {
      await expectLater(
        user.subscribe(<String>['$name:a', '$name:b']),
        throwsA(
          isA<RedisError>().having(
            (RedisError e) => e.message,
            'message',
            contains('NOPERM'),
          ),
        ),
      );
      // The client is back to normal and works.
      await user.set('$name:k', 'v');
      expect(await user.get('$name:k'), 'v');
      await user.delete('$name:k');
      expect(user.connection.subscribeListeners, isEmpty);
    }, timeout: Timeout(Duration(seconds: 5)));

    test('psubscribe with two patterns throws NOPERM', () async {
      await expectLater(
        user.psubscribe(<String>['$name:a*', '$name:b*']),
        throwsA(
          isA<RedisError>().having(
            (RedisError e) => e.message,
            'message',
            contains('NOPERM'),
          ),
        ),
      );
      expect(await user.ping(), 'PONG');
      expect(user.connection.patternListeners, isEmpty);
    }, timeout: Timeout(Duration(seconds: 5)));

    test('a working subscription stays after a subscribe fails', () async {
      String ok = '$name.ok1';
      Completer<String?> got = Completer<String?>();
      RedisSubscriber s = await user.subscribe(ok);
      s.onMessage = (String channel, String? message) {
        if (!got.isCompleted) got.complete(message);
      };
      await expectLater(
        user.subscribe(<String>['$name:a', '$name:b']),
        throwsA(isA<RedisError>()),
      );
      expect(user.redisClientType, RedisType.subscriber);
      expect(await admin.publish(ok, 'hi'), 1);
      expect(await got.future.timeout(Duration(seconds: 2)), 'hi');
    }, timeout: Timeout(Duration(seconds: 5)));

    test('a failed psubscribe gives back the listener it replaced', () async {
      String okPattern = '$name.ok*';
      Completer<String?> got = Completer<String?>();
      RedisSubscriber first = await user.psubscribe(okPattern);
      first.onPatternMessage = (String p, String channel, String? message) {
        if (!got.isCompleted) got.complete(message);
      };
      // The same pattern twice, plus one that is not allowed.
      await expectLater(
        user.psubscribe(<String>[okPattern, okPattern, '$name:no*']),
        throwsA(isA<RedisError>()),
      );
      expect(user.connection.patternListeners[okPattern], <RedisSubscriber>[
        first,
      ]);
      expect(user.connection.patternListeners.length, 1);
      expect(await admin.publish('$name.ok2', 'hi'), 1);
      expect(await got.future.timeout(Duration(seconds: 2)), 'hi');
    }, timeout: Timeout(Duration(seconds: 5)));

    test(
      'a failed psubscribe removes only its own subscriber of a pattern',
      () async {
        String okPattern = '$name.ok*';
        List<String?> gotFirst = <String?>[];
        List<String?> gotSecond = <String?>[];
        RedisSubscriber first = await user.psubscribe(okPattern);
        RedisSubscriber second = await user.psubscribe(okPattern);
        first.onPatternMessage = (String p, String c, String? m) =>
            gotFirst.add(m);
        second.onPatternMessage = (String p, String c, String? m) =>
            gotSecond.add(m);
        await expectLater(
          user.psubscribe(<String>[okPattern, '$name:no*']),
          throwsA(isA<RedisError>()),
        );
        expect(user.connection.patternListeners[okPattern], <RedisSubscriber>[
          first,
          second,
        ]);
        expect(await admin.publish('$name.ok10', 'hi'), 1);
        await user.connection.sendCommand(<String>['PING']);
        expect(gotFirst, <String?>['hi']);
        expect(gotSecond, <String?>['hi']);
      },
      timeout: Timeout(Duration(seconds: 5)),
    );

    test('a client whose subscribes all failed can publish', () async {
      // Two subscribes at the same time. Both fail.
      Future<RedisSubscriber> a = user.subscribe(<String>['$name:a', 'x']);
      Future<RedisSubscriber> b = user.psubscribe(<String>['$name:b*', 'y*']);
      await expectLater(a, throwsA(isA<RedisError>()));
      await expectLater(b, throwsA(isA<RedisError>()));
      expect(user.redisClientType, RedisType.normal);
      expect(user.connection.keepBytes, isFalse);
      expect(await user.publish('$name.ok3', 'hi'), 0);
    }, timeout: Timeout(Duration(seconds: 5)));

    test(
      'overlapping psubscribe: the one that works keeps its listener',
      () async {
        String okPattern = '$name.ok*';
        Completer<String?> got = Completer<String?>();
        // Start both at the same time. Only the first one is rejected.
        Future<RedisSubscriber> a = user.psubscribe(<String>[
          okPattern,
          '$name:no*',
        ]);
        Future<RedisSubscriber> b = user.psubscribe(okPattern);
        await expectLater(a, throwsA(isA<RedisError>()));
        RedisSubscriber sb = await b;
        sb.onPatternMessage = (String p, String channel, String? message) {
          if (!got.isCompleted) got.complete(message);
        };
        expect(user.connection.patternListeners[okPattern], <RedisSubscriber>[
          sb,
        ]);
        expect(user.redisClientType, RedisType.subscriber);
        expect(await admin.publish('$name.ok4', 'hi'), 1);
        expect(await got.future.timeout(Duration(seconds: 2)), 'hi');
      },
      timeout: Timeout(Duration(seconds: 5)),
    );

    test(
      'two failed psubscribe calls do not put back a failed listener',
      () async {
        String okPattern = '$name.ok*';
        Future<RedisSubscriber> a = user.psubscribe(<String>[
          okPattern,
          '$name:no*',
        ]);
        Future<RedisSubscriber> b = user.psubscribe(<String>[
          okPattern,
          '$name:no2*',
        ]);
        await expectLater(a, throwsA(isA<RedisError>()));
        await expectLater(b, throwsA(isA<RedisError>()));
        expect(user.connection.patternListeners, isEmpty);
        expect(user.redisClientType, RedisType.normal);
      },
      timeout: Timeout(Duration(seconds: 5)),
    );

    test(
      'same List in two subscribe calls: the one that works stays',
      () async {
        List<String> channels = <String>['$name.ok5'];
        Completer<String?> got = Completer<String?>();
        RedisSubscriber s = await user.subscribe(channels);
        s.onMessage = (String channel, String? message) {
          if (!got.isCompleted) got.complete(message);
        };
        // Add a channel that is not allowed to the same List.
        channels.add('$name:no');
        await expectLater(user.subscribe(channels), throwsA(isA<RedisError>()));
        expect(user.connection.subscribeListeners[channels], same(s));
        expect(await admin.publish('$name.ok5', 'hi'), 1);
        expect(await got.future.timeout(Duration(seconds: 2)), 'hi');
      },
      timeout: Timeout(Duration(seconds: 5)),
    );

    test('unsubscribe at the same time does not keep a failed entry', () async {
      // The UNSUBSCRIBE reply comes first and moves every entry to a new
      // List. The failed SUBSCRIBE must still remove its own entry.
      Future<void> u = user.unsubscribe('$name.ok7');
      Future<RedisSubscriber> s = user.subscribe(<String>[
        '$name:a',
        '$name:b',
      ]);
      await u;
      await expectLater(s, throwsA(isA<RedisError>()));
      expect(user.connection.subscribeListeners, isEmpty);
      expect(user.redisClientType, RedisType.normal);
      expect(user.connection.keepBytes, isFalse);
      expect(await user.publish('$name.ok7', 'hi'), 0);
    }, timeout: Timeout(Duration(seconds: 5)));

    test(
      'two failed psubscribe calls give back the older working one',
      () async {
        String okPattern = '$name.ok*';
        Completer<String?> got = Completer<String?>();
        RedisSubscriber first = await user.psubscribe(okPattern);
        first.onPatternMessage = (String p, String channel, String? message) {
          if (!got.isCompleted) got.complete(message);
        };
        Future<RedisSubscriber> a = user.psubscribe(<String>[
          okPattern,
          '$name:no1*',
        ]);
        Future<RedisSubscriber> b = user.psubscribe(<String>[
          okPattern,
          '$name:no2*',
        ]);
        await expectLater(a, throwsA(isA<RedisError>()));
        await expectLater(b, throwsA(isA<RedisError>()));
        expect(user.connection.patternListeners[okPattern], <RedisSubscriber>[
          first,
        ]);
        expect(user.connection.patternListeners.length, 1);
        expect(await admin.publish('$name.ok8', 'hi'), 1);
        expect(await got.future.timeout(Duration(seconds: 2)), 'hi');
      },
      timeout: Timeout(Duration(seconds: 5)),
    );

    test(
      'two failed subscribe calls on the same List give back the first',
      () async {
        List<String> channels = <String>['$name.ok9'];
        RedisSubscriber first = await user.subscribe(channels);
        channels.add('$name:no');
        Future<RedisSubscriber> a = user.subscribe(channels);
        Future<RedisSubscriber> b = user.subscribe(channels);
        await expectLater(a, throwsA(isA<RedisError>()));
        await expectLater(b, throwsA(isA<RedisError>()));
        expect(user.connection.subscribeListeners[channels], same(first));
        expect(user.connection.subscribeListeners.length, 1);
      },
      timeout: Timeout(Duration(seconds: 5)),
    );
  });
}
