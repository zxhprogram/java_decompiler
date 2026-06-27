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
}
