import 'dart:convert';
import 'dart:typed_data';

/// Writes RESP commands into one growing byte buffer.
/// The buffer is reused, so encoding a command does not allocate
/// new lists in the common case.
class RedisMessageEncoder {
  Uint8List _buffer = Uint8List(4096);

  int _length = 0;

  /// Number of bytes written and not taken yet.
  int get length => _length;

  /// Encode one value and return its bytes.
  /// It does not touch bytes that were written before.
  Uint8List encode(Object? object) {
    int start = _length;
    write(object);
    Uint8List bytes = Uint8List.fromList(
      Uint8List.sublistView(_buffer, start, _length),
    );
    _length = start;
    return bytes;
  }

  /// Copy all written bytes out and empty the buffer.
  Uint8List takeBytes() {
    Uint8List bytes = Uint8List.fromList(
      Uint8List.sublistView(_buffer, 0, _length),
    );
    clear();
    return bytes;
  }

  /// Drop all written bytes.
  void clear() {
    _length = 0;
    // Do not keep a very large buffer after one big command.
    if (_buffer.length > 1 << 20) _buffer = Uint8List(4096);
  }

  /// Append one value to the buffer.
  /// Strings become bulk strings, lists become arrays,
  /// ints inside a list become bulk strings.
  void write(Object? object) {
    if (object is String) {
      _writeBulk(object);
    } else if (object is List) {
      _writeHeader(0x2a, object.length); // '*'
      for (int i = 0; i < object.length; i++) {
        Object? v = object[i];
        if (v is String) {
          _writeBulk(v);
        } else {
          write(v is int ? v.toString() : v);
        }
      }
    } else if (object is Iterable) {
      write(object.toList());
    } else if (object is int) {
      _writeHeader(0x3a, object); // ':'
    } else if (object == null) {
      _writeHeader(0x24, -1); // '$-1' null bulk string
    } else {
      throw Exception('unable to serialize');
    }
  }

  void _writeBulk(String value) {
    int n = value.length;
    // Fast path: ASCII text is copied byte by byte, no utf8.encode.
    _ensure(n + 24);
    int start = _length;
    _writeHeader(0x24, n); // '$'
    int pos = _length;
    Uint8List buf = _buffer;
    for (int i = 0; i < n; i++) {
      int c = value.codeUnitAt(i);
      if (c > 0x7f) {
        _length = start;
        _writeBulkBytes(utf8.encode(value));
        return;
      }
      buf[pos++] = c;
    }
    buf[pos++] = 0x0d;
    buf[pos++] = 0x0a;
    _length = pos;
  }

  void _writeBulkBytes(Uint8List data) {
    _ensure(data.length + 24);
    _writeHeader(0x24, data.length);
    _buffer.setRange(_length, _length + data.length, data);
    _length += data.length;
    _buffer[_length++] = 0x0d;
    _buffer[_length++] = 0x0a;
  }

  /// Write `<type><number>\r\n`.
  void _writeHeader(int type, int value) {
    _ensure(24);
    Uint8List buf = _buffer;
    buf[_length++] = type;
    if (value < 0) {
      buf[_length++] = 0x2d; // '-'
      if (value == -value) {
        // The smallest int has no positive value. It is rare, use toString.
        for (int c in value.toString().substring(1).codeUnits) {
          buf[_length++] = c;
        }
        buf[_length++] = 0x0d;
        buf[_length++] = 0x0a;
        return;
      }
      value = -value;
    }
    if (value < 10) {
      buf[_length++] = 0x30 + value;
    } else {
      int digits = 0;
      for (int v = value; v > 0; v ~/= 10) {
        digits++;
      }
      int end = _length + digits;
      for (int p = end - 1; p >= _length; p--) {
        buf[p] = 0x30 + value % 10;
        value ~/= 10;
      }
      _length = end;
    }
    buf[_length++] = 0x0d;
    buf[_length++] = 0x0a;
  }

  void _ensure(int extra) {
    int needed = _length + extra;
    if (needed <= _buffer.length) return;
    int size = _buffer.length * 2;
    while (size < needed) {
      size *= 2;
    }
    Uint8List bigger = Uint8List(size);
    bigger.setRange(0, _length, _buffer);
    _buffer = bigger;
  }
}
