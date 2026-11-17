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
      expect(user.connection.patternListeners[okPattern], same(first));
      expect(user.connection.patternListeners.length, 1);
      expect(await admin.publish('$name.ok2', 'hi'), 1);
      expect(await got.future.timeout(Duration(seconds: 2)), 'hi');
    }, timeout: Timeout(Duration(seconds: 5)));

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
  });
}
