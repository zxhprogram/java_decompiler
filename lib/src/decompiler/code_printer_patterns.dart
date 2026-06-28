part of 'code_printer.dart';

/// 模式匹配：instanceof record pattern 预处理与残留清理。
extension on CodePrinter {
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

    // 1b. 简化原始类型 instanceof 模式（JDK 23+ preview）
    //     字节码模式：
    //     ```
    //     Type pN = selector;
    //     if (pN == null) goto label_A;
    //     if ((pN instanceof java.lang.Wrapper) == 0) goto label_A;
    //     goto label_B;
    //   label_A:
    //   label_B:
    //     if (0 == 0) goto label_C;   // 永真条件，跳过 then 块
    //     prim p2 = ((java.lang.Wrapper) selector).xxxValue();
    //     <then body>
    //   label_C:
    //     ```
    //     还原为：
    //     ```
    //     if (selector instanceof prim p2) {
    //       <then body>
    //     }
    //     ```
    lines = _simplifyPrimitiveInstanceofPattern(lines);

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

  /// 简化原始类型 instanceof 模式（JDK 23+ preview）。
  /// 详见 _preprocessPatternMatching 中的注释。
  List<String> _simplifyPrimitiveInstanceofPattern(List<String> lines) {
    // 模式行正则
    // 变量赋值：`java.lang.Object pN = selector;` 或 `pN = selector;`（复用变量）
    final assignRe = RegExp(r'^ +(?:java\.lang\.Object )?(\w+) = (\w+);$');
    final nullCheckRe = RegExp(r'^ +if \((\w+) == null\) goto (label_\d+);$');
    final instanceofRe = RegExp(
        r'^ +if \(\((\w+) instanceof java\.lang\.(\w+)\) == 0\) goto (label_\d+);$');
    final gotoRe = RegExp(r'^ +goto (label_\d+);$');
    final labelRe = RegExp(r'^ +(label_\d+):$');
    final constCondRe = RegExp(r'^ +if \(0 == 0\) goto (label_\d+);$');
    final unboxRe = RegExp(
        r'^ +(\w+) (\w+) = \(\(java\.lang\.(\w+)\) (\w+)\)\.(\w+Value\(\));$');

    // 包装类 -> 原始类型 映射
    const wrapperToPrim = {
      'Integer': 'int',
      'Long': 'long',
      'Float': 'float',
      'Double': 'double',
      'Byte': 'byte',
      'Short': 'short',
      'Character': 'char',
      'Boolean': 'boolean',
    };

    for (var i = 0; i < lines.length; i++) {
      if (i + 7 >= lines.length) break;
      // 1. Object pN = selector;
      final am = assignRe.firstMatch(lines[i]);
      if (am == null) continue;
      final tmpVar = am.group(1)!;
      final selector = am.group(2)!;

      // 2. if (pN == null) goto label_A;
      final ncm = nullCheckRe.firstMatch(lines[i + 1]);
      if (ncm == null || ncm.group(1) != tmpVar) continue;
      final failLabel = ncm.group(2)!;

      // 3. if ((pN instanceof java.lang.Wrapper) == 0) goto label_A;
      final iom = instanceofRe.firstMatch(lines[i + 2]);
      if (iom == null || iom.group(1) != tmpVar) continue;
      if (iom.group(3) != failLabel) continue;
      final wrapperName = iom.group(2)!;
      final primName = wrapperToPrim[wrapperName];
      if (primName == null) continue;

      // 4. goto label_B;
      final gm = gotoRe.firstMatch(lines[i + 3]);
      if (gm == null) continue;
      final successLabel = gm.group(1)!;

      // 5. label_A:
      final lm1 = labelRe.firstMatch(lines[i + 4]);
      if (lm1 == null || lm1.group(1) != failLabel) continue;

      // 6. label_B:
      final lm2 = labelRe.firstMatch(lines[i + 5]);
      if (lm2 == null || lm2.group(1) != successLabel) continue;

      // 7. if (0 == 0) goto label_C;
      final ccm = constCondRe.firstMatch(lines[i + 6]);
      if (ccm == null) continue;
      final endLabel = ccm.group(1)!;

      // 8. prim p2 = ((java.lang.Wrapper) selector).xxxValue();
      final um = unboxRe.firstMatch(lines[i + 7]);
      if (um == null || um.group(3) != wrapperName || um.group(4) != selector) {
        continue;
      }
      final primVar = um.group(2)!;

      // 找到 label_C 的位置（then 块结束）
      int? endLabelIdx;
      for (var k = i + 8; k < lines.length; k++) {
        final lm = labelRe.firstMatch(lines[k]);
        if (lm != null && lm.group(1) == endLabel) {
          endLabelIdx = k;
          break;
        }
      }
      if (endLabelIdx == null) continue;

      // 提取 then 块（i+8 到 endLabelIdx-1），去掉 unbox 行（i+7）
      final thenBlock = <String>[];
      for (var k = i + 8; k < endLabelIdx; k++) {
        final line = lines[k];
        if (line.trim().isEmpty) continue;
        // 去掉一层缩进
        if (line.startsWith('        ')) {
          thenBlock.add('            ${line.substring(8)}');
        } else {
          thenBlock.add('            $line');
        }
      }

      // 构造新的 if 块：`if (selector instanceof prim primVar) { ... }`
      final newLines = <String>[];
      newLines.add('        if ($selector instanceof $primName $primVar) {');
      newLines.addAll(thenBlock);
      newLines.add('        }');

      // 替换 i 到 endLabelIdx-1
      lines.replaceRange(i, endLabelIdx, newLines);
      i += newLines.length - 1;
    }

    return lines;
  }

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
            if (c == '{') {
              depth++;
            } else if (c == '}') {
              depth--;
            }
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
              if (c == '{') {
                depth++;
              } else if (c == '}') {
                depth--;
              }
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
}
