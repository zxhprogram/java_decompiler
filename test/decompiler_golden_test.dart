// 黄金文件回归测试：保证 code_printer.dart 重构前后输出完全一致。
//
// 如果反编译逻辑发生有意变更，可用环境变量刷新基线：
//   UPDATE_GOLDEN=true dart test
import 'dart:io';

import 'package:java_decompiler/java_decompiler.dart';
import 'package:test/test.dart';

/// 被测的 class 文件列表（相对于项目根目录）。
/// 选择标准：覆盖尽可能多的反编译路径（控制流、模式匹配、lambda、
/// try-catch-finally、枚举、record、sealed 等）。
const _classFiles = <String>[
  'bin/Add.class',
  'bin/AllJava21Syntax.class',
  'bin/BaseDemoApplication.class',
  'bin/CascadeService.class',
  'bin/CodeConstants.class',
  'bin/ColoredPoint.class',
  'DateUtils.class',
  'bin/Season.class',
  'bin/Shape.class',
];

void main() {
  final goldenDir = Directory('test/fixtures');
  final updateGolden = Platform.environment.containsKey('UPDATE_GOLDEN');

  for (final classPath in _classFiles) {
    final name =
        classPath.split(RegExp(r'[/\\]')).last.replaceAll('.class', '');
    test('decompile $name matches golden output', () {
      final file = File(classPath);
      // CI 环境（如 GitHub Actions）不包含被 .gitignore 排除的 *.class；
      // 这些测试输入需要本地手动准备，缺失时跳过而非失败。
      if (!file.existsSync()) {
        print('跳过: 缺少测试输入 $classPath（CI 环境正常）');
        return;
      }

      final bytes = file.readAsBytesSync();
      final cf = ClassFileParser(bytes).parse();
      final output = Decompiler(cf).decompile();

      final goldenPath = '${goldenDir.path}/$name.txt';
      final goldenFile = File(goldenPath);

      if (updateGolden || !goldenFile.existsSync()) {
        goldenFile.writeAsStringSync(output);
        return;
      }

      // 黄金文件可能因操作系统重定向而带有 \r\n，统一规范化为 \n 再比较。
      String normalize(String s) =>
          s.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trimRight();
      final expected = normalize(goldenFile.readAsStringSync());
      expect(
        normalize(output),
        equals(expected),
        reason: '反编译输出与黄金文件不一致: $goldenPath\n'
            '如有意变更请运行: UPDATE_GOLDEN=true dart test',
      );
    });
  }
}
