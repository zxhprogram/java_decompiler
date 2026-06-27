import '../attributes/attribute_models.dart';
import '../bytecode/bytecode_decoder.dart';
import '../bytecode/instructions.dart';
import '../class_file.dart';
import '../constants/constant_pool.dart';
import '../descriptor_parser.dart';
import '../flags/access_flags.dart';

class _TypedValue {
  final String expr;
  final String type;
  _TypedValue(this.expr, {this.type = ''});
}

class _CountingSink implements StringSink {
  final StringBuffer _buf;
  int lineCount;
  _CountingSink(this._buf) : lineCount = 0;

  @override
  void write(Object? obj) => _buf.write(obj);

  @override
  void writeln([Object? obj = '']) {
    _buf.writeln(obj);
    lineCount++;
  }

  @override
  void writeAll(Iterable objects, [String separator = '']) =>
      _buf.writeAll(objects, separator);

  @override
  void writeCharCode(int charCode) => _buf.writeCharCode(charCode);
}

class CodePrinter {
  final MethodInfo _method;
  final CodeAttribute _code;
  final ClassFile _cf;
  late final ConstantPool _pool = _cf.constantPool;

  CodePrinter(this._method, this._code, this._cf);

  static final Set<int> _branchOpcodes = {
    Opcodes.ifeq,
    Opcodes.ifne,
    Opcodes.iflt,
    Opcodes.ifge,
    Opcodes.ifgt,
    Opcodes.ifle,
    Opcodes.if_icmpeq,
    Opcodes.if_icmpne,
    Opcodes.if_icmplt,
    Opcodes.if_icmpge,
    Opcodes.if_icmpgt,
    Opcodes.if_icmple,
    Opcodes.if_acmpeq,
    Opcodes.if_acmpne,
    Opcodes.goto_,
    Opcodes.jsr,
    Opcodes.ifnull,
    Opcodes.ifnonnull,
    Opcodes.goto_w,
    Opcodes.jsr_w,
  };

  String printBody() {
    final instructions = BytecodeDecoder(_code.code).decode();
    if (instructions.isEmpty) {
      return '        // empty code\n';
    }

    final simple = _trySimplePattern(instructions);
    if (simple != null) return simple;

    final (raw, offsetToLine) = _printStackBased(instructions);
    var text = _preprocessPatternMatching(raw);
    text = _structureTryCatch(text, offsetToLine);
    text = _structureIfs(text);
    text = _structurePatternSwitch(text);
    text = _structureSimpleSwitch(text);
    text = _structureIfElse(text);
    text = _structureForEach(text);
    text = _structureWhileLoops(text);
    text = _structureForLoops(text);
    text = _structureDoWhileLoops(text);
    text = _structureArrayInit(text);
    text = _cleanupBreakContinue(text);
    text = _removeUnusedLabels(text);
    text = _simplifyEmptyIfElse(text);
    text = _cleanupTryCatchResidue(text);
    text = _cleanupPatternMatchingResidue(text);
    text = _simplifyInstanceofRecordPattern(text);
    text = _removeStackUnderflow(text);
    text = _simplifyBoxing(text);
    text = _restoreVariableNames(text);
    return text;
  }

  /// 简化自动装箱调用：
  /// `Integer.valueOf(1)` → `1`，`Double.valueOf(2.0)` → `2.0` 等。
  /// 仅当参数为字面量时替换，避免改变语义。
  String _simplifyBoxing(String source) {
    final intLit = r'-?\d+';
    final longLit = r'-?\d+L';
    final doubleLit = r'-?\d+\.\d+(?:[eE][+-]?\d+)?';
    final floatLit = r'-?\d+\.\d+[fF]';
    final prefix = r'(?:java\.lang\.)?';

    source = source.replaceAllMapped(
      RegExp(prefix + r'Integer\.valueOf\((' + intLit + r')\)'),
      (m) => m.group(1)!,
    );
    source = source.replaceAllMapped(
      RegExp(prefix + r'Long\.valueOf\((' + longLit + r')\)'),
      (m) => m.group(1)!,
    );
    source = source.replaceAllMapped(
      RegExp(prefix + r'Double\.valueOf\((' + doubleLit + r')\)'),
      (m) => m.group(1)!,
    );
    source = source.replaceAllMapped(
      RegExp(prefix + r'Float\.valueOf\((' + floatLit + r')\)'),
      (m) => m.group(1)!,
    );
    source = source.replaceAllMapped(
      RegExp(prefix + r'Boolean\.valueOf\((true|false)\)'),
      (m) => m.group(1)!,
    );
    source = source.replaceAllMapped(
      RegExp(prefix + r"Character\.valueOf\(('(?:[^'\\]|\\.)')\)"),
      (m) => m.group(1)!,
    );
    return source;
  }

  /// 预处理模式匹配相关的编译器生成代码：
  /// 1. `if (1 == 0) goto label_X;` - 始终为假的条件跳转，直接移除
  /// 2. `Throwable pN = /*exception*/; throw new MatchException(...)` - 编译器为
  ///    pattern switch 生成的 MatchException 包装，移除后 _structureTryCatch
  ///    不会再把整个方法体包进 try-catch
  /// 3. `Objects.requireNonNull(var);` - 编译器生成的 null 检查
  String _preprocessPatternMatching(String source) {
    var lines = source.split('\n');

    // 1. 移除 `if (1 == 0) goto label_X;`（永假条件，直接删除即可）
    final alwaysFalseRe = RegExp(r'^ +if \(1 == 0\) goto (label_\d+);$');
    for (var i = 0; i < lines.length; i++) {
      if (alwaysFalseRe.hasMatch(lines[i])) {
        lines[i] = '';
      }
    }

    // 2. 移除编译器生成的 MatchException catch
    //    模式：`Throwable pN = /*exception*/;` 后跟 `throw new MatchException(pN.toString(), pN);`
    final throwableExRe =
        RegExp(r'^ +(?:java\.lang\.)?Throwable (\w+) = /\*exception\*/;$');
    for (var i = 0; i < lines.length; i++) {
      final m = throwableExRe.firstMatch(lines[i]);
      if (m == null) continue;
      final varName = m.group(1)!;
      // 查找后续非空行，检查是否是 `throw new MatchException(varName.toString(), varName);`
      for (var k = i + 1; k < lines.length; k++) {
        final trimmed = lines[k].trim();
        if (trimmed.isEmpty) continue;
        final matchExRe = RegExp(
            r'^throw new (?:java\.lang\.)?MatchException\(' +
                RegExp.escape(varName) +
                r'\.toString\(\), ' +
                RegExp.escape(varName) +
                r'\);$');
        if (matchExRe.hasMatch(trimmed)) {
          lines[i] = '';
          lines[k] = '';
        }
        break;
      }
    }

    // 3. 移除独立的 `Objects.requireNonNull(var);`
    final requireRe =
        RegExp(r'^ +(?:java\.util\.)?Objects\.requireNonNull\([\w.]+\);$');
    for (var i = 0; i < lines.length; i++) {
      if (requireRe.hasMatch(lines[i])) {
        lines[i] = '';
      }
    }

    // 清理空行
    final result = <String>[];
    var prevEmpty = false;
    for (final line in lines) {
      final isEmpty = line.trim().isEmpty;
      if (isEmpty && prevEmpty) continue;
      result.add(line);
      prevEmpty = isEmpty;
    }
    return result.join('\n');
  }

  /// 简化 instanceof record pattern 反编译结果。
  ///
  /// 输入示例：
  /// ```
  /// if ((p0 instanceof Point)) {
  ///     Point p1 = ((Point) p0);
  ///     int p3 = p1.x();
  ///     int p5 = p3;
  ///
  ///     int p2 = p3;
  ///     p3 = p1.y();
  ///     System.out.println("x=" + p2);
  /// }
  /// ```
  /// 输出示例：
  /// ```
  /// if (p0 instanceof Point(int x, _)) {
  ///     System.out.println("x=" + x);
  /// }
  /// ```
  String _simplifyInstanceofRecordPattern(String source) {
    var lines = source.split('\n');
    // 模式：`if ((VAR instanceof TYPE)) {`，TYPE 可能是全限定类名
    final ifRe = RegExp(r'^(\s*)if \(\((\w+) instanceof ([\w.]+)\)\) \{$');
    for (var i = 0; i < lines.length; i++) {
      final m = ifRe.firstMatch(lines[i]);
      if (m == null) continue;
      final indent = m.group(1)!;
      final objVar = m.group(2)!;
      final fullTypeName = m.group(3)!;
      // 简化类型名（去掉包前缀）
      final typeName = fullTypeName.contains('.')
          ? fullTypeName.substring(fullTypeName.lastIndexOf('.') + 1)
          : fullTypeName;

      // 找到对应的右花括号
      int depth = 1;
      int? closeLine;
      for (var j = i + 1; j < lines.length; j++) {
        final t = lines[j].trim();
        if (t.endsWith('{')) depth++;
        if (t == '}') {
          depth--;
          if (depth == 0) {
            closeLine = j;
            break;
          }
        }
      }
      if (closeLine == null) continue;

      final body = lines.sublist(i + 1, closeLine);
      // 第一行应是 `TYPE pN = ((TYPE) VAR);`，TYPE 可能是全限定类名
      final castRe = RegExp(
          r'^\s*([\w.]+) (\w+) = \(\(\1\) ' + RegExp.escape(objVar) + r'\);$');
      final castM = castRe.firstMatch(body.isNotEmpty ? body.first : '');
      if (castM == null) continue;
      final patternVar = castM.group(2)!;

      // 按行顺序扫描，跟踪每个变量的当前"含义"：
      // - 'accessor:NAME' 表示该变量当前持有 patternVar.NAME() 的值
      // - 'alias:VAR' 表示该变量是另一个变量的别名
      // 变量可能被复用（先存 x，再存 y），所以必须按行顺序处理。
      final varMeaning = <String, String>{};
      // 每个 accessor 是否被使用（在非声明行中被引用）
      final usedAccessors = <String>{};
      // 要跳过的行（组件提取 / 别名声明）
      final skipLines = <int>{};
      // accessor 第一次出现时的变量名（用于构造 pattern）
      final accessorFirstVar = <String, String>{};

      final compRe = RegExp(r'^\s*(?:[\w.]+ )?(\w+) = ' +
          RegExp.escape(patternVar) +
          r'\.(\w+)\(\);$');
      final aliasRe = RegExp(r'^\s*(?:[\w.]+ )?(\w+) = (\w+);$');

      for (var k = 1; k < body.length; k++) {
        final line = body[k];
        // 检查是否是组件提取
        final cm = compRe.firstMatch(line);
        if (cm != null) {
          final v = cm.group(1)!;
          final acc = cm.group(2)!;
          varMeaning[v] = 'accessor:$acc';
          accessorFirstVar.putIfAbsent(acc, () => v);
          skipLines.add(k);
          continue;
        }
        // 检查是否是别名声明
        final am = aliasRe.firstMatch(line);
        if (am != null) {
          final v = am.group(1)!;
          final src = am.group(2)!;
          if (varMeaning.containsKey(src)) {
            varMeaning[v] = varMeaning[src]!;
            skipLines.add(k);
            continue;
          }
        }
        // 其他行：检查引用了哪些变量，标记对应的 accessor 为已使用
        for (final entry in varMeaning.entries) {
          if (RegExp(r'\b' + RegExp.escape(entry.key) + r'\b').hasMatch(line)) {
            if (entry.value.startsWith('accessor:')) {
              usedAccessors.add(entry.value.substring('accessor:'.length));
            }
          }
        }
      }

      // 如果没有提取任何组件，不是 record pattern，跳过
      if (accessorFirstVar.isEmpty) continue;

      // 构造 pattern：按 accessor 字母序排列（适用于 x/y）
      final accessors = accessorFirstVar.keys.toList()..sort();
      final patternParts = <String>[];
      for (final acc in accessors) {
        if (usedAccessors.contains(acc)) {
          patternParts.add(acc);
        } else {
          patternParts.add('_');
        }
      }
      final pattern = '$typeName(${patternParts.join(', ')})';

      // 构造新的 body：跳过声明行，替换变量引用为 accessor 名
      // 但变量可能被复用，所以需要按行重新计算含义
      final newBody = <String>[];
      final currentMeaning = <String, String>{};
      for (var k = 1; k < body.length; k++) {
        final line = body[k];
        if (skipLines.contains(k)) {
          // 更新当前含义
          final cm = compRe.firstMatch(line);
          if (cm != null) {
            final v = cm.group(1)!;
            final acc = cm.group(2)!;
            currentMeaning[v] = 'accessor:$acc';
            continue;
          }
          final am = aliasRe.firstMatch(line);
          if (am != null) {
            final v = am.group(1)!;
            final src = am.group(2)!;
            if (currentMeaning.containsKey(src)) {
              currentMeaning[v] = currentMeaning[src]!;
            }
            continue;
          }
        }
        if (line.trim().isEmpty) continue;
        // 替换变量引用
        var newLine = line;
        for (final entry in currentMeaning.entries) {
          if (entry.value.startsWith('accessor:')) {
            final acc = entry.value.substring('accessor:'.length);
            // 只有当 accessor 被使用时才替换
            if (usedAccessors.contains(acc)) {
              newLine = newLine.replaceAll(
                RegExp(r'\b' + RegExp.escape(entry.key) + r'\b'),
                acc,
              );
            }
          }
        }
        newBody.add(newLine);
      }

      // 去掉 newBody 末尾空行
      while (newBody.isNotEmpty && newBody.last.trim().isEmpty) {
        newBody.removeLast();
      }

      // 组装新的 if 块
      final newLines = <String>[];
      newLines.add('$indent if ($objVar instanceof $pattern) {');
      for (final l in newBody) {
        newLines.add(l);
      }
      newLines.add('$indent}');
      lines.replaceRange(i, closeLine + 1, newLines);
      i += newLines.length - 1;
    }
    return lines.join('\n');
  }

  /// 清理模式匹配反编译后的残留：
  /// 1. `if (1) { body } else { ... }` - 始终为真的 if，展开 body 并丢弃 else 分支
  /// 2. `if (1) { body }` - 始终为真的 if，展开为 body
  /// 3. `Objects.requireNonNull(var);` - 编译器生成的 null 检查
  String _cleanupPatternMatchingResidue(String source) {
    var lines = source.split('\n');

    // 1. 清理 `if (1) { body } else { elseBody }` 和 `if (1) { body }`
    final ifOneRe = RegExp(r'^(\s*)if \(1\) \{$');
    bool changed;
    do {
      changed = false;
      for (var i = 0; i < lines.length; i++) {
        final m = ifOneRe.firstMatch(lines[i]);
        if (m == null) continue;

        // 找到 if 块的闭合 `}`（可能是 `}` 或 `} else {`）
        int? ifCloseLine;
        var depth = 1;
        for (var k = i + 1; k < lines.length; k++) {
          final line = lines[k];
          for (var ci = 0; ci < line.length; ci++) {
            final c = line[ci];
            if (c == '{')
              depth++;
            else if (c == '}') depth--;
            if (depth == 0) {
              ifCloseLine = k;
              break;
            }
          }
          if (ifCloseLine != null) break;
        }
        if (ifCloseLine == null) continue;

        // 提取 if body（去掉一层缩进）
        final ifBody = <String>[];
        for (var k = i + 1; k < ifCloseLine; k++) {
          final line = lines[k];
          if (line.trim().isEmpty) {
            ifBody.add(line);
          } else if (line.startsWith('    ')) {
            ifBody.add(line.substring(4));
          } else {
            ifBody.add(line);
          }
        }

        // 检查闭合行是否同时开启 else 分支（`} else {` 在同一行）
        final closeLineContent = lines[ifCloseLine].trim();
        if (closeLineContent == '} else {') {
          // else 块的 `{` 未被 depth 计数（在 depth==0 时就 break 了）
          // 从 ifCloseLine+1 开始搜索，depth 起始为 1
          int? elseCloseLine;
          depth = 1;
          for (var k = ifCloseLine + 1; k < lines.length; k++) {
            final line = lines[k];
            for (var ci = 0; ci < line.length; ci++) {
              final c = line[ci];
              if (c == '{')
                depth++;
              else if (c == '}') depth--;
              if (depth == 0) {
                elseCloseLine = k;
                break;
              }
            }
            if (elseCloseLine != null) break;
          }
          if (elseCloseLine != null) {
            // 替换整个 if-else 为 if body
            lines.replaceRange(i, elseCloseLine + 1, ifBody);
            changed = true;
            break;
          }
        } else if (closeLineContent.startsWith('} else')) {
          // `} else if (...) {` 或其他形式 - 不处理
          continue;
        } else {
          // 无 else 分支，直接替换
          lines.replaceRange(i, ifCloseLine + 1, ifBody);
          changed = true;
          break;
        }
      }
    } while (changed);

    // 2. 清理独立的 `Objects.requireNonNull(var);` 行
    final requireRe =
        RegExp(r'^\s+(?:java\.util\.)?Objects\.requireNonNull\([\w.]+\);$');
    for (var i = 0; i < lines.length; i++) {
      if (requireRe.hasMatch(lines[i])) {
        lines[i] = '';
      }
    }

    // 清理空行
    final result = <String>[];
    var prevEmpty = false;
    for (final line in lines) {
      final isEmpty = line.trim().isEmpty;
      if (isEmpty && prevEmpty) continue;
      result.add(line);
      prevEmpty = isEmpty;
    }
    return result.join('\n');
  }

