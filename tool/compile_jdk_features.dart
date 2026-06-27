// 编译 JDK 特性测试源码：读取 test/jdk_features/manifest.json，
// 按每个条目的 release / preview 调用 javac，输出 .class 到 build/ 目录。
//
// 用法:
//   dart run tool/compile_jdk_features.dart            # 编译全部
//   dart run tool/compile_jdk_features.dart v22        # 仅编译指定版本
//
// 前置条件: PATH 中存在 javac（JDK 24）。脚本会校验 --release 是否受支持。
import 'dart:convert';
import 'dart:io';

void main(List<String> args) async {
  final manifestPath = 'test/jdk_features/manifest.json';
  final srcDir = Directory('test/jdk_features');
  final buildDir = Directory('${srcDir.path}/build');
  buildDir.createSync(recursive: true);

  final manifest =
      jsonDecode(File(manifestPath).readAsStringSync()) as Map<String, dynamic>;
  final sources = (manifest['sources'] as List).cast<Map<String, dynamic>>();

  final onlyVersion = args.isNotEmpty ? args.first : null;

  final results = <_CompileResult>[];
  for (final entry in sources) {
    final version = entry['version'] as String;
    if (onlyVersion != null && version != onlyVersion) continue;
    final file = entry['file'] as String;
    final release = entry['release'] as int;
    final preview = entry['preview'] as bool;
    results.add(await _compile(entry, srcDir, buildDir));
  }

  stdout.writeln('\n=== Compile summary ===');
  var ok = 0, fail = 0;
  for (final r in results) {
    final status = r.success ? 'OK ' : 'FAIL';
    stdout.writeln('  $status  v${r.version.padLeft(4)}  ${r.file}  ${r.note}');
    if (r.success) {
      ok++;
    } else {
      fail++;
    }
  }
  stdout.writeln('  $ok ok, $fail failed');

  exitCode = fail == 0 ? 0 : 1;
}

Future<_CompileResult> _compile(
  Map<String, dynamic> entry,
  Directory srcDir,
  Directory buildDir,
) async {
  final version = entry['version'] as String;
  final file = entry['file'] as String;
  final release = entry['release'] as int;
  final preview = entry['preview'] as bool;
  final srcPath = '${srcDir.path}/$file';

  if (!File(srcPath).existsSync()) {
    return _CompileResult(version, file, false, 'source missing');
  }

  final args = <String>[
    '--release',
    '$release',
    if (preview) '--enable-preview',
    '-d',
    buildDir.path,
    srcPath,
  ];

  final res = await Process.run('javac', args);
  if (res.exitCode != 0) {
    final err = (res.stderr as String).trim().split('\n').first;
    return _CompileResult(version, file, false, 'javac: $err');
  }
  return _CompileResult(version, file, true, 'release=$release preview=$preview');
}

class _CompileResult {
  final String version;
  final String file;
  final bool success;
  final String note;
  _CompileResult(this.version, this.file, this.success, this.note);
}
