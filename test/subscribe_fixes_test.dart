import 'dart:async';

import 'package:ioredis/ioredis.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  group('subscribe fixes |', () {
    test('same const List twice keeps both subscribers', () async {
      String chan = uniquePrefix('samelist').replaceAll(':', '_');
      List<String> chans = <String>[chan];
      Redis sub = testClient();
      Redis pub = testClient();
      List<String> a = <String>[];
      List<String> b = <String>[];
      (await sub.subscribe(chans)).onMessage = (String c, String? m) {
        a.add(m!);
      };
      (await sub.subscribe(chans)).onMessage = (String c, String? m) {
        b.add(m!);
      };
      await pub.publish(chan, 'hi');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(a, <String>['hi']);
      expect(b, <String>['hi']);
    });

    test('async callback that throws goes to onError', () async {
      String chan = uniquePrefix('asyncthrow').replaceAll(':', '_');
      Completer<Object> got = Completer<Object>();
      Redis sub = Redis(
        RedisOptions(
          host: redisHost,
          port: redisPort,
          onError: (dynamic e) {
            if (!got.isCompleted && e.toString().contains('boom')) {
              got.complete(e as Object);
            }
          },
        ),
      );
      addTearDown(sub.quit);
      Redis pub = testClient();
      (await sub.subscribe(chan)).onMessage = (String c, String? m) async {
        await Future<void>.delayed(Duration.zero);
        throw StateError('boom');
      };
      List<String> pmsgs = <String>[];
      (await sub.psubscribe('$chan*'))
          .onPatternMessage = (String p, String c, String? m) async {
        pmsgs.add(m!);
        throw StateError('boom');
      };
      await pub.publish(chan, 'x');
      expect(await got.future.timeout(const Duration(seconds: 3)), isNotNull);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(pmsgs, <String>['x']);
    });
  });
}