  /// 清理 try/catch/finally 反编译后的残留：
  /// 1. catch 块末尾的 finally 内联副本（goto 前的 finally body）
  /// 2. catch 块外的 finally handler 残留（`Throwable pN = /*exception*/; ... throw pN;`）
  /// 3. try-with-resources 的 close 调用和 addSuppressed 模式
  String _cleanupTryCatchResidue(String source) {
    var lines = source.split('\n');

    // 模式 1：识别 catch 块外的 finally handler 残留
    // `Throwable pN = /*exception*/;` 或 `java.lang.Throwable pN = /*exception*/;`
    final finallyHandlerRe = RegExp(
        r'^        (?:java\.lang\.)?Throwable (\w+) = /\*exception\*/;$');
    final throwVarRe = RegExp(r'^        throw (\w+);$');

    bool changed;
    do {
      changed = false;
      for (var i = 0; i < lines.length; i++) {
        final m = finallyHandlerRe.firstMatch(lines[i]);
        if (m == null) continue;
        final varName = m.group(1)!;

        // 找到对应的 throw varName; 结束
        var throwLine = -1;
        for (var k = i + 1; k < lines.length; k++) {
          final tm = throwVarRe.firstMatch(lines[k]);
          if (tm != null && tm.group(1) == varName) {
            throwLine = k;
            break;
          }
          // 遇到另一个 handler 或 try 开始则停止
          if (finallyHandlerRe.hasMatch(lines[k]) ||
              lines[k].trim() == 'try {' ||
              lines[k].contains('} catch ') ||
              lines[k].contains('} finally ')) {
            break;
          }
        }
        if (throwLine < 0) continue;

        // 提取 finally body（i+1 到 throwLine，去掉异常变量赋值和 throw）
        final finallyBody = lines
            .sublist(i + 1, throwLine)
            .where((l) => l.trim().isNotEmpty && !l.contains('/*exception*/'))
            .toList();

        // 检查前一个 catch 块是否以 `goto label_X;` 结尾（finally 内联副本）
        // 向前查找时跳过已插入的 finally 块（`} finally { ... }`）
        var catchEndLine = i - 1;
        // 跳过空行
        while (catchEndLine >= 0 && lines[catchEndLine].trim().isEmpty) {
          catchEndLine--;
        }
        // 跳过已插入的 finally 块：`}` 前是 `} finally { ... }`
        if (catchEndLine >= 0 && lines[catchEndLine].trim() == '}') {
          // 向前查找，如果遇到 `} finally {`，跳过整个 finally 块
          for (var k = catchEndLine; k >= 0; k--) {
            if (lines[k].contains('} finally {')) {
              catchEndLine = k - 1;
              while (catchEndLine >= 0 && lines[catchEndLine].trim().isEmpty) {
                catchEndLine--;
              }
              break;
            }
            if (lines[k].contains('} catch ') || lines[k].contains('} }')) {
              break;
            }
          }
        }
        // 如果 catchEndLine 是 catch 块的 `}`，向前找 catch 块内最后一行（goto）
        if (catchEndLine >= 0 && lines[catchEndLine].trim() == '}') {
          var k = catchEndLine - 1;
          while (k >= 0 && lines[k].trim().isEmpty) {
            k--;
          }
          if (k >= 0) catchEndLine = k;
        }

        // 收集要删除的行索引
        final toRemove = <int>{};

        // 移除 finally handler 残留（i 到 throwLine）
        for (var k = i; k <= throwLine; k++) {
          toRemove.add(k);
        }

        // 如果 catch 块以 goto 结尾，移除 finally 副本和 goto
        if (catchEndLine >= 0) {
          final gotoRe = RegExp(r'^            goto (label_\d+);$');
          if (gotoRe.hasMatch(lines[catchEndLine])) {
            toRemove.add(catchEndLine); // goto
            // 向上查找 finally 副本
            for (var k = catchEndLine - 1; k >= 0; k--) {
              final trimmed = lines[k].trim();
              if (trimmed.isEmpty) continue;
              final inFinallyBody =
                  finallyBody.any((fb) => fb.trim() == trimmed);
              if (inFinallyBody) {
                toRemove.add(k);
              } else {
                break;
              }
            }
          }
        }

        // 在前面找到 try/catch 块的 `}`，添加 finally
        var insertLine = -1;
        for (var k = i - 1; k >= 0; k--) {
          if (toRemove.contains(k)) continue;
          final t = lines[k].trim();
          if (t == '}') {
            insertLine = k;
            break;
          }
          if (t.isEmpty) continue;
        }

        // 构建 finally 块（如果 finallyBody 非空）
        List<String>? finallyBlock;
        if (finallyBody.any((l) => l.trim().isNotEmpty)) {
          finallyBlock = <String>[
            '        } finally {',
            ...finallyBody.map((l) => l.isEmpty ? l : '    $l'),
            '        }',
          ];
        }

        // 应用删除和插入
        final newLines = <String>[];
        for (var k = 0; k < lines.length; k++) {
          if (k == insertLine) {
            // 替换 `}` 为 finally 块（或不替换如果 finallyBlock 为 null）
            if (finallyBlock != null) {
              newLines.addAll(finallyBlock);
            } else {
              newLines.add(lines[k]); // 保留 `}`
            }
          } else if (!toRemove.contains(k)) {
            newLines.add(lines[k]);
          }
        }
        lines = newLines;
        changed = true;
        break;
      }
    } while (changed);

    // 模式 1.5：处理残留的非 Throwable /*exception*/ 模式
    // 这些是 _structureTryCatch 未能处理的嵌套 catch 块
    lines = _cleanupRemainingExceptions(lines);
    // 模式 2：try-with-resources 清理
    lines = _cleanupTryWithResources(lines);

    // 模式 3：清理 try-with-resources 的 null 检查 `if (var == null) goto label_X;`
    // 这些 null 检查在资源管理代码被清理后变得多余
    final nullCheckRe = RegExp(r'^\s+if \((\w+) == null\) goto (label_\d+);$');
    for (var i = 0; i < lines.length; i++) {
      final m = nullCheckRe.firstMatch(lines[i]);
      if (m == null) continue;
      final label = m.group(2)!;
      // 向前查找第一个非空行，检查是否是目标 label
      // 如果是，说明 null 检查是多余的（goto 到下一有效行）
      var labelNearby = false;
      for (var k = i + 1; k < lines.length; k++) {
        final trimmed = lines[k].trim();
        if (trimmed.isEmpty) continue; // 跳过空行
        if (trimmed == label + ':') {
          labelNearby = true;
        }
        break; // 遇到第一个非空行就停止
      }
      if (labelNearby) {
        lines[i] = '';
        continue;
      }
      // 检查目标 label 是否存在，如果不存在（已被清理），移除 null 检查
      var labelExists = false;
      for (var k = 0; k < lines.length; k++) {
        if (k == i) continue;
        if (lines[k].trim() == label + ':') {
          labelExists = true;
          break;
        }
      }
      if (!labelExists) {
        lines[i] = '';
      }
    }

    // 模式 4：清理 finally 块后的孤立 label（合并点）
    // 这些 label 是 catch 块的 goto 目标，但 catch 块已清理，label 不再被引用
    final labelRe = RegExp(r'^\s+(label_\d+):$');
    final gotoLabelRe = RegExp(r'goto (label_\d+);');
    for (var i = 0; i < lines.length; i++) {
      final m = labelRe.firstMatch(lines[i]);
      if (m == null) continue;
      final label = m.group(1)!;
      // 检查是否还有 goto 引用此 label
      var hasRef = false;
      for (var k = 0; k < lines.length; k++) {
        if (k == i) continue;
        if (gotoLabelRe.hasMatch(lines[k]) &&
            lines[k].contains('goto $label;')) {
          hasRef = true;
          break;
        }
      }
      if (!hasRef) {
        lines[i] = '';
      }
    }

    // 清理空行
    final result = <String>[];
    var prevEmpty = false;
    for (final line in lines) {
      final isEmpty = line.trim().isEmpty;
      if (isEmpty && prevEmpty) continue;
      result.add(line);
      prevEmpty = isEmpty;
    }
    return result.join('\n');
  }

  /// 清理 try-with-resources 生成的 close 调用和异常处理代码
  List<String> _cleanupTryWithResources(List<String> lines) {
    // try-with-resources 的字节码模式（以两个资源为例）：
    //   [业务代码]
    //   var1.close();            // 正常关闭内层资源
    //   goto label_A;
    //   Throwable e1 = /*exception*/;  // var1 异常处理
    //   var1.close();
    //   goto label_B;
    //   Throwable e2 = /*exception*/;  // var1.close() 抛异常
    //   e1.addSuppressed(e2);
    // label_B:
    //   throw e1;
    // label_A:
    //   var0.close();            // 正常关闭外层资源
    //   goto label_C;
    //   Throwable e3 = /*exception*/;  // var0 异常处理
    //   var0.close();
    //   goto label_D;
    //   e3_alt = /*exception*/;
    //   var0.addSuppressed(e3_alt);
    // label_D:
    //   throw e3;
    // label_C:
    //
    // 清理策略：识别从第一个 `var.close(); goto label_X;` 开始的资源管理块，
    // 直到对应的 `label_X:` 结束，移除其中的 close/goto/throwable/addSuppressed/throw/label。

    final closeRe = RegExp(r'^\s+(\w+)\.close\(\);$');
    final gotoRe = RegExp(r'^\s+goto (label_\d+);$');
    // 匹配 `Throwable pN = /*exception*/;` 或 `java.lang.Throwable pN = /*exception*/;`
    final exceptionRe =
        RegExp(r'^\s+(?:java\.lang\.)?Throwable (\w+) = /\*exception\*/;$');
    final exceptionAssignRe =
        RegExp(r'^\s+(\w+) = /\*exception\*/;$'); // `p2 = /*exception*/;`
    final addSuppressedRe = RegExp(r'^\s+(\w+)\.addSuppressed\((\w+)\);$');
    final throwRe = RegExp(r'^\s+throw (\w+);$');
    final labelRe = RegExp(r'^\s+(label_\d+):$');
    // try-with-resources 的 null 检查：`if (var == null) goto label_X;`
    final nullCheckRe = RegExp(r'^\s+if \((\w+) == null\) goto (label_\d+);$');

    bool changed;
    do {
      changed = false;
      for (var i = 0; i < lines.length - 1; i++) {
        // 查找起始：`var.close(); goto label_X;`
        final closeMatch = closeRe.firstMatch(lines[i]);
        if (closeMatch == null) continue;
        if (!gotoRe.hasMatch(lines[i + 1])) continue;

        // 找到 goto 的目标 label
        final gotoMatch = gotoRe.firstMatch(lines[i + 1])!;
        final targetLabel = gotoMatch.group(1)!;

        // 向后查找 targetLabel 的位置（这标志着整个资源管理块的结束）
        var labelLine = -1;
        for (var k = i + 2; k < lines.length; k++) {
          final lm = labelRe.firstMatch(lines[k]);
          if (lm != null && lm.group(1) == targetLabel) {
            labelLine = k;
            break;
          }
        }
        if (labelLine < 0) continue;

        // 验证 i 到 labelLine 之间是 try-with-resources 模式：
        // 应包含 `Throwable ... = /*exception*/;` 和 `throw ...;`
        var hasException = false;
        var hasThrow = false;
        for (var k = i; k < labelLine; k++) {
          if (exceptionRe.hasMatch(lines[k]) ||
              exceptionAssignRe.hasMatch(lines[k])) {
            hasException = true;
          }
          if (throwRe.hasMatch(lines[k])) hasThrow = true;
        }
        if (!hasException || !hasThrow) continue;

        // 清理 i 到 labelLine-1（不含 labelLine）之间的资源管理代码
        // labelLine 是外层块的开始或合并点，保留
        for (var k = i; k < labelLine; k++) {
          final line = lines[k];
          if (closeRe.hasMatch(line) ||
              gotoRe.hasMatch(line) ||
              exceptionRe.hasMatch(line) ||
              exceptionAssignRe.hasMatch(line) ||
              addSuppressedRe.hasMatch(line) ||
              throwRe.hasMatch(line) ||
              labelRe.hasMatch(line) ||
              nullCheckRe.hasMatch(line)) {
            lines[k] = '';
          }
        }
        changed = true;
        break;
      }
    } while (changed);

    return lines;
  }

  /// 处理残留的非 Throwable /*exception*/ 模式
  /// 这些是 _structureTryCatch 未能处理的嵌套 catch 块
  /// 模式：
  ///   <try body>
  ///   goto label_X;                       <- 跳过 catch 块
  ///   ExceptionType pN = /*exception*/;   <- catch 块开始
  ///   <exception body>
  ///   } catch (Throwable e) {             <- 外层 Throwable catch
  ///
  /// 转换为：
  ///   <try body>
  ///   } catch (ExceptionType _) {
  ///   <exception body>
  ///   } catch (Throwable e) {
  List<String> _cleanupRemainingExceptions(List<String> lines) {
    final exceptionRe = RegExp(r'^(\s+)(\S+) (\w+) = /\*exception\*/;$');
    final catchBlockRe = RegExp(r'^(\s+)\} catch \(Throwable e\) \{$');
    final gotoRe = RegExp(r'^(\s+)goto (label_\d+);$');
    final labelRe = RegExp(r'^(\s+)(label_\d+):$');

    bool changed;
    do {
      changed = false;
      for (var i = 0; i < lines.length; i++) {
        final m = exceptionRe.firstMatch(lines[i]);
        if (m == null) continue;
        final typeName = m.group(2)!;
        final varName = m.group(3)!;

        // 查找后续的 catch (Throwable e) 块作为插入点
        var catchBlockLine = -1;
        String? catchIndent;
        for (var k = i + 1; k < lines.length; k++) {
          final cm = catchBlockRe.firstMatch(lines[k]);
          if (cm != null) {
            catchBlockLine = k;
            catchIndent = cm.group(1)!;
            break;
          }
        }
        if (catchBlockLine < 0 || catchIndent == null) continue;

        // 提取异常处理代码（i+1 到 catchBlockLine-1）
        final exceptionBody = <String>[];
        for (var k = i + 1; k < catchBlockLine; k++) {
          final trimmed = lines[k].trim();
          if (trimmed.isEmpty) continue;
          // 跳过 catch 块末尾的 goto（跳转到合并点）
          if (RegExp(r'^goto (label_\d+);$').hasMatch(trimmed)) continue;
          // 将异常变量替换为 _（无名模式）
          exceptionBody.add(
            lines[k].replaceAllMapped(
              RegExp(r'\b' + RegExp.escape(varName) + r'\b'),
              (_) => '_',
            ),
          );
        }

        // 检查前一行是否是 goto label_X;（跳过 catch 块的跳转）
        var gotoLine = -1;
        if (i > 0) {
          final gm = gotoRe.firstMatch(lines[i - 1]);
          if (gm != null) {
            gotoLine = i - 1;
          }
        }

        // 构建新的 catch 块（使用外层 catch 的缩进）
        // 注意：不添加闭合 `}`，因为后续的 `} catch (Throwable e) {`
        // 中的 `}` 会闭合本 catch 块，形成多 catch 子句
        final newCatchBlock = <String>[
          '$catchIndent} catch ($typeName _) {',
          ...exceptionBody,
        ];

        // 替换：从 gotoLine（如果有）或 i 开始，到 catchBlockLine 之前
        final startLine = gotoLine >= 0 ? gotoLine : i;
        lines.replaceRange(startLine, catchBlockLine, newCatchBlock);
        changed = true;
        break;
      }
    } while (changed);

    // 清理 goto 目标 label 如果不再被引用
    final gotoLabelRe = RegExp(r'goto (label_\d+);');
    for (var i = 0; i < lines.length; i++) {
      final m = labelRe.firstMatch(lines[i]);
      if (m == null) continue;
      final label = m.group(2)!;
      var hasRef = false;
      for (var k = 0; k < lines.length; k++) {
        if (k == i) continue;
        if (gotoLabelRe.hasMatch(lines[k]) &&
            lines[k].contains('goto $label;')) {
          hasRef = true;
          break;
        }
      }
      if (!hasRef) {
        lines[i] = '';
      }
    }

    return lines;
  }

  /// 简化 `if (!cond) { } else { body }` 为 `if (cond) { body }`
  /// 以及 `if (cond) { } else { body }` 为 `if (!cond) { body }`
  String _simplifyEmptyIfElse(String source) {
    var lines = source.split('\n');
    final ifOpenRe = RegExp(r'^(\s*)if \((.+)\) \{$');

    // 逐字符追踪深度，返回使深度归零的行号（从 startLine 开始向后搜索）
    // 如果该行在归零后还有 `{`，返回剩余部分（如 `else {`）
    int? findCloseLine(List<String> ls, int startLine, int startDepth) {
      var depth = startDepth;
      for (var k = startLine; k < ls.length; k++) {
        final line = ls[k];
        var inString = false;
        for (var ci = 0; ci < line.length; ci++) {
          final c = line[ci];
          final prev = ci > 0 ? line[ci - 1] : '';
          if (c == '"' && prev != '\\') inString = !inString;
          if (inString) continue;
          if (c == '{') depth++;
          if (c == '}') {
            depth--;
            if (depth == 0) return k;
          }
        }
      }
      return null;
    }

    bool changed;
    do {
      changed = false;
      for (var i = 0; i < lines.length; i++) {
        final m = ifOpenRe.firstMatch(lines[i]);
        if (m == null) continue;
        final indent = m.group(1)!;
        final cond = m.group(2)!;

        // 找到 then 块结束（深度回到 0）
        final closeIdx = findCloseLine(lines, i + 1, 1);
        if (closeIdx == null) continue;

        // closeIdx 行包含使 then 块结束的 `}`，检查是否是 `} else {` 形式
        final closeLine = lines[closeIdx].trim();
        if (closeLine != '} else {') continue;

        // then 块必须为空
        final thenBody = lines.sublist(i + 1, closeIdx);
        if (thenBody.any((l) => l.trim().isNotEmpty)) continue;

        // 找到 else 块结束（从 closeIdx+1 开始，深度 1）
        final elseClose = findCloseLine(lines, closeIdx + 1, 1);
        if (elseClose == null) continue;

        // else 块必须非空
        final elseBody = lines.sublist(closeIdx + 1, elseClose);
        if (!elseBody.any((l) => l.trim().isNotEmpty)) continue;

        // 取反条件
        final newCond = _negateCondition(cond);
        final newLines = <String>[
          '${indent}if ($newCond) {',
          ...elseBody,
          '${indent}}',
        ];
        lines.replaceRange(i, elseClose + 1, newLines);
        changed = true;
        break;
      }
    } while (changed);

    return lines.join('\n');
  }

  /// 将循环体内的 `goto label_X;` 转换为 `break;` 或 `continue;`。
  /// - 如果 label_X 在循环之后（end label），转换为 `break;`
  /// - 如果 label_X 在循环之前（start label），转换为 `continue;`
  String _cleanupBreakContinue(String source) {
    var lines = source.split('\n');

    final gotoRe = RegExp(r'^(\s*)goto (label_\d+);$');
    final labelRe = RegExp(r'^(\s*)(label_\d+):$');
    final loopStartRe = RegExp(r'^\s*(for|while|do)\b');
    final loopEndRe = RegExp(r'^\s*\}\s*$');

    bool changed;
    do {
      changed = false;
      // 构建 label 位置映射
      final labelPos = <String, int>{};
      for (var i = 0; i < lines.length; i++) {
        final m = labelRe.firstMatch(lines[i]);
        if (m != null) labelPos[m.group(2)!] = i;
      }

      for (var i = 0; i < lines.length; i++) {
        final gm = gotoRe.firstMatch(lines[i]);
        if (gm == null) continue;
        final indent = gm.group(1)!;
        final target = gm.group(2)!;
        final targetPos = labelPos[target];
        if (targetPos == null) continue;

        // 找到包含此 goto 的最内层循环
        // 向上查找循环开始
        int? loopStartLine;
        var depth = 0;
        for (var k = i - 1; k >= 0; k--) {
          final t = lines[k].trim();
          if (t == '}') depth++;
          if (t == '{' || t.endsWith('{')) {
            if (depth > 0) {
              depth--;
            } else {
              // 这是包含 goto 的块的开始
              // 检查是否是循环
              if (loopStartRe.hasMatch(lines[k])) {
                loopStartLine = k;
                break;
              }
            }
          }
        }

        if (loopStartLine == null) continue;

        // 如果 target 在循环之后，是 break
        if (targetPos > loopStartLine) {
          // 确认 target 在循环结束之后
          // 找循环结束
          var d = 1;
          var end = loopStartLine + 1;
          while (end < lines.length && d > 0) {
            final t = lines[end].trim();
            if (t == '{' || t.endsWith('{')) d++;
            if (t == '}') d--;
            end++;
          }
          if (targetPos >= end) {
            lines[i] = '${indent}break;';
            changed = true;
            break;
          }
        }

        // 如果 target 在循环之前，是 continue
        if (targetPos < loopStartLine) {
          lines[i] = '${indent}continue;';
          changed = true;
          break;
        }
      }
    } while (changed);

    return lines.join('\n');
  }

  /// 移除未被引用的 label 行
  String _removeUnusedLabels(String source) {
    var lines = source.split('\n');
    final labelRe = RegExp(r'^(\s*)(label_\d+):$');
    final gotoRe = RegExp(r'\bgoto (label_\d+);');

    bool changed;
    do {
      changed = false;

      // 1. 先移除 "goto label_X;" 紧接着 "label_X:" 的模式
      //    （goto 跳到下一行的 label，是冗余跳转）
      for (var i = 0; i < lines.length - 1; i++) {
        final gotoM = RegExp(r'^(\s*)goto (label_\d+);$').firstMatch(lines[i]);
        if (gotoM == null) continue;
        final label = gotoM.group(2)!;
        // 查找紧接的 label 行（允许中间有空白行）
        for (var j = i + 1; j < lines.length; j++) {
          if (lines[j].trim().isEmpty) continue;
          final labelM = labelRe.firstMatch(lines[j]);
          if (labelM != null && labelM.group(2) == label) {
            lines[i] = '';
            changed = true;
          }
          break;
        }
      }

      // 2. 收集所有被引用的 label
      final referenced = <String>{};
      for (final line in lines) {
        for (final m in gotoRe.allMatches(line)) {
          referenced.add(m.group(1)!);
        }
      }
      // 移除未被引用的 label 行（置空，不删除行以保持行号）
      for (var i = 0; i < lines.length; i++) {
        final m = labelRe.firstMatch(lines[i]);
        if (m == null) continue;
        final label = m.group(2)!;
        if (!referenced.contains(label)) {
          lines[i] = '';
          changed = true;
        }
      }
    } while (changed);

    // 仅移除连续空行中的多余空行（保留单个空行分隔）
    final result = <String>[];
    var prevEmpty = false;
    for (final line in lines) {
      final isEmpty = line.trim().isEmpty;
      if (isEmpty && prevEmpty) continue;
      result.add(line);
      prevEmpty = isEmpty;
    }
    return result.join('\n');
  }

  String _removeStackUnderflow(String source) {
    return source
        .split('\n')
        .where((line) => line.trim() != 'return /*stack underflow*/;')
        .join('\n');
  }

