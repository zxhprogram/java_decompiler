part of 'code_printer.dart';

/// 栈式字节码发射：将指令序列翻译为中间文本，含类型推断与变量命名。
extension on CodePrinter {
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

  /// 检测 switch 表达式合并点模式并返回应 return 的值（如果可处理）。
  ///
  /// 模式 A（栈非空时）: goto 目标为 `istore N; iload N; ireturn`
  ///   - 栈顶值直接 return（由调用方 pop）
  ///   - 返回空字符串 "" 表示"使用栈顶值"
  ///
  /// 模式 B（栈空时）: goto 目标为 `<push V>; istore N; iload N; ireturn`
  ///   - 返回 V 的字符串表示，调用方直接 emit `return V;`
  ///
  /// 不能处理时返回 null。
  String? _trySwitchExprReturnValue(
      int offset, Map<int, Instruction> offsetToIns) {
    final targetIns = offsetToIns[offset];
    if (targetIns == null) return null;
    final targetOp = targetIns.opcode;

    // 判断 store/load 指令集
    bool isStoreOpcode(int op) =>
        op == Opcodes.istore ||
        op == Opcodes.lstore ||
        op == Opcodes.fstore ||
        op == Opcodes.dstore ||
        op == Opcodes.astore ||
        op == Opcodes.istore_0 ||
        op == Opcodes.istore_1 ||
        op == Opcodes.istore_2 ||
        op == Opcodes.istore_3 ||
        op == Opcodes.lstore_0 ||
        op == Opcodes.lstore_1 ||
        op == Opcodes.lstore_2 ||
        op == Opcodes.lstore_3 ||
        op == Opcodes.fstore_0 ||
        op == Opcodes.fstore_1 ||
        op == Opcodes.fstore_2 ||
        op == Opcodes.fstore_3 ||
        op == Opcodes.dstore_0 ||
        op == Opcodes.dstore_1 ||
        op == Opcodes.dstore_2 ||
        op == Opcodes.dstore_3 ||
        op == Opcodes.astore_0 ||
        op == Opcodes.astore_1 ||
        op == Opcodes.astore_2 ||
        op == Opcodes.astore_3;
    bool isLoadOpcode(int op) =>
        op == Opcodes.iload ||
        op == Opcodes.lload ||
        op == Opcodes.fload ||
        op == Opcodes.dload ||
        op == Opcodes.aload ||
        op == Opcodes.iload_0 ||
        op == Opcodes.iload_1 ||
        op == Opcodes.iload_2 ||
        op == Opcodes.iload_3 ||
        op == Opcodes.lload_0 ||
        op == Opcodes.lload_1 ||
        op == Opcodes.lload_2 ||
        op == Opcodes.lload_3 ||
        op == Opcodes.fload_0 ||
        op == Opcodes.fload_1 ||
        op == Opcodes.fload_2 ||
        op == Opcodes.fload_3 ||
        op == Opcodes.dload_0 ||
        op == Opcodes.dload_1 ||
        op == Opcodes.dload_2 ||
        op == Opcodes.dload_3 ||
        op == Opcodes.aload_0 ||
        op == Opcodes.aload_1 ||
        op == Opcodes.aload_2 ||
        op == Opcodes.aload_3;

    // 校验 store; load; return 三段式（从给定 store 偏移开始）
    bool verifyStoreLoadReturn(int storeOffset) {
      final loadOffset = _nextInstructionOffset(storeOffset, offsetToIns);
      if (loadOffset == null) return false;
      final loadIns = offsetToIns[loadOffset];
      if (loadIns == null || !isLoadOpcode(loadIns.opcode)) return false;
      final retOffset = _nextInstructionOffset(loadOffset, offsetToIns);
      if (retOffset == null) return false;
      final retIns = offsetToIns[retOffset];
      return retIns != null && _isReturn(retIns);
    }

    // 模式 A: 目标本身是 store; load; return
    if (isStoreOpcode(targetOp) && verifyStoreLoadReturn(offset)) {
      return ''; // 使用栈顶值
    }

    // 模式 B: 目标是 push 指令，后面跟 store; load; return
    final pushValue = _pushInstructionValue(targetIns);
    if (pushValue != null) {
      final storeOffset = _nextInstructionOffset(offset, offsetToIns);
      if (storeOffset != null &&
          offsetToIns[storeOffset] != null &&
          isStoreOpcode(offsetToIns[storeOffset]!.opcode) &&
          verifyStoreLoadReturn(storeOffset)) {
        return pushValue;
      }
    }

    return null;
  }

