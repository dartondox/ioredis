import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:ioredis/src/redis_response.dart';

StreamTransformer<Uint8List, String> transformer =
    StreamTransformer<Uint8List, String>.fromHandlers(
  handleData: (List<int> data, EventSink<String> sink) {
    sink.add(utf8.decode(data));
  },
  handleError: (Object err, StackTrace st, EventSink<String> sink) {
    sink.addError(err);
  },
  handleDone: (EventSink<String> sink) {
    sink.close();
  },
);

StreamTransformer<String, dynamic> redisResponseTransformer =
    StreamTransformer<String, dynamic>.fromHandlers(
  handleData: (String data, EventSink<dynamic> sink) {
    sink.add(RedisResponse.transform(data));
  },
  handleError: (Object err, StackTrace st, EventSink<dynamic> sink) {
    sink.addError(err);
  },
  handleDone: (EventSink<dynamic> sink) {
    sink.close();
  },
);
