part of 'code_printer.dart';

/// switch 语句结构化：pattern switch 与简单 switch 还原。
extension on CodePrinter {
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

    // 按 case 块在源码中出现的顺序（blockStarts）重排 cases，
    // javac 生成的 switch 表 case 值顺序可能与源码中 label 顺序不一致
    // （null case、record 模式、guard 等场景），需要按位置排序后再处理。
    final order = List.generate(cases.length, (i) => i)
      ..sort((a, b) => blockStarts[a].compareTo(blockStarts[b]));
    final sortedCases = [for (final i in order) cases[i]];
    final sortedBlockStarts = [for (final i in order) blockStarts[i]];

    // default 块位置校验：
    // - 若 default 在所有 case 块之后：正常处理（用户提供的 default）
    // - 若 default 在所有 case 块之前：通常是编译器为 sealed/exhaustive switch
    //   生成的 MatchException 异常路径，可安全跳过（不输出 default case）
    // - 若 default 在中间：结构复杂，放弃
    bool skipDefault = false;
    if (defaultStartLine != null && sortedBlockStarts.isNotEmpty) {
      if (defaultStartLine <= sortedBlockStarts.first) {
        // default 在所有 case 之前 - 检查是否为 MatchException 异常路径
        // default 块到第一个 case 块之间
        final defaultBlock = lines.sublist(
          defaultStartLine,
          sortedBlockStarts.first,
        );
        final isMatchException = defaultBlock.any((l) =>
            l.contains('throw new MatchException') ||
            l.contains('throw new java.lang.MatchException'));
        if (isMatchException) {
          skipDefault = true;
          // 在 default 在前的情况下，exceptionStartLine 指向的是第一个 case label
          // 而非真正的异常处理块，需要清除
          exceptionStartLine = null;
        } else {
          return source;
        }
      } else if (defaultStartLine <= sortedBlockStarts.last) {
        return source;
      }
    }

    // 5. 逐个处理块，生成 case 子句
    // 提取 typeSwitch 的 case 值到类型名的映射（用于未命名模式 `case Type _`）
    final typeSwitchCases = _lookupTypeSwitchCases();
    final caseLines = <({bool isExpr, String body})>[];
    for (var ci = 0; ci < sortedCases.length; ci++) {
      final start = sortedBlockStarts[ci];
      final int end;
      if (ci + 1 < sortedBlockStarts.length) {
        end = sortedBlockStarts[ci + 1];
      } else if (skipDefault) {
        // default 在前且被跳过时，最后一个 case 块延伸到文件末尾
        // 或下一个非 case label
        end = lines.length;
      } else {
        end = defaultStartLine ?? lines.length;
      }
      if (end <= start) return source;
      final block = lines.sublist(start, end);
      final caseLine = _patternCaseFromBlock(
        sortedCases[ci].value,
        block,
        sel,
        st,
        swLabel,
        typeSwitchCases: typeSwitchCases,
      );
      // 若任一 case 块解析失败，放弃结构化（避免生成不完整的 switch）
      if (caseLine == null) return source;
      caseLines.add(caseLine);
    }