  String? _trySimplePattern(List<Instruction> ins) {
    final name = _pool.getString(_method.nameIndex);
    final isStatic = (_method.accessFlags & AccessFlags.ACC_STATIC) != 0;

    // 空构造 / Object.<init>
    if (name == '<init>' && ins.length == 3) {
      if (_isLoad(ins[0], isStatic ? null : 0) &&
          ins[1].opcode == Opcodes.invokespecial &&
          ins[2].opcode == Opcodes.return_) {
        final (cname, mname, _) = _methodRef(ins[1].operands[0] as int);
        if (mname == '<init>' && cname == 'java.lang.Object') {
          return '';
        }
        return '        super(); // $cname.<init>()\n';
      }
    }

    // getter
    if (ins.length == 3) {
      final load = ins[0];
      final get = ins[1];
      final ret = ins[2];
      if (_isReturn(ret) && get.opcode == Opcodes.getfield) {
        if (!isStatic && _isLoad(load, 0)) {
          final (_, fname, _) = _fieldRef(get.operands[0] as int);
          return '        return this.$fname;\n';
        }
      }
      if (_isReturn(ret) && get.opcode == Opcodes.getstatic && isStatic) {
        final (_, fname, _) = _fieldRef(get.operands[0] as int);
        return '        return $fname;\n';
      }
    }

    // setter
    if (ins.length == 4) {
      final a = ins[0];
      final b = ins[1];
      final put = ins[2];
      final ret = ins[3];
      if (ret.opcode == Opcodes.return_ && put.opcode == Opcodes.putfield) {
        if (!isStatic && _isLoad(a, 0) && _isLoad(b, 1)) {
          final (_, fname, _) = _fieldRef(put.operands[0] as int);
          return '        this.$fname = p0;\n';
        }
      }
      if (ret.opcode == Opcodes.return_ &&
          put.opcode == Opcodes.putstatic &&
          isStatic) {
        if (_isLoad(a, 0)) {
          final (_, fname, _) = _fieldRef(put.operands[0] as int);
          return '        $fname = p0;\n';
        }
      }
    }

    return null;
  }

  bool _isLoad(Instruction ins, int? expected) {
    final op = ins.opcode;
    if (op == Opcodes.aload ||
        op == Opcodes.iload ||
        op == Opcodes.lload ||
        op == Opcodes.fload ||
        op == Opcodes.dload) {
      return expected == null || (ins.operands[0] as int) == expected;
    }
    final implicit = {
      Opcodes.aload_0: 0,
      Opcodes.aload_1: 1,
      Opcodes.aload_2: 2,
      Opcodes.aload_3: 3,
      Opcodes.iload_0: 0,
      Opcodes.iload_1: 1,
      Opcodes.iload_2: 2,
      Opcodes.iload_3: 3,
      Opcodes.lload_0: 0,
      Opcodes.lload_1: 1,
      Opcodes.lload_2: 2,
      Opcodes.lload_3: 3,
      Opcodes.fload_0: 0,
      Opcodes.fload_1: 1,
      Opcodes.fload_2: 2,
      Opcodes.fload_3: 3,
      Opcodes.dload_0: 0,
      Opcodes.dload_1: 1,
      Opcodes.dload_2: 2,
      Opcodes.dload_3: 3,
    };
    if (!implicit.containsKey(op)) return false;
    return expected == null || implicit[op] == expected;
  }

  bool _isReturn(Instruction ins) {
    final op = ins.opcode;
    return op == Opcodes.ireturn ||
        op == Opcodes.lreturn ||
        op == Opcodes.freturn ||
        op == Opcodes.dreturn ||
        op == Opcodes.areturn ||
        op == Opcodes.return_;
  }

  (String, Map<int, int>) _printStackBased(List<Instruction> ins) {
    final buffer = StringBuffer();
    final out = _CountingSink(buffer);
    final labels = <int>{};
    final offsetToLine = <int, int>{};
    for (final i in ins) {
      if (_branchOpcodes.contains(i.opcode) ||
          i.opcode == Opcodes.tableswitch ||
          i.opcode == Opcodes.lookupswitch) {
        for (final op in i.operands) {
          if (op is int && op >= 0 && op <= _code.code.length) {
            labels.add(op);
          } else if (op is List<int>) {
            for (final o in op) {
              if (o >= 0 && o <= _code.code.length) labels.add(o);
            }
          } else if (op is List<(int, int)>) {
            for (final pair in op) {
              final target = pair.$2;
              if (target >= 0 && target <= _code.code.length) {
                labels.add(target);
              }
            }
          }
        }
      }
    }

    final returnType = DescriptorParser.parseMethodDescriptor(
      _pool.getString(_method.descriptorIndex),
    ).$2;
    final isVoid = returnType == 'void';
    final skipFinalReturn =
        isVoid && ins.isNotEmpty && ins.last.opcode == Opcodes.return_;

    final stack = <String>[];
    String pop() => stack.isEmpty ? '/*stack underflow*/' : stack.removeLast();
    bool isReturnOpcode(int opcode) =>
        opcode == Opcodes.ireturn ||
        opcode == Opcodes.lreturn ||
        opcode == Opcodes.freturn ||
        opcode == Opcodes.dreturn ||
        opcode == Opcodes.areturn ||
        opcode == Opcodes.return_;
    final offsetToIns = <int, Instruction>{
      for (final insi in ins) insi.offset: insi
    };

    final isStatic = (_method.accessFlags & AccessFlags.ACC_STATIC) != 0;
    final methodDesc = _pool.getString(_method.descriptorIndex);
    final localNames = _buildLocalNames(isStatic, methodDesc);
    final (storeTypes, _) = _inferStoreTypes(ins);
    final localDeclaredTypes = <int, String>{};

    // 异常处理器入口：JVM 会把异常对象压入操作数栈。
    final handlerTypes = <int, String>{};
    for (final e in _code.exceptionTable) {
      if (!handlerTypes.containsKey(e.handlerPc)) {
        handlerTypes[e.handlerPc] = e.catchType == 0
            ? 'Throwable'
            : DescriptorParser.internalToSourceName(
                _pool.getClassName(e.catchType));
      }
    }

    String boolLiteral(String value) {
      if (value == '0') return 'false';
      if (value == '1') return 'true';
      return value;
    }

    void emitStore(int slot, String value, int idx) {
      final name = localNames[slot] ?? 'p$slot';
      final type = storeTypes[idx];
      final display = type == 'boolean' ? boolLiteral(value) : value;
      if (type != null && type.isNotEmpty && localDeclaredTypes[slot] != type) {
        out.writeln('        $type $name = $display;');
        localDeclaredTypes[slot] = type;
      } else {
        out.writeln('        $name = $display;');
      }
    }

    for (var idx = 0; idx < ins.length; idx++) {
      final i = ins[idx];
      if (labels.contains(i.offset)) {
        out.writeln('      label_${i.offset}:');
      }
      offsetToLine[i.offset] = out.lineCount;
      void push(String v) => stack.add(v);

      final handlerType = handlerTypes[i.offset];
      if (handlerType != null) {
        push('/*exception*/');
      }

      switch (i.opcode) {
        case Opcodes.nop:
          break;
        case Opcodes.aconst_null:
          push('null');
        case Opcodes.iconst_m1:
        case Opcodes.iconst_0:
        case Opcodes.iconst_1:
        case Opcodes.iconst_2:
        case Opcodes.iconst_3:
        case Opcodes.iconst_4:
        case Opcodes.iconst_5:
          push('${i.opcode - Opcodes.iconst_0}');
        case Opcodes.lconst_0:
        case Opcodes.lconst_1:
          push('${i.opcode - Opcodes.lconst_0}L');
        case Opcodes.fconst_0:
        case Opcodes.fconst_1:
        case Opcodes.fconst_2:
          push('${i.opcode - Opcodes.fconst_0}f');
        case Opcodes.dconst_0:
        case Opcodes.dconst_1:
          push('${i.opcode - Opcodes.dconst_0}.0');
        case Opcodes.bipush:
          push('${i.operands[0]}');
        case Opcodes.sipush:
          push('${i.operands[0]}');
        case Opcodes.ldc:
        case Opcodes.ldc_w:
        case Opcodes.ldc2_w:
          push(_pool.getLiteral(i.operands[0] as int));
        case Opcodes.iload:
        case Opcodes.lload:
        case Opcodes.fload:
        case Opcodes.dload:
        case Opcodes.aload:
          push(localNames[i.operands[0] as int] ?? 'p${i.operands[0]}');
        case Opcodes.iload_0 ||
              Opcodes.lload_0 ||
              Opcodes.fload_0 ||
              Opcodes.dload_0 ||
              Opcodes.aload_0:
          push(localNames[0] ?? 'p0');
        case Opcodes.iload_1 ||
              Opcodes.lload_1 ||
              Opcodes.fload_1 ||
              Opcodes.dload_1 ||
              Opcodes.aload_1:
          push(localNames[1] ?? 'p1');
        case Opcodes.iload_2 ||
              Opcodes.lload_2 ||
              Opcodes.fload_2 ||
              Opcodes.dload_2 ||
              Opcodes.aload_2:
          push(localNames[2] ?? 'p2');
        case Opcodes.iload_3 ||
              Opcodes.lload_3 ||
              Opcodes.fload_3 ||
              Opcodes.dload_3 ||
              Opcodes.aload_3:
          push(localNames[3] ?? 'p3');
        case Opcodes.iaload ||
              Opcodes.laload ||
              Opcodes.faload ||
              Opcodes.daload ||
              Opcodes.aaload ||
              Opcodes.baload ||
              Opcodes.caload ||
              Opcodes.saload:
          final idx = pop();
          final arr = pop();
          push('$arr[$idx]');
        case Opcodes.istore ||
              Opcodes.lstore ||
              Opcodes.fstore ||
              Opcodes.dstore ||
              Opcodes.astore:
          final v = pop();
          final slot = i.operands[0] as int;
          emitStore(slot, v, idx);
        case Opcodes.istore_0 ||
              Opcodes.lstore_0 ||
              Opcodes.fstore_0 ||
              Opcodes.dstore_0 ||
              Opcodes.astore_0:
          emitStore(0, pop(), idx);
        case Opcodes.istore_1 ||
              Opcodes.lstore_1 ||
              Opcodes.fstore_1 ||
              Opcodes.dstore_1 ||
              Opcodes.astore_1:
          emitStore(1, pop(), idx);
        case Opcodes.istore_2 ||
              Opcodes.lstore_2 ||
              Opcodes.fstore_2 ||
              Opcodes.dstore_2 ||
              Opcodes.astore_2:
          emitStore(2, pop(), idx);
        case Opcodes.istore_3 ||
              Opcodes.lstore_3 ||
              Opcodes.fstore_3 ||
              Opcodes.dstore_3 ||
              Opcodes.astore_3:
          emitStore(3, pop(), idx);
        case Opcodes.iastore ||
              Opcodes.lastore ||
              Opcodes.fastore ||
              Opcodes.dastore ||
              Opcodes.aastore ||
              Opcodes.bastore ||
              Opcodes.castore ||
              Opcodes.sastore:
          final v = pop();
          final idx = pop();
          final arr = pop();
          out.writeln('        $arr[$idx] = $v;');
        case Opcodes.pop:
          _maybeEmitDiscarded(pop(), out);
        case Opcodes.pop2:
          _maybeEmitDiscarded(pop(), out);
          _maybeEmitDiscarded(pop(), out);
        case Opcodes.dup:
          push(stack.last);
        case Opcodes.dup_x1:
          final a = pop();
          final b = pop();
          push(a);
          push(b);
          push(a);
        case Opcodes.dup_x2:
          final a = pop();
          final b = pop();
          final c = pop();
          push(a);
          push(c);
          push(b);
          push(a);
        case Opcodes.dup2:
          final len = stack.length;
          if (len >= 2) {
            push(stack[len - 2]);
            push(stack[len - 1]);
          } else {
            push('/*dup2 underflow*/');
          }
        case Opcodes.dup2_x1:
          final a = pop();
          final b = pop();
          final c = pop();
          push(b);
          push(a);
          push(c);
          push(b);
          push(a);
        case Opcodes.dup2_x2:
          final a = pop();
          final b = pop();
          final c = pop();
          final d = pop();
          push(b);
          push(a);
          push(d);
          push(c);
          push(b);
          push(a);
        case Opcodes.swap:
          final a = pop();
          final b = pop();
          push(a);
          push(b);
        case Opcodes.iadd || Opcodes.ladd || Opcodes.fadd || Opcodes.dadd:
          push('(${pop()} + ${pop()})');
        case Opcodes.isub || Opcodes.lsub || Opcodes.fsub || Opcodes.dsub:
          final b = pop();
          final a = pop();
          push('($a - $b)');
        case Opcodes.imul || Opcodes.lmul || Opcodes.fmul || Opcodes.dmul:
          push('(${pop()} * ${pop()})');
        case Opcodes.idiv || Opcodes.ldiv || Opcodes.fdiv || Opcodes.ddiv:
          final b = pop();
          final a = pop();
          push('($a / $b)');
        case Opcodes.irem || Opcodes.lrem || Opcodes.frem || Opcodes.drem:
          final b = pop();
          final a = pop();
          push('($a % $b)');
        case Opcodes.ineg || Opcodes.lneg || Opcodes.fneg || Opcodes.dneg:
          push('(-${pop()})');
        case Opcodes.ishl || Opcodes.lshl:
          final s = pop();
          final v = pop();
          push('($v << $s)');
        case Opcodes.ishr || Opcodes.lshr:
          final s = pop();
          final v = pop();
          push('($v >> $s)');
        case Opcodes.iushr || Opcodes.lushr:
          final s = pop();
          final v = pop();
          push('($v >>> $s)');
        case Opcodes.iand || Opcodes.land:
          push('(${pop()} & ${pop()})');
        case Opcodes.ior || Opcodes.lor:
          push('(${pop()} | ${pop()})');
        case Opcodes.ixor || Opcodes.lxor:
          push('(${pop()} ^ ${pop()})');
        case Opcodes.iinc:
          final slot = i.operands[0] as int;
          final inc = i.operands[1] as int;
          out.writeln('        ${localNames[slot] ?? "p$slot"} += $inc;');
        case Opcodes.i2l ||
              Opcodes.i2f ||
              Opcodes.i2d ||
              Opcodes.l2i ||
              Opcodes.l2f ||
              Opcodes.l2d ||
              Opcodes.f2i ||
              Opcodes.f2l ||
              Opcodes.f2d ||
              Opcodes.d2i ||
              Opcodes.d2l ||
              Opcodes.d2f ||
              Opcodes.i2b ||
              Opcodes.i2c ||
              Opcodes.i2s:
          push('(${i.mnemonic}(${pop()}))');
        case Opcodes.lcmp ||
              Opcodes.fcmpl ||
              Opcodes.fcmpg ||
              Opcodes.dcmpl ||
              Opcodes.dcmpg:
          final b = pop();
          final a = pop();
          push('($a <=> $b)');
        case Opcodes.ifeq:
          out.writeln(
              '        if (${pop()} == 0) goto label_${i.operands[0]};');
        case Opcodes.ifne:
          out.writeln(
              '        if (${pop()} != 0) goto label_${i.operands[0]};');
        case Opcodes.iflt:
          out.writeln('        if (${pop()} < 0) goto label_${i.operands[0]};');
        case Opcodes.ifge:
          out.writeln(
              '        if (${pop()} >= 0) goto label_${i.operands[0]};');
        case Opcodes.ifgt:
          out.writeln('        if (${pop()} > 0) goto label_${i.operands[0]};');
        case Opcodes.ifle:
          out.writeln(
              '        if (${pop()} <= 0) goto label_${i.operands[0]};');
        case Opcodes.if_icmpeq || Opcodes.if_acmpeq:
          final b = pop();
          final a = pop();
          out.writeln('        if ($a == $b) goto label_${i.operands[0]};');
        case Opcodes.if_icmpne || Opcodes.if_acmpne:
          final b = pop();
          final a = pop();
          out.writeln('        if ($a != $b) goto label_${i.operands[0]};');
        case Opcodes.if_icmplt:
          final b = pop();
          final a = pop();
          out.writeln('        if ($a < $b) goto label_${i.operands[0]};');
        case Opcodes.if_icmpge:
          final b = pop();
          final a = pop();
          out.writeln('        if ($a >= $b) goto label_${i.operands[0]};');
        case Opcodes.if_icmpgt:
          final b = pop();
          final a = pop();
          out.writeln('        if ($a > $b) goto label_${i.operands[0]};');
        case Opcodes.if_icmple:
          final b = pop();
          final a = pop();
          out.writeln('        if ($a <= $b) goto label_${i.operands[0]};');
        case Opcodes.goto_:
        case Opcodes.goto_w:
          final target = i.operands[0] as int;
          final targetIns = offsetToIns[target];
          if (stack.isNotEmpty &&
              targetIns != null &&
              isReturnOpcode(targetIns.opcode)) {
            out.writeln('        return ${pop()};');
            stack.clear();
          } else {
            out.writeln('        goto label_$target;');
          }
        case Opcodes.jsr || Opcodes.jsr_w:
          out.writeln('        // jsr ${i.operands[0]}');
        case Opcodes.ret:
          out.writeln('        // ret ${i.operands[0]}');
        case Opcodes.ifnull:
          out.writeln(
              '        if (${pop()} == null) goto label_${i.operands[0]};');
        case Opcodes.ifnonnull:
          out.writeln(
              '        if (${pop()} != null) goto label_${i.operands[0]};');
        case Opcodes.ireturn ||
              Opcodes.lreturn ||
              Opcodes.freturn ||
              Opcodes.dreturn ||
              Opcodes.areturn:
          out.writeln('        return ${pop()};');
        case Opcodes.return_:
          if (skipFinalReturn && i == ins.last) {
            // void 方法末尾的 return 可以省略
          } else {
            out.writeln('        return;');
          }
        case Opcodes.getstatic:
          final (cname, fname, fdesc) = _fieldRef(i.operands[0] as int);
          push('$cname.$fname');
        case Opcodes.putstatic:
          final (cname, fname, _) = _fieldRef(i.operands[0] as int);
          out.writeln('        $cname.$fname = ${pop()};');
        case Opcodes.getfield:
          final (cname, fname, _) = _fieldRef(i.operands[0] as int);
          final obj = pop();
          push('$obj.$fname');
        case Opcodes.putfield:
          final (cname, fname, _) = _fieldRef(i.operands[0] as int);
          final v = pop();
          final obj = pop();
          out.writeln('        $obj.$fname = $v;');
        case Opcodes.invokevirtual ||
              Opcodes.invokespecial ||
              Opcodes.invokestatic ||
              Opcodes.invokeinterface ||
              Opcodes.invokedynamic:
          final (expr, returns) = _invokeFromStack(i, stack);
          if (returns) {
            push(expr);
          } else {
            out.writeln('        $expr;');
          }
        case Opcodes.new_:
          push(
              'new ${DescriptorParser.internalToSourceName(_pool.getClassName(i.operands[0] as int))}()');
        case Opcodes.newarray:
          final atype = _newArrayType(i.operands[0] as int);
          push('new $atype[${pop()}]');
        case Opcodes.anewarray:
          final etype = DescriptorParser.internalToSourceName(
              _pool.getClassName(i.operands[0] as int));
          push('new $etype[${pop()}]');
        case Opcodes.multianewarray:
          final dims = i.operands[1] as int;
          final etype = DescriptorParser.internalToSourceName(
              _pool.getClassName(i.operands[0] as int));
          final args = List.generate(dims, (_) => pop()).reversed.join(', ');
          push('new $etype[$args]');
        case Opcodes.arraylength:
          push('${pop()}.length');
        case Opcodes.athrow:
          out.writeln('        throw ${pop()};');
        case Opcodes.checkcast:
          push(
              '((${DescriptorParser.internalToSourceName(_pool.getClassName(i.operands[0] as int))}) ${pop()})');
        case Opcodes.instanceof:
          push(
              '(${pop()} instanceof ${DescriptorParser.internalToSourceName(_pool.getClassName(i.operands[0] as int))})');
        case Opcodes.monitorenter:
          out.writeln('        synchronized (${pop()}) { // monitor enter');
        case Opcodes.monitorexit:
          out.writeln('        } // monitor exit');
        case Opcodes.tableswitch:
          final defaultTarget = i.operands[0] as int;
          final low = i.operands[1] as int;
          final offsets = i.operands[3] as List<int>;
          final key = pop();
          out.writeln('        switch ($key) {');
          for (var j = 0; j < offsets.length; j++) {
            out.writeln(
                '            case ${low + j}: goto label_${offsets[j]};');
          }
          out.writeln('            default: goto label_$defaultTarget;');
          out.writeln('        }');
        case Opcodes.lookupswitch:
          final defaultTarget = i.operands[0] as int;
          final pairs = i.operands[1] as List<(int, int)>;
          final key = pop();
          out.writeln('        switch ($key) {');
          for (final (match, target) in pairs) {
            out.writeln('            case $match: goto label_$target;');
          }
          out.writeln('            default: goto label_$defaultTarget;');
          out.writeln('        }');
        case Opcodes.wide:
          out.writeln('        // wide ${i.operands}');
        default:
          out.writeln('        // ${i.mnemonic} ${i.operands}');
      }
    }
    return (buffer.toString(), offsetToLine);
  }

