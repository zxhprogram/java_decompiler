part of 'code_printer.dart';

/// 后处理简化 pass：布尔返回、短路展平、条件简化、装箱拆箱、
/// 标签清理、栈下溢移除等。
extension on CodePrinter {
  /// 对返回类型为 boolean 的方法，把 `return 0;`/`return 1;` 转换为
  /// `return false;`/`return true;`，让源码更贴近原始 Java 写法。
  String _simplifyBooleanReturns(String source) {
    final descriptor = _pool.getString(_method.descriptorIndex);
    final returnType = DescriptorParser.parseMethodDescriptor(descriptor).$2;
    if (returnType != 'boolean') return source;
    return source
        .replaceAllMapped(
          RegExp(r'return 0;'),
          (m) => 'return false;',
        )
        .replaceAllMapped(
          RegExp(r'return 1;'),
          (m) => 'return true;',
        );
  }

  /// 把 `if (!A) { if (!B) return X; } return Y;` 形式的嵌套短路返回
  /// 展平为 `if (A) return Y; if (B) return Y; return X;`，
  /// 让控制流更扁平、更易读。
  ///
  /// 这是 `A || B` 编译后的典型模式：
  ///   if (A) goto trueLabel;
  ///   if (!B) goto falseLabel;
  /// trueLabel: return Y;
  /// falseLabel: return X;
  /// 提升后变成 `if (!A) { if (!B) return X; } return Y;`，
  /// 进一步展平为两个独立的条件返回。
  String _flattenShortCircuitReturns(String source) {
    final lines = source.split('\n');
    final ifOpenRe = RegExp(r'^( +)if \((.+)\) \{$');
    final ifReturnRe = RegExp(r'^( +)if \((.+)\) (return .+;|throw .+;)$');
    final returnRe = RegExp(r'^ +return (.+);$');
    final closeRe = RegExp(r'^( +)\}$');

    bool changed;
    do {
      changed = false;
      for (var i = 0; i < lines.length - 3; i++) {
        // 匹配 `if (!A) {`
        final outer = ifOpenRe.firstMatch(lines[i]);
        if (outer == null) continue;
        final outerIndent = outer.group(1)!;
        final outerCond = outer.group(2)!;
        // 只处理 `!A` 形式
        if (!outerCond.startsWith('!')) continue;

        // 下一行是 `if (!B) return X;`（单行 if-return，更深缩进）
        final inner = ifReturnRe.firstMatch(lines[i + 1]);
        if (inner == null) continue;
        final innerIndent = inner.group(1)!;
        if (innerIndent.length != outerIndent.length + 4) continue;
        final innerCond = inner.group(2)!;
        if (!innerCond.startsWith('!')) continue;
        final innerReturn = inner.group(3)!;

        // 下一行是 `}`（与外层 if 同缩进）
        final close = closeRe.firstMatch(lines[i + 2]);
        if (close == null) continue;
        if (close.group(1)! != outerIndent) continue;

        // 下一行是 `return Y;`（与外层 if 同缩进）
        final outerReturnM = returnRe.firstMatch(lines[i + 3]);
        if (outerReturnM == null) continue;
        // 检查缩进
        final outerReturnIndent =
            RegExp(r'^( +)').firstMatch(lines[i + 3])!.group(1)!;
        if (outerReturnIndent != outerIndent) continue;
        final outerReturn = 'return ${outerReturnM.group(1)};';

        // 展平：`if (A) return Y; if (B) return Y; return X;`
        // A = outerCond 去掉 !，B = innerCond 去掉 !
        final a = _stripNot(outerCond);
        final b = _stripNot(innerCond);
        final newLines = <String>[
          '${outerIndent}if ($a) $outerReturn',
          '${outerIndent}if ($b) $outerReturn',
          '$outerIndent$innerReturn',
        ];
        lines.replaceRange(i, i + 4, newLines);
        changed = true;
        break;
      }
    } while (changed);

    return lines.join('\n');
  }