  /// 若指令是"压入常量到栈"的指令，返回其值的字符串表示；否则返回 null。
  String? _pushInstructionValue(Instruction ins) {
    final op = ins.opcode;
    switch (op) {
      case Opcodes.iconst_m1:
        return '-1';
      case Opcodes.iconst_0:
      case Opcodes.iconst_1:
      case Opcodes.iconst_2:
      case Opcodes.iconst_3:
      case Opcodes.iconst_4:
      case Opcodes.iconst_5:
        return '${op - Opcodes.iconst_0}';
      case Opcodes.lconst_0:
      case Opcodes.lconst_1:
        return '${op - Opcodes.lconst_0}.0L';
      case Opcodes.fconst_0:
      case Opcodes.fconst_1:
      case Opcodes.fconst_2:
        return '${op - Opcodes.fconst_0}.0f';
      case Opcodes.dconst_0:
      case Opcodes.dconst_1:
        return '${op - Opcodes.dconst_0}.0';
      case Opcodes.bipush:
      case Opcodes.sipush:
        return '${ins.operands[0]}';
      case Opcodes.ldc:
      case Opcodes.ldc_w:
        return _ldcValue(ins.operands[0] as int);
      case Opcodes.aconst_null:
        return 'null';
      default:
        return null;
    }
  }

  /// 返回 ldc 指令加载的常量的字符串表示。
  String _ldcValue(int index) {
    try {
      return _pool.getLiteral(index);
    } catch (_) {
      return 'null';
    }
  }

  /// 返回给定偏移量之后的下一条指令偏移量。
  int? _nextInstructionOffset(int offset, Map<int, Instruction> offsetToIns) {
    final sortedOffsets = offsetToIns.keys.toList()..sort();
    final idx = sortedOffsets.indexOf(offset);
    if (idx < 0 || idx + 1 >= sortedOffsets.length) return null;
    return sortedOffsets[idx + 1];
  }

