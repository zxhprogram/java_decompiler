/// 将字段/方法描述符解析为 Java 源码风格的类型字符串。
class DescriptorParser {
  /// 将字段描述符（如 `Ljava/lang/String;`、`[[I`）解析为源码类型。
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
        while (descriptor[i] == '[') i++;
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
