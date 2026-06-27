part of 'code_printer.dart';

/// 跨模块工具方法：别名替换、平凡条件判断、类型兼容性检查。
extension on CodePrinter {
  String _replaceAliasNames(String expr, Map<String, String> aliasMap) {
    if (aliasMap.isEmpty) return expr;
    final entries = aliasMap.entries.toList()
      ..sort((a, b) => b.key.length.compareTo(a.key.length));
    var result = expr;
    for (final e in entries) {
      result = result.replaceAll(
          RegExp(r'\b' + RegExp.escape(e.key) + r'\b'), e.value);
    }
    return result;
  }

  bool _isTrivialCondition(String cond) {
    final c = cond.replaceAll(' ', '');
    return c == '1' ||
        c == '0' ||
        c == 'true' ||
        c == 'false' ||
        c == '1==0' ||
        c == '0==1' ||
        c == '1!=0' ||
        c == '0!=1';
  }

  /// 判断两个类型是否兼容（可相互反向传播）。
  /// boolean 与 int 不兼容，避免把数组长度误判为 boolean。
  bool _typesCompatible(String a, String b) {
    if (a == b) return true;
    final numTypes = {'int', 'long', 'short', 'byte', 'char'};
    if (numTypes.contains(a) && numTypes.contains(b)) return true;
    return false;
  }

  /// 将原始字符串值格式化为 Java 字符串字面量。
  /// - JDK 13+ (majorVersion >= 57): 多行字符串使用文本块 `"""..."""`
  /// - JDK < 13: 使用 `\n` 等转义序列拼接
  String _formatStringLiteral(String raw) {
    final hasNewline = raw.contains('\n') || raw.contains('\r');

    // JDK 13+ 文本块：仅当字符串含换行、且不含 """ 序列时使用
    if (hasNewline &&
        _cf.majorVersion >= 57 && // JDK 13 = major 57
        !raw.contains('"""')) {
      return _formatTextBlock(raw);
    }

    // 普通字符串字面量：转义所有特殊字符
    final escaped = raw
        .replaceAll('\\', '\\\\')
        .replaceAll('"', '\\"')
        .replaceAll('\n', '\\n')
        .replaceAll('\r', '\\r')
        .replaceAll('\t', '\\t');
    return '"$escaped"';
  }

  /// 将多行字符串格式化为 Java 13+ 文本块。
  String _formatTextBlock(String raw) {
    // 规范化行尾：统一为 \n
    final normalized = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    var lines = normalized.split('\n');

    // Java 文本块：闭合 """ 前的换行属于内容的一部分。
    // 若字符串以 \n 结尾，split 会产生末尾空串，需去掉以避免多余空行。
    if (lines.isNotEmpty && lines.last.isEmpty) {
      lines = lines.sublist(0, lines.length - 1);
    }

    // 文本块格式：
    // """
    //     line1
    //     line2
    //     """
    // 内容缩进为 8 空格（方法体内），闭合 """ 在同一缩进
    final indent = '        ';
    final buf = StringBuffer('"""\n');
    for (final line in lines) {
      buf.writeln('$indent$line');
    }
    buf.write('$indent"""');
    return buf.toString();
  }

  /// 重新缩进代码块，保留相对缩进。
  /// [targetIndent] 是第一行（最外层）应该使用的缩进。
  /// 其他行根据与第一行的相对缩进差进行调整。
}