  Map<int, String> _buildLocalNames(bool isStatic, String descriptor) {
    final names = <int, String>{};
    if (!isStatic) names[0] = 'this';

    final lvt = _method.attribute<LocalVariableTableAttribute>();
    if (lvt != null) {
      final entries = List.of(lvt.localVariableTable)
        ..sort((a, b) => a.startPc.compareTo(b.startPc));
      for (final e in entries) {
        if (!names.containsKey(e.index)) {
          names[e.index] = _pool.getString(e.nameIndex);
        }
      }
    }

    // 未命名的参数占位
    var slot = isStatic ? 0 : 1;
    final (_, paramTypes) = DescriptorParser.parseMethodDescriptor(descriptor);
    for (var i = 0; i < paramTypes.length; i++) {
      if (!names.containsKey(slot)) names[slot] = 'p$i';
      slot++;
      if (paramTypes[i] == 'long' || paramTypes[i] == 'double') slot++;
    }
    return names;
  }

  /// 获取参数类型列表，优先使用泛型签名。
  List<String> _parameterTypes() {
    final descriptor = _pool.getString(_method.descriptorIndex);
    final sigAttr = _method.attribute<SignatureAttribute>();
    if (sigAttr != null) {
      try {
        final (params, _) = SignatureParser.parseMethodSignature(
          _pool.getString(sigAttr.signatureIndex),
        );
        return params;
      } catch (_) {
        // 解析失败时回退到擦除类型
      }
    }
    return DescriptorParser.parseMethodDescriptor(descriptor).$1;
  }

  /// 推断每个局部变量槽在每次 store 指令时被写入的类型，用于输出类型声明。
  (List<String?>, List<int?>) _inferStoreTypes(List<Instruction> ins) {
    final storeTypes = List<String?>.filled(ins.length, null);
    final storeSlots = List<int?>.filled(ins.length, null);
    final localTypes = <int, String>{};
    final stack = <_TypedValue>[];

    // 用参数类型初始化局部变量槽，使 aload 0 等能携带泛型类型信息。
    final isStatic = (_method.accessFlags & AccessFlags.ACC_STATIC) != 0;
    final paramTypes = _parameterTypes();
    var slot = isStatic ? 0 : 1;
    for (var pi = 0; pi < paramTypes.length; pi++) {
      localTypes[slot] = paramTypes[pi];
      slot++;
      if (paramTypes[pi] == 'long' || paramTypes[pi] == 'double') slot++;
    }

    _TypedValue pop() => stack.isEmpty ? _TypedValue('') : stack.removeLast();
    void push(_TypedValue v) => stack.add(v);

    String componentType(String type) {
      if (type.endsWith('[]')) return type.substring(0, type.length - 2);
      return '';
    }

    String classType(int poolIndex) =>
        DescriptorParser.internalToSourceName(_pool.getClassName(poolIndex));

    String invokeReturnType(int opcode, int operand) {
      final entry = _pool.get(operand);
      final nameAndTypeIndex = switch (entry) {
        CpMethodref(:final nameAndTypeIndex) => nameAndTypeIndex,
        CpInterfaceMethodref(:final nameAndTypeIndex) => nameAndTypeIndex,
        CpInvokeDynamic(:final nameAndTypeIndex) => nameAndTypeIndex,
        _ => 0,
      };
      final descriptorIndex =
          _pool.getNameAndType(nameAndTypeIndex).descriptorIndex;
      return DescriptorParser.parseMethodDescriptor(
        _pool.getString(descriptorIndex),
      ).$2;
    }

    void recordStore(int slot, _TypedValue v, int instructionIndex) {
      storeSlots[instructionIndex] = slot;
      storeTypes[instructionIndex] = v.type;
      final cur = localTypes[slot];
      localTypes[slot] = (cur == null || cur.isEmpty) ? v.type : cur;
    }

    // 异常处理器入口：JVM 会把异常对象压入操作数栈。
    final handlerTypes = <int, String>{};
    for (final e in _code.exceptionTable) {
      if (!handlerTypes.containsKey(e.handlerPc)) {
        handlerTypes[e.handlerPc] = e.catchType == 0
            ? 'Throwable'
            : DescriptorParser.internalToSourceName(
                _pool.getClassName(e.catchType));
      }
    }

    for (var idx = 0; idx < ins.length; idx++) {
      final i = ins[idx];
      final handlerType = handlerTypes[i.offset];
      if (handlerType != null) {
        push(_TypedValue('/*exception*/', type: handlerType));
      }

      switch (i.opcode) {
        case Opcodes.nop:
        case Opcodes.goto_:
        case Opcodes.goto_w:
        case Opcodes.jsr:
        case Opcodes.jsr_w:
        case Opcodes.return_:
        case Opcodes.ireturn:
        case Opcodes.lreturn:
        case Opcodes.freturn:
        case Opcodes.dreturn:
        case Opcodes.areturn:
        case Opcodes.tableswitch:
        case Opcodes.lookupswitch:
          break;

        case Opcodes.aconst_null:
          push(_TypedValue('null'));
          break;
        case Opcodes.iconst_m1:
        case Opcodes.iconst_0:
        case Opcodes.iconst_1:
        case Opcodes.iconst_2:
        case Opcodes.iconst_3:
        case Opcodes.iconst_4:
        case Opcodes.iconst_5:
        case Opcodes.bipush:
        case Opcodes.sipush:
          push(_TypedValue('int', type: 'int'));
          break;
        case Opcodes.lconst_0:
        case Opcodes.lconst_1:
          push(_TypedValue('long', type: 'long'));
          break;
        case Opcodes.fconst_0:
        case Opcodes.fconst_1:
        case Opcodes.fconst_2:
          push(_TypedValue('float', type: 'float'));
          break;
        case Opcodes.dconst_0:
        case Opcodes.dconst_1:
          push(_TypedValue('double', type: 'double'));
          break;

        case Opcodes.ldc:
        case Opcodes.ldc_w:
        case Opcodes.ldc2_w:
          final entry = _pool.get(i.operands[0] as int);
          String type;
          if (entry is CpString) {
            type = 'String';
          } else if (entry is CpInteger) {
            type = 'int';
          } else if (entry is CpFloat) {
            type = 'float';
          } else if (entry is CpLong) {
            type = 'long';
          } else if (entry is CpDouble) {
            type = 'double';
          } else if (entry is CpClass) {
            type = 'Class';
          } else {
            type = '';
          }
          push(_TypedValue('literal', type: type));
          break;

        case Opcodes.iload:
        case Opcodes.iload_0:
        case Opcodes.iload_1:
        case Opcodes.iload_2:
        case Opcodes.iload_3:
          push(_TypedValue('int', type: 'int'));
          break;
        case Opcodes.lload:
        case Opcodes.lload_0:
        case Opcodes.lload_1:
        case Opcodes.lload_2:
        case Opcodes.lload_3:
          push(_TypedValue('long', type: 'long'));
          break;
        case Opcodes.fload:
        case Opcodes.fload_0:
        case Opcodes.fload_1:
        case Opcodes.fload_2:
        case Opcodes.fload_3:
          push(_TypedValue('float', type: 'float'));
          break;
        case Opcodes.dload:
        case Opcodes.dload_0:
        case Opcodes.dload_1:
        case Opcodes.dload_2:
        case Opcodes.dload_3:
          push(_TypedValue('double', type: 'double'));
          break;
        case Opcodes.aload:
          push(_TypedValue('', type: localTypes[i.operands[0] as int] ?? ''));
          break;
        case Opcodes.aload_0:
          push(_TypedValue('', type: localTypes[0] ?? ''));
          break;
        case Opcodes.aload_1:
          push(_TypedValue('', type: localTypes[1] ?? ''));
          break;
        case Opcodes.aload_2:
          push(_TypedValue('', type: localTypes[2] ?? ''));
          break;
        case Opcodes.aload_3:
          push(_TypedValue('', type: localTypes[3] ?? ''));
          break;

        case Opcodes.iaload:
          pop();
          pop();
          push(_TypedValue('int', type: 'int'));
          break;
        case Opcodes.laload:
          pop();
          pop();
          push(_TypedValue('long', type: 'long'));
          break;
        case Opcodes.faload:
          pop();
          pop();
          push(_TypedValue('float', type: 'float'));
          break;
        case Opcodes.daload:
          pop();
          pop();
          push(_TypedValue('double', type: 'double'));
          break;
        case Opcodes.aaload:
          pop();
          final arr = pop();
          push(_TypedValue('', type: componentType(arr.type)));
          break;
        case Opcodes.baload:
        case Opcodes.caload:
        case Opcodes.saload:
          pop();
          pop();
          push(_TypedValue('int', type: 'int'));
          break;

        case Opcodes.istore:
          recordStore(
              i.operands[0] as int, _TypedValue('int', type: 'int'), idx);
          break;
        case Opcodes.lstore:
          recordStore(
              i.operands[0] as int, _TypedValue('long', type: 'long'), idx);
          break;
        case Opcodes.fstore:
          recordStore(
              i.operands[0] as int, _TypedValue('float', type: 'float'), idx);
          break;
        case Opcodes.dstore:
          recordStore(
              i.operands[0] as int, _TypedValue('double', type: 'double'), idx);
          break;
        case Opcodes.astore:
          recordStore(i.operands[0] as int, pop(), idx);
          break;
        case Opcodes.istore_0:
          recordStore(0, _TypedValue('int', type: 'int'), idx);
          break;
        case Opcodes.istore_1:
          recordStore(1, _TypedValue('int', type: 'int'), idx);
          break;
        case Opcodes.istore_2:
          recordStore(2, _TypedValue('int', type: 'int'), idx);
          break;
        case Opcodes.istore_3:
          recordStore(3, _TypedValue('int', type: 'int'), idx);
          break;
        case Opcodes.lstore_0:
          recordStore(0, _TypedValue('long', type: 'long'), idx);
          break;
        case Opcodes.lstore_1:
          recordStore(1, _TypedValue('long', type: 'long'), idx);
          break;
        case Opcodes.lstore_2:
          recordStore(2, _TypedValue('long', type: 'long'), idx);
          break;
        case Opcodes.lstore_3:
          recordStore(3, _TypedValue('long', type: 'long'), idx);
          break;
        case Opcodes.fstore_0:
          recordStore(0, _TypedValue('float', type: 'float'), idx);
          break;
        case Opcodes.fstore_1:
          recordStore(1, _TypedValue('float', type: 'float'), idx);
          break;
        case Opcodes.fstore_2:
          recordStore(2, _TypedValue('float', type: 'float'), idx);
          break;
        case Opcodes.fstore_3:
          recordStore(3, _TypedValue('float', type: 'float'), idx);
          break;
        case Opcodes.dstore_0:
          recordStore(0, _TypedValue('double', type: 'double'), idx);
          break;
        case Opcodes.dstore_1:
          recordStore(1, _TypedValue('double', type: 'double'), idx);
          break;
        case Opcodes.dstore_2:
          recordStore(2, _TypedValue('double', type: 'double'), idx);
          break;
        case Opcodes.dstore_3:
          recordStore(3, _TypedValue('double', type: 'double'), idx);
          break;
        case Opcodes.astore_0:
          recordStore(0, pop(), idx);
          break;
        case Opcodes.astore_1:
          recordStore(1, pop(), idx);
          break;
        case Opcodes.astore_2:
          recordStore(2, pop(), idx);
          break;
        case Opcodes.astore_3:
          recordStore(3, pop(), idx);
          break;
        case Opcodes.iastore:
        case Opcodes.lastore:
        case Opcodes.fastore:
        case Opcodes.dastore:
        case Opcodes.aastore:
        case Opcodes.bastore:
        case Opcodes.castore:
        case Opcodes.sastore:
          pop();
          pop();
          pop();
          break;

        case Opcodes.pop:
          if (stack.isNotEmpty) stack.removeLast();
          break;
        case Opcodes.pop2:
          if (stack.isNotEmpty) stack.removeLast();
          if (stack.isNotEmpty) stack.removeLast();
          break;
        case Opcodes.dup:
          if (stack.isNotEmpty) push(stack.last);
          break;
        case Opcodes.dup_x1:
          if (stack.length >= 2) {
            final a = pop();
            final b = pop();
            push(a);
            push(b);
            push(a);
          }
          break;
        case Opcodes.dup_x2:
          if (stack.length >= 3) {
            final a = pop();
            final b = pop();
            final c = pop();
            push(a);
            push(c);
            push(b);
            push(a);
          }
          break;
        case Opcodes.dup2:
          if (stack.length >= 2) {
            final a = pop();
            final b = pop();
            push(b);
            push(a);
            push(b);
            push(a);
          }
          break;
        case Opcodes.dup2_x1:
          if (stack.length >= 3) {
            final a = pop();
            final b = pop();
            final c = pop();
            push(b);
            push(a);
            push(c);
            push(b);
            push(a);
          }
          break;
        case Opcodes.dup2_x2:
          if (stack.length >= 4) {
            final a = pop();
            final b = pop();
            final c = pop();
            final d = pop();
            push(b);
            push(a);
            push(d);
            push(c);
            push(b);
            push(a);
          }
          break;
        case Opcodes.swap:
          if (stack.length >= 2) {
            final a = pop();
            final b = pop();
            push(a);
            push(b);
          }
          break;

        case Opcodes.iadd:
        case Opcodes.isub:
        case Opcodes.imul:
        case Opcodes.idiv:
        case Opcodes.irem:
        case Opcodes.ineg:
        case Opcodes.iand:
        case Opcodes.ior:
        case Opcodes.ixor:
        case Opcodes.ishl:
        case Opcodes.ishr:
        case Opcodes.iushr:
          if (i.opcode != Opcodes.ineg) pop();
          pop();
          push(_TypedValue('int', type: 'int'));
          break;
        case Opcodes.ladd:
        case Opcodes.lsub:
        case Opcodes.lmul:
        case Opcodes.ldiv:
        case Opcodes.lrem:
        case Opcodes.lneg:
        case Opcodes.land:
        case Opcodes.lor:
        case Opcodes.lxor:
        case Opcodes.lshl:
        case Opcodes.lshr:
        case Opcodes.lushr:
          if (i.opcode != Opcodes.lneg) pop();
          pop();
          push(_TypedValue('long', type: 'long'));
          break;
        case Opcodes.fadd:
        case Opcodes.fsub:
        case Opcodes.fmul:
        case Opcodes.fdiv:
        case Opcodes.frem:
        case Opcodes.fneg:
          if (i.opcode != Opcodes.fneg) pop();
          pop();
          push(_TypedValue('float', type: 'float'));
          break;
        case Opcodes.dadd:
        case Opcodes.dsub:
        case Opcodes.dmul:
        case Opcodes.ddiv:
        case Opcodes.drem:
        case Opcodes.dneg:
          if (i.opcode != Opcodes.dneg) pop();
          pop();
          push(_TypedValue('double', type: 'double'));
          break;

        case Opcodes.iinc:
          break;

        case Opcodes.i2l:
          pop();
          push(_TypedValue('long', type: 'long'));
          break;
        case Opcodes.i2f:
          pop();
          push(_TypedValue('float', type: 'float'));
          break;
        case Opcodes.i2d:
          pop();
          push(_TypedValue('double', type: 'double'));
          break;
        case Opcodes.l2i:
          pop();
          push(_TypedValue('int', type: 'int'));
          break;
        case Opcodes.l2f:
          pop();
          push(_TypedValue('float', type: 'float'));
          break;
        case Opcodes.l2d:
          pop();
          push(_TypedValue('double', type: 'double'));
          break;
        case Opcodes.f2i:
          pop();
          push(_TypedValue('int', type: 'int'));
          break;
        case Opcodes.f2l:
          pop();
          push(_TypedValue('long', type: 'long'));
          break;
        case Opcodes.f2d:
          pop();
          push(_TypedValue('double', type: 'double'));
          break;
        case Opcodes.d2i:
          pop();
          push(_TypedValue('int', type: 'int'));
          break;
        case Opcodes.d2l:
          pop();
          push(_TypedValue('long', type: 'long'));
          break;
        case Opcodes.d2f:
          pop();
          push(_TypedValue('float', type: 'float'));
          break;
        case Opcodes.i2b:
          pop();
          push(_TypedValue('byte', type: 'byte'));
          break;
        case Opcodes.i2c:
          pop();
          push(_TypedValue('char', type: 'char'));
          break;
        case Opcodes.i2s:
          pop();
          push(_TypedValue('short', type: 'short'));
          break;

        case Opcodes.lcmp:
        case Opcodes.fcmpl:
        case Opcodes.fcmpg:
        case Opcodes.dcmpl:
        case Opcodes.dcmpg:
          pop();
          pop();
          push(_TypedValue('int', type: 'boolean'));
          break;

        case Opcodes.ifeq:
        case Opcodes.ifne:
        case Opcodes.iflt:
        case Opcodes.ifge:
        case Opcodes.ifgt:
        case Opcodes.ifle:
        case Opcodes.ifnull:
        case Opcodes.ifnonnull:
          pop();
          break;
        case Opcodes.if_icmpeq:
        case Opcodes.if_icmpne:
        case Opcodes.if_icmplt:
        case Opcodes.if_icmpge:
        case Opcodes.if_icmpgt:
        case Opcodes.if_icmple:
        case Opcodes.if_acmpeq:
        case Opcodes.if_acmpne:
          pop();
          pop();
          break;

        case Opcodes.getstatic:
          final ref = _pool.getFieldref(i.operands[0] as int);
          final desc = _pool.getString(
            _pool.getNameAndType(ref.nameAndTypeIndex).descriptorIndex,
          );
          push(_TypedValue('',
              type: DescriptorParser.parseFieldDescriptor(desc)));
          break;
        case Opcodes.putstatic:
          pop();
          break;
        case Opcodes.getfield:
          pop();
          final ref = _pool.getFieldref(i.operands[0] as int);
          final desc = _pool.getString(
            _pool.getNameAndType(ref.nameAndTypeIndex).descriptorIndex,
          );
          push(_TypedValue('',
              type: DescriptorParser.parseFieldDescriptor(desc)));
          break;
        case Opcodes.putfield:
          pop();
          pop();
          break;

        case Opcodes.invokevirtual:
        case Opcodes.invokespecial:
        case Opcodes.invokestatic:
        case Opcodes.invokeinterface:
        case Opcodes.invokedynamic:
          final entry = _pool.get(i.operands[0] as int);
          final nameAndTypeIndex = switch (entry) {
            CpMethodref(:final nameAndTypeIndex) => nameAndTypeIndex,
            CpInterfaceMethodref(:final nameAndTypeIndex) => nameAndTypeIndex,
            CpInvokeDynamic(:final nameAndTypeIndex) => nameAndTypeIndex,
            _ => 0,
          };
          final params = DescriptorParser.parseMethodDescriptor(
            _pool.getString(
              _pool.getNameAndType(nameAndTypeIndex).descriptorIndex,
            ),
          ).$1;
          for (var k = 0; k < params.length; k++) {
            pop();
          }
          if (i.opcode != Opcodes.invokestatic &&
              i.opcode != Opcodes.invokedynamic) {
            pop();
          }
          final rt = invokeReturnType(i.opcode, i.operands[0] as int);
          if (rt != 'void') push(_TypedValue('', type: rt));
          break;

        case Opcodes.new_:
          push(_TypedValue('', type: classType(i.operands[0] as int)));
          break;
        case Opcodes.newarray:
          pop();
          final t = switch (i.operands[0] as int) {
            4 => 'boolean[]',
            5 => 'char[]',
            6 => 'float[]',
            7 => 'double[]',
            8 => 'byte[]',
            9 => 'short[]',
            10 => 'int[]',
            11 => 'long[]',
            _ => '',
          };
          push(_TypedValue('', type: t));
          break;
        case Opcodes.anewarray:
          pop();
          push(_TypedValue('', type: '${classType(i.operands[0] as int)}[]'));
          break;
        case Opcodes.arraylength:
          pop();
          push(_TypedValue('int', type: 'int'));
          break;
        case Opcodes.athrow:
          pop();
          break;
        case Opcodes.checkcast:
          pop();
          push(_TypedValue('', type: classType(i.operands[0] as int)));
          break;
        case Opcodes.instanceof:
          pop();
          push(_TypedValue('boolean', type: 'boolean'));
          break;
        case Opcodes.monitorenter:
        case Opcodes.monitorexit:
          pop();
          break;
        case Opcodes.multianewarray:
          final dims = i.operands[1] as int;
          for (var k = 0; k < dims; k++) {
            pop();
          }
          push(_TypedValue('',
              type: DescriptorParser.parseFieldDescriptor(
                _pool.getString(i.operands[0] as int),
              )));
          break;

        default:
          // 未知指令：清空栈，避免错误传播。
          stack.clear();
      }
    }

    // 反向传播：把 null/未知赋值后续的实际类型补回来。
    // 注意：只在类型兼容时传播，避免把 boolean 反向传播到 int 类型的 store。
    final bySlot = <int, List<int>>{};
    for (var idx = 0; idx < ins.length; idx++) {
      final s = storeSlots[idx];
      if (s != null) bySlot.putIfAbsent(s, () => []).add(idx);
    }
    for (final indices in bySlot.values) {
      var pending = '';
      for (var k = indices.length - 1; k >= 0; k--) {
        final idx = indices[k];
        final t = storeTypes[idx];
        if (t != null && t.isNotEmpty) {
          // 切换 pending 类型时，避免不兼容类型的反向覆盖
          // （如 int 变量后续被复用为 boolean，不应把前面的 int 改成 boolean）
          if (pending.isEmpty ||
              _typesCompatible(t, pending) ||
              _typesCompatible(pending, t)) {
            pending = t;
          }
        } else if (pending.isNotEmpty) {
          storeTypes[idx] = pending;
        }
      }
    }

    // 根据 ifeq/ifne 的用法把相关 int 局部变量推断为 boolean。
    // 仅当变量从未在 if_icmp* 等数值比较中使用、且至少有一次用于 ifeq/ifne 时才推断为 boolean。
    // 这样避免把用于 if_icmpge/if_icmple 等比较的 int 变量误判为 boolean。
    final booleanCandidateSlots = <int>{};
    final intComparisonSlots = <int>{};
    for (var idx = 0; idx < ins.length - 1; idx++) {
      final next = ins[idx + 1];
      final op = ins[idx].opcode;
      final slot = switch (op) {
        Opcodes.iload_0 => 0,
        Opcodes.iload_1 => 1,
        Opcodes.iload_2 => 2,
        Opcodes.iload_3 => 3,
        Opcodes.iload => ins[idx].operands[0] as int,
        _ => null,
      };
      if (slot == null) continue;
      if (next.opcode == Opcodes.ifeq || next.opcode == Opcodes.ifne) {
        booleanCandidateSlots.add(slot);
      }
      // if_icmp* 指令前会有两个 iload，这些 slot 是数值比较变量
      if (next.opcode == Opcodes.if_icmpeq ||
          next.opcode == Opcodes.if_icmpne ||
          next.opcode == Opcodes.if_icmplt ||
          next.opcode == Opcodes.if_icmpge ||
          next.opcode == Opcodes.if_icmpgt ||
          next.opcode == Opcodes.if_icmple) {
        intComparisonSlots.add(slot);
        // 前一个 iload 的 slot 也是数值比较变量
        if (idx > 0) {
          final prevOp = ins[idx - 1].opcode;
          final prevSlot = switch (prevOp) {
            Opcodes.iload_0 => 0,
            Opcodes.iload_1 => 1,
            Opcodes.iload_2 => 2,
            Opcodes.iload_3 => 3,
            Opcodes.iload => ins[idx - 1].operands[0] as int,
            _ => null,
          };
          if (prevSlot != null) intComparisonSlots.add(prevSlot);
        }
      }
    }
    final booleanSlots = booleanCandidateSlots.difference(intComparisonSlots);
    for (var idx = 0; idx < ins.length; idx++) {
      final s = storeSlots[idx];
      if (s != null && booleanSlots.contains(s)) {
        final t = storeTypes[idx];
        if (t == null || t.isEmpty || t == 'int') {
          storeTypes[idx] = 'boolean';
        }
      }
    }

    return (storeTypes, storeSlots);
  }

