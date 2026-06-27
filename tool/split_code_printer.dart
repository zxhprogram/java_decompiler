// 一次性重构脚本：将 code_printer.dart 按职责拆分为多个 part 文件。
// 使用 extension on CodePrinter 保持同一库作用域，私有成员仍可直接访问。
import 'dart:io';

void main() {
  final srcPath = 'lib/src/decompiler/code_printer.dart';
  final lines = File(srcPath).readAsLinesSync();

  // 方法定义起始行（1-indexed），按文件中出现顺序排列。
  //
  // 分组策略（按职责）:
  //   simplify  — 布尔/短路/装箱/标签/栈下溢等后处理简化
  //   patterns  — 模式匹配预处理与残留清理
  //   try_catch — try-catch-finally / try-with-resources 清理
  //   stack     — 栈式字节码发射及相关辅助
  //   control   — if/else/while/for/foreach/do-while/try 结构化
  //   lambda    — Lambda / 方法引用解析
  //   switch    — switch / pattern switch 结构化
  //   utils     — 跨模块工具方法

  final groups = <String, List<(int, int)>>{
    'simplify': [
      (107, 336),
      (1121, 1340),
      (5285, 5304),
    ],
    'patterns': [
      (337, 691),
    ],
    'try_catch': [
      (692, 1120),
    ],
    'stack': [
      (1341, 2714),
      (4000, 4036),
      (4240, 4413),
      (5214, 5226),
      (5305, 5334),
    ],
    'control': [
      (2715, 3999),
      (5263, 5284),
    ],
    'lambda': [
      (4037, 4239),
    ],
    'switch': [
      (4414, 5213),
    ],
    'utils': [
      (5227, 5262),
    ],
  };

  final partFileNames = <String, String>{
    'simplify': 'code_printer_simplify.dart',
    'patterns': 'code_printer_patterns.dart',
    'try_catch': 'code_printer_try_catch.dart',
    'stack': 'code_printer_stack.dart',
    'control': 'code_printer_control_flow.dart',
    'lambda': 'code_printer_lambda.dart',
    'switch': 'code_printer_switch.dart',
    'utils': 'code_printer_utils.dart',
  };

  final partHeaders = <String, String>{
    'simplify': '/// 后处理简化 pass：布尔返回、短路展平、条件简化、装箱拆箱、\n'
        '/// 标签清理、栈下溢移除等。',
    'patterns': '/// 模式匹配：instanceof record pattern 预处理与残留清理。',
    'try_catch': '/// try-catch-finally / try-with-resources 残留清理。',
    'stack': '/// 栈式字节码发射：将指令序列翻译为中间文本，含类型推断与变量命名。',
    'control': '/// 控制流结构化：if-else / while / for / for-each / do-while /\n'
        '/// try-catch 结构还原。',
    'lambda': '/// Lambda 表达式与方法引用解析。',
    'switch': '/// switch 语句结构化：pattern switch 与简单 switch 还原。',
    'utils': '/// 跨模块工具方法：别名替换、平凡条件判断、类型兼容性检查。',
  };

  // 对每个 range 的起始行向前扫描，包含方法的 /// 文档注释和空行。
  // 停止条件：遇到非空行且非 /// 注释行（通常是上一个方法的闭合括号）。
  List<(int, int)> adjustRanges(List<(int, int)> ranges) {
    return ranges.map((r) {
      var (start, end) = r;
      // 向前扫描：包含空行和 /// 文档注释
      while (start > 1) {
        final prev = lines[start - 2]; // 0-indexed, start is 1-indexed
        final trimmed = prev.trim();
        if (trimmed.isEmpty || trimmed.startsWith('///')) {
          start--;
        } else {
          break;
        }
      }
      return (start, end);
    }).toList();
  }

  // 写出每个 part 文件
  for (final entry in groups.entries) {
    final name = entry.key;
    final ranges = adjustRanges(entry.value);
    final fileName = partFileNames[name]!;
    final buf = StringBuffer();

    buf.writeln("part of 'code_printer.dart';");
    buf.writeln();
    buf.writeln(partHeaders[name]);
    buf.writeln('extension on CodePrinter {');

    for (final (start, end) in ranges) {
      // lines 是 0-indexed，输入行号是 1-indexed
      final slice = lines.sublist(start - 1, end);
      buf.writeln();
      buf.writeln(slice.join('\n'));
    }

    buf.writeln('}');

    final outPath = 'lib/src/decompiler/$fileName';
    File(outPath).writeAsStringSync(buf.toString());
    stdout.writeln('Created: $outPath');
  }

  // 重写主文件：保留 imports、_TypedValue、_CountingSink、CodePrinter 核心定义、
  // printBody()，加上 part 指令，最后是 class 闭合括号。
  final mainBuf = StringBuffer();

  // 头部：imports（lines 1-7）
  mainBuf.writeln(lines.sublist(0, 7).join('\n'));
  mainBuf.writeln();

  // part 指令
  for (final fileName in [
    'code_printer_stack.dart',
    'code_printer_control_flow.dart',
    'code_printer_switch.dart',
    'code_printer_patterns.dart',
    'code_printer_try_catch.dart',
    'code_printer_simplify.dart',
    'code_printer_lambda.dart',
    'code_printer_utils.dart',
  ]) {
    mainBuf.writeln("part '$fileName';");
  }
  mainBuf.writeln();

  // _TypedValue 类（lines 9-12）和 _CountingSink 类（lines 14-35）
  mainBuf.writeln(lines.sublist(8, 35).join('\n'));
  mainBuf.writeln();

  // CodePrinter 类定义：fields, constructor, _branchOpcodes, printBody()（lines 37-103）
  mainBuf.writeln(lines.sublist(36, 103).join('\n'));

  // class 闭合括号
  mainBuf.writeln('}');

  File(srcPath).writeAsStringSync(mainBuf.toString());
  stdout.writeln('Rewritten: $srcPath');
}