    // default 块
    if (defaultStartLine != null && !skipDefault) {
      final end = exceptionStartLine ?? lines.length;
      if (end <= defaultStartLine) return source;
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

    final switchOpenRe = RegExp(r'^( {8,})switch \((.+)\) \{$');
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

        // 确定合并标号（regionEnd 处的 label）：case body 中的 `goto merge;`
        // 应被替换为 `break;`，而最后一个 body 可以直接 fallthrough 到 merge。
        String? mergeLabel;
        if (regionEnd < lines.length) {
          final lm = anyLabelRe.firstMatch(lines[regionEnd]);
          if (lm != null) mergeLabel = lm.group(1);
        }

        // 检查每个 case body 的终止方式：
        //   - terminates: 以 return/throw 结束（保留原样）
        //   - breakToMerge: 以 `goto mergeLabel;` 结束（转换为 break;）
        //   - fallthrough: 不以 goto 结束，且是最后一个 body（直接 fallthrough）
        //   - unsupported: 其他情况（跳过此 switch）
        // 同时收集每个 body 是否为空（空 body 只在 fallthrough 时允许）。
        final bodyKinds = <String, String>{};
        bool supported = true;
        for (final label in allLabels) {
          final body = extractBody(label);
          if (body.isEmpty) {
            // 空 body：只有当它是最后一个 body 且会 fallthrough 到 merge 时才允许
            bodyKinds[label] = 'fallthrough';
            continue;
          }
          final lastLine = body.last.trim();
          if (lastLine.startsWith('return') || lastLine.startsWith('throw')) {
            bodyKinds[label] = 'terminates';
          } else if (mergeLabel != null && lastLine == 'goto $mergeLabel;') {
            bodyKinds[label] = 'breakToMerge';
          } else if (lastLine.startsWith('goto ')) {
            // goto 到其他位置 - 不支持
            supported = false;
            break;
          } else {
            // 不以 goto/return/throw 结束 - fallthrough
            bodyKinds[label] = 'fallthrough';
          }
        }
        if (!supported) continue;

        // fallthrough 只允许出现在最后一个 body（按位置最靠后的那个）。
        // 其他 body 必须以 return/throw/breakToMerge 结束。
        final lastBodyLabel = sortedByPos.last;
        for (final label in allLabels) {
          if (label != lastBodyLabel && bodyKinds[label] == 'fallthrough') {
            supported = false;
            break;
          }
        }
        if (!supported) continue;

        // 构建 case body（重新缩进到 switch 内部）
        final caseIndent = '$indent    ';
        final bodyIndent = '$caseIndent    ';
        String reindent(String line) {
          final trimmed = line.trimLeft();
          return '$bodyIndent$trimmed';
        }

        // 清理 body：去掉末尾的 `goto mergeLabel;`（将在后续按需补 `break;`）
        List<String> cleanBody(String label) {
          final body = extractBody(label);
          if (body.isEmpty) return body;
          final kind = bodyKinds[label];
          if (kind == 'breakToMerge') {
            return body.sublist(0, body.length - 1);
          }
          return body;
        }

        // 按目标 label 分组连续的 case，使共享同一 body 的 case 合并输出：
        //   case 1:
        //   case 2:
        //       body;
        final newLines = <String>['${indent}switch ($selector) {'];
        var ci = 0;
        while (ci < cases.length) {
          final (caseValue, caseLabel) = cases[ci];
          newLines.add('${caseIndent}case $caseValue:');
          // 合并后续共享同一 caseLabel 的 case
          var cj = ci + 1;
          while (cj < cases.length && cases[cj].$2 == caseLabel) {
            newLines.add('${caseIndent}case ${cases[cj].$1}:');
            cj++;
          }
          final body = cleanBody(caseLabel);
          newLines.addAll(body.map(reindent));
          if (bodyKinds[caseLabel] == 'breakToMerge') {
            newLines.add('${bodyIndent}break;');
          }
          ci = cj;
        }
        // default
        newLines.add('${caseIndent}default:');
        final dBody = cleanBody(defaultLabel);
        newLines.addAll(dBody.map(reindent));
        if (bodyKinds[defaultLabel] == 'breakToMerge') {
          newLines.add('${bodyIndent}break;');
        }
        newLines.add('$indent}');

        // 若 regionEnd 处的 label 是未被引用的孤立尾部 label，一并移除
        int replaceEnd = regionEnd;
        if (regionEnd < lines.length) {
          final lm = anyLabelRe.firstMatch(lines[regionEnd]);
          if (lm != null) {
            final tailLabel = lm.group(1)!;
            // 只统计 switch 区域 [i, regionEnd) 之外对该标号的引用：
            // 区域内的 `goto mergeLabel;` 已被转换为 `break;`。
            bool referenced = false;
            for (var k = 0; k < lines.length; k++) {
              if (k >= i && k <= regionEnd) continue;
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

  /// 把 Java 字符串 switch 的两级结构（hashCode 分发 + equals 校验 + 序号 switch）
  /// 合并还原为 `switch (var) { case "lit": ... }` 形式。
  /// 必须在 [_structureSimpleSwitch] 之后运行——后者已把第二级 switch 结构化。
  String _structureStringSwitch(String source) {
    var lines = source.split('\n');

    final hashCodeSwitchRe = RegExp(r'^( +)switch \((\w+)\.hashCode\(\)\) \{$');
    final caseGotoRe = RegExp(r'^ +case (-?\d+): goto (label_\d+);$');
    final defaultGotoRe = RegExp(r'^ +default: goto (label_\d+);$');
    final anyLabelRe = RegExp(r'^ *(label_\d+):$');
    // `if (!VAR.equals("LIT"))` 或 `if (VAR.equals("LIT"))`
    final equalsRe = RegExp(r'(\w+)\.equals\("((?:[^"\\]|\\.)*)"\)');
    final ordAssignRe = RegExp(r'^ +(\w+) = (\d+);$');

    bool changed;
    do {
      changed = false;

      final labelMap = <String, int>{};
      for (var i = 0; i < lines.length; i++) {
        final m = anyLabelRe.firstMatch(lines[i]);
        if (m != null) labelMap[m.group(1)!] = i;
      }

      for (var i = 0; i < lines.length; i++) {
        final sm = hashCodeSwitchRe.firstMatch(lines[i]);
        if (sm == null) continue;
        final indent = sm.group(1)!;
        final hashVar = sm.group(2)!; // e.g. p1

        // 找到 hashCode switch 的 `}`
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

        // 解析 hashCode switch 的 case -> label 与 default -> merge label
        final hashCases = <(int, String)>[];
        String? mergeLabel;
        for (var k = i + 1; k < closeLine; k++) {
          final cm = caseGotoRe.firstMatch(lines[k]);
          if (cm != null) {
            hashCases.add((int.parse(cm.group(1)!), cm.group(2)!));
            continue;
          }
          final dm = defaultGotoRe.firstMatch(lines[k]);
          if (dm != null) {
            mergeLabel = dm.group(1);
          }
        }
        if (mergeLabel == null || hashCases.isEmpty) continue;

        // 解析每个 case label 的 equals 校验块，构建 ordinal -> "literal" 映射
        final ordToString = <int, String>{};
        String? ordVar;

        for (final (_, label) in hashCases) {
          final pos = labelMap[label];
          if (pos == null) continue;

          // 收集该 label 到下一个 label 之间的非空行
          final blockLines = <String>[];
          for (var k = pos + 1; k < lines.length; k++) {
            if (anyLabelRe.hasMatch(lines[k])) break;
            if (lines[k].trim().isNotEmpty) blockLines.add(lines[k]);
          }

          String? literal;
          int? ordinal;
          for (final line in blockLines) {
            final em = equalsRe.firstMatch(line);
            if (em != null && em.group(1) == hashVar) {
              literal = em.group(2);
            }
            final am = ordAssignRe.firstMatch(line);
            if (am != null) {
              ordVar = am.group(1);
              ordinal = int.parse(am.group(2)!);
            }
          }
          if (literal != null && ordinal != null) {
            ordToString[ordinal] = literal;
          }
        }

        if (ordVar == null || ordToString.isEmpty) continue;

        // 找到 merge label 位置
        final mergePos = labelMap[mergeLabel];
        if (mergePos == null) continue;

        // 在 merge label 之后找第二级 switch（on ordVar）
        int? secondSwitchLine;
        final secondSwitchRe =
            RegExp(r'^ +switch \(' + RegExp.escape(ordVar) + r'\) \{$');
        for (var k = mergePos + 1; k < lines.length; k++) {
          if (secondSwitchRe.hasMatch(lines[k])) {
            secondSwitchLine = k;
            break;
          }
        }
        if (secondSwitchLine == null) continue;

        // 找到第二级 switch 的 `}`
        late final int secondCloseLine;
        depth = 1;
        foundClose = false;
        for (var k = secondSwitchLine + 1; k < lines.length; k++) {
          if (lines[k].contains('{')) depth++;
          if (lines[k].contains('}')) {
            depth--;
            if (depth == 0) {
              secondCloseLine = k;
              foundClose = true;
              break;
            }
          }
        }
        if (!foundClose) continue;

        // 解析第二级 switch 的 case groups
        // 格式（已被 _structureSimpleSwitch 结构化）：
        //   case N:
        //       BODY;
        //   case M:
        //   case P:
        //       BODY2;
        //   default:
        //       DEFAULT_BODY;
        final caseIndent = '$indent    ';
        final bodyIndent = '$caseIndent    ';
        final caseLineRe = RegExp(r'^ +case (-?\d+):$');
        final defaultLineRe = RegExp(r'^ +default:$');

        final ordGroups = <(List<int>, List<String>)>[]; // (ordinals, body)
        var defaultBody = <String>[];

        var k = secondSwitchLine + 1;
        while (k < secondCloseLine) {
          final line = lines[k];
          if (line.trim().isEmpty) {
            k++;
            continue;
          }

          // 检查是否是 default
          if (defaultLineRe.hasMatch(line)) {
            k++;
            // 收集 default body
            final body = <String>[];
            while (k < secondCloseLine) {
              final bl = lines[k];
              if (caseLineRe.hasMatch(bl) || defaultLineRe.hasMatch(bl)) break;
              if (bl.trim().isNotEmpty) body.add(bl);
              k++;
            }
            defaultBody = body;
            continue;
          }

          // 收集 case 标签组
          final ordinals = <int>[];
          while (k < secondCloseLine) {
            final cm = caseLineRe.firstMatch(lines[k]);
            if (cm != null) {
              ordinals.add(int.parse(cm.group(1)!));
              k++;
              continue;
            }
            break;
          }
          if (ordinals.isEmpty) {
            k++;
            continue;
          }

          // 收集 body
          final body = <String>[];
          while (k < secondCloseLine) {
            final bl = lines[k];
            if (caseLineRe.hasMatch(bl) || defaultLineRe.hasMatch(bl)) break;
            if (bl.trim().isNotEmpty) body.add(bl);
            k++;
          }
          ordGroups.add((ordinals, body));
        }

        // 查找原始选择器：向前找 `String hashVar = SELECTOR;`
        String selector = hashVar;
        for (var j = i - 1; j >= 0 && j >= i - 6; j--) {
          final copyMatch = RegExp(r'^ +(?:java\.lang\.)?String ' +
                  RegExp.escape(hashVar) +
                  r' = (.+);$')
              .firstMatch(lines[j]);
          if (copyMatch != null) {
            selector = copyMatch.group(1)!;
            break;
          }
        }

        // 确定替换范围：从 `String hashVar = ...;` 或 `int ordVar = -1;` 开始
        // 到第二级 switch 结束
        int replaceStart = i;
        // 向前查找 `int ordVar = -1;` 或 `String hashVar = ...;`
        for (var j = i - 1; j >= 0 && j >= i - 6; j--) {
          final l = lines[j].trim();
          final isCopy = RegExp(
                  r'^(?:java\.lang\.)?String ' + RegExp.escape(hashVar) + r' =')
              .hasMatch(l);
          final isOrdInit = l.startsWith('int $ordVar');
          if (isCopy || isOrdInit) {
            replaceStart = j;
          }
          if (isCopy) break;
        }

        // 构建替换文本
        final newLines = <String>['${indent}switch ($selector) {'];

        for (final (ordinals, body) in ordGroups) {
          // 为每个 ordinal 找到对应的 string literal
          for (final ord in ordinals) {
            final lit = ordToString[ord];
            if (lit != null) {
              newLines.add('${caseIndent}case "$lit":');
            } else {
              // 找不到对应的 string literal，保留 ordinal 形式
              newLines.add('${caseIndent}case $ord:');
            }
          }
          // 重新缩进 body
          for (final bl in body) {
            final trimmed = bl.trimLeft();
            newLines.add('$bodyIndent$trimmed');
          }
        }

        // default
        newLines.add('${caseIndent}default:');
        for (final bl in defaultBody) {
          final trimmed = bl.trimLeft();
          newLines.add('$bodyIndent$trimmed');
        }

        newLines.add('$indent}');

        lines.replaceRange(replaceStart, secondCloseLine + 1, newLines);
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
    Map<int, String>? typeSwitchCases,
  }) {
    if (block.isEmpty) return null;

    // 检测复杂控制流：含有 instanceof 或 if-else 块的 case 无法安全结构化
    // （嵌套 record 模式等场景），直接返回 null 让外层放弃结构化。
    final hasComplexFlow = block.any((l) =>
        l.contains('instanceof') ||
        (l.contains('if (') && l.contains(') {')) ||
        l.contains('} else {'));
    if (hasComplexFlow) {
      // 尝试处理嵌套 record 模式（case 块含 instanceof 用于嵌套 record 提取）
      final nested = _tryBuildNestedRecordCase(
        caseValue,
        block,
        selectorVar,
        stateVar,
        switchLabel,
        isDefault: isDefault,
      );
      return nested;
    }

    // 找到结果表达式：块中最后一个 `return expr;` 或 `throw expr;`
    String? resultExpr;
    for (var i = block.length - 1; i >= 0; i--) {
      final m = RegExp(r'^        (return|throw) (.+);$').firstMatch(block[i]);
      if (m != null) {
        resultExpr = m.group(1) == 'throw' ? 'throw ${m.group(2)}' : m.group(2);
        break;
      }
    }

    // 处理 guard 直接返回型：`if (cond) return expr;`
    // 这种情况下 resultExpr 为 null（return 在 if 内），需要单独提取
    if (resultExpr == null) {
      final guardReturnRe = RegExp(r'^ *if \((.+)\) (return .+;|throw .+;)$');
      for (var i = 0; i < block.length; i++) {
        final m = guardReturnRe.firstMatch(block[i]);
        if (m != null) {
          final ret = m.group(2)!;
          resultExpr = ret.startsWith('throw')
              ? 'throw ${ret.substring(6)}'
              : ret.substring(7, ret.length - 1);
          break;
        }
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

    // 找到模式变量声明：
    //  - 引用类型：`Type v = ((Type) selector);`
    //  - 原始类型：`prim v = ((Wrapper) selector).xxxValue();`
    final castRe = RegExp(r'^        (\S+(?:<[^>]+>)?) (\w+) = \(\(\1\) ' +
        RegExp.escape(selectorVar) +
        r'\);$');
    // 原始类型模式：`int v = ((java.lang.Integer) selector).intValue();`
    final primCastRe = RegExp(
        r'^        (int|long|float|double|byte|short|char|boolean) (\w+) = \(\((?:java\.lang\.)?(\w+)\) ' +
            RegExp.escape(selectorVar) +
            r'\)\.(\w+Value\(\))\;$');
    String? patternType;
    String? patternVar;
    int? castLine;
    for (var i = 0; i < block.length; i++) {
      final pm = primCastRe.firstMatch(block[i]);
      if (pm != null) {
        patternType = pm.group(1);
        patternVar = pm.group(2);
        castLine = i;
        break;
      }
      final m = castRe.firstMatch(block[i]);
      if (m != null) {
        patternType = m.group(1);
        patternVar = m.group(2);
        castLine = i;
        break;
      }
    }
    if (patternVar == null || patternType == null || castLine == null) {
      // 未命名类型模式：`case Type _ -> expr;`
      // 字节码中没有 cast 行（变量未绑定），通过 typeSwitch 的 case 值查找类型
      if (caseValue != null &&
          caseValue >= 0 &&
          typeSwitchCases != null &&
          typeSwitchCases.containsKey(caseValue)) {
        final typeName = typeSwitchCases[caseValue]!;
        final simpleTypeName = _simplifyTypeName(typeName);
        return (
          isExpr: true,
          body: 'case $simpleTypeName _ -> $resultExpr;',
        );
      }
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
    //    guard = !cond（条件不满足时重试下一个 case）
    // 2) 成功返回型：if (cond) goto label_true;  label_true: return expr;
    //    guard = cond
    // 3) 直接返回型：if (cond) return expr; state = N; goto switch;
    //    guard = cond（条件满足时返回，否则重试下一个 case）
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

    // 3) 直接返回型：if (cond) return expr; ... state = N; goto switch;
    //    模式：cast 行后紧跟 `if (cond) return expr;`，且块中存在 `goto switchLabel;`
    if (guard == null && switchLabel != null) {
      final directReturnIfRe =
          RegExp(r'^ *if \((.+)\) (return .+;|throw .+;)$');
      // 检查块中是否存在 `goto switchLabel;`（说明此 case 失败时会重试）
      final hasRetry = block.any((l) => l.contains('goto $switchLabel;'));
      if (hasRetry) {
        for (var i = castLineIdx + 1; i < block.length; i++) {
          final m = directReturnIfRe.firstMatch(block[i]);
          if (m == null) continue;
          final cond = m.group(1)!;
          if (_isTrivialCondition(cond)) continue;
          guard = _simplifyDoubleNegation(_replaceAliasNames(cond, aliasMap));
          break;
        }
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

    // 简化 guard 中的比较运算符（如 `(a <=> b) > 0` → `a > b`）
    if (guard != null) {
      guard = _simplifyGuardComparison(guard);
    }

    final guardPart = guard != null ? ' when $guard' : '';
    final simpleType = _simplifyTypeName(patternType);

    // 尝试构造 record 模式：若 resultExpr 中只引用了 patternVar 的访问器调用
    // （如 p3.x()、p3.y()），且该类型是 record，则生成 `Type(x, y)` 形式。
    final recordPattern = _tryBuildRecordPattern(
      patternType,
      patternVar,
      resultExpr,
      aliasMap,
    );
    if (recordPattern != null && guard == null) {
      // 将 resultExpr 中的 patternVar.accessor() 替换为组件名
      var replacedExpr = resultExpr;
      final components = _lookupRecordComponents(patternType)!;
      for (final comp in components) {
        replacedExpr = replacedExpr.replaceAll(
          '$patternVar.${comp.name}()',
          comp.name,
        );
      }
      return (
        isExpr: true,
        body: 'case $simpleType$recordPattern -> $replacedExpr;',
      );
    }

    return (
      isExpr: true,
      body: 'case $simpleType $patternVar$guardPart -> $resultExpr;',
    );
  }

  /// 尝试处理嵌套 record 模式的 case 块。
  ///
  /// 典型字节码模式（源码 `case Colored(Point(int x, int y), String color) -> ...`）：
  /// ```
  /// Colored p4 = (Colored) selector;
  /// Point p9 = p4.p();              // 嵌套 record 组件
  /// if (p9 instanceof Point) {      // 嵌套 record 检查
  ///     Point p5 = p9;              // 别名
  ///     String p9 = p4.color();     // 其他组件（槽位复用）
  ///     ... 提取嵌套组件 x, y ...
  /// } else {
  ///     state = N; goto switchLabel; // 失败重试
  /// }
  /// return resultExpr;
  /// ```
  /// 返回结构化的 `case Outer(Inner(...), comp) -> expr;` 或 null。
  ({bool isExpr, String body})? _tryBuildNestedRecordCase(
    int? caseValue,
    List<String> block,
    String selectorVar,
    String stateVar,
    String? switchLabel, {
    bool isDefault = false,
  }) {
    if (isDefault || caseValue == null || caseValue < 0) return null;
    if (switchLabel == null) return null;

    // 1. 找到外层 cast 行：`Outer pN = ((Outer) selector);`
    final castRe = RegExp(r'^        (\S+(?:<[^>]+>)?) (\w+) = \(\(\1\) ' +
        RegExp.escape(selectorVar) +
        r'\);$');
    String? outerType;
    String? outerVar;
    int? castLineIdx;
    for (var i = 0; i < block.length; i++) {
      final m = castRe.firstMatch(block[i]);
      if (m != null) {
        outerType = m.group(1);
        outerVar = m.group(2);
        castLineIdx = i;
        break;
      }
    }
    if (outerType == null || outerVar == null || castLineIdx == null) {
      return null;
    }

    // 2. 找到 instanceof 检查：`if ((pN instanceof Type)) {`
    //    pN 是 outerVar 的某个组件（通过 accessor 调用获得）
    final instanceofRe = RegExp(r'^ *if \(\((\w+) instanceof (\S+)\)\) \{$');
    int? instanceofLineIdx;
    String? nestedVar; // 被检查的变量（如 p9）
    String? nestedType; // 嵌套 record 类型（如 Point）
    for (var i = castLineIdx + 1; i < block.length; i++) {
      final m = instanceofRe.firstMatch(block[i]);
      if (m != null) {
        nestedVar = m.group(1);
        nestedType = m.group(2);
        instanceofLineIdx = i;
        break;
      }
    }
    if (instanceofLineIdx == null || nestedVar == null || nestedType == null) {
      return null;
    }
    final nestedTypeSimple = _simplifyTypeName(nestedType);

    // 3. 找到 if 块的结束（`}`）。
    //    javac 生成的结构可能是：
    //    a) `if (instanceof) { ... } else { state=N; goto switch; }` （旧模式）
    //    b) `if (instanceof) { ... goto label_end; } state=N; goto switch; label_end: ...` （新模式）
    int? ifCloseLineIdx;
    for (var i = instanceofLineIdx + 1; i < block.length; i++) {
      if (block[i].trim() == '}') {
        ifCloseLineIdx = i;
        break;
      }
    }
    if (ifCloseLineIdx == null) {
      return null;
    }

    // 判断是哪种模式
    // 模式 a：if 后面紧跟 ` else {`
    bool isElseMode = ifCloseLineIdx + 1 < block.length &&
        block[ifCloseLineIdx].trim() == '}' &&
        block[ifCloseLineIdx + 1].trim() == '} else {';

    int? elseLineIdx;
    int? elseCloseLineIdx;
    if (isElseMode) {
      elseLineIdx = ifCloseLineIdx + 1;
      for (var i = elseLineIdx + 1; i < block.length; i++) {
        if (block[i].trim() == '}') {
          elseCloseLineIdx = i;
          break;
        }
      }
      if (elseCloseLineIdx == null) return null;
    }

    // 4. 验证重试部分
    final gotoRe = RegExp(r'^ *goto (label_\d+);$');
    final labelDefRe = RegExp(r'^ *(label_\d+):$');
    bool isRetry = false;
    int retryEndLine; // 重试部分结束行（不含）
    if (isElseMode) {
      // else 块内：`state = N; goto switchLabel;`
      final elseBlock =
          block.sublist((elseLineIdx ?? 0) + 1, elseCloseLineIdx ?? 0);
      for (final l in elseBlock) {
        if (l.contains('goto $switchLabel;')) {
          isRetry = true;
          break;
        }
      }
      retryEndLine = (elseCloseLineIdx ?? 0) + 1;
    } else {
      // 模式 b：if 块内以 `goto label_end;` 结束，if 后面是 `state=N; goto switchLabel; label_end: return ...`
      // 验证 if 块内有 goto
      final ifBlock = block.sublist(instanceofLineIdx + 1, ifCloseLineIdx);
      for (final l in ifBlock) {
        final m = gotoRe.firstMatch(l);
        if (m != null) {}
      }
      // if 之后到 return 之前应有 `state=N; goto switchLabel;`
      int? foundRetryEnd;
      for (var i = (ifCloseLineIdx) + 1; i < block.length; i++) {
        final t = block[i].trim();
        if (t.isEmpty) continue;
        if (t.contains('goto $switchLabel;')) {
          isRetry = true;
        }
        final lm = labelDefRe.firstMatch(block[i]);
        if (lm != null) {
          foundRetryEnd = i + 1;
          break;
        }
        if (block[i].startsWith('        return ') ||
            block[i].startsWith('        throw ')) {
          foundRetryEnd = i;
          break;
        }
      }
      if (!isRetry) {
        return null;
      }
      if (foundRetryEnd == null) {
        return null;
      }
      retryEndLine = foundRetryEnd;
    }

    // 5. 收集 if 块内的变量赋值，建立变量到组件的映射
    final ifBlockEnd = isElseMode ? elseLineIdx! : ifCloseLineIdx;
    final ifBlock = block.sublist(instanceofLineIdx + 1, ifBlockEnd);
    // 跟踪每个变量代表的"语义"：
    // - 'outer.ACCESSOR' 表示外层 record 的某个组件
    // - 'nested.ACCESSOR' 表示嵌套 record 的某个组件
    // - 'nested' 表示嵌套 record 本身
    final varSemantics = <String, String>{};
    // nestedVar 在 if 之前由 `outerVar.accessor()` 赋值
    // 查找这个赋值
    final nestedAssignRe = RegExp(r'^ *(?:\S+(?:<[^>]+>)? )?(\w+) = ' +
        RegExp.escape(outerVar) +
        r'\.(\w+)\(\);$');
    for (var i = castLineIdx + 1; i < instanceofLineIdx; i++) {
      final m = nestedAssignRe.firstMatch(block[i]);
      if (m != null && m.group(1) == nestedVar) {
        varSemantics[nestedVar] = 'outer.${m.group(2)}';
        break;
      }
    }
    if (!varSemantics.containsKey(nestedVar)) return null;

    // 处理 if 块内的赋值
    // 通用组件访问：`Type pN = src.method();`（外层或嵌套）
    final nestedCompRe =
        RegExp(r'^ *(?:\S+(?:<[^>]+>)? )?(\w+) = (\w+)\.(\w+)\(\);$');
    // 简单赋值/别名：`pN = pM;`（槽位复用）
    final simpleAssignRe = RegExp(r'^ *(?:\S+(?:<[^>]+>)? )?(\w+) = (\w+);$');

    // 顺序处理 if 块内的赋值（处理槽位复用：同一变量可能被多次赋值）
    // 关键：当 `p6 = p9` 时，p6 获得 p9 当前的语义；之后 p9 被重新赋值不影响 p6
    // nestedVar 初始语义是 'outer.COMPONENT'（外层 record 的嵌套 record 组件）
    // 当 `var = nestedVar` 时，若 nestedVar 仍指向嵌套 record（语义为 'outer.组件名'），
    // 则 var 成为嵌套 record 的别名（'nested'）；否则按普通别名处理。
    final nestedComponentName =
        varSemantics[nestedVar]!.substring('outer.'.length);
    for (final l in ifBlock) {
      // 通用组件访问：`Type pN = src.method();`
      // 根据 src 的语义判断是外层还是嵌套组件访问
      final ncm = nestedCompRe.firstMatch(l);
      if (ncm != null) {
        final v = ncm.group(1)!;
        final src = ncm.group(2)!;
        final acc = ncm.group(3)!;
        if (src == outerVar) {
          // 外层组件访问
          varSemantics[v] = 'outer.$acc';
        } else if (varSemantics[src] == 'nested') {
          // 嵌套组件访问
          varSemantics[v] = 'nested.$acc';
        }
        continue;
      }
      // 简单赋值：`pN = pM;`
      final sam = simpleAssignRe.firstMatch(l);
      if (sam != null) {
        final v = sam.group(1)!;
        final src = sam.group(2)!;
        // 特殊处理：`var = nestedVar` 且 nestedVar 仍指向嵌套 record
        if (src == nestedVar &&
            varSemantics[nestedVar] == 'outer.$nestedComponentName') {
          varSemantics[v] = 'nested';
        } else if (varSemantics[src] != null) {
          varSemantics[v] = varSemantics[src]!;
        }
      }
    }

    // 6. 找到结果表达式（重试部分之后的 return/throw）
    String? resultExpr;
    for (var i = retryEndLine; i < block.length; i++) {
      final m = RegExp(r'^        (return|throw) (.+);$').firstMatch(block[i]);
      if (m != null) {
        resultExpr = m.group(1) == 'throw' ? 'throw ${m.group(2)}' : m.group(2);
        break;
      }
    }
    if (resultExpr == null) {
      return null;
    }

    // 清理 String.valueOf 包装
    resultExpr = resultExpr.replaceAllMapped(
        RegExp(r'(?:java\.lang\.)?String\.valueOf\(([^)]+)\)'),
        (m) => m.group(1)!);

    // 7. 查找外层和嵌套 record 的组件列表
    final outerComponents = _lookupRecordComponents(outerType);
    final nestedComponents = _lookupRecordComponents(nestedType);
    if (outerComponents == null || nestedComponents == null) return null;

    // 8. 将 resultExpr 中的变量替换为组件名
    // 收集结果表达式中使用的变量
    final usedVars = <String>{};
    for (final entry in varSemantics.entries) {
      if (RegExp(r'\b' + RegExp.escape(entry.key) + r'\b')
          .hasMatch(resultExpr)) {
        usedVars.add(entry.key);
      }
    }

    // 替换变量为组件名
    var replacedExpr = resultExpr;
    final usedOuterComps = <String>{};
    final usedNestedComps = <String>{};
    for (final v in usedVars) {
      final sem = varSemantics[v];
      if (sem == null) continue;
      if (sem.startsWith('outer.')) {
        final comp = sem.substring('outer.'.length);
        usedOuterComps.add(comp);
        replacedExpr = replacedExpr.replaceAll(
          RegExp(r'\b' + RegExp.escape(v) + r'\b'),
          comp,
        );
      } else if (sem.startsWith('nested.')) {
        final comp = sem.substring('nested.'.length);
        usedNestedComps.add(comp);
        replacedExpr = replacedExpr.replaceAll(
          RegExp(r'\b' + RegExp.escape(v) + r'\b'),
          comp,
        );
      }
    }

    // 9. 构造嵌套 record 模式
    // 外层模式：Outer(nestedPattern, comp1, comp2, ...)
    // 嵌套模式：Inner(usedNestedComps...)
    // 简化类型名
    final outerTypeSimple = _simplifyTypeName(outerType);

    // 构造嵌套 record 模式：`Inner(c1, c2)` 或 `Inner(Type c1, Type c2)`
    // 仅使用在结果表达式中出现的组件
    final nestedParts = <String>[];
    for (final comp in nestedComponents) {
      if (usedNestedComps.contains(comp.name)) {
        nestedParts.add('${comp.type} ${comp.name}');
      }
    }
    if (nestedParts.isEmpty) return null;
    final nestedPattern = '$nestedTypeSimple(${nestedParts.join(', ')})';

    // 构造外层 record 模式：按组件顺序，嵌套位置用 nestedPattern，其他用组件名或 _
    final outerParts = <String>[];
    // 找到嵌套 record 对应的外层组件名
    // 使用处理前的 nestedComponentName（nestedVar 可能已被重新赋值）
    final nestedOuterComp = nestedComponentName;
    for (final comp in outerComponents) {
      if (comp.name == nestedOuterComp) {
        outerParts.add(nestedPattern);
      } else if (usedOuterComps.contains(comp.name)) {
        outerParts.add('${comp.type} ${comp.name}');
      } else {
        outerParts.add('_');
      }
    }
    final outerPattern = '$outerTypeSimple(${outerParts.join(', ')})';

    return (
      isExpr: true,
      body: 'case $outerPattern -> $replacedExpr;',
    );
  }

  /// 尝试构造 record 模式 `Type(int x, int y)` 或 `Type(int x, _)`。
  /// 当 patternType 是 record 且 resultExpr 中通过 `patternVar.accessor()` 形式
  /// 引用了部分或全部组件时返回模式字符串，否则返回 null。
  /// 未引用的组件用 `_`（未命名模式）表示。
  String? _tryBuildRecordPattern(
    String patternType,
    String patternVar,
    String resultExpr,
    Map<String, String> aliasMap,
  ) {
    // 查找该 record 类型的组件（名+类型）列表
    final components = _lookupRecordComponents(patternType);
    if (components == null || components.isEmpty) return null;

    // 检查 resultExpr 中引用了 patternVar 的哪些组件访问器
    final usedAccessors = <String>{};
    for (final comp in components) {
      final accessorCall = '$patternVar.${comp.name}()';
      if (resultExpr.contains(accessorCall)) {
        usedAccessors.add(comp.name);
      }
    }
    // 至少使用一个组件才能生成 record 模式
    if (usedAccessors.isEmpty) return null;

    // 检查 resultExpr 中是否还有 patternVar 的其他引用（非 accessor 调用）
    // 如 `p4.toString()` 或裸 `p4`，若有则不能生成 record 模式
    final patternVarRefRe = RegExp(r'\b' + RegExp.escape(patternVar) + r'\b');
    // 移除所有 accessor 调用后检查是否还有 patternVar 引用
    final exprWithoutAccessors = resultExpr.replaceAll(
        RegExp(RegExp.escape(patternVar) + r'\.\w+\(\)'), '');
    if (patternVarRefRe.hasMatch(exprWithoutAccessors)) return null;

    // 生成 `(Type1 comp1, _)` 形式，未使用的组件用 `_` 表示
    final parts = components.map((c) {
      if (usedAccessors.contains(c.name)) {
        return '${c.type} ${c.name}';
      }
      return '_';
    }).join(', ');
    return '($parts)';
  }

  /// 从 typeSwitch invokedynamic 的 bootstrap 参数中提取 case 值到类型名的映射。
  /// typeSwitch 的 bootstrap 参数是一组 CONSTANT_Class_info，case 值 0 对应第一个，
  /// case 值 1 对应第二个，以此类推。case 值 -1 始终是 null。
  /// 对于原始类型模式（JDK 23+），参数可能是 CONSTANT_Class_info 包装的原始类型描述符
  /// （如 I、J、F、D）或对应的包装类（Integer、Long、Float、Double）。
  /// 返回 `Map<int, String>` 或 null（无法解析时）。
  Map<int, String>? _lookupTypeSwitchCases() {
    try {
      BootstrapMethodsAttribute? bmAttr;
      for (final attr in _cf.attributes) {
        if (attr is BootstrapMethodsAttribute) {
          bmAttr = attr;
          break;
        }
      }
      if (bmAttr == null) return null;

      // 在常量池中查找名为 typeSwitch 的 CpInvokeDynamic 条目
      for (var i = 1; i < _pool.length; i++) {
        final e = _pool.get(i);
        if (e is! CpInvokeDynamic) continue;
        final nt = _pool.getNameAndType(e.nameAndTypeIndex);
        final name = _pool.getString(nt.nameIndex);
        if (name != 'typeSwitch') continue;

        // 获取对应的 bootstrap 方法
        if (e.bootstrapMethodAttrIndex >= bmAttr.bootstrapMethods.length) {
          continue;
        }
        final bm = bmAttr.bootstrapMethods[e.bootstrapMethodAttrIndex];
        final result = <int, String>{};
        // bootstrap 参数通常是 CONSTANT_Class_info，依次对应 case 0, 1, 2, ...
        for (var k = 0; k < bm.bootstrapArguments.length; k++) {
          final argIdx = bm.bootstrapArguments[k];
          final arg = _pool.get(argIdx);
          if (arg is CpClass) {
            final internalName = _pool.getString(arg.nameIndex);
            // 原始类型描述符（I, J, F, D, etc.）
            if (internalName.length == 1) {
              final primitive =
                  DescriptorParser.parseFieldDescriptor(internalName);
              result[k] = primitive;
            } else {
              // 将内部名（如 java/lang/Integer）转为源码名（如 java.lang.Integer）
              final sourceName =
                  DescriptorParser.internalToSourceName(internalName);
              result[k] = sourceName;
            }
          }
        }
        return result;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 查找 record 类型的组件（名+类型）列表。
  /// 通过常量池中该类型的方法引用推断无参 accessor 方法。
  List<({String name, String type})>? _lookupRecordComponents(
      String patternType) {
    // 简单实现：仅对已知的 record 类型（通过 _cf 的 RecordAttribute 或
    // 内部类查找）返回组件。这里通过反射已加载的 ClassFile 获取。
    // 由于反编译上下文中可能没有目标类的 ClassFile，我们通过常量池中
    // 出现的 record 组件方法名启发式推断。
    try {
      final internalName = patternType.replaceAll('.', '/');
      // 在常量池中查找该类型的 RecordAttribute 或组件方法
      // 简化：通过方法引用推断组件（x(), y(), r() 等无参方法）
      final components = <({String name, String type})>[];
      for (var i = 1; i < _pool.length; i++) {
        final e = _pool.get(i);
        if (e is CpMethodref || e is CpInterfaceMethodref) {
          final classIndex = e is CpMethodref
              ? e.classIndex
              : (e as CpInterfaceMethodref).classIndex;
          final natIndex = e is CpMethodref
              ? e.nameAndTypeIndex
              : (e as CpInterfaceMethodref).nameAndTypeIndex;
          final nt = _pool.getNameAndType(natIndex);
          final cls = _pool.getClassName(classIndex);
          if (cls == internalName) {
            final name = _pool.getString(nt.nameIndex);
            final desc = _pool.getString(nt.descriptorIndex);
            // 无参方法且返回值非 void，可能是组件访问器
            if (desc.startsWith('()') && !desc.endsWith(')V')) {
              // 排除 Object 方法
              if (name != 'toString' &&
                  name != 'hashCode' &&
                  name != 'getClass' &&
                  !name.startsWith('get')) {
                // 从描述符提取返回类型（如 ()I -> int, ()D -> double）
                final retTypeDesc = desc.substring(2);
                final retType =
                    DescriptorParser.parseFieldDescriptor(retTypeDesc);
                components.add((name: name, type: retType));
              }
            }
          }
        }
      }
      return components.isEmpty ? null : components;
    } catch (_) {
      return null;
    }
  }

  /// 简化 guard 中的比较运算符：
  /// `(a <=> b) > 0` → `a > b`，`(a <=> b) < 0` → `a < b` 等。
  /// 同时去掉冗余的外层括号。
  String _simplifyGuardComparison(String guard) {
    var result = guard.trim();
    // `(a <=> b) OP 0` → `a OP b`
    final cmpRe = RegExp(r'^\((.+) <=> (.+)\) (>|<|>=|<=|==|!=) 0$');
    final m = cmpRe.firstMatch(result);
    if (m != null) {
      final a = m.group(1)!.trim();
      final b = m.group(2)!.trim();
      final op = m.group(3)!;
      result = '$a $op $b';
    }
    // 去掉冗余外层括号（如 `(p6.r() > 0.0)` → `p6.r() > 0.0`）
    if (result.startsWith('(') && result.endsWith(')')) {
      var depth = 0;
      var canStrip = true;
      for (var i = 0; i < result.length; i++) {
        if (result[i] == '(') depth++;
        if (result[i] == ')') {
          depth--;
          if (depth == 0 && i != result.length - 1) {
            canStrip = false;
            break;
          }
        }
      }
      if (canStrip) {
        result = result.substring(1, result.length - 1);
      }
    }
    return result;
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
}