  /// 把简单的 `if ... goto label` 伪代码转换成普通的 if 分支。
  String _structureIfs(String source) {
    final lines = source.split('\n');
    final gotoRe = RegExp(r'^( +)if \((.+)\) goto (label_\d+);$');
    final labelRe = RegExp(r'^( *)(label_\d+):$');

    bool changed;
    do {
      changed = false;
      final labelMap = <String, int>{};
      for (var i = 0; i < lines.length; i++) {
        final m = labelRe.firstMatch(lines[i]);
        if (m != null) labelMap[m.group(2)!] = i;
      }

      // 从后往前处理，这样嵌套的 if 可以先被转换成内层 if 块，
      // 再处理外层共享同一个合并标号的 if。
      for (var i = lines.length - 1; i >= 0; i--) {
        final m = gotoRe.firstMatch(lines[i]);
        if (m == null) continue;
        final indent = m.group(1)!;
        final cond = m.group(2)!;
        final label = m.group(3)!;
        final j = labelMap[label];
        if (j == null || j <= i) continue;

        // 目标标号前必须没有其他标号，避免破坏更复杂的控制流。
        bool bodyHasLabel = false;
        for (var k = i + 1; k < j; k++) {
          if (labelRe.hasMatch(lines[k])) {
            bodyHasLabel = true;
            break;
          }
        }
        if (bodyHasLabel) continue;

        // 当前 goto 之后不能再有其它跳转引用同一标号（未处理的）。
        var otherRefs = false;
        for (var k = i + 1; k < lines.length; k++) {
          if (lines[k].contains('goto $label;')) {
            otherRefs = true;
            break;
          }
        }
        if (otherRefs) continue;

        final block = lines.sublist(i + 1, j);
        final newLines = <String>[
          '${indent}if (${_negateCondition(cond)}) {',
          ...block.map((l) => l.isEmpty ? l : '    $l'),
          '$indent}',
        ];

        // 若之前还有其它跳转引用同一标号（外层 if-goto），
        // 保留合并标号供外层转换时使用；否则消费掉标号行。
        bool hasPrevRef = false;
        for (var k = 0; k < i; k++) {
          if (lines[k].contains('goto $label;')) {
            hasPrevRef = true;
            break;
          }
        }
        if (hasPrevRef) {
          lines.replaceRange(i, j, newLines);
        } else {
          lines.replaceRange(i, j + 1, newLines);
        }
        changed = true;
        break;
      }
    } while (changed);

    return lines.join('\n');
  }

  String _negateCondition(String cond) {
    final trimmed = cond.trim();
    // !!expr -> expr
    if (trimmed.startsWith('!(') && trimmed.endsWith(')')) {
      final inner = trimmed.substring(2, trimmed.length - 1);
      // 如果内部也是 !(...)，则双重否定
      final innerNeg = _negateCondition(inner);
      return innerNeg;
    }
    // !var -> var
    final notVar = RegExp(r'^!(\w+)$').firstMatch(trimmed);
    if (notVar != null) return notVar.group(1)!;
    final eq0 = RegExp(r'^(.+) == 0$').firstMatch(cond);
    if (eq0 != null) return eq0.group(1)!.trim();
    final ne0 = RegExp(r'^(.+) != 0$').firstMatch(cond);
    if (ne0 != null) return '!${ne0.group(1)!.trim()}';
    final cmp = RegExp(r'^(.+?) (==|!=|<=|>=|<|>) (.+)$').firstMatch(cond);
    if (cmp != null) {
      final left = cmp.group(1)!.trim();
      final op = cmp.group(2)!;
      final right = cmp.group(3)!.trim();
      final neg = const {
        '==': '!=',
        '!=': '==',
        '<': '>=',
        '>=': '<',
        '>': '<=',
        '<=': '>',
      }[op]!;
      return '$left $neg $right';
    }
    return '!($cond)';
  }

  /// 根据异常表把 `try { ... } goto end; ... catch ... end:` 还原成 try/catch 块。
  String _structureTryCatch(String source, Map<int, int> offsetToLine) {
    var lines = source.split('\n');
    final gotoRe = RegExp(r'^ {8,}goto (label_\d+);$');
    final labelRe = RegExp(r'^      (label_\d+):$');
    final exceptionRe =
        RegExp(r'^        (\S+(?:<[^>]+>)?) (\w+) = /\*exception\*/;$');

    // 先处理 catch（catchType != 0），再处理 finally（catchType == 0）。
    // 同类内按 handlerPc 降序，优先处理内层。
    final catchEntries = _code.exceptionTable
        .where((e) => e.catchType != 0)
        .toList()
      ..sort((a, b) => b.handlerPc.compareTo(a.handlerPc));
    final finallyEntries = _code.exceptionTable
        .where((e) => e.catchType == 0)
        .toList()
      ..sort((a, b) => b.handlerPc.compareTo(a.handlerPc));
    final entries = [...catchEntries, ...finallyEntries];

    // 记录已处理的 handler，避免 multi-catch 重复处理
    final processedHandlers = <int>{};

    for (final e in entries) {
      final tryStart = offsetToLine[e.startPc];
      final catchStart = offsetToLine[e.handlerPc];
      if (tryStart == null || catchStart == null) continue;
      if (catchStart <= tryStart || catchStart >= lines.length) continue;
      // 已经转换过或者不是典型 catch 入口的跳过。
      if (!lines[catchStart].contains('/*exception*/')) continue;

      // 检查同一 handler 是否有多个 catch 类型（multi-catch）
      final sameHandlerEntries = _code.exceptionTable
          .where((other) => other.handlerPc == e.handlerPc)
          .toList();
      final isMultiCatch = sameHandlerEntries.length > 1;
      final isFinally = e.catchType == 0;

      // multi-catch: 只处理第一个条目，跳过后续相同 handler
      if (isMultiCatch && !isFinally) {
        if (processedHandlers.contains(e.handlerPc)) continue;
        processedHandlers.add(e.handlerPc);
      }

      // 在 try 区域内找到跳过后续 catch 的 goto（其目标标号位于 catch 之后）。
      int? gotoLine;
      int? labelLine;
      for (var k = catchStart - 1; k >= tryStart; k--) {
        if (k < 0) continue;
        final m = gotoRe.firstMatch(lines[k]);
        if (m == null) continue;
        final lbl = m.group(1)!;
        for (var j = catchStart; j < lines.length; j++) {
          final lm = labelRe.firstMatch(lines[j]);
          if (lm != null && lm.group(1) == lbl) {
            gotoLine = k;
            labelLine = j;
            break;
          }
        }
        if (gotoLine != null) break;
      }

      // 对于 finally 块，try body 结束位置应该用 endPc 而非 goto
      // finally 的 try 范围是 [startPc, endPc)，catch handler 在另一个位置
      int? finallyTryEnd;
      if (isFinally) {
        final endLine = offsetToLine[e.endPc];
        if (endLine != null && endLine > tryStart && endLine <= catchStart) {
          finallyTryEnd = endLine;
        }
      }

      int tryBodyEnd; // exclusive
      int catchEnd; // inclusive
      int replaceEnd; // exclusive
      if (isFinally && finallyTryEnd != null) {
        // finally 块：try body 到 endPc，finally handler 内容作为 finally body
        tryBodyEnd = finallyTryEnd;
        catchEnd = _lastNonEmptyLine(lines);
        // 尝试找到 finally 块后的合并点
        if (gotoLine != null && labelLine != null && labelLine > catchStart) {
          catchEnd = labelLine - 1;
          replaceEnd = labelLine + 1;
        } else {
          replaceEnd = catchEnd + 1;
        }
      } else if (gotoLine != null && labelLine != null) {
        // try 末尾用 goto 跳过 catch，catch 之后有合并标号。
        tryBodyEnd = gotoLine;
        catchEnd = labelLine - 1;
        replaceEnd = labelLine + 1;
      } else {
        // try 末尾是 return/throw，没有跳过 catch 的 goto；
        // catch 一直延伸到方法体末尾。
        tryBodyEnd = catchStart;
        catchEnd = _lastNonEmptyLine(lines);
        replaceEnd = catchEnd + 1;
      }

      // 限制 catch 块范围：如果 catch 块内遇到另一个异常 handler
      // （以 `/*exception*/` 标记开头且不是当前 handler），应在它之前截断。
      if (!isFinally) {
        for (var k = catchStart + 1; k <= catchEnd; k++) {
          if (lines[k].contains('/*exception*/')) {
            // 检查这是否是另一个 handler 的开始
            final kOffset = _lineToOffset(lines, k, offsetToLine);
            if (kOffset != null && kOffset != e.handlerPc) {
              final isOtherHandler = _code.exceptionTable
                  .any((other) => other.handlerPc == kOffset);
              if (isOtherHandler) {
                catchEnd = k - 1;
                // replaceEnd 也需要调整：保留到 catchEnd+1
                replaceEnd = catchEnd + 1;
                // 如果后面有 label 行也保留
                if (labelLine != null && labelLine > catchEnd) {
                  // 不删除 label 行，让后续处理
                }
                break;
              }
            }
          }
        }
      }

      if (catchEnd < catchStart) continue;
      if (tryBodyEnd > catchStart) continue;

      final tryBody = lines.sublist(tryStart, tryBodyEnd).toList();
      var catchBody = lines.sublist(catchStart, catchEnd + 1).toList();

      // 去掉 try body 末尾的空行
      while (tryBody.isNotEmpty && tryBody.last.trim().isEmpty) {
        tryBody.removeLast();
      }

      // 处理异常变量：去掉 `Exception p1 = /*exception*/;` 这类行，
      // 把后续对该变量的引用统一改为 `e`（若未被引用则用 `_` 表示 unnamed pattern）。
      String catchVar = 'e';
      bool catchVarUsed = false;
      if (catchBody.isNotEmpty) {
        final m = exceptionRe.firstMatch(catchBody[0]);
        if (m != null) {
          catchVar = m.group(2)!;
          catchBody.removeAt(0);
          // 检查 catchVar 是否在 catch body 中被引用
          final wordRe = RegExp(r'\b' + RegExp.escape(catchVar) + r'\b');
          for (var i = 0; i < catchBody.length; i++) {
            if (wordRe.hasMatch(catchBody[i])) {
              catchVarUsed = true;
              break;
            }
          }
          if (catchVarUsed && catchVar != 'e') {
            for (var i = 0; i < catchBody.length; i++) {
              catchBody[i] = catchBody[i].replaceAll(wordRe, 'e');
            }
          }
        }
      }

      // 清理 catch body 中残留的 `goto label_X;`（通常是 try/catch 边界处的跳转）
      final catchGotoRe = RegExp(r'^ *goto (label_\d+);$');
      catchBody = catchBody.where((l) => !catchGotoRe.hasMatch(l)).toList();
      // 去掉 catch body 末尾的空行
      while (catchBody.isNotEmpty && catchBody.last.trim().isEmpty) {
        catchBody.removeLast();
      }

      // 构建 catch 类型名（若 catch 变量未被引用，使用 `_` 表示 unnamed pattern）
      final varName = catchVarUsed ? 'e' : '_';
      String catchTypeDecl;
      if (isFinally) {
        catchTypeDecl = ''; // finally 块无类型
      } else if (isMultiCatch) {
        // multi-catch: 合并所有相同 handler 的类型
        final typeNames = <String>{};
        for (final she in sameHandlerEntries) {
          if (she.catchType == 0) continue;
          var tn = DescriptorParser.internalToSourceName(
              _pool.getClassName(she.catchType));
          if (tn.startsWith('java.lang.')) {
            tn = tn.substring('java.lang.'.length);
          }
          typeNames.add(tn);
        }
        catchTypeDecl = '${typeNames.join(' | ')} $varName';
      } else {
        var typeName = DescriptorParser.internalToSourceName(
            _pool.getClassName(e.catchType));
        if (typeName.startsWith('java.lang.')) {
          typeName = typeName.substring('java.lang.'.length);
        }
        catchTypeDecl = '$typeName $varName';
      }

      // 如果是 finally 块，需要检查 catchBody 是否包含 athrow（重新抛出）
      // 真正的 finally 块中如果有 athrow，说明是编译器生成的 finally 复制
      // 我们需要识别 finally 块并提取真正的 finally 内容
      String indent(String l) => l.isEmpty ? l : '    $l';

      final newLines = <String>[
        '        try {',
        ...tryBody.map(indent),
      ];

      if (isFinally) {
        // finally 块：去掉末尾的 athrow 和异常变量引用
        // finally 块通常以 `e = /*exception*/; ... athrow` 结尾
        final cleanedCatchBody = <String>[];
        for (var i = 0; i < catchBody.length; i++) {
          final line = catchBody[i].trim();
          // 跳过 athrow（重新抛出）
          if (line == 'throw e;' || line == 'athrow') continue;
          // 跳过 `Throwable e = /*exception*/;`（已在前面处理）
          if (line.contains('/*exception*/')) continue;
          cleanedCatchBody.add(catchBody[i]);
        }
        // 如果清理后为空，跳过（finally 内容已在 try 中内联）
        if (cleanedCatchBody.any((l) => l.trim().isNotEmpty)) {
          newLines.add('        } finally {');
          newLines.addAll(cleanedCatchBody.map(indent));
          newLines.add('        }');
        } else {
          newLines.add('        }');
        }
      } else {
        newLines.add('        } catch ($catchTypeDecl) {');
        newLines.addAll(catchBody.map(indent));
        newLines.add('        }');
      }
      lines.replaceRange(tryStart, replaceEnd, newLines);
    }

    return lines.join('\n');
  }

  int _lastNonEmptyLine(List<String> lines) {
    for (var i = lines.length - 1; i >= 0; i--) {
      if (lines[i].trim().isNotEmpty) return i;
    }
    return -1;
  }

  /// 通过行号反查字节码 offset。
  int? _lineToOffset(
      List<String> lines, int lineNo, Map<int, int> offsetToLine) {
    for (final entry in offsetToLine.entries) {
      if (entry.value == lineNo) return entry.key;
    }
    return null;
  }

  /// 把 if/else 的各种 goto 形式还原成标准的 if/else 块。
  String _structureIfElse(String source) {
    final lines = source.split('\n');
    final condGotoRe = RegExp(r'^( {8,})if \((.+)\) goto (label_\d+);$');
    final openIfRe = RegExp(r'^( {8,})if \((.+)\) \{$');
    final gotoRe = RegExp(r'^ {8,}goto (label_\d+);$');
    final labelRe = RegExp(r'^ {6,}(label_\d+):$');

    bool changed;
    do {
      changed = false;
      final labelMap = <String, int>{};
      for (var i = 0; i < lines.length; i++) {
        final m = labelRe.firstMatch(lines[i]);
        if (m != null) labelMap[m.group(1)!] = i;
      }

      // 模式 B：`_structureIfs` 已经把条件分支包成了 if 块，但 then 分支末尾还
      // 残留 `goto end;`，后面跟着 else 代码和 end 标号。
      //   if (cond) {
      //       thenBody;
      //       goto end;
      //   }
      //   elseBody;
      // end:
      for (var i = lines.length - 1; i >= 0; i--) {
        final open = openIfRe.firstMatch(lines[i]);
        if (open == null) continue;
        final indent = open.group(1)!;
        final cond = open.group(2)!;

        // 找到配对的右花括号。
        int? closeLine;
        var depth = 1;
        for (var k = i + 1; k < lines.length; k++) {
          if (lines[k].contains('{')) depth++;
          if (lines[k].contains('}')) {
            depth--;
            if (depth == 0) {
              closeLine = k;
              break;
            }
          }
        }
        if (closeLine == null) continue;

        // then 分支末尾的无条件 goto。
        final gotoInBlockRe = RegExp(r'^' + indent + r'    goto (label_\d+);$');
        int? gotoLine;
        String? endLabel;
        for (var k = closeLine - 1; k > i; k--) {
          final gm = gotoInBlockRe.firstMatch(lines[k]);
          if (gm != null) {
            gotoLine = k;
            endLabel = gm.group(1);
            break;
          }
        }
        if (gotoLine == null || endLabel == null) continue;

        final endLine = labelMap[endLabel];
        if (endLine == null || endLine <= closeLine) continue;

        // endLabel 只能被这个 goto 引用。
        var otherRefs = false;
        for (var k = 0; k < lines.length; k++) {
          if (k == gotoLine) continue;
          if (lines[k].contains('goto $endLabel;')) {
            otherRefs = true;
            break;
          }
        }
        if (otherRefs) continue;

        final thenBody = lines.sublist(i + 1, gotoLine);
        final elseBody = lines.sublist(closeLine + 1, endLine);
        String bodyIndent(String l) =>
            l.isEmpty ? l : '$indent    ${l.trimLeft()}';
        final newLines = <String>[
          '${indent}if ($cond) {',
          ...thenBody.map(bodyIndent),
        ];
        if (elseBody.any((l) => l.trim().isNotEmpty)) {
          newLines.add('$indent} else {');
          newLines.addAll(elseBody.map(bodyIndent));
        }
        newLines.add('$indent}');
        lines.replaceRange(i, endLine + 1, newLines);
        changed = true;
        break;
      }
      if (changed) continue;

      // 模式 A：原始的 `if (cond) goto else; then; goto end; else: else-body; end:`。
      for (var i = lines.length - 1; i >= 0; i--) {
        final cm = condGotoRe.firstMatch(lines[i]);
        if (cm == null) continue;
        final indent = cm.group(1)!;
        final cond = cm.group(2)!;
        final elseLabel = cm.group(3)!;
        final elseLine = labelMap[elseLabel];
        if (elseLine == null || elseLine <= i) continue;

        int? gotoLine;
        String? endLabel;
        for (var g = i + 1; g < elseLine; g++) {
          final gm = gotoRe.firstMatch(lines[g]);
          if (gm != null) {
            gotoLine = g;
            endLabel = gm.group(1);
            break;
          }
        }
        if (gotoLine == null || endLabel == null) continue;

        final endLine = labelMap[endLabel];
        if (endLine == null || endLine <= elseLine) continue;

        bool bodyHasLabel = false;
        for (var k = i + 1; k < gotoLine; k++) {
          if (labelRe.hasMatch(lines[k])) {
            bodyHasLabel = true;
            break;
          }
        }
        if (bodyHasLabel) continue;
        for (var k = elseLine + 1; k < endLine; k++) {
          if (labelRe.hasMatch(lines[k])) {
            bodyHasLabel = true;
            break;
          }
        }
        if (bodyHasLabel) continue;

        var otherRefs = false;
        for (var k = 0; k < lines.length; k++) {
          if (k == i) continue;
          if (lines[k].contains('goto $elseLabel;')) {
            otherRefs = true;
            break;
          }
        }
        if (otherRefs) continue;
        for (var k = 0; k < lines.length; k++) {
          if (k == gotoLine) continue;
          if (lines[k].contains('goto $endLabel;')) {
            otherRefs = true;
            break;
          }
        }
        if (otherRefs) continue;

        final thenBody = lines.sublist(i + 1, gotoLine);
        final elseBody = lines.sublist(elseLine + 1, endLine);
        String bodyIndent(String l) =>
            l.isEmpty ? l : '$indent    ${l.trimLeft()}';
        final newLines = <String>[
          '${indent}if (${_negateCondition(cond)}) {',
          ...thenBody.map(bodyIndent),
          '$indent} else {',
          ...elseBody.map(bodyIndent),
          '$indent}',
        ];
        lines.replaceRange(i, endLine + 1, newLines);
        changed = true;
        break;
      }
    } while (changed);

    return lines.join('\n');
  }

