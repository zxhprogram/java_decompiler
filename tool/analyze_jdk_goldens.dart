// 扫描 test/jdk_features/golden/*.txt，检测明确的反编译缺陷信号，
// 输出每个版本的缺陷统计，用于生成测试报告。
//
// 用法: dart run tool/analyze_jdk_goldens.dart
import 'dart:convert';
import 'dart:io';

void main() {
  final manifest =
      jsonDecode(File('test/jdk_features/manifest.json').readAsStringSync())
          as Map;
  final sources = (manifest['sources'] as List).cast<Map<String, dynamic>>();
  final goldenDir = Directory('test/jdk_features/golden');

  // 缺陷信号 -> 描述
  final signals = <(Pattern, String)>[
    (RegExp(r'\[\[I|\[\[L'), 'multianewarray 类型未解码'),
    (RegExp(r'invokedynamic\b'), 'invokedynamic 未解析为 lambda/方法引用'),
    (RegExp(r'/\*exception\*/'), '异常变量未还原'),
    (RegExp(r'\bgoto label_\d+\b'), 'goto/label 未结构化'),
    (RegExp(r'UnnamedPattern|_\b'), '未命名模式残留'),
    (RegExp(r'\bcase null\b'), 'null case 处理'),
  ];

  stdout.writeln('version | class | lines | signals');
  stdout.writeln('--------|-------|-------|--------');
  for (final entry in sources) {
    final version = entry['version'] as String;
    final file = entry['file'] as String;
    final cls = file.replaceAll('.java', '');
    final gf = File('${goldenDir.path}/$cls.txt');
    if (!gf.existsSync()) {
      stdout.writeln('$version | $cls | - | MISSING');
      continue;
    }
    final text = gf.readAsStringSync();
    final lines = text.split('\n');
    final hits = <String>[];
    for (final (pat, desc) in signals) {
      final m = pat.allMatches(text).toList();
      if (m.isNotEmpty) hits.add('$desc(${m.length})');
    }
    stdout.writeln(
        '$version | $cls | ${lines.length} | ${hits.isEmpty ? "clean" : hits.join("; ")}');
  }
}
