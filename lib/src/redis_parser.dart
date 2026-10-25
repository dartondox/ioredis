import 'dart:convert';
import 'dart:typed_data';

import 'package:ioredis/src/redis_error.dart';

/// An array that still waits for some of its items.
class _OpenArray {
  final List<dynamic> items;
  int remaining;

  _OpenArray(int count)
    : items = List<dynamic>.filled(count, null),
      remaining = count;
}

/// Streaming RESP2 parser.
/// Bytes from the socket go in with [feed]. Every complete reply comes out.
/// A reply can be split over many chunks, and one chunk can hold many replies.
///
/// The parser reads the chunks in place. It does not copy them, except
/// for the bytes of one element that is split between chunks.
/// Arrays are kept open between chunks, so a big array is read only once.
class RedisParser {
  /// Bytes of one element that is not complete yet (a view, no copy).
  Uint8List? _rest;

  /// Chunks that came after [_rest] and are not joined yet.
  final List<Uint8List> _waiting = <Uint8List>[];

  int _waitingLength = 0;

  /// How many bytes (from the start of [_rest]) the split element needs.
  int _needed = 0;

  /// Arrays that are being filled, the innermost one last.
  final List<_OpenArray> _open = <_OpenArray>[];

  /// End position of the element read by [_readElement].
  int _end = 0;

  /// When true, bulk strings come out as `Uint8List` (raw bytes, not
  /// decoded). Used on pub/sub connections, so binary payloads keep
  /// their exact bytes.
  bool keepBytes = false;

  /// Add bytes and get back all replies that are now complete.
  /// Reply types: `String` (simple and bulk string), `int`, `null`,
  /// `List<dynamic>` (array, may be nested) and [RedisError].
  /// With [keepBytes], bulk strings are `Uint8List` instead of `String`.
  List<dynamic> feed(List<int> data) {
    Uint8List chunk = data is Uint8List ? data : Uint8List.fromList(data);
    Uint8List? rest = _rest;
    List<dynamic> replies = <dynamic>[];
    if (rest != null) {
      _waiting.add(chunk);
      _waitingLength += chunk.length;
      // A big bulk string: wait until all its bytes are here, then join once.
      if (rest.length + _waitingLength < _needed) return replies;
      chunk = _join(rest);
    }
    _parse(chunk, replies);
    return replies;
  }

  Uint8List _join(Uint8List rest) {
    BytesBuilder builder = BytesBuilder(copy: false);
    builder.add(rest);
    for (Uint8List c in _waiting) {
      builder.add(c);
    }
    _waiting.clear();
    _waitingLength = 0;
    _rest = null;
    return builder.takeBytes();
  }

  void _parse(Uint8List buf, List<dynamic> replies) {
    int pos = 0;
    int length = buf.length;
    while (pos < length) {
      int type = buf[pos];
      dynamic value;
      if (type == 0x2a) {
        // '*' array: only the header is read here, the items come next.
        int lineEnd = _lineEnd(buf, pos + 1);
        if (lineEnd < 0) {
          _keep(buf, pos, length - pos + 1);
          return;
        }
        int count = _int(buf, pos + 1, lineEnd);
        pos = lineEnd + 2;
        if (count > 0) {
          _open.add(_OpenArray(count));
          continue;
        }
        value = count == 0 ? <dynamic>[] : null;
      } else {
        int needed = _readElement(buf, pos, type);
        if (needed > 0) {
          _keep(buf, pos, needed);
          return;
        }
        value = _value;
        pos = _end;
      }
      // Put the value into its array. A full array is a value for the
      // array around it.
      while (_open.isNotEmpty) {
        _OpenArray top = _open.last;
        top.items[top.items.length - top.remaining] = value;
        if (--top.remaining > 0) break;
        _open.removeLast();
        value = top.items;
      }
      if (_open.isEmpty) replies.add(value);
    }
  }

  /// Keep the unfinished element for the next chunk.
  void _keep(Uint8List buf, int pos, int needed) {
    _rest = Uint8List.sublistView(buf, pos);
    _needed = needed;
  }

  dynamic _value;

  /// Read one non-array element at [pos] into [_value] and [_end].
  /// Returns 0 when done, or how many bytes from [pos] are needed at least.
  int _readElement(Uint8List buf, int pos, int type) {
    int lineEnd = _lineEnd(buf, pos + 1);
    if (lineEnd < 0) return buf.length - pos + 1;
    int next = lineEnd + 2;
    switch (type) {
      case 0x24: // '$' bulk string, length is in bytes
        int length = _int(buf, pos + 1, lineEnd);
        if (length < 0) {
          _value = null;
          _end = next;
          return 0;
        }
        int end = next + length;
        if (buf.length < end + 2) return end + 2 - pos;
        Uint8List bytes = Uint8List.sublistView(buf, next, end);
        _value = keepBytes ? bytes : utf8.decode(bytes, allowMalformed: true);
        _end = end + 2;
        return 0;
      case 0x3a: // ':' integer
        _value = _int(buf, pos + 1, lineEnd);
        _end = next;
        return 0;
      case 0x2b: // '+' simple string
        _value = _text(buf, pos + 1, lineEnd);
        _end = next;
        return 0;
      case 0x2d: // '-' error
        _value = RedisError(_text(buf, pos + 1, lineEnd));
        _end = next;
        return 0;
      default:
        throw FormatException('Unknown RESP type byte: $type');
    }
  }

  String _text(Uint8List buf, int start, int end) {
    return utf8.decode(
      Uint8List.sublistView(buf, start, end),
      allowMalformed: true,
    );
  }

  /// Read a signed integer from the bytes, no String in between.
  int _int(Uint8List buf, int start, int end) {
    bool negative = start < end && buf[start] == 0x2d;
    int i = negative ? start + 1 : start;
    if (i >= end) throw FormatException('Bad RESP integer');
    int value = 0;
    for (; i < end; i++) {
      int d = buf[i] - 0x30;
      if (d < 0 || d > 9) throw FormatException('Bad RESP integer');
      value = value * 10 + d;
    }
    return negative ? -value : value;
  }

  /// Find the index of the next `\r\n`, or -1.
  int _lineEnd(Uint8List buf, int start) {
    int last = buf.length - 1;
    for (int i = start; i < last; i++) {
      if (buf[i] == 0x0d && buf[i + 1] == 0x0a) return i;
    }
    return -1;
  }
}