  (String, Map<int, int>) _printStackBased(List<Instruction> ins) {
    final buffer = StringBuffer();
    final out = _CountingSink(buffer);
    final labels = <int>{};
    final offsetToLine = <int, int>{};
    for (final i in ins) {
      if (CodePrinter._branchOpcodes.contains(i.opcode) ||
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
          final ldcEntry = _pool.get(i.operands[0] as int);
          if (ldcEntry is CpString) {
            final raw = _pool.getString(ldcEntry.stringIndex);
            push(_formatStringLiteral(raw));
          } else {
            push(_pool.getLiteral(i.operands[0] as int));
          }
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
          final castType = switch (i.opcode) {
            Opcodes.i2l => 'long',
            Opcodes.i2f => 'float',
            Opcodes.i2d => 'double',
            Opcodes.l2i => 'int',
            Opcodes.l2f => 'float',
            Opcodes.l2d => 'double',
            Opcodes.f2i => 'int',
            Opcodes.f2l => 'long',
            Opcodes.f2d => 'double',
            Opcodes.d2i => 'int',
            Opcodes.d2l => 'long',
            Opcodes.d2f => 'float',
            Opcodes.i2b => 'byte',
            Opcodes.i2c => 'char',
            Opcodes.i2s => 'short',
            _ => 'int'
          };
          push('(($castType) (${pop()}))');
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
            // 检测 switch 表达式合并点模式
            final retVal = _trySwitchExprReturnValue(target, offsetToIns);
            if (retVal != null) {
              if (retVal.isEmpty) {
                // 模式 A: 使用栈顶值
                if (stack.isNotEmpty) {
                  out.writeln('        return ${pop()};');
                  stack.clear();
                } else {
                  out.writeln('        goto label_$target;');
                }
              } else {
                // 模式 B: 使用 push 指令的常量值
                out.writeln('        return $retVal;');
                stack.clear();
              }
            } else {
              out.writeln('        goto label_$target;');
            }
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
          } else if (expr.isNotEmpty) {
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
          final size = pop();
          // 检测数组字面量初始化模式：
          // anewarray N, dup, iconst_0, xload, aastore, [iconst_1, xload, aastore, ...]
          // 若紧跟此模式，生成 `new Type[]{v0, v1, ...}` 并跳过相应指令
          final (literalExpr, skipTo) = _tryBuildArrayLiteral(
            ins,
            idx,
            etype,
            size,
            localNames,
          );
          if (literalExpr != null) {
            push(literalExpr);
            idx = skipTo;
          } else {
            push('new $etype[$size]');
          }
        case Opcodes.multianewarray:
          final dims = i.operands[1] as int;
          // operand[0] 指向 CpClass，其名为字段描述符（如 `[[I` 或 `[Ljava/lang/Object;`）。
          // 解析为源码形式（如 `int[][]`），再把前 dims 个 `[]` 替换为 `[arg]`。
          final fullType = DescriptorParser.parseFieldDescriptor(
              _pool.getClassName(i.operands[0] as int));
          final args = List.generate(dims, (_) => pop()).reversed.toList();
          var rendered = fullType;
          for (var d = 0; d < dims; d++) {
            rendered = rendered.replaceFirst('[]', '[${args[d]}]');
          }
          push('new $rendered');
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
    final (paramTypes, _) = DescriptorParser.parseMethodDescriptor(descriptor);
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
                _pool.getClassName(i.operands[0] as int),
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

  /// 解析 LambdaMetafactory.metafactory 调用，返回方法引用或 lambda 表达式字符串。
  /// 返回 null 表示无法解析。

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

      // 尝试解析 LambdaMetafactory 调用
      final lambdaResult = _tryParseLambda(id, args);
      if (lambdaResult != null) {
        expr = lambdaResult;
        returns = ret != 'void';
      } else {
        expr = 'invokedynamic $name(${args.join(', ')})';
        returns = ret != 'void';
      }
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
      final rawArgs = List.generate(params.length, (_) => stack.removeLast())
          .reversed
          .toList();
      // 对 boolean 类型参数把字面量 0/1 转为 false/true
      final args = <String>[];
      for (var ai = 0; ai < rawArgs.length; ai++) {
        final a = rawArgs[ai];
        final t = ai < params.length ? params[ai] : '';
        if (t == 'boolean') {
          if (a == '0') {
            args.add('false');
          } else if (a == '1') {
            args.add('true');
          } else {
            args.add(a);
          }
        } else {
          args.add(a);
        }
      }
      final argsStr = args.join(', ');
      if (op == Opcodes.invokestatic) {
        expr = '${ref.$1}.${ref.$2}($argsStr)';
      } else if (op == Opcodes.invokespecial && ref.$2 == '<init>') {
        if (stack.isEmpty) {
          expr = '/*init underflow*/.<init>($argsStr)';
          return (expr, false);
        }
        final obj = stack.removeLast();
        // new Class() / dup / invokespecial <init> 合并成 new Class(args)
        if (obj.startsWith('new ${ref.$1}(')) {
          if (stack.isNotEmpty && stack.last == obj) {
            stack.removeLast(); // 移除 new 留下的占位对象
          }
          expr = 'new ${ref.$1}($argsStr)';
          return (expr, true);
        }
        // super(...) 或 this(...) 调用：obj 通常是 `this`
        // 生成 `super(args)` 或 `this(args)` 并作为语句输出
        if (obj == 'this') {
          // 判断是 super 还是 this 调用
          final thisClassName = DescriptorParser.internalToSourceName(
              _pool.getClassName(_cf.thisClass));
          final isThisCall = ref.$1 == thisClassName;
          if (isThisCall) {
            // this(args) 调用总是保留
            expr = 'this($argsStr)';
            return (expr, false);
          }
          // super 调用：
          // - super() 无参：Java 中隐式，跳过
          // - super(name, ordinal) 到 java.lang.Enum：编译器生成，跳过
          // - super(...) 到 java.lang.Object：跳过
          final superClassName = ref.$1;
          if (argsStr.isEmpty) {
            return ('', false); // 隐式 super()
          }
          if (superClassName == 'java.lang.Object' ||
              superClassName == 'java.lang.Enum') {
            return ('', false); // 编译器生成
          }
          expr = 'super($argsStr)';
          return (expr, false);
        }
        expr = '$obj.<init>($argsStr)';
        return (expr, false);
      } else if (op == Opcodes.invokespecial) {
        final obj = stack.removeLast();
        expr = '$obj.${ref.$2}($argsStr)';
      } else {
        final obj = stack.removeLast();
        expr = '$obj.${ref.$2}($argsStr)';
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

  /// 尝试检测并构建数组字面量初始化模式：
  /// `anewarray N, dup, iconst_0, xload, aastore, [iconst_1, xload, aastore, ...]`
  ///
  /// 从 [startIdx]（指向 anewarray）开始检测，返回生成的字面量表达式和
  /// 应跳转到的下一条指令索引（指向 aastore 之后的指令）。
  /// 若模式不匹配，返回 (null, startIdx)。
  (String?, int) _tryBuildArrayLiteral(
    List<Instruction> ins,
    int startIdx,
    String etype,
    String sizeExpr,
    Map<int, String> localNames,
  ) {
    // 必须是常量大小
    final size = int.tryParse(sizeExpr);
    if (size == null || size < 0 || size > 16) return (null, startIdx);
    var i = startIdx + 1;
    // 下一条必须是 dup
    if (i >= ins.length || ins[i].opcode != Opcodes.dup) {
      return (null, startIdx);
    }
    i++;
    final elements = <String>[];
    for (var k = 0; k < size; k++) {
      // 期望：iconst_k 或 bipush/ldc k
      final idxInstr = ins[i];
      final idxOk = switch (idxInstr.opcode) {
        Opcodes.iconst_m1 => k == -1,
        Opcodes.iconst_0 => k == 0,
        Opcodes.iconst_1 => k == 1,
        Opcodes.iconst_2 => k == 2,
        Opcodes.iconst_3 => k == 3,
        Opcodes.iconst_4 => k == 4,
        Opcodes.iconst_5 => k == 5,
        Opcodes.bipush => (idxInstr.operands[0] as int) == k,
        _ => false,
      };
      if (!idxOk) return (null, startIdx);
      i++;
      // 加载值：iload/aload/ldc/iconst 等（仅处理简单 load 指令）
      if (i >= ins.length) return (null, startIdx);
      final loadInstr = ins[i];
      final value = _loadExpr(loadInstr, localNames);
      if (value == null) return (null, startIdx);
      i++;
      // aastore
      if (i >= ins.length || ins[i].opcode != Opcodes.aastore) {
        return (null, startIdx);
      }
      i++;
      elements.add(value);
    }
    return ('new $etype[]{ ${elements.join(', ')} }', i - 1);
  }

  /// 返回 load 指令对应的表达式，若不是支持的 load 指令则返回 null。
  String? _loadExpr(Instruction i, Map<int, String> localNames) {
    switch (i.opcode) {
      case Opcodes.aconst_null:
        return 'null';
      case Opcodes.iconst_m1:
        return '-1';
      case Opcodes.iconst_0:
        return '0';
      case Opcodes.iconst_1:
        return '1';
      case Opcodes.iconst_2:
        return '2';
      case Opcodes.iconst_3:
        return '3';
      case Opcodes.iconst_4:
        return '4';
      case Opcodes.iconst_5:
        return '5';
      case Opcodes.lconst_0:
        return '0L';
      case Opcodes.lconst_1:
        return '1L';
      case Opcodes.fconst_0:
        return '0.0F';
      case Opcodes.fconst_1:
        return '1.0F';
      case Opcodes.fconst_2:
        return '2.0F';
      case Opcodes.dconst_0:
        return '0.0';
      case Opcodes.dconst_1:
        return '1.0';
      case Opcodes.bipush:
        return '${i.operands[0]}';
      case Opcodes.sipush:
        return '${i.operands[0]}';
      case Opcodes.ldc:
      case Opcodes.ldc_w:
      case Opcodes.ldc2_w:
        return _ldcValue(i.operands[0] as int);
      case Opcodes.iload:
      case Opcodes.lload:
      case Opcodes.fload:
      case Opcodes.dload:
      case Opcodes.aload:
        return localNames[i.operands[0] as int] ?? 'var${i.operands[0]}';
      case Opcodes.iload_0:
      case Opcodes.lload_0:
      case Opcodes.fload_0:
      case Opcodes.dload_0:
      case Opcodes.aload_0:
        return localNames[0] ?? 'var0';
      case Opcodes.iload_1:
      case Opcodes.lload_1:
      case Opcodes.fload_1:
      case Opcodes.dload_1:
      case Opcodes.aload_1:
        return localNames[1] ?? 'var1';
      case Opcodes.iload_2:
      case Opcodes.lload_2:
      case Opcodes.fload_2:
      case Opcodes.dload_2:
      case Opcodes.aload_2:
        return localNames[2] ?? 'var2';
      case Opcodes.iload_3:
      case Opcodes.lload_3:
      case Opcodes.fload_3:
      case Opcodes.dload_3:
      case Opcodes.aload_3:
        return localNames[3] ?? 'var3';
      default:
        return null;
    }
  }

  /// 返回 ldc 指令加载的常量值的源码表示。

  /// 尝试把 Java 21 的 pattern switch 状态机还原成可读的 switch 表达式。
  /// 这只是一个启发式优化，针对 `invokedynamic typeSwitch` 生成的典型字节码。

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
