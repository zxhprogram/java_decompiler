part of 'code_printer.dart';

/// 控制流结构化：if-else / while / for / for-each / do-while /
/// try-catch 结构还原。
extension on CodePrinter {
  /// 把 `if (cond) goto label_X; ... label_X: <terminator>;` 模式提升为
  /// `if (cond) <terminator>;`，从而消除冗余标号、简化控制流。
  ///
  /// terminator 指会终结当前基本块的语句，例如 `return`、`throw`、`goto`。
  /// 这种模式常见于 `A || B`、`A && B` 编译后的短路字节码：
  ///   if (A) goto trueLabel;
  ///   if (!B) goto falseLabel;
  /// trueLabel:
  ///   return 1;
  /// falseLabel:
  ///   return 0;
  /// 转换后：
  ///   if (A) return 1;
  ///   if (!B) return 0;
  String _liftIfGotoToTerminator(String source) {
    final lines = source.split('\n');
    final gotoRe = RegExp(r'^( +)if \((.+)\) goto (label_\d+);$');
    final labelRe = RegExp(r'^( *)(label_\d+):$');
    final terminatorRe = RegExp(r'^ +(?:return|throw|goto )');

    bool changed;
    do {
      changed = false;
      final labelMap = <String, int>{};
      for (var i = 0; i < lines.length; i++) {
        final m = labelRe.firstMatch(lines[i]);
        if (m != null) labelMap[m.group(2)!] = i;
      }

      // 从后往前处理，避免索引变动影响。
      for (var i = lines.length - 1; i >= 0; i--) {
        final m = gotoRe.firstMatch(lines[i]);
        if (m == null) continue;
        final indent = m.group(1)!;
        final cond = m.group(2)!;
        final label = m.group(3)!;
        final j = labelMap[label];
        if (j == null || j <= i) continue;

        // 收集 label 处连续的标号行（可能有多个标号在同一位置）。
        var k = j;
        final labelsHere = <String>[];
        while (k < lines.length && labelRe.hasMatch(lines[k])) {
          final lm = labelRe.firstMatch(lines[k])!;
          labelsHere.add(lm.group(2)!);
          k++;
        }
        if (k >= lines.length) continue;
        // label 后的第一条实际语句必须是终结语句。
        if (!terminatorRe.hasMatch(lines[k])) continue;

        // 该终结语句只能是这条 goto 引用此 label，
        // 否则其他跳转点也需要执行该终结语句，提升会改变语义。
        // 这里检查：当前 label 的所有引用点，提升只能针对当前 goto。
        // 简单起见：如果 label 被多个 goto 引用，跳过（保守策略）。
        var refCount = 0;
        for (var r = 0; r < lines.length; r++) {
          if (lines[r].contains('goto $label;')) refCount++;
        }
        if (refCount != 1) continue;

        // 关键检查：label 前一行必须是终结语句（return/throw/goto/}），
        // 否则 label 会被 fall-through 到达，提升会丢失该路径。
        // label 前一行是 j-1（如果 j > 0）。
        if (j > 0) {
          lines[j - 1].trim();
          // 跳过空行
          var pl = j - 1;
          while (pl >= 0 && lines[pl].trim().isEmpty) {
            pl--;
          }
          if (pl >= 0) {
            final plTrimmed = lines[pl].trim();
            // 终结语句：return, throw, goto, } 结尾, if (...) goto
            final isTerminator = plTrimmed.startsWith('return ') ||
                plTrimmed.startsWith('throw ') ||
                plTrimmed.startsWith('goto ') ||
                plTrimmed == '}' ||
                RegExp(r'^if \(.+\) goto label_\d+;$').hasMatch(plTrimmed);
            if (!isTerminator) {
              // label 会被 fall-through 到达，不能提升
              continue;
            }
          }
        }

        // body（if 到 label 之间）不能有未处理的 goto 跳到其他位置，
        // 否则提升后控制流会错乱。这里放宽限制：允许 body 有任意内容，
        // 因为提升只影响 label 处的语句，body 的控制流保持不变。

        // 检查其他标号是否也被引用，如果 labelsHere 中有其他标号被引用，
        // 不能删除它们。
        final otherLabelsReferenced = <String>{};
        for (final lb in labelsHere) {
          if (lb == label) continue;
          for (var r = 0; r < lines.length; r++) {
            if (lines[r].contains('goto $lb;')) {
              otherLabelsReferenced.add(lb);
              break;
            }
          }
        }
        // 简化处理：如果 otherLabelsReferenced 非空，跳过（保守）
        if (otherLabelsReferenced.isNotEmpty) continue;

        // 提升：在 if 行后插入 `if (cond) <terminator>;`
        // 重新构建：保留 i 之前，插入新的 if+terminator，保留 i+1 到 j-1（body），
        // 跳过 j 到 k（labels 和 terminator），保留 k+1 之后
        final terminatorLine = lines[k];
        final result = <String>[
          ...lines.sublist(0, i),
          '${indent}if ($cond) ${terminatorLine.trim()}',
          ...lines.sublist(i + 1, j),
          ...lines.sublist(k + 1),
        ];
        lines
          ..clear()
          ..addAll(result);
        changed = true;
        break;
      }
    } while (changed);

    return lines.join('\n');
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
    if (eq0 != null) {
      final inner = eq0.group(1)!.trim();
      // 对 boolean 表达式（方法调用等）简化为 expr；对变量保留比较形式
      return _looksBoolean(inner) ? inner : '$inner != 0';
    }
    final ne0 = RegExp(r'^(.+) != 0$').firstMatch(cond);
    if (ne0 != null) {
      final inner = ne0.group(1)!.trim();
      return _looksBoolean(inner) ? '!$inner' : '$inner == 0';
    }
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

  /// 把共享同一合并标号的 if 链还原为 if / else if / else 结构。
  /// 识别模式（_structureIfs 已将条件分支包成 if 块，但 then 末尾残留 goto merge）：
  ///   if (cond1) {
  ///       body1;
  ///       goto merge;
  ///   }
  ///   if (cond2) {
  ///       body2;
  ///       goto merge;
  ///   }
  ///   elseBody;
  /// merge:
  /// 转换为：
  ///   if (cond1) {
  ///       body1;
  ///   } else if (cond2) {
  ///       body2;
  ///   } else {
  ///       elseBody;
  ///   }
  /// 要求 merge 只被链内 goto 引用，以便一并消除标号。
  String _structureIfElseIfChain(String source) {
    var lines = source.split('\n');
    final openIfRe = RegExp(r'^( {8,})if \((.+)\) \{$');
    final labelRe = RegExp(r'^ {6,}(label_\d+):$');
    final gotoAnyRe = RegExp(r'goto (label_\d+);');

    bool changed;
    do {
      changed = false;
      final labelMap = <String, int>{};
      for (var i = 0; i < lines.length; i++) {
        final m = labelRe.firstMatch(lines[i]);
        if (m != null) labelMap[m.group(1)!] = i;
      }

      for (var i = 0; i < lines.length; i++) {
        final open = openIfRe.firstMatch(lines[i]);
        if (open == null) continue;
        final indent = open.group(1)!;
        final gotoInBlockRe = RegExp(r'^' + indent + r'    goto (label_\d+);$');

        // 收集连续的、都以 `goto merge;` 结尾的 if 块链。
        final chain = <(int ifLine, int closeLine, int gotoLine)>[];
        String? mergeLabel;
        var curIf = i;
        while (curIf < lines.length) {
          final curOpen = openIfRe.firstMatch(lines[curIf]);
          if (curOpen == null) break;
          // 找到配对的右花括号。
          int? curClose;
          var depth = 1;
          for (var k = curIf + 1; k < lines.length; k++) {
            if (lines[k].contains('{')) depth++;
            if (lines[k].contains('}')) {
              depth--;
              if (depth == 0) {
                curClose = k;
                break;
              }
            }
          }
          if (curClose == null) break;

          // 在 then 分支末尾找 `goto merge;`。
          int? curGoto;
          String? curMerge;
          for (var k = curClose - 1; k > curIf; k--) {
            final gm = gotoInBlockRe.firstMatch(lines[k]);
            if (gm != null) {
              curGoto = k;
              curMerge = gm.group(1);
              break;
            }
          }
          if (curGoto == null || curMerge == null) break;

          if (mergeLabel == null) {
            mergeLabel = curMerge;
          } else if (curMerge != mergeLabel) {
            break;
          }

          // 仅当下一个 if 紧跟当前 if 块（允许空行）时才继续延伸链。
          chain.add((curIf, curClose, curGoto));
          var next = curClose + 1;
          while (next < lines.length && lines[next].trim().isEmpty) {
            next++;
          }
          if (next >= lines.length || !openIfRe.hasMatch(lines[next])) break;
          curIf = next;
        }

        if (chain.length < 2 || mergeLabel == null) continue;

        final mergeLine = labelMap[mergeLabel];
        if (mergeLine == null || mergeLine <= chain.last.$2) continue;

        // merge 标号只能被链内 goto 引用，否则不能消除。
        final expectedRefs = chain.length;
        var actualRefs = 0;
        for (var k = 0; k < lines.length; k++) {
          if (lines[k].contains('goto $mergeLabel;')) actualRefs++;
        }
        if (actualRefs != expectedRefs) continue;

        // 链内每个 if 块的 then 体不能包含其他 label（控制流需简单）。
        bool bodyHasLabel = false;
        for (final c in chain) {
          for (var k = c.$1 + 1; k < c.$2; k++) {
            if (labelRe.hasMatch(lines[k])) {
              bodyHasLabel = true;
              break;
            }
          }
          if (bodyHasLabel) break;
        }
        if (bodyHasLabel) continue;

        // else 体：最后一个 if 块到 merge 标号之间的代码。
        final elseBody = lines
            .sublist(chain.last.$2 + 1, mergeLine)
            .where((l) => l.trim().isNotEmpty)
            .toList();

        // else 体中也不能有 label。
        for (final l in elseBody) {
          if (labelRe.hasMatch(l)) {
            bodyHasLabel = true;
            break;
          }
        }
        if (bodyHasLabel) continue;

        String bodyIndent(String l) =>
            l.isEmpty ? l : '$indent    ${l.trimLeft()}';

        final newLines = <String>[];
        for (var ci = 0; ci < chain.length; ci++) {
          final (ifLine, closeLine, gotoLine) = chain[ci];
          final cond = openIfRe.firstMatch(lines[ifLine])!.group(2)!;
          final body = lines.sublist(ifLine + 1, gotoLine);
          if (ci == 0) {
            newLines.add('$indent' + 'if ($cond) {');
          } else {
            newLines.add('$indent} else if ($cond) {');
          }
          newLines.addAll(body.map(bodyIndent));
        }
        if (elseBody.isNotEmpty) {
          newLines.add('$indent} else {');
          newLines.addAll(elseBody.map(bodyIndent));
        }
        newLines.add('$indent}');

        // 替换整条链到 merge 标号（一并消除标号）。
        lines.replaceRange(chain.first.$1, mergeLine + 1, newLines);
        changed = true;
        break;
      }
    } while (changed);

    // 链中可能仍残留未被消解的 goto（当 merge 被外部引用时），
    // 交给后续 _cleanupBreakContinue / _removeUnusedLabels 处理。
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
        while (idx0Line >= 0 && lines[idx0Line].trim().isEmpty) {
          idx0Line--;
        }
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
            '$whileIndent}',
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
          '        for ($initDecl; $cond; $idxVar++) {',
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
          if (n > j && n < incLabelLine) continue; // 循环体内的 break
          if (n >= incLabelLine && n <= gotoLine!) continue; // inc 部分
          if (lines[n].contains('goto $endLabel;')) endLabelRefs++;
        }
        if (endLabelRefs > 0) continue;

        // 获取 incLabel 名称（用于检测 continue 语句）
        final incLabelName = labelRe.firstMatch(lines[incLabelLine])?.group(1);

        // 检查 incLabel 是否被 body 外部引用
        // 若被外部引用，不能安全地转换为 continue（跳过此 for 循环）
        bool incLabelExternalRef = false;
        if (incLabelName != null) {
          for (var n = 0; n < lines.length; n++) {
            if (n == incLabelLine) continue;
            if (!lines[n].contains('goto $incLabelName;')) continue;
            if (n > j && n < incLabelLine) continue; // body 内引用（continue）
            incLabelExternalRef = true;
            break;
          }
        }
        if (incLabelExternalRef) continue;

        // 处理 body 中的 continue/break：
        // - goto incLabel; → continue (或 continue outer; 若在嵌套循环内)
        // - goto endLabel; 在嵌套循环内 → break outer;
        // - goto endLabel; 不在嵌套循环内 → 保留（由 _cleanupBreakContinue 处理）
        final loopStartRe = RegExp(r'^\s*(for|while|do)\b');

        bool isInsideNestedLoop(int gotoIdx) {
          final stack = <int>[];
          for (var k = j + 1; k < gotoIdx; k++) {
            for (var c = 0; c < lines[k].length; c++) {
              if (lines[k][c] == '{') stack.add(k);
              if (lines[k][c] == '}' && stack.isNotEmpty) {
                stack.removeLast();
              }
            }
          }
          // 栈中所有层级都是嵌套构造（for 循环自身的花括号不在 body 中）
          for (var s = 0; s < stack.length; s++) {
            if (loopStartRe.hasMatch(lines[stack[s]])) return true;
          }
          return false;
        }

        bool needsLabel = false;
        final bodyLines = <String>[];
        for (var n = j + 1; n < incLabelLine; n++) {
          final line = lines[n];
          if (line.trim().isEmpty) continue;
          final trimmed = line.trim();
          final indent = line.substring(0, line.length - trimmed.length);

          if (incLabelName != null && trimmed == 'goto $incLabelName;') {
            if (isInsideNestedLoop(n)) {
              needsLabel = true;
              bodyLines.add('${indent}continue outer;');
            } else {
              bodyLines.add('${indent}continue;');
            }
          } else if (trimmed == 'goto $endLabel;' && isInsideNestedLoop(n)) {
            needsLabel = true;
            bodyLines.add('${indent}break outer;');
          } else {
            bodyLines.add(line);
          }
        }
        final indentedBody = _reindentBlock(bodyLines, '            ');

        // 条件取反：if (idxVar >= N) goto end -> while (idxVar < N)
        final cond = op == '>=' ? '$idxVar < $bound' : '$idxVar >= $bound';

        final newLines = <String>[
          if (needsLabel) '      outer:',
          '        for ($initDecl; $cond; $idxVar++) {',
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
}