  /// 把典型的 `for (T e : arr)` 字节码模式还原为增强 for 循环。
  /// 识别模式（label 形式）：
  ///   arrVar = arrayExpr;
  ///   int lenVar = arrVar.length;
  ///   int idxVar = 0;
  /// label_X:
  ///   if (idxVar < lenVar) {
  ///       T elemVar = arrVar[idxVar];
  ///       body;
  ///       idxVar += 1;
  ///       goto label_X;
  ///   }
  String _structureForEach(String source) {
    final lines = source.split('\n');
    final labelRe = RegExp(r'^      (label_\d+):$');
    final ifRe = RegExp(r'^        if \((\w+) < (\w+)\) \{$');
    final initIdxRe = RegExp(r'^        int (\w+) = 0;$');
    final initLenRe = RegExp(r'^        int (\w+) = (\w+)\.length;$');
    final initArrRe = RegExp(r'^        (\S+) (\w+) = (.+);$');
    final elemRe = RegExp(r'^        (\S+) (\w+) = (\w+)\[(\w+)\];$');
    final incRe = RegExp(r'^        (\w+) \+= 1;$');
    final gotoRe = RegExp(r'^ {8,}goto (label_\d+);$');

    bool changed;
    do {
      changed = false;
      for (var i = 0; i < lines.length; i++) {
        final labelMatch = labelRe.firstMatch(lines[i]);
        if (labelMatch == null) continue;
        final label = labelMatch.group(1)!;

        // label 下一行应为 if (idx < len) {
        var ifLine = i + 1;
        while (ifLine < lines.length && lines[ifLine].trim().isEmpty) {
          ifLine++;
        }
        if (ifLine >= lines.length) continue;
        final ifMatch = ifRe.firstMatch(lines[ifLine]);
        if (ifMatch == null) continue;
        final idxVar = ifMatch.group(1)!;
        final lenVar = ifMatch.group(2)!;

        // 找到 if 块结束
        var depth = 1;
        var closeIdx = ifLine + 1;
        while (closeIdx < lines.length && depth > 0) {
          final t = lines[closeIdx].trim();
          if (t == '{') depth++;
          if (t == '}') depth--;
          closeIdx++;
        }
        if (depth != 0) continue;
        closeIdx--; // 指向 '}' 行

        // 块内第一条语句应为 elem = arr[idx]
        var firstLine = ifLine + 1;
        while (firstLine < closeIdx && lines[firstLine].trim().isEmpty) {
          firstLine++;
        }
        if (firstLine >= closeIdx) continue;
        final elemMatch = elemRe.firstMatch(lines[firstLine]);
        if (elemMatch == null) continue;
        final elemType = elemMatch.group(1)!;
        final elemVar = elemMatch.group(2)!;
        final arrVar = elemMatch.group(3)!;
        if (elemMatch.group(4) != idxVar) continue;

        // 块内最后一条非空语句应为 idx += 1（倒数第二），最后一条为 goto label
        var lastLine = closeIdx - 1;
        while (lastLine > ifLine && lines[lastLine].trim().isEmpty) {
          lastLine--;
        }
        final gotoMatch = gotoRe.firstMatch(lines[lastLine]);
        if (gotoMatch == null || gotoMatch.group(1) != label) continue;

        var incLine = lastLine - 1;
        while (incLine > ifLine && lines[incLine].trim().isEmpty) {
          incLine--;
        }
        final incMatch = incRe.firstMatch(lines[incLine]);
        if (incMatch == null || incMatch.group(1) != idxVar) continue;

        // label 前面应依次为 idx=0, len=arr.length, arr=arrayExpr
        var idx0Line = i - 1;
        while (idx0Line >= 0 && lines[idx0Line].trim().isEmpty) idx0Line--;
        if (idx0Line < 0) continue;
        final idx0Match = initIdxRe.firstMatch(lines[idx0Line]);
        if (idx0Match == null || idx0Match.group(1) != idxVar) continue;

        var lenLine = idx0Line - 1;
        while (lenLine >= 0 && lines[lenLine].trim().isEmpty) {
          lenLine--;
        }
        if (lenLine < 0) continue;
        final lenMatch = initLenRe.firstMatch(lines[lenLine]);
        if (lenMatch == null ||
            lenMatch.group(1) != lenVar ||
            lenMatch.group(2) != arrVar) {
          continue;
        }

        var arrLine = lenLine - 1;
        while (arrLine >= 0 && lines[arrLine].trim().isEmpty) {
          arrLine--;
        }
        if (arrLine < 0) continue;
        final arrMatch = initArrRe.firstMatch(lines[arrLine]);
        if (arrMatch == null || arrMatch.group(2) != arrVar) {
          continue;
        }
        final arrayExpr = arrMatch.group(3)!;

        // 构造 for-each 体：去掉 elem 声明、idx += 1 和 goto
        final bodyLines = lines
            .sublist(firstLine + 1, incLine)
            .where((l) => l.trim().isNotEmpty)
            .toList();

        final newLines = <String>[
          '        for ($elemType $elemVar : $arrayExpr) {',
          ...bodyLines.map((l) => '    $l'),
          '        }',
        ];
        lines.replaceRange(arrLine, closeIdx + 1, newLines);
        changed = true;
        break;
      }
    } while (changed);

    return lines.join('\n');
  }

  String _structureWhileLoops(String source) {
    final lines = source.split('\n');
    final labelRe = RegExp(r'^      (label_\d+):$');
    final ifRe = RegExp(r'^        if \((.+)\) \{$');
    final ifGotoRe = RegExp(r'^        if \((.+)\) goto (label_\d+);$');
    final gotoRe = RegExp(r'^ {8,}goto (label_\d+);$');

    bool changed;
    do {
      changed = false;
      for (var i = 0; i < lines.length; i++) {
        final labelMatch = labelRe.firstMatch(lines[i]);
        if (labelMatch == null) continue;
        final label = labelMatch.group(1)!;

        // 紧跟 label 的下一行应为 `if (cond) {` 或 `if (cond) goto exit;`
        var j = i + 1;
        while (j < lines.length && lines[j].trim().isEmpty) {
          j++;
        }
        if (j >= lines.length) continue;

        // 模式 A：`if (cond) {` 形式（已由 _structureIfs 转换）
        final ifMatch = ifRe.firstMatch(lines[j]);
        if (ifMatch != null) {
          final cond = ifMatch.group(1)!;

          // 找到 `if` 块的结束 `}`
          var depth = 1;
          var k = j + 1;
          while (k < lines.length && depth > 0) {
            final t = lines[k].trim();
            if (t == '{') depth++;
            if (t == '}') depth--;
            k++;
          }
          if (depth != 0) continue;
          final closeIdx = k - 1;

          // 块内最后一条非空语句应为 `goto label;`
          var g = closeIdx - 1;
          while (g > j && lines[g].trim().isEmpty) {
            g--;
          }
          final gotoMatch = gotoRe.firstMatch(lines[g]);
          if (gotoMatch == null || gotoMatch.group(1) != label) continue;

          // 确保 label 只在本处定义和循环末尾被引用，避免破坏多重跳转
          var labelRefs = 0;
          for (var n = 0; n < lines.length; n++) {
            if (n == i || n == g) continue;
            if (lines[n].trim() == 'goto $label;' ||
                lines[n].trim().startsWith('$label:')) {
              labelRefs++;
            }
          }
          if (labelRefs > 0) continue;

          // 替换为 while 并删除 label 与 goto
          lines[j] = '        while ($cond) {';
          lines[i] = '';
          lines[g] = '';
          changed = true;
          break;
        }

        // 模式 B：`if (cond) goto exit;` 形式（典型 while 循环前置条件跳转）
        final ifGotoMatch = ifGotoRe.firstMatch(lines[j]);
        if (ifGotoMatch != null) {
          final cond = ifGotoMatch.group(1)!;
          final exitLabel = ifGotoMatch.group(2)!;

          // 收集 body：从 j+1 到下一个 `goto label;`（回到循环头）
          var g = j + 1;
          int? gotoEnd;
          while (g < lines.length) {
            final gm = gotoRe.firstMatch(lines[g]);
            if (gm != null && gm.group(1) == label) {
              gotoEnd = g;
              break;
            }
            // 遇到其他 label 表示结构不匹配
            if (labelRe.hasMatch(lines[g])) break;
            g++;
          }
          if (gotoEnd == null) continue;

          // 确保 label 只在本处定义和循环末尾被引用
          var labelRefs = 0;
          for (var n = 0; n < lines.length; n++) {
            if (n == i || n == gotoEnd) continue;
            if (lines[n].trim() == 'goto $label;' ||
                lines[n].trim().startsWith('$label:')) {
              labelRefs++;
            }
          }
          if (labelRefs > 0) continue;

          // body 为 j+1 到 gotoEnd（不含），需要取反条件
          final bodyLines = lines
              .sublist(j + 1, gotoEnd)
              .where((l) => l.trim().isNotEmpty)
              .toList();
          final negCond = _negateCondition(cond);

          // 基于 while 行的缩进 + 4 作为 body 缩进
          final whileIndent = '        '; // while 行固定 8 空格
          final indentedBody = _reindentBlock(bodyLines, '            ');

          final newLines = <String>[
            '${whileIndent}while ($negCond) {',
            ...indentedBody,
            '${whileIndent}}',
          ];
          // 找到 exit label 位置，如果它在 gotoEnd 后紧邻且未被其他地方引用，
          // 一并移除（它通常是循环结束后的下一条语句标号）
          int replaceEnd = gotoEnd + 1;
          final exitLabelLine = _findLabelLine(lines, exitLabel);
          if (exitLabelLine != null && exitLabelLine > gotoEnd) {
            // 检查 exit label 是否只被这一处 if goto 引用
            var exitRefs = 0;
            for (var n = 0; n < lines.length; n++) {
              if (n == exitLabelLine) continue;
              if (lines[n].contains('goto $exitLabel;')) exitRefs++;
            }
            if (exitRefs == 0 && exitLabelLine == gotoEnd + 1) {
              replaceEnd = exitLabelLine + 1;
            }
          }
          lines.replaceRange(i, replaceEnd, newLines);
          changed = true;
          break;
        }
      }
    } while (changed);

    return lines.join('\n');
  }

  int? _findLabelLine(List<String> lines, String label) {
    final labelRe = RegExp(r'^      (label_\d+):$');
    for (var i = 0; i < lines.length; i++) {
      final m = labelRe.firstMatch(lines[i]);
      if (m != null && m.group(1) == label) return i;
    }
    return null;
  }

  /// 把 `int p = 0; while (p < N) { ...; p += 1; }` 还原成
  /// `for (int p = 0; p < N; p++) { ... }`。也支持 >= 形式（取反条件）。
  /// 同时处理 label 形式的 for 循环：
  ///   idxVar = 0;
  /// label_X:
  ///   if (idxVar >= N) goto label_END;
  ///   body;
  /// label_INC:
  ///   idxVar += 1;
  ///   goto label_X;
  /// label_END:
  String _structureForLoops(String source) {
    var lines = source.split('\n');

    final initRe = RegExp(r'^        (?:\S+(?:\[\])*\s+)?(\w+) = 0;$');
    final whileRe = RegExp(r'^        while \((\w+) (<|>=) ([^)]+)\) \{$');
    final incRe = RegExp(r'^            (\w+) \+= 1;$');
    final labelRe = RegExp(r'^      (label_\d+):$');
    final ifGotoRe =
        RegExp(r'^        if \((\w+) (>=|<) ([^)]+)\) goto (label_\d+);$');
    final gotoRe = RegExp(r'^        goto (label_\d+);$');
    final incLabelRe = RegExp(r'^        (\w+) \+= 1;$');

    bool changed;
    do {
      changed = false;

      // 模式 A：while 形式的 for 循环
      var found = false;
      for (var i = 0; i < lines.length && !found; i++) {
        final wm = whileRe.firstMatch(lines[i]);
        if (wm == null) continue;
        final idxVar = wm.group(1)!;
        final op = wm.group(2)!;
        final bound = wm.group(3)!;

        // 找到 while 块结束
        var depth = 1;
        var closeIdx = i + 1;
        while (closeIdx < lines.length && depth > 0) {
          final t = lines[closeIdx].trim();
          if (t == '{') depth++;
          if (t == '}') depth--;
          closeIdx++;
        }
        if (depth != 0) continue;
        closeIdx--;

        // 块内最后一条非空语句应为 idxVar += 1
        var incLine = closeIdx - 1;
        while (incLine > i && lines[incLine].trim().isEmpty) {
          incLine--;
        }
        final im = incRe.firstMatch(lines[incLine]);
        if (im == null || im.group(1) != idxVar) continue;

        // while 前一条非空语句应为 idxVar = 0
        var initLine = i - 1;
        while (initLine >= 0 && lines[initLine].trim().isEmpty) {
          initLine--;
        }
        if (initLine < 0) continue;
        final im2 = initRe.firstMatch(lines[initLine]);
        if (im2 == null || im2.group(1) != idxVar) continue;
        // 去掉末尾分号，for 语句会自己加
        var initDecl = lines[initLine].trim();
        if (initDecl.endsWith(';')) {
          initDecl = initDecl.substring(0, initDecl.length - 1);
        }

        final cond = op == '<' ? '$idxVar < $bound' : '$idxVar >= $bound';
        final bodyLines = lines
            .sublist(i + 1, incLine)
            .where((l) => l.trim().isNotEmpty)
            .toList();
        // 重新缩进 body，保留相对缩进
        final indentedBody = _reindentBlock(bodyLines, '            ');

        final newLines = <String>[
          '        for ($initDecl; $cond; ${idxVar}++) {',
          ...indentedBody,
          '        }',
        ];
        lines.replaceRange(initLine, closeIdx + 1, newLines);
        changed = true;
        found = true;
      }

      if (changed) continue;

      // 模式 B：label 形式的 for 循环
      // label_X:
      //   if (idxVar >= N) goto label_END;
      //   body;
      // label_INC:
      //   idxVar += 1;
      //   goto label_X;
      // label_END:
      final labelMap = <String, int>{};
      for (var i = 0; i < lines.length; i++) {
        final m = labelRe.firstMatch(lines[i]);
        if (m != null) labelMap[m.group(1)!] = i;
      }

      for (var i = 0; i < lines.length && !found; i++) {
        final lm = labelRe.firstMatch(lines[i]);
        if (lm == null) continue;
        final startLabel = lm.group(1)!;

        // 下一行应为 if (idxVar op N) goto label_END;
        var j = i + 1;
        while (j < lines.length && lines[j].trim().isEmpty) {
          j++;
        }
        if (j >= lines.length) continue;
        final ifm = ifGotoRe.firstMatch(lines[j]);
        if (ifm == null) continue;
        final idxVar = ifm.group(1)!;
        final op = ifm.group(2)!;
        final bound = ifm.group(3)!;
        final endLabel = ifm.group(4)!;

        final endLabelLine = labelMap[endLabel];
        if (endLabelLine == null || endLabelLine <= j) continue;

        // 在 j+1 到 endLabelLine 之间找 `idxVar += 1; goto startLabel;` 模式
        // 通常是: label_INC: idxVar += 1; goto startLabel;
        int? incLabelLine;
        int? incLine;
        int? gotoLine;
        for (var k = j + 1; k < endLabelLine - 2; k++) {
          final lm2 = labelRe.firstMatch(lines[k]);
          if (lm2 == null) continue;
          // 检查后续两行是否为 idxVar += 1; goto startLabel;
          final incMatch = incLabelRe.firstMatch(lines[k + 1]);
          final gotoMatch = gotoRe.firstMatch(lines[k + 2]);
          if (incMatch != null &&
              incMatch.group(1) == idxVar &&
              gotoMatch != null &&
              gotoMatch.group(1) == startLabel) {
            incLabelLine = k;
            incLine = k + 1;
            gotoLine = k + 2;
            break;
          }
        }
        if (incLabelLine == null) continue;

        // 找到 init: idxVar = 0; 在 label 前
        var initLine = i - 1;
        while (initLine >= 0 && lines[initLine].trim().isEmpty) {
          initLine--;
        }
        if (initLine < 0) continue;
        final im2 = initRe.firstMatch(lines[initLine]);
        if (im2 == null || im2.group(1) != idxVar) continue;
        var initDecl = lines[initLine].trim();
        if (initDecl.endsWith(';')) {
          initDecl = initDecl.substring(0, initDecl.length - 1);
        }

        // 确保 startLabel 只在 incLine 处被 goto 引用
        var startLabelRefs = 0;
        for (var n = 0; n < lines.length; n++) {
          if (n == i) continue;
          if (lines[n].contains('goto $startLabel;')) startLabelRefs++;
        }
        if (startLabelRefs != 1) continue;

        // 确保 endLabel 只在循环体内被 goto 引用（作为 break），不在循环体外被引用
        var endLabelRefs = 0;
        for (var n = 0; n < lines.length; n++) {
          if (n == j) continue;
          if (n > j && n < incLabelLine!) continue; // 循环体内的 break
          if (n >= incLabelLine && n <= gotoLine!) continue; // inc 部分
          if (lines[n].contains('goto $endLabel;')) endLabelRefs++;
        }
        if (endLabelRefs > 0) continue;

        // body 为 j+1 到 incLabelLine（不含）
        final bodyLines = lines
            .sublist(j + 1, incLabelLine)
            .where((l) => l.trim().isNotEmpty)
            .toList();
        final indentedBody = _reindentBlock(bodyLines, '            ');

        // 条件取反：if (idxVar >= N) goto end -> while (idxVar < N)
        final cond = op == '>=' ? '$idxVar < $bound' : '$idxVar >= $bound';

        final newLines = <String>[
          '        for ($initDecl; $cond; ${idxVar}++) {',
          ...indentedBody,
          '        }',
        ];
        // 替换范围：initLine 到 endLabelLine（不含 endLabelLine 本身）
        lines.replaceRange(initLine, endLabelLine, newLines);
        changed = true;
        found = true;
      }
    } while (changed);

    return lines.join('\n');
  }

