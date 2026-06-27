class DescriptorParser {
  static String parseFieldDescriptor(String descriptor) {
    final (type, _) = _parseType(descriptor, 0);
    return type;
  }

  /// 解析方法描述符，返回 `(参数类型列表, 返回类型)`。
  static (List<String>, String) parseMethodDescriptor(String descriptor) {
    if (!descriptor.startsWith('(')) {
      throw FormatException('Invalid method descriptor: $descriptor');
    }
    final params = <String>[];
    var i = 1;
    while (i < descriptor.length && descriptor[i] != ')') {
      final (type, next) = _parseType(descriptor, i);
      params.add(type);
      i = next;
    }
    if (i >= descriptor.length || descriptor[i] != ')') {
      throw FormatException('Invalid method descriptor: $descriptor');
    }
    final (returnType, _) = _parseType(descriptor, i + 1);
    return (params, returnType);
  }

  static (String, int) _parseType(String descriptor, int start) {
    final c = descriptor[start];
    switch (c) {
      case 'B':
        return ('byte', start + 1);
      case 'C':
        return ('char', start + 1);
      case 'D':
        return ('double', start + 1);
      case 'F':
        return ('float', start + 1);
      case 'I':
        return ('int', start + 1);
      case 'J':
        return ('long', start + 1);
      case 'S':
        return ('short', start + 1);
      case 'Z':
        return ('boolean', start + 1);
      case 'V':
        return ('void', start + 1);
      case '[':
        var i = start + 1;
        final (component, next) = _parseType(descriptor, i);
        return ('$component[]', next);
      case 'L':
        final end = descriptor.indexOf(';', start);
        if (end == -1) {
          throw FormatException('Invalid class descriptor: $descriptor');
        }
        final raw = descriptor.substring(start + 1, end);
        return (_internalToSourceName(raw), end + 1);
      default:
        throw FormatException(
            'Unknown type descriptor char "$c" at $start in $descriptor');
    }
  }

  /// 把内部形式 `java/lang/Object` 转换为源码形式 `java.lang.Object`。
  static String internalToSourceName(String internal) {
    return internal.replaceAll('/', '.');
  }

  static String _internalToSourceName(String internal) {
    final name = internal.replaceAll('/', '.');
    // 去掉尾部多余的分号已在 parseType 处理
    return name;
  }

  /// 从方法描述符中读取参数个数（用于局部变量表索引计算）。
  static int parameterSlotCount(String descriptor) {
    var count = 0;
    var i = 1;
    while (i < descriptor.length && descriptor[i] != ')') {
      final c = descriptor[i];
      if (c == 'L') {
        i = descriptor.indexOf(';', i) + 1;
        count++;
      } else if (c == '[') {
        // 跳过数组维度，基础类型占 1 槽
        i++;
        while (descriptor[i] == '[') {
          i++;
        }
        if (descriptor[i] == 'L') {
          i = descriptor.indexOf(';', i) + 1;
        } else {
          i++;
        }
        count++;
      } else {
        // J/D 占两个槽
        if (c == 'J' || c == 'D') count += 2;
        count++;
        i++;
      }
    }
    return count;
  }
}

/// 解析 Java 泛型签名（Signature 属性）。
/// 目前支持解析方法签名中的参数类型和返回类型。
class SignatureParser {
  final String _s;
  int _pos = 0;

  SignatureParser(this._s);

  /// 解析方法签名，返回 `(参数类型列表, 返回类型)`。
  static (List<String>, String) parseMethodSignature(String signature) {
    return SignatureParser(signature)._parseMethodSignature();
  }

  /// 解析方法签名的类型参数部分，返回例如 `<T extends Comparable<T>>`，没有则返回 null。
  static String? parseTypeParameters(String signature) {
    final parser = SignatureParser(signature);
    if (parser._peek() != '<') return null;
    return parser._parseTypeParameters();
  }

  (List<String>, String) _parseMethodSignature() {
    // 可选的类型参数
    if (_peek() == '<') {
      _parseTypeParameters();
    }
    if (_peek() != '(') {
      throw FormatException('Expected "(" in method signature: $_s');
    }
    _pos++; // '('
    final params = <String>[];
    while (_peek() != ')') {
      params.add(_parseFieldTypeSignature());
    }
    _pos++; // ')'
    final returnType = _parseReturnType();
    // 忽略 throws 签名
    return (params, returnType);
  }

