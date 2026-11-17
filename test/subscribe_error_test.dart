import 'package:ioredis/ioredis.dart';
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
      // A user with all commands and keys, but no pub/sub channels.
      await admin.call('ACL', <String>[
        'SETUSER',
        name,
        'on',
        '>pass',
        '~*',
        '+@all',
        'resetchannels',
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
  });
}
