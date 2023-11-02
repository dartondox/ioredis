enum RedisResponseConstant {
  ok('OK'),
  simpleString('+'),
  error('-'),
  bulkString('\$'),
  integer(':'),
  array('*');

  final String name;
  const RedisResponseConstant(this.name);
}

enum RedisType {
  both('both'),
  subscriber('publisher'),
  publisher('publisher');

  final String name;
  const RedisType(this.name);
}

class RedisResponse {
  static bool ok(String? s) {
    return s == 'OK';
  }

  static bool isSimpleString(String s) {
    return s.startsWith(RedisResponseConstant.simpleString.name);
  }

  static String? toSimpleString(String s) {
    String? val = s.substring(1, s.length - 2);
    if (val.isEmpty) return null;
    return val;
  }

  static String? toBulkString(String s) {
    List<String> listOfData = s.split('\r\n');
    if (listOfData[1].isEmpty) return null;
    return listOfData[1];
  }

  static List<String?> toArrayString(String s) {
    List<String> listOfData = s.split('\r\n');
    List<String?> elements = <String?>[];
    for (int i = 1; i < listOfData.length; i++) {
      String element = listOfData[i];
      if (i % 2 == 0) {
        elements.add(element.isEmpty ? null : element);
      }
    }
    return elements;
  }

  String? toErrorString(String s) {
    return s.substring(1, s.length - 2);
  }

  static bool isError(String s) {
    return s.startsWith(RedisResponseConstant.error.name);
  }

  static bool isBulkString(String s) {
    return s.startsWith(RedisResponseConstant.bulkString.name);
  }

  static bool isInteger(String s) {
    return s.startsWith(RedisResponseConstant.integer.name);
  }

  static bool isArray(String s) {
    return s.startsWith(RedisResponseConstant.array.name);
  }

  static dynamic transform(String? s) {
    if (s == null) return null;
    if (RedisResponse.isSimpleString(s)) {
      return RedisResponse.toSimpleString(s);
    } else if (RedisResponse.isError(s)) {
      return RedisResponse.toSimpleString(s);
    } else if (RedisResponse.isInteger(s)) {
      return RedisResponse.toSimpleString(s);
    } else if (RedisResponse.isBulkString(s)) {
      return RedisResponse.toBulkString(s);
    } else if (RedisResponse.isArray(s)) {
      return RedisResponse.toArrayString(s);
    }
    return null;
  }
}