  /// 去掉条件最外层的 `!`，处理 `!(expr)` 和 `!var` 两种形式。
  String _stripNot(String cond) {
    final trimmed = cond.trim();
    if (trimmed.startsWith('!(') && trimmed.endsWith(')')) {
      return trimmed.substring(2, trimmed.length - 1);
    }
    if (trimmed.startsWith('!')) {
      return trimmed.substring(1);
    }
    return trimmed;
  }

  /// 简化条件表达式中的冗余比较：
  /// - `expr == 0` → `!expr`（当 expr 是 boolean/method 调用时）
  /// - `expr != 0` → `expr`
  /// 仅在 if 条件中应用，避免改变赋值表达式语义。
  String _simplifyConditions(String source) {
    // 收集 boolean 类型的参数名（如 p2），用于简化 `p2 == 0` → `!p2`
    final booleanParams = <String>{};
    final paramTypes = _parameterTypes();
    final isStatic = (_method.accessFlags & AccessFlags.ACC_STATIC) != 0;
    var slot = isStatic ? 0 : 1;
    for (final t in paramTypes) {
      if (t == 'boolean') booleanParams.add('p$slot');
      slot++;
      if (t == 'long' || t == 'double') slot++;
    }

    final lines = source.split('\n');
    // 手动匹配 `if (cond) rest`，其中 cond 内部可能含括号，需平衡。
    final ifStartRe = RegExp(r'^( +)if \(');

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final sm = ifStartRe.firstMatch(line);
      if (sm == null) continue;
      final indent = sm.group(1)!;
      // 从 `if (` 之后开始，找到匹配的 `)`
      var depth = 1;
      var start = sm.end;
      var end = -1;
      for (var k = start; k < line.length; k++) {
        final c = line[k];
        if (c == '(') depth++;
        if (c == ')') {
          depth--;
          if (depth == 0) {
            end = k;
            break;
          }
        }
      }
      if (end < 0) continue;
      final cond = line.substring(start, end);
      final rest = line.substring(end + 1);
      final simplified = _simplifyBoolCond(cond, booleanParams);
      if (simplified != cond) {
        lines[i] = '${indent}if ($simplified)$rest';
      }
    }
    return lines.join('\n');
  }

  /// 简化布尔条件：`expr == 0` → `!expr`，`expr != 0` → `expr`。
  /// 仅当 expr 看起来是布尔表达式（方法调用、boolean 变量）时应用。
  String _simplifyBoolCond(String cond, [Set<String>? booleanParams]) {
    final trimmed = cond.trim();
    // expr == 0 → !expr
    final eq0 = RegExp(r'^(.+) == 0$').firstMatch(trimmed);
    if (eq0 != null) {
      final inner = eq0.group(1)!.trim();
      // 避免对数值表达式简化（如 i == 0 应保留）
      if (_looksBoolean(inner, booleanParams)) {
        return '!$inner';
      }
    }
    // expr != 0 → expr
    final ne0 = RegExp(r'^(.+) != 0$').firstMatch(trimmed);
    if (ne0 != null) {
      final inner = ne0.group(1)!.trim();
      if (_looksBoolean(inner, booleanParams)) {
        return inner;
      }
    }
    return cond;
  }

  /// 判断表达式是否看起来是布尔类型（方法调用、已带 ! 的表达式、boolean 参数）。
  /// 注意：仅对显式识别的 boolean 参数（如方法签名中标记为 boolean 的 p0/p1 等）
  /// 简化，避免误把数值变量的 `== 0`/`!= 0` 简化为 `!var`/`var`。
  bool _looksBoolean(String expr, [Set<String>? booleanParams]) {
    // 方法调用（含 .equals, .contains, .isEmpty 等）
    if (expr.contains('(') && expr.contains(')')) return true;
    // 已经是 !expr 形式
    if (expr.startsWith('!')) return true;
    // 已知 boolean 参数（通过方法签名识别）
    if (booleanParams != null && booleanParams.contains(expr.trim())) {
      return true;
    }
    return false;
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
          '$indent}',
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
}
