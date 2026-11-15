import 'dart:typed_data';

/// Writes RESP commands into one growing byte buffer.
/// The buffer is reused, so encoding a command does not allocate
/// new lists in the common case.
class RedisMessageEncoder {
  static const int _initialSize = 4096;

  /// A buffer bigger than this is dropped after a flush, so one big
  /// command does not keep its memory for ever. Batches up to this size
  /// keep their buffer and do not grow it again each time.
  static const int _keepLimit = 256 * 1024;

  Uint8List _buffer = Uint8List(_initialSize);

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
  /// The copy is needed: the socket keeps the list until it is written,
  /// and the buffer is used again for the next commands. A view would not
  /// help either: dart:io copies a view of a bigger buffer before it writes.
  Uint8List takeBytes() {
    Uint8List bytes = _buffer.sublist(0, _length);
    clear();
    return bytes;
  }

  /// Drop the bytes written after [length]. Used to undo a half-written
  /// command.
  void truncate(int length) {
    if (length < _length) _length = length;
  }

  /// Drop all written bytes.
  void clear() {
    _length = 0;
    // Do not keep a large buffer after one big command.
    if (_buffer.length > _keepLimit) _buffer = Uint8List(_initialSize);
  }

  /// Append one value to the buffer.
  /// Strings become bulk strings, lists become arrays,
  /// ints and `Uint8List` inside a list become bulk strings.
  void write(Object? object) {
    if (object is String) {
      _writeBulk(object);
    } else if (object is List) {
      _writeHeader(0x2a, object.length); // '*'
      for (int i = 0; i < object.length; i++) {
        Object? v = object[i];
        if (v is String) {
          _writeBulk(v);
        } else if (v is Uint8List) {
          _writeBulkBytes(v);
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
        _writeBulkUtf8(value, start, pos, i);
        return;
      }
      buf[pos++] = c;
    }
    buf[pos++] = 0x0d;
    buf[pos++] = 0x0a;
    _length = pos;
  }

  /// Text with a non-ASCII character at [index]. The header (for
  /// value.length bytes) is at [start] and the ASCII part before [index]
  /// ends at [pos]. Encode the rest as UTF-8 straight into the buffer,
  /// then fix the header to the real byte length.
  /// The bytes are the same as `utf8.encode`: a lone surrogate becomes
  /// U+FFFD (EF BF BD).
  void _writeBulkUtf8(String value, int start, int pos, int index) {
    int n = value.length;
    // One UTF-16 unit is at most 3 bytes (a pair of 2 units is 4 bytes).
    // The header can get one more digit; 24 bytes leave room for it.
    _length = pos;
    _ensure((n - index) * 3 + 24);
    Uint8List buf = _buffer;
    for (int i = index; i < n; i++) {
      int c = value.codeUnitAt(i);
      if (c < 0x80) {
        buf[pos++] = c;
      } else if (c < 0x800) {
        buf[pos++] = 0xc0 | (c >> 6);
        buf[pos++] = 0x80 | (c & 0x3f);
      } else if ((c & 0xf800) != 0xd800) {
        buf[pos++] = 0xe0 | (c >> 12);
        buf[pos++] = 0x80 | ((c >> 6) & 0x3f);
        buf[pos++] = 0x80 | (c & 0x3f);
      } else if (c < 0xdc00 &&
          i + 1 < n &&
          (value.codeUnitAt(i + 1) & 0xfc00) == 0xdc00) {
        // A surrogate pair: one code point, 4 bytes.
        int cp =
            0x10000 + ((c & 0x3ff) << 10) + (value.codeUnitAt(++i) & 0x3ff);
        buf[pos++] = 0xf0 | (cp >> 18);
        buf[pos++] = 0x80 | ((cp >> 12) & 0x3f);
        buf[pos++] = 0x80 | ((cp >> 6) & 0x3f);
        buf[pos++] = 0x80 | (cp & 0x3f);
      } else {
        // A lone surrogate: U+FFFD, like utf8.encode.
        buf[pos++] = 0xef;
        buf[pos++] = 0xbf;
        buf[pos++] = 0xbd;
      }
    }
    int oldHeader = _headerSize(n);
    int dataStart = start + oldHeader;
    int byteLength = pos - dataStart;
    int shift = _headerSize(byteLength) - oldHeader;
    if (shift > 0) {
      // The header got longer. Move the data to make room (setRange on
      // the same list handles the overlap).
      buf.setRange(dataStart + shift, pos + shift, buf, dataStart);
      pos += shift;
    }
    _length = start;
    _writeHeader(0x24, byteLength);
    buf[pos++] = 0x0d;
    buf[pos++] = 0x0a;
    _length = pos;
  }

  /// Size of `$<length>\r\n` for a length of zero or more.
  static int _headerSize(int length) {
    int digits = 1;
    while (length >= 10) {
      length ~/= 10;
      digits++;
    }
    return digits + 3;
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
