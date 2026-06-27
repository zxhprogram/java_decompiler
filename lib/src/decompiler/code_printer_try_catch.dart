part of 'code_printer.dart';

/// try-catch-finally / try-with-resources 残留清理。
extension on CodePrinter {
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
        if (trimmed == '$label:') {
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
        if (lines[k].trim() == '$label:') {
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
}
