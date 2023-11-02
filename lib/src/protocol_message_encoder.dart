import 'dart:convert';
import 'dart:typed_data';

class RedisProtocolSerializer {
  final Uint8List _semicolon = ascii.encode(':');
  final Uint8List _crlf = ascii.encode('\r\n');
  final Uint8List _star = ascii.encode('*');
  final Uint8List _nullValue = ascii.encode('\$-1');
  final Uint8List _dollar = ascii.encode('\$');

  List<int> serialize(Object? object) {
    List<int> s = <int>[];
    consume(object, (Iterable<int> v) => s.addAll(v));
    return s;
  }

  void consume(Object? object, void Function(Iterable<int> s) add) {
    if (object is String) {
      List<int> data = utf8.encode(object);
      add(_dollar);
      add(ascii.encode(data.length.toString()));
      add(_crlf);
      add(data);
      add(_crlf);
    } else if (object is Iterable) {
      int len = object.length;
      add(_star);
      add(ascii.encode(len.toString()));
      add(_crlf);
      for (dynamic v in object) {
        consume(v is int ? v.toString() : v, add);
      }
    } else if (object is int) {
      add(_semicolon);
      add(ascii.encode(object.toString()));
      add(_crlf);
    } else if (object == null) {
      add(_nullValue);
    } else {
      throw Exception('unable to serialize');
    }
  }
}