  /// 把 `do { body; } while (cond);` 还原。
  /// 识别模式（label 形式）：
  ///   label_X:
  ///     body;
  ///     if (cond) goto label_X;
  String _structureDoWhileLoops(String source) {
    var lines = source.split('\n');

    final labelRe = RegExp(r'^      (label_\d+):$');
    final condGotoRe = RegExp(r'^        if \((.+)\) goto (label_\d+);$');

    bool changed;
    do {
      changed = false;
      final labelMap = <String, int>{};
      for (var i = 0; i < lines.length; i++) {
        final m = labelRe.firstMatch(lines[i]);
        if (m != null) labelMap[m.group(1)!] = i;
      }

      for (var i = 0; i < lines.length; i++) {
        final cm = condGotoRe.firstMatch(lines[i]);
        if (cm == null) continue;
        final cond = cm.group(1)!;
        final target = cm.group(2)!;
        final labelLine = labelMap[target];
        if (labelLine == null || labelLine >= i) continue;

        // 确保 target label 只被这一处 goto 引用
        var refs = 0;
        for (var k = 0; k < lines.length; k++) {
          if (k == labelLine) continue;
          if (lines[k].contains('goto $target;')) refs++;
        }
        if (refs != 1) continue;

        // body 为 labelLine+1 到 i（不含）
        final bodyLines = lines
            .sublist(labelLine + 1, i)
            .where((l) => l.trim().isNotEmpty)
            .toList();
        if (bodyLines.isEmpty) continue;

        // 重新缩进 body
        final newLines = <String>[
          '        do {',
          ...bodyLines.map((l) {
            final t = l.trimLeft();
            return '            $t';
          }),
          '        } while ($cond);',
        ];
        lines.replaceRange(labelLine, i + 1, newLines);
        changed = true;
        break;
      }
    } while (changed);

    return lines.join('\n');
  }

  /// 把 `new T[N][i] = v;` 形式的数组初始化还原为数组字面量
  /// `T[] var = {v1, v2, ...};`。需要后面跟着 `T[] var = new T[N];` 形式的赋值。
  String _structureArrayInit(String source) {
    var lines = source.split('\n');

    // 匹配 new int[5][0] = 1; 形式
    final storeRe = RegExp(r'^        new (\S+)\[(\d+)\]\[(\d+)\] = (.+);$');
    // 匹配 int[] p0 = new int[5]; 形式
    final declRe = RegExp(r'^        (\S+\[\]) (\w+) = new (\S+)\[(\d+)\];$');

    bool changed;
    do {
      changed = false;

      // 收集连续的 new T[N][i] = v; 块
      for (var i = 0; i < lines.length; i++) {
        final sm = storeRe.firstMatch(lines[i]);
        if (sm == null) continue;
        final type = sm.group(1)!;
        final size = int.parse(sm.group(2)!);
        final firstIdx = int.parse(sm.group(3)!);

        // 收集从 i 开始的连续 store 行
        final values = <int, String>{};
        var end = i;
        for (var k = i; k < lines.length; k++) {
          final m = storeRe.firstMatch(lines[k]);
          if (m == null) break;
          if (m.group(1) != type || int.parse(m.group(2)!) != size) break;
          values[int.parse(m.group(3)!)] = m.group(4)!;
          end = k;
        }

        // 必须从 0 开始且数量与 size 匹配
        if (!values.containsKey(firstIdx) || firstIdx != 0) continue;
        if (values.length != size) continue;

        // end+1 处可能为 T[] var = new T[N]; 或包含 new T[N] 的内联表达式
        var nextLine = end + 1;
        while (nextLine < lines.length && lines[nextLine].trim().isEmpty) {
          nextLine++;
        }
        if (nextLine >= lines.length) continue;

        final dm = declRe.firstMatch(lines[nextLine]);
        if (dm != null) {
          // 情况1：变量声明 T[] var = new T[N];
          final declType = dm.group(1)!; // e.g. int[]
          final varName = dm.group(2)!;
          final newType = dm.group(3)!; // e.g. int
          final newSize = int.parse(dm.group(4)!);
          if (declType != '$newType[]') continue;
          if (newType != type) continue;
          if (newSize != size) continue;

          final elems = <String>[];
          for (var k = 0; k < size; k++) {
            elems.add(values[k]!);
          }
          final elemsStr = elems.join(', ');
          final newLine = '        $declType $varName = { $elemsStr };';
          lines.replaceRange(i, nextLine + 1, [newLine]);
          changed = true;
          break;
        }

        // 情况2：内联数组 - 消费行包含 new T[N]（不紧跟 [）
        final inlineRe = RegExp(r'\bnew ' +
            RegExp.escape(type) +
            r'\[' +
            size.toString() +
            r'\](?!\[)');
        if (inlineRe.hasMatch(lines[nextLine])) {
          final elems = <String>[];
          for (var k = 0; k < size; k++) {
            elems.add(values[k]!);
          }
          final arrayLiteral = 'new $type[]{ ${elems.join(', ')} }';
          final replaced = lines[nextLine].replaceAll(inlineRe, arrayLiteral);
          lines.replaceRange(i, nextLine + 1, [replaced]);
          changed = true;
          break;
        }
      }
    } while (changed);

    return lines.join('\n');
  }

  (String className, String fieldName, String descriptor) _fieldRef(int index) {
    final ref = _pool.getFieldref(index);
    final cls = DescriptorParser.internalToSourceName(
        _pool.getClassName(ref.classIndex));
    final nt = _pool.getNameAndType(ref.nameAndTypeIndex);
    return (
      cls,
      _pool.getString(nt.nameIndex),
      _pool.getString(nt.descriptorIndex)
    );
  }

  (String, String, String) _methodRef(int index) {
    final ref = _pool.getMethodref(index);
    final cls = DescriptorParser.internalToSourceName(
        _pool.getClassName(ref.classIndex));
    final nt = _pool.getNameAndType(ref.nameAndTypeIndex);
    return (
      cls,
      _pool.getString(nt.nameIndex),
      _pool.getString(nt.descriptorIndex)
    );
  }

  void _maybeEmitDiscarded(String value, StringSink out) {
    // 丢弃非平凡的表达式时（例如调用的返回值未使用），输出为独立语句。
    // 跳过无参的 new Class().<init>()，它通常来自 new/dup/invokespecial 组合。
    final simple = RegExp(r'^[a-zA-Z_$][\w$]*$');
    if (!simple.hasMatch(value) &&
        value != '/*stack underflow*/' &&
        !value.endsWith('.<init>()')) {
      out.writeln('        $value;');
    }
  }

  /// 把 StringConcatFactory.makeConcatWithConstants 的 recipe 还原成字符串拼接表达式。
  String _formatStringConcat(String recipe, List<String> args) {
    final parts = <String>[];
    final literal = StringBuffer();
    var argIndex = 0;
    for (var i = 0; i < recipe.length; i++) {
      final c = recipe.codeUnitAt(i);
      if (c == 0x0001 || c == 0x0002) {
        if (literal.isNotEmpty) {
          parts.add(_quoteStringLiteral(literal.toString()));
          literal.clear();
        }
        if (argIndex < args.length) {
          parts.add(args[argIndex++]);
        }
      } else {
        literal.writeCharCode(c);
      }
    }
    if (literal.isNotEmpty) {
      parts.add(_quoteStringLiteral(literal.toString()));
    }
    if (parts.isEmpty) return '""';
    if (parts.length == 1) return parts.first;
    return parts.join(' + ');
  }

  String _quoteStringLiteral(String s) {
    final escaped = s
        .replaceAll('\\', '\\\\')
        .replaceAll('"', '\\"')
        .replaceAll('\n', '\\n')
        .replaceAll('\r', '\\r')
        .replaceAll('\t', '\\t');
    return '"$escaped"';
  }

  (String expr, bool returns) _invokeFromStack(
      Instruction i, List<String> stack) {
    final op = i.opcode;
    final index = i.operands[0] as int;
    String expr;
    bool returns = true;
    if (op == Opcodes.invokedynamic) {
      final id = _pool.getInvokeDynamic(index);
      final nt = _pool.getNameAndType(id.nameAndTypeIndex);
      final name = _pool.getString(nt.nameIndex);
      final desc = _pool.getString(nt.descriptorIndex);
      final (params, ret) = DescriptorParser.parseMethodDescriptor(desc);
      final args = List.generate(params.length, (_) => stack.removeLast())
          .reversed
          .toList();
      if (name == 'makeConcatWithConstants') {
        BootstrapMethodsAttribute? bmAttr;
        for (final attr in _cf.attributes) {
          if (attr is BootstrapMethodsAttribute) {
            bmAttr = attr;
            break;
          }
        }
        if (bmAttr != null &&
            id.bootstrapMethodAttrIndex < bmAttr.bootstrapMethods.length &&
            bmAttr.bootstrapMethods[id.bootstrapMethodAttrIndex]
                .bootstrapArguments.isNotEmpty) {
          try {
            final recipeIndex = bmAttr
                .bootstrapMethods[id.bootstrapMethodAttrIndex]
                .bootstrapArguments[0];
            final recipe =
                _pool.getString(_pool.getStringInfo(recipeIndex).stringIndex);
            expr = _formatStringConcat(recipe, args);
            returns = ret != 'void';
            return (expr, returns);
          } catch (_) {
            // 解析失败时回退到通用 invokedynamic 表示
          }
        }
      }
      expr = 'invokedynamic $name(${args.join(', ')})';
      returns = ret != 'void';
    } else {
      final entry = _pool.get(index);
      late final (String cls, String name, String desc) ref;
      if (entry is CpMethodref) {
        ref = _methodRef(index);
      } else if (entry is CpInterfaceMethodref) {
        final r = _pool.getInterfaceMethodref(index);
        final cls = DescriptorParser.internalToSourceName(
            _pool.getClassName(r.classIndex));
        final nt = _pool.getNameAndType(r.nameAndTypeIndex);
        ref = (
          cls,
          _pool.getString(nt.nameIndex),
          _pool.getString(nt.descriptorIndex)
        );
      } else {
        final (cls, fname, fdesc) = _fieldRef(index);
        ref = (cls, fname, fdesc);
      }
      final (params, ret) = DescriptorParser.parseMethodDescriptor(ref.$3);
      final args = List.generate(params.length, (_) => stack.removeLast())
          .reversed
          .join(', ');
      if (op == Opcodes.invokestatic) {
        expr = '${ref.$1}.${ref.$2}($args)';
      } else if (op == Opcodes.invokespecial && ref.$2 == '<init>') {
        if (stack.isEmpty) {
          expr = '/*init underflow*/.<init>($args)';
        } else {
          final obj = stack.removeLast();
          // new Class() / dup / invokespecial <init> 合并成 new Class(args)
          if (obj.startsWith('new ${ref.$1}(')) {
            if (stack.isNotEmpty && stack.last == obj) {
              stack.removeLast(); // 移除 new 留下的占位对象
            }
            expr = 'new ${ref.$1}($args)';
          } else {
            expr = '$obj.<init>($args)';
          }
        }
        return (expr, true);
      } else if (op == Opcodes.invokespecial) {
        final obj = stack.removeLast();
        expr = '$obj.${ref.$2}($args)';
      } else {
        final obj = stack.removeLast();
        expr = '$obj.${ref.$2}($args)';
      }
      returns = ret != 'void';
    }
    return (expr, returns);
  }

  String _newArrayType(int atype) {
    return switch (atype) {
      4 => 'boolean',
      5 => 'char',
      6 => 'float',
      7 => 'double',
      8 => 'byte',
      9 => 'short',
      10 => 'int',
      11 => 'long',
      _ => '?',
    };
  }

  /// 尝试把 Java 21 的 pattern switch 状态机还原成可读的 switch 表达式。
  /// 这只是一个启发式优化，针对 `invokedynamic typeSwitch` 生成的典型字节码。
  String _structurePatternSwitch(String source) {
    final lines = source.split('\n');

    // 1. 定位 typeSwitch 头部：
    //    Object p1 = p0;
    //    int p2 = 0;
    //  label_4:
    //    switch (invokedynamic typeSwitch(p1, p2)) {
    final switchRe = RegExp(
        r'^        switch \(invokedynamic typeSwitch\((\w+), (\w+)\)\) \{$');
    final labelRe = RegExp(r'^      (label_\d+):$');
    // 状态变量初始化：`int p2 = 0;` 或 `p2 = 0;`（当变量已声明时）
    final intInitRe = RegExp(r'^        (?:int )?(\w+) = 0;$');
    final headerAssignRe =
        RegExp(r'^        (\S+(?:<[^>]+>)?) (\w+) = (\w+);$');

    int? headerStart; // Object p1 = p0; 所在行
    String? originalSelector;
    String? selectorVar;
    String? stateVar;
    String? switchLabel;
    int? switchLine;
    for (var i = 0; i < lines.length; i++) {
      final sm = switchRe.firstMatch(lines[i]);
      if (sm == null) continue;
      switchLine = i;
      selectorVar = sm.group(1);
      stateVar = sm.group(2);

      // 向前搜索状态初始化、选择器赋值以及最近的标签（javac 生成的前导代码不尽相同）
      int? stateInitLine;
      for (var j = i - 1; j >= 0 && j >= i - 15; j--) {
        final line = lines[j];
        final lm = labelRe.firstMatch(line);
        if (lm != null) {
          switchLabel ??= lm.group(1);
          continue;
        }
        if (stateInitLine == null) {
          final im = intInitRe.firstMatch(line);
          if (im != null && im.group(1) == stateVar) {
            stateInitLine = j;
            continue;
          }
        }
        if (stateInitLine != null) {
          final hm = headerAssignRe.firstMatch(line);
          if (hm != null && hm.group(2) == selectorVar) {
            headerStart = j;
            originalSelector = hm.group(3);
            break;
          }
        }
      }
      break;
    }

    if (switchLine == null ||
        selectorVar == null ||
        stateVar == null ||
        headerStart == null ||
        originalSelector == null) {
      return source;
    }

    // 若 switch 前还有编译器生成的 label 与 Objects.requireNonNull，也一并移除
    var preludeStart = headerStart;
    final requireRe = RegExp(r'^(?:java\.util\.)?Objects\.requireNonNull\(' +
        RegExp.escape(originalSelector) +
        r'\);$');
    while (preludeStart > 0) {
      final prev = lines[preludeStart - 1].trim();
      if (prev.startsWith('label_') && prev.endsWith(':')) {
        preludeStart--;
        continue;
      }
      if (requireRe.hasMatch(prev)) {
        preludeStart--;
        continue;
      }
      break;
    }
    headerStart = preludeStart;
    final sel = selectorVar;
    final st = stateVar;
    final swLabel = switchLabel;

    // 2. 找到 switch 的右花括号
    int? switchCloseLine;
    for (var i = switchLine + 1; i < lines.length; i++) {
      if (lines[i] == '        }') {
        switchCloseLine = i;
        break;
      }
    }
    if (switchCloseLine == null) return source;

    // 2b. 若 javac 把部分 case 体包在 try/catch 中处理 MatchException，先剥掉该包装
    int? tryStart;
    for (var i = switchCloseLine + 1; i < lines.length; i++) {
      if (lines[i].trim() == 'try {') {
        tryStart = i;
        break;
      }
    }
    if (tryStart != null) {
      int? tryCloseLine;
      for (var i = tryStart + 1; i < lines.length; i++) {
        if (lines[i].contains('} catch (Throwable e) {')) {
          tryCloseLine = i;
          break;
        }
      }
      if (tryCloseLine != null) {
        int? catchEndLine;
        for (var i = tryCloseLine + 1; i < lines.length; i++) {
          if (lines[i].trim() == '}') {
            catchEndLine = i;
            break;
          }
        }
        if (catchEndLine != null) {
          final inner = lines.sublist(tryStart + 1, tryCloseLine);
          final unindented = inner
              .map((l) => l.startsWith('    ') ? l.substring(4) : l)
              .toList();
          lines.replaceRange(tryStart, catchEndLine + 1, unindented);
        }
      }
    }

    // 3. 解析 case -> label 映射（按 switch 中出现的顺序）
    final caseRe = RegExp(r'^            case (-?\d+): goto (label_\d+);$');
    final defaultRe = RegExp(r'^            default: goto (label_\d+);$');
    final cases = <({int value, String label})>[];
    String? defaultLabel;
    for (var i = switchLine + 1; i < switchCloseLine; i++) {
      final cm = caseRe.firstMatch(lines[i]);
      if (cm != null) {
        cases.add((value: int.parse(cm.group(1)!), label: cm.group(2)!));
        continue;
      }
      final dm = defaultRe.firstMatch(lines[i]);
      if (dm != null) {
        defaultLabel = dm.group(1);
      }
    }
    if (defaultLabel == null || cases.isEmpty) return source;

    // 4. 把 switch 后的代码切分成每个 case 的处理块
    // 每个 case 以模式变量声明开头：Type var = ((Type) selector);
    // 注意：switch 的 case 目标 label 现在会被打印出来，需要基于 label 定位。
    final anyLabelRe = RegExp(r'^      (label_\d+):$');

    // 建立 label -> 行号 映射
    final labelLineMap = <String, int>{};
    for (var i = switchCloseLine + 1; i < lines.length; i++) {
      final lm = anyLabelRe.firstMatch(lines[i]);
      if (lm != null) {
        labelLineMap[lm.group(1)!] = i;
      }
    }

    // 对每个 case，找到其 label 后的第一个非空行作为 block start
    final blockStarts = <int>[];
    for (final c in cases) {
      final labelLine = labelLineMap[c.label];
      if (labelLine == null) return source;
      var bs = labelLine + 1;
      while (bs < lines.length && lines[bs].trim().isEmpty) {
        bs++;
      }
      if (bs >= lines.length) return source;
      blockStarts.add(bs);
    }

    // default block
    int? defaultStartLine;
    int? exceptionStartLine;
    final defaultLabelLine = labelLineMap[defaultLabel];
    if (defaultLabelLine != null) {
      var dl = defaultLabelLine + 1;
      while (dl < lines.length && lines[dl].trim().isEmpty) {
        dl++;
      }
      defaultStartLine = dl;
      // 找到 default 后的下一个 label（异常处理块）
      for (var i = defaultLabelLine + 1; i < lines.length; i++) {
        if (anyLabelRe.hasMatch(lines[i])) {
          exceptionStartLine = i;
          break;
        }
      }
    }

    if (cases.length != blockStarts.length) {
      return source;
    }

    // 5. 逐个处理块，生成 case 子句
    final caseLines = <({bool isExpr, String body})>[];
    for (var ci = 0; ci < cases.length; ci++) {
      final start = blockStarts[ci];
      final end = (ci + 1 < blockStarts.length)
          ? blockStarts[ci + 1]
          : (defaultStartLine ?? lines.length);
      final block = lines.sublist(start, end);
      final caseLine = _patternCaseFromBlock(
        cases[ci].value,
        block,
        sel,
        st,
        swLabel,
      );
      if (caseLine != null) caseLines.add(caseLine);
    }

    // default 块
    if (defaultStartLine != null) {
      final end = exceptionStartLine ?? lines.length;
      final block = lines.sublist(defaultStartLine, end);
      final defaultLine =
          _patternCaseFromBlock(null, block, sel, st, swLabel, isDefault: true);
      if (defaultLine != null) caseLines.add(defaultLine);
    }

    if (caseLines.isEmpty) return source;

    // 6. 组装新的 switch
    // 若所有 case 都是表达式风格，生成 `return switch (...) { ... };`（表达式）
    // 否则生成语句风格的 `switch (...) { ... }`
    final allExpr = caseLines.every((c) => c.isExpr);
    final indent = '            ';
    final newSwitch = <String>[];
    if (allExpr) {
      newSwitch.add('        return switch ($originalSelector) {');
      for (final c in caseLines) {
        newSwitch.add('$indent${c.body}');
      }
      newSwitch.add('        };');
    } else {
      newSwitch.add('        switch ($originalSelector) {');
      for (final c in caseLines) {
        // 语句块可能跨多行，统一缩进
        for (final l in c.body.split('\n')) {
          newSwitch.add('$indent$l');
        }
      }
      newSwitch.add('        }');
    }

    // 7. 替换区域：把整个 pattern switch 生成的状态机替换为新的 switch
    //    只替换到状态机结束（exceptionStartLine 或最后一个 case 块结束位置），
    //    保留后续的 try-catch 等代码。
    final replaceEnd = exceptionStartLine ?? lines.length;
    lines.replaceRange(headerStart, replaceEnd, newSwitch);
    return '${lines.join('\n')}\n';
  }

