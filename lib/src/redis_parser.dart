import 'dart:convert';
import 'dart:typed_data';

import 'package:ioredis/src/redis_error.dart';

/// Streaming RESP2 parser.
/// Bytes from the socket go in with [feed]. Every complete reply comes out.
/// A reply can be split over many chunks, and one chunk can hold many replies.
class RedisParser {
  /// Bytes that do not form a complete reply yet.
  Uint8List _buffer = Uint8List(0);

  /// Add bytes and get back all replies that are now complete.
  /// Reply types: `String` (simple and bulk string), `int`, `null`,
  /// `List<dynamic>` (array, may be nested) and [RedisError].
  List<dynamic> feed(List<int> data) {
    // ponytail: the unparsed tail is copied on every chunk. That is O(n^2)
    // for one very large reply. Keep a list of chunks if that ever matters.
    BytesBuilder builder = BytesBuilder(copy: false);
    builder.add(_buffer);
    builder.add(data);
    _buffer = builder.takeBytes();

    List<dynamic> replies = <dynamic>[];
    int pos = 0;
    while (pos < _buffer.length) {
      (dynamic, int)? result = _parse(pos);
      if (result == null) break;
      replies.add(result.$1);
      pos = result.$2;
    }
    _buffer = Uint8List.sublistView(_buffer, pos);
    return replies;
  }

  /// Parse one reply that starts at [pos].
  /// Returns the value and the position after it,
  /// or null when the reply is not complete yet.
  (dynamic, int)? _parse(int pos) {
    int lineEnd = _findLineEnd(pos + 1);
    if (lineEnd < 0) return null;
    int type = _buffer[pos];
    String line = utf8.decode(
      Uint8List.sublistView(_buffer, pos + 1, lineEnd),
      allowMalformed: true,
    );
    int next = lineEnd + 2;

    switch (type) {
      case 0x2b: // '+' simple string
        return (line, next);
      case 0x2d: // '-' error
        return (RedisError(line), next);
      case 0x3a: // ':' integer
        return (int.parse(line), next);
      case 0x24: // '$' bulk string, length is in bytes
        int length = int.parse(line);
        if (length < 0) return (null, next);
        if (_buffer.length < next + length + 2) return null;
        String value = utf8.decode(
          Uint8List.sublistView(_buffer, next, next + length),
          allowMalformed: true,
        );
        return (value, next + length + 2);
      case 0x2a: // '*' array
        int count = int.parse(line);
        if (count < 0) return (null, next);
        List<dynamic> items = <dynamic>[];
        for (int i = 0; i < count; i++) {
          (dynamic, int)? item = _parse(next);
          if (item == null) return null;
          items.add(item.$1);
          next = item.$2;
        }
        return (items, next);
      default:
        throw FormatException('Unknown RESP type byte: $type');
    }
  }

  /// Find the index of the next `\r\n`, or -1.
  int _findLineEnd(int start) {
    for (int i = start; i < _buffer.length - 1; i++) {
      if (_buffer[i] == 0x0d && _buffer[i + 1] == 0x0a) return i;
    }
    return -1;
  }
}