  String _parseTypeParameters() {
    if (_peek() != '<') {
      throw FormatException('Expected "<" in type parameters: $_s');
    }
    _pos++; // '<'
    final params = <String>[];
    while (_peek() != '>') {
      final id = _parseIdentifier();
      if (_peek() != ':') {
        throw FormatException('Expected ":" after type parameter $id: $_s');
      }
      _pos++; // ':'
      final bounds = <String>[];
      // class bound
      bounds.add(_parseFieldTypeSignature());
      // interface bounds
      while (_peek() == ':') {
        _pos++;
        bounds.add(_parseFieldTypeSignature());
      }
      final boundParts = <String>[];
      // java.lang.Object 是默认类上界，省略
      if (bounds.isNotEmpty && bounds.first != 'java.lang.Object') {
        boundParts.add(bounds.first);
      }
      boundParts.addAll(bounds.skip(1));
      if (boundParts.isEmpty) {
        params.add(id);
      } else {
        params.add('$id extends ${boundParts.join(' & ')}');
      }
    }
    _pos++; // '>'
    return '<${params.join(', ')}>';
  }

  String _parseReturnType() {
    if (_peek() == 'V') {
      _pos++;
      return 'void';
    }
    return _parseFieldTypeSignature();
  }

  String _parseFieldTypeSignature() {
    final c = _peek();
    if (c == 'L') {
      return _parseClassTypeSignature();
    } else if (c == '[') {
      _pos++;
      return '${_parseFieldTypeSignature()}[]';
    } else if (c == 'T') {
      _pos++; // 'T'
      final id = _parseIdentifier();
      _expect(';');
      return id;
    } else {
      throw FormatException('Unexpected char "$c" at $_pos in signature: $_s');
    }
  }

  String _parseClassTypeSignature() {
    _expect('L');
    final parts = <_ClassTypePart>[];
    while (true) {
      final name = _parseIdentifier().replaceAll('/', '.');
      String? args;
      if (_peek() == '<') {
        args = '<${_parseTypeArguments()}>';
      }
      parts.add(_ClassTypePart(name, args));
      final c = _peek();
      if (c == '.') {
        _pos++;
        continue;
      } else if (c == ';') {
        _pos++;
        break;
      } else {
        throw FormatException('Expected "." or ";" at $_pos in signature: $_s');
      }
    }
    final sb = StringBuffer();
    for (var i = 0; i < parts.length; i++) {
      if (i > 0) sb.write('.');
      sb.write(parts[i].name);
      if (parts[i].args != null) sb.write(parts[i].args);
    }
    return sb.toString();
  }

  String _parseTypeArguments() {
    _expect('<');
    final args = <String>[];
    while (_peek() != '>') {
      final c = _peek();
      if (c == '*') {
        _pos++;
        args.add('?');
      } else if (c == '+') {
        _pos++;
        args.add('? extends ${_parseFieldTypeSignature()}');
      } else if (c == '-') {
        _pos++;
        args.add('? super ${_parseFieldTypeSignature()}');
      } else {
        args.add(_parseFieldTypeSignature());
      }
    }
    _expect('>');
    return args.join(', ');
  }

  String _parseIdentifier() {
    final start = _pos;
    while (_pos < _s.length && _isIdentifierChar(_s.codeUnitAt(_pos))) {
      _pos++;
    }
    if (start == _pos) {
      throw FormatException('Expected identifier at $_pos in signature: $_s');
    }
    return _s.substring(start, _pos);
  }

  bool _isIdentifierChar(int code) {
    return (code >= 65 && code <= 90) || // A-Z
        (code >= 97 && code <= 122) || // a-z
        (code >= 48 && code <= 57) || // 0-9
        code == 95 || // _
        code == 36 || // $
        code == 47; // /
  }

  String _peek() {
    if (_pos >= _s.length) {
      throw FormatException('Unexpected end of signature: $_s');
    }
    return _s[_pos];
  }

  void _expect(String expected) {
    if (_peek() != expected) {
      throw FormatException('Expected "$expected" at $_pos in signature: $_s');
    }
    _pos++;
  }
}

class _ClassTypePart {
  final String name;
  final String? args;
  _ClassTypePart(this.name, this.args);
}