  /// 把 `switch (var) { case N: goto label_X; ... }` 形式的字节码还原成
  /// 结构化的 switch-case 语句。仅处理每个 case 体都以 return/throw 结束、
  /// 不存在 fallthrough 的简单情形。
  String _structureSimpleSwitch(String source) {
    var lines = source.split('\n');

    final switchOpenRe = RegExp(r'^( {8,})switch \(([^)]+)\) \{$');
    final caseGotoRe = RegExp(r'^ +case (-?\d+): goto (label_\d+);$');
    final defaultGotoRe = RegExp(r'^ +default: goto (label_\d+);$');
    final anyLabelRe = RegExp(r'^ *(label_\d+):$');
    final gotoLabelRe = RegExp(r'goto (label_\d+);');

    bool changed;
    do {
      changed = false;

      final labelMap = <String, int>{};
      for (var i = 0; i < lines.length; i++) {
        final m = anyLabelRe.firstMatch(lines[i]);
        if (m != null) labelMap[m.group(1)!] = i;
      }

      for (var i = 0; i < lines.length; i++) {
        final sm = switchOpenRe.firstMatch(lines[i]);
        if (sm == null) continue;
        final indent = sm.group(1)!;
        final selector = sm.group(2)!;

        // 跳过 pattern switch（由 _structurePatternSwitch 处理）
        if (selector.startsWith('invokedynamic')) continue;

        // 找到 switch 结束 `}`
        late final int closeLine;
        var depth = 1;
        bool foundClose = false;
        for (var k = i + 1; k < lines.length; k++) {
          if (lines[k].contains('{')) depth++;
          if (lines[k].contains('}')) {
            depth--;
            if (depth == 0) {
              closeLine = k;
              foundClose = true;
              break;
            }
          }
        }
        if (!foundClose) continue;

        // 解析 case -> label 与 default -> label 映射
        final cases = <(int, String)>[];
        String? defaultLabel;
        for (var k = i + 1; k < closeLine; k++) {
          final cm = caseGotoRe.firstMatch(lines[k]);
          if (cm != null) {
            cases.add((int.parse(cm.group(1)!), cm.group(2)!));
            continue;
          }
          final dm = defaultGotoRe.firstMatch(lines[k]);
          if (dm != null) {
            defaultLabel = dm.group(1);
          }
        }
        if (cases.isEmpty || defaultLabel == null) continue;

        final allLabels = <String>[...cases.map((c) => c.$2), defaultLabel];

        // 检查所有 label 都存在且在 switch 之后
        bool valid = allLabels.every((l) {
          final pos = labelMap[l];
          return pos != null && pos > closeLine;
        });
        if (!valid) continue;

        // switch 后到第一个 case label 之间不能有未标记代码
        final sortedByPos = allLabels.toList()
          ..sort((a, b) => labelMap[a]!.compareTo(labelMap[b]!));
        final firstCasePos = labelMap[sortedByPos.first]!;
        for (var k = closeLine + 1; k < firstCasePos; k++) {
          if (lines[k].trim().isNotEmpty) {
            valid = false;
            break;
          }
        }
        if (!valid) continue;

        // 收集 switch 之后所有 label（按位置排序），用于确定 body 边界
        final switchAfterLabels = <(String, int)>[];
        for (var k = closeLine + 1; k < lines.length; k++) {
          final m = anyLabelRe.firstMatch(lines[k]);
          if (m != null) {
            switchAfterLabels.add((m.group(1)!, k));
          }
        }
        switchAfterLabels.sort((a, b) => a.$2.compareTo(b.$2));

        // 确定整个 switch 区域的结束：最后一个 case body 后的第一个非 case label
        final lastCasePos = labelMap[sortedByPos.last]!;
        int regionEnd = lines.length;
        for (final (label, pos) in switchAfterLabels) {
          if (pos > lastCasePos && !allLabels.contains(label)) {
            regionEnd = pos;
            break;
          }
        }

        // 提取指定 label 对应的 body（从 label 下一行到下一个 label）
        List<String> extractBody(String label) {
          final pos = labelMap[label]!;
          int bodyEnd = regionEnd;
          for (final entry in switchAfterLabels) {
            if (entry.$2 > pos) {
              bodyEnd = entry.$2;
              break;
            }
          }
          return lines
              .sublist(pos + 1, bodyEnd)
              .where((l) => l.trim().isNotEmpty)
              .toList();
        }

        // 检查所有 case body 都以 return/throw 结束（无 fallthrough）
        bool allBodiesTerminate = true;
        for (final label in allLabels) {
          final body = extractBody(label);
          if (body.isEmpty) {
            allBodiesTerminate = false;
            break;
          }
          final lastLine = body.last.trim();
          if (!lastLine.startsWith('return') && !lastLine.startsWith('throw')) {
            allBodiesTerminate = false;
            break;
          }
        }
        if (!allBodiesTerminate) continue;

        // 构建 case body（重新缩进到 switch 内部）
        final caseIndent = '$indent    ';
        final bodyIndent = '$caseIndent    ';
        String reindent(String line) {
          final trimmed = line.trimLeft();
          return '$bodyIndent$trimmed';
        }

        final newLines = <String>['${indent}switch ($selector) {'];
        for (final (caseValue, caseLabel) in cases) {
          final body = extractBody(caseLabel);
          newLines.add('${caseIndent}case $caseValue:');
          newLines.addAll(body.map(reindent));
        }
        final defaultBody = extractBody(defaultLabel);
        newLines.add('${caseIndent}default:');
        newLines.addAll(defaultBody.map(reindent));
        newLines.add('$indent}');

        // 若 regionEnd 处的 label 是未被引用的孤立尾部 label，一并移除
        int replaceEnd = regionEnd;
        if (regionEnd < lines.length) {
          final lm = anyLabelRe.firstMatch(lines[regionEnd]);
          if (lm != null) {
            final tailLabel = lm.group(1)!;
            bool referenced = false;
            for (var k = 0; k < lines.length; k++) {
              if (k == regionEnd) continue;
              if (gotoLabelRe.hasMatch(lines[k]) &&
                  lines[k].contains('goto $tailLabel;')) {
                referenced = true;
                break;
              }
            }
            if (!referenced) {
              replaceEnd = regionEnd + 1;
            }
          }
        }

        lines.replaceRange(i, replaceEnd, newLines);
        changed = true;
        break;
      }
    } while (changed);

    return lines.join('\n');
  }

  /// 处理结果：可能是单表达式（`return/throw expr;`），也可能是语句块。
  /// 当 [isExpr] 为 true 时 [body] 是单个表达式，否则是已经缩进好的语句行。
  ({bool isExpr, String body})? _patternCaseFromBlock(
    int? caseValue,
    List<String> block,
    String selectorVar,
    String stateVar,
    String? switchLabel, {
    bool isDefault = false,
  }) {
    if (block.isEmpty) return null;

    // 找到结果表达式：块中最后一个 `return expr;` 或 `throw expr;`
    String? resultExpr;
    for (var i = block.length - 1; i >= 0; i--) {
      final m = RegExp(r'^        (return|throw) (.+);$').firstMatch(block[i]);
      if (m != null) {
        resultExpr = m.group(1) == 'throw' ? 'throw ${m.group(2)}' : m.group(2);
        break;
      }
    }

    // 没有返回/抛出表达式 -> 按语句块处理
    if (resultExpr == null) {
      return _patternCaseFromBlockStmt(
        caseValue,
        block,
        selectorVar,
        stateVar,
        switchLabel,
        isDefault: isDefault,
      );
    }

    resultExpr = resultExpr.replaceAllMapped(
        RegExp(r'(?:java\.lang\.)?String\.valueOf\(([^)]+)\)'),
        (m) => m.group(1)!);

    // 默认块 / null 块
    if (isDefault) {
      return (isExpr: true, body: 'default -> $resultExpr;');
    }
    if (caseValue == -1) {
      return (isExpr: true, body: 'case null -> $resultExpr;');
    }

    // 找到模式变量声明：Type v = ((Type) selector);
    final castRe = RegExp(r'^        (\S+(?:<[^>]+>)?) (\w+) = \(\(\1\) ' +
        RegExp.escape(selectorVar) +
        r'\);$');
    String? patternType;
    String? patternVar;
    int? castLine;
    for (var i = 0; i < block.length; i++) {
      final m = castRe.firstMatch(block[i]);
      if (m != null) {
        patternType = m.group(1);
        patternVar = m.group(2);
        castLine = i;
        break;
      }
    }
    if (patternVar == null || patternType == null || castLine == null) {
      return null;
    }
    final castLineIdx = castLine;

    // 收集组件访问别名：compVar = patternVar.method();
    final aliasMap = <String, String>{};
    final compRe = RegExp(r'^ *(?:\S+(?:<[^>]+>)? )?(\w+) = ' +
        RegExp.escape(patternVar) +
        r'\.(\w+)\(\);$');
    final aliasRe = RegExp(r'^ *(?:\S+(?:<[^>]+>)? )?(\w+) = (\w+);$');
    for (var i = castLineIdx + 1; i < block.length; i++) {
      final line = block[i];
      final cm = compRe.firstMatch(line);
      if (cm != null) {
        aliasMap[cm.group(1)!] = '$patternVar.${cm.group(2)!}()';
        continue;
      }
      final am = aliasRe.firstMatch(line);
      if (am != null) {
        final src = am.group(2)!;
        if (aliasMap.containsKey(src)) {
          aliasMap[am.group(1)!] = aliasMap[src]!;
        }
      }
    }

    resultExpr = _replaceAliasNames(resultExpr, aliasMap).replaceAllMapped(
        RegExp(r'(?:java\.lang\.)?String\.valueOf\(([^)]+)\)'),
        (m) => m.group(1)!);

    // 探测 guard：
    // 1) 失败重试型：if (cond) { state = N; goto switch; } ... return expr;
    // 2) 成功返回型：if (cond) goto label_true;  label_true: return expr;
    String? guard;
    final retryIfRe = RegExp(r'^ *if \((.+)\) \{$');
    for (var i = castLineIdx + 1;
        i < block.length && switchLabel != null;
        i++) {
      final m = retryIfRe.firstMatch(block[i]);
      if (m == null) continue;
      final cond = m.group(1)!;
      if (_isTrivialCondition(cond)) continue;
      var retries = false;
      for (var k = i + 1;
          k < block.length && !block[k].startsWith('        }');
          k++) {
        if (block[k].contains('goto $switchLabel;')) {
          retries = true;
          break;
        }
      }
      if (retries) {
        guard = _simplifyDoubleNegation(
            _replaceAliasNames(_negateCondition(cond), aliasMap));
        break;
      }
    }

    final trueGuardRe = RegExp(r'^ *if \((.+)\) goto (label_\d+);$');
    for (var i = castLineIdx + 1; i < block.length && guard == null; i++) {
      final m = trueGuardRe.firstMatch(block[i]);
      if (m == null) continue;
      final cond = m.group(1)!;
      final target = m.group(2)!;
      if (_isTrivialCondition(cond)) continue;
      for (var k = i + 1; k < block.length; k++) {
        if (block[k].trim() == '$target:') {
          guard = _simplifyDoubleNegation(_replaceAliasNames(cond, aliasMap));
          break;
        }
      }
      if (guard != null) break;
    }

    final guardPart = guard != null ? ' when $guard' : '';
    final simpleType = _simplifyTypeName(patternType);
    return (
      isExpr: true,
      body: 'case $simpleType $patternVar$guardPart -> $resultExpr;',
    );
  }

  /// 处理不含 `return/throw` 的 case 块（语句风格），收集有效语句生成 case 体。
  ({bool isExpr, String body})? _patternCaseFromBlockStmt(
    int? caseValue,
    List<String> block,
    String selectorVar,
    String stateVar,
    String? switchLabel, {
    bool isDefault = false,
  }) {
    final gotoRe = RegExp(r'^ *goto (label_\d+);$');
    final labelRe = RegExp(r'^ *(label_\d+):$');

    // 1. 提取模式变量（cast 行）
    final castRe = RegExp(r'^        (\S+(?:<[^>]+>)?) (\w+) = \(\(\1\) ' +
        RegExp.escape(selectorVar) +
        r'\);$');
    String? patternType;
    String? patternVar;
    int? castLineIdx;
    if (!isDefault && caseValue != -1) {
      for (var i = 0; i < block.length; i++) {
        final m = castRe.firstMatch(block[i]);
        if (m != null) {
          patternType = _simplifyTypeName(m.group(1)!);
          patternVar = m.group(2);
          castLineIdx = i;
          break;
        }
      }
    }

    // 2. 按行顺序跟踪变量含义，处理变量复用
    // varMeaning: variable -> 'accessor:NAME' 或 'alias:VAR'
    final varMeaning = <String, String>{};
    final usedAccessors = <String>{};
    final skipLines = <int>{};
    final accessorFirstVar = <String, String>{};

    if (patternVar != null) {
      final compRe = RegExp(r'^ *(?:\S+(?:<[^>]+>)? )?(\w+) = ' +
          RegExp.escape(patternVar) +
          r'\.(\w+)\(\);$');
      final aliasRe = RegExp(r'^ *(?:\S+(?:<[^>]+>)? )?(\w+) = (\w+);$');

      for (var k = (castLineIdx ?? -1) + 1; k < block.length; k++) {
        final line = block[k];
        final cm = compRe.firstMatch(line);
        if (cm != null) {
          final v = cm.group(1)!;
          final acc = cm.group(2)!;
          varMeaning[v] = 'accessor:$acc';
          accessorFirstVar.putIfAbsent(acc, () => v);
          skipLines.add(k);
          continue;
        }
        final am = aliasRe.firstMatch(line);
        if (am != null) {
          final v = am.group(1)!;
          final src = am.group(2)!;
          if (varMeaning.containsKey(src)) {
            varMeaning[v] = varMeaning[src]!;
            skipLines.add(k);
            continue;
          }
        }
        // 其他行：检查引用了哪些变量，标记 accessor 为已使用
        for (final entry in varMeaning.entries) {
          if (RegExp(r'\b' + RegExp.escape(entry.key) + r'\b').hasMatch(line)) {
            if (entry.value.startsWith('accessor:')) {
              usedAccessors.add(entry.value.substring('accessor:'.length));
            }
          }
        }
      }
    }

    // 3. 收集有效语句
    final stmts = <String>[];
    final stateAssignRe =
        RegExp(r'^ *' + RegExp.escape(stateVar) + r' = \d+;$');
    final stateResetRe = RegExp(r'^ *' + RegExp.escape(stateVar) + r' = -1;$');

    // 重新按行计算含义（因为变量可能被复用）
    final currentMeaning = <String, String>{};
    if (castLineIdx != null) {
      // 从 cast 行之后开始
    }

    for (var i = 0; i < block.length; i++) {
      final line = block[i];
      final trimmed = line.trim();

      if (trimmed.isEmpty) continue;
      // 跳过 cast 行
      if (i == castLineIdx) continue;
      // 跳过 goto
      if (gotoRe.hasMatch(line)) continue;
      // 跳过 label
      if (labelRe.hasMatch(line)) continue;
      // 跳过状态变量赋值
      if (stateAssignRe.hasMatch(line) || stateResetRe.hasMatch(line)) continue;
      // 跳过编译器生成的 null 检查
      if (line.contains('Objects.requireNonNull')) continue;
      // 跳过 instanceof 检查残留
      if (RegExp(r'^ *if \(\((\w+) instanceof').hasMatch(line)) continue;

      // 跳过 if (cond) { state = N; goto switch; } 形式的重试代码
      final retryIfRe = RegExp(r'^ *if \((.+)\) \{$');
      final m = retryIfRe.firstMatch(line);
      if (m != null) {
        var isRetry = false;
        for (var k = i + 1; k < block.length; k++) {
          if (block[k].trim() == '}') break;
          if (gotoRe.hasMatch(block[k])) {
            final gm = gotoRe.firstMatch(block[k]);
            if (gm != null && gm.group(1) == switchLabel) {
              isRetry = true;
              break;
            }
          }
        }
        if (isRetry) {
          i++;
          while (i < block.length && block[i].trim() != '}') {
            i++;
          }
          continue;
        }
      }

      // 如果是组件提取或别名声明行，更新 currentMeaning 并跳过
      if (patternVar != null && skipLines.contains(i)) {
        final compRe = RegExp(r'^ *(?:\S+(?:<[^>]+>)? )?(\w+) = ' +
            RegExp.escape(patternVar) +
            r'\.(\w+)\(\);$');
        final aliasRe = RegExp(r'^ *(?:\S+(?:<[^>]+>)? )?(\w+) = (\w+);$');
        final cm = compRe.firstMatch(line);
        if (cm != null) {
          currentMeaning[cm.group(1)!] = 'accessor:${cm.group(2)!}';
          continue;
        }
        final am = aliasRe.firstMatch(line);
        if (am != null) {
          final v = am.group(1)!;
          final src = am.group(2)!;
          if (currentMeaning.containsKey(src)) {
            currentMeaning[v] = currentMeaning[src]!;
          }
          continue;
        }
      }

      // 替换变量引用为 accessor 名
      var processed = line;
      if (patternVar != null) {
        for (final entry in currentMeaning.entries) {
          if (entry.value.startsWith('accessor:')) {
            final acc = entry.value.substring('accessor:'.length);
            if (usedAccessors.contains(acc)) {
              processed = processed.replaceAll(
                RegExp(r'\b' + RegExp.escape(entry.key) + r'\b'),
                acc,
              );
            }
          }
        }
      }
      processed = _simplifyTypeNamesInLine(processed);
      stmts.add(processed);
    }

    if (stmts.isEmpty) {
      if (isDefault) {
        return (isExpr: false, body: 'default -> {}');
      }
      return null;
    }

    // 4. 构造 case 头部
    String caseHead;
    if (isDefault) {
      caseHead = 'default -> {';
    } else if (caseValue == -1) {
      caseHead = 'case null -> {';
    } else if (patternType != null && patternVar != null) {
      // 如果有组件提取，构造 record pattern
      if (accessorFirstVar.isNotEmpty) {
        final accessors = accessorFirstVar.keys.toList()..sort();
        final parts = accessors.map((acc) {
          return usedAccessors.contains(acc) ? acc : '_';
        }).join(', ');
        caseHead = 'case $patternType($parts) -> {';
      } else {
        caseHead = 'case $patternType $patternVar -> {';
      }
    } else {
      caseHead = 'case $caseValue -> {';
    }

    // 5. 缩进语句
    final indentedStmts = stmts.map((s) {
      var stripped = s.replaceFirst(RegExp(r'^ +'), '');
      return '    $stripped';
    }).toList();

    final body = '$caseHead\n${indentedStmts.join('\n')}\n}';
    return (isExpr: false, body: body);
  }

  /// 在一行中简化 java.lang. 类型前缀
  String _simplifyTypeNamesInLine(String line) {
    return line.replaceAllMapped(
      RegExp(r'java\.lang\.(\w+)'),
      (m) => m.group(1)!,
    );
  }

  String _simplifyTypeName(String type) {
    const prefix = 'java.lang.';
    if (type.startsWith(prefix)) return type.substring(prefix.length);
    return type;
  }

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
  List<String> _reindentBlock(List<String> lines, String targetIndent) {
    if (lines.isEmpty) return lines;
    // 找到第一个非空行的原始缩进作为基准
    var baseIndentLen = -1;
    for (final l in lines) {
      if (l.trim().isEmpty) continue;
      baseIndentLen = l.length - l.trimLeft().length;
      break;
    }
    if (baseIndentLen < 0) return lines;

    final targetLen = targetIndent.length;
    return lines.map((l) {
      if (l.trim().isEmpty) return '';
      final currentIndent = l.length - l.trimLeft().length;
      final diff = currentIndent - baseIndentLen;
      final newLen = targetLen + diff < 0 ? 0 : targetLen + diff;
      final newIndent = ' ' * newLen;
      return '$newIndent${l.trimLeft()}';
    }).toList();
  }

  String _simplifyDoubleNegation(String cond) {
    var result = cond.trim();
    while (true) {
      if (result.startsWith('!(') && result.endsWith(')')) {
        final inner = result.substring(2, result.length - 1).trim();
        if (inner.startsWith('!')) {
          result = inner.substring(1).trim();
          continue;
        }
      }
      if (result.startsWith('!!')) {
        result = result.substring(2).trim();
        continue;
      }
      break;
    }
    return result;
  }

  /// 利用 LocalVariableTable 把生成的 pN 变量名还原成源码中的名字。
  String _restoreVariableNames(String source) {
    LocalVariableTableAttribute? lvt;
    for (final attr in _method.attributes) {
      if (attr is LocalVariableTableAttribute) {
        lvt = attr;
        break;
      }
    }
    if (lvt == null) return source;

    final renames = <int, String>{};
    for (final e in lvt.localVariableTable) {
      final name = _pool.getString(e.nameIndex);
      if (name.isEmpty) continue;
      if (!renames.containsKey(e.index)) {
        renames[e.index] = name;
      }
    }
    if (renames.isEmpty) return source;

    final entries = renames.entries.toList()
      ..sort((a, b) => b.key.compareTo(a.key));
    var result = source;
    for (final e in entries) {
      final from = 'p${e.key}';
      result = result.replaceAll(
          RegExp(r'\b' + RegExp.escape(from) + r'\b'), e.value);
    }
    return result;
  }
}
