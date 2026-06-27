// JDK 1.0 -> 24 语法特性反编译兼容性测试。
//
// 流程:
//   1. 读取 test/jdk_features/manifest.json
//   2. 对每个条目，反编译 test/jdk_features/build/<Class>.class
//   3. 与 test/jdk_features/golden/<Class>.txt 比对（行尾规范化）
//
// 前置: 先运行 `dart run tool/compile_jdk_features.dart` 生成 .class。
// 刷新基线: `UPDATE_GOLDEN=true dart test test/jdk_features_test.dart`
//
// 反编译过程中抛出的异常会被捕获并记为 FAIL（带堆栈），用于定位缺失实现。
import 'dart:convert';
import 'dart:io';

import 'package:java_decompiler/java_decompiler.dart';
import 'package:test/test.dart';

const _manifestPath = 'test/jdk_features/manifest.json';
const _buildDir = 'test/jdk_features/build';
const _goldenDir = 'test/jdk_features/golden';

List<Map<String, dynamic>> _readSources() {
  final manifest = jsonDecode(File(_manifestPath).readAsStringSync())
      as Map<String, dynamic>;
  return (manifest['sources'] as List).cast<Map<String, dynamic>>();
}

String _className(String file) => file.replaceAll('.java', '');

String _normalize(String s) =>
    s.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trimRight();

void main() {
  final sources = _readSources();
  final updateGolden = Platform.environment.containsKey('UPDATE_GOLDEN');

  for (final entry in sources) {
    final version = entry['version'] as String;
    final file = entry['file'] as String;
    final features = (entry['features'] as List).join('; ');
    final classFile =
        entry['classFile'] as String? ?? '${_className(file)}.class';
    final goldenName = classFile.replaceAll('.class', '');

    test('JDK $version  $goldenName  [$features]', () {
      final classPath = '$_buildDir/$classFile';

      final cf = File(classPath);
      if (!cf.existsSync()) {
        fail(
            '缺少 .class: $classPath\n请先运行: dart run tool/compile_jdk_features.dart');
      }

      final bytes = cf.readAsBytesSync();
      final String output;
      try {
        final parsed = ClassFileParser(bytes).parse();
        output = Decompiler(parsed).decompile();
      } catch (e, st) {
        // 反编译抛异常 => 明确失败，便于定位缺失实现。
        fail('反编译抛异常: $e\n$st');
      }

      final goldenPath = '$_goldenDir/$goldenName.txt';
      final goldenFile = File(goldenPath);

      if (updateGolden || !goldenFile.existsSync()) {
        goldenFile.writeAsStringSync(output);
        return;
      }

      final expected = _normalize(goldenFile.readAsStringSync());
      expect(
        _normalize(output),
        equals(expected),
        reason: '反编译输出与黄金文件不一致: $goldenPath\n'
            '如有意变更请运行: UPDATE_GOLDEN=true dart test test/jdk_features_test.dart',
      );
    });
  }
}
