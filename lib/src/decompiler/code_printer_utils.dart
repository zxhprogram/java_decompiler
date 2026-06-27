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

  /// 重新缩进代码块，保留相对缩进。
  /// [targetIndent] 是第一行（最外层）应该使用的缩进。
  /// 其他行根据与第一行的相对缩进差进行调整。
}
