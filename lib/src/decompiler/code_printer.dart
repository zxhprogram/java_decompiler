import '../attributes/attribute_models.dart';
import '../bytecode/bytecode_decoder.dart';
import '../bytecode/instructions.dart';
import '../class_file.dart';
import '../constants/constant_pool.dart';
import '../descriptor_parser.dart';
import '../flags/access_flags.dart';

class CodePrinter {
  final MethodInfo _method;
  final CodeAttribute _code;
  final ConstantPool _pool;

  CodePrinter(this._method, this._code, this._pool);

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

    return _printStackBased(instructions);
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

  String _printStackBased(List<Instruction> ins) {
    final out = StringBuffer();
    final labels = <int>{};
    for (final i in ins) {
      if (_branchOpcodes.contains(i.opcode) ||
          i.opcode == Opcodes.tableswitch ||
          i.opcode == Opcodes.lookupswitch) {
        for (final op in i.operands) {
          if (op is int && op >= 0 && op <= _code.code.length) labels.add(op);
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

    final isStatic = (_method.accessFlags & AccessFlags.ACC_STATIC) != 0;
    final methodDesc = _pool.getString(_method.descriptorIndex);
    final localNames = _buildLocalNames(isStatic, methodDesc);

    for (final i in ins) {
      if (labels.contains(i.offset)) {
        out.writeln('      label_${i.offset}:');
      }
      void push(String v) => stack.add(v);

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
          push(localNames[i.operands[0] as int] ?? 'lv${i.operands[0]}');
        case Opcodes.iload_0 ||
              Opcodes.lload_0 ||
              Opcodes.fload_0 ||
              Opcodes.dload_0 ||
              Opcodes.aload_0:
          push(localNames[0] ?? 'lv0');
        case Opcodes.iload_1 ||
              Opcodes.lload_1 ||
              Opcodes.fload_1 ||
              Opcodes.dload_1 ||
              Opcodes.aload_1:
          push(localNames[1] ?? 'lv1');
        case Opcodes.iload_2 ||
              Opcodes.lload_2 ||
              Opcodes.fload_2 ||
              Opcodes.dload_2 ||
              Opcodes.aload_2:
          push(localNames[2] ?? 'lv2');
        case Opcodes.iload_3 ||
              Opcodes.lload_3 ||
              Opcodes.fload_3 ||
              Opcodes.dload_3 ||
              Opcodes.aload_3:
          push(localNames[3] ?? 'lv3');
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
          out.writeln('        ${localNames[slot] ?? "lv$slot"} = $v;');
        case Opcodes.istore_0 ||
              Opcodes.lstore_0 ||
              Opcodes.fstore_0 ||
              Opcodes.dstore_0 ||
              Opcodes.astore_0:
          _emitStore(out, localNames[0], pop());
        case Opcodes.istore_1 ||
              Opcodes.lstore_1 ||
              Opcodes.fstore_1 ||
              Opcodes.dstore_1 ||
              Opcodes.astore_1:
          _emitStore(out, localNames[1], pop());
        case Opcodes.istore_2 ||
              Opcodes.lstore_2 ||
              Opcodes.fstore_2 ||
              Opcodes.dstore_2 ||
              Opcodes.astore_2:
          _emitStore(out, localNames[2], pop());
        case Opcodes.istore_3 ||
              Opcodes.lstore_3 ||
              Opcodes.fstore_3 ||
              Opcodes.dstore_3 ||
              Opcodes.astore_3:
          _emitStore(out, localNames[3], pop());
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
          out.writeln('        ${localNames[slot] ?? "lv$slot"} += $inc;');
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
          out.writeln('        goto label_${i.operands[0]};');
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
        case Opcodes.goto_w:
          out.writeln('        goto label_${i.operands[0]};');
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
    return out.toString();
  }

  void _emitStore(StringBuffer out, String? name, String value) {
    out.writeln('        ${name ?? "?"} = $value;');
  }

  Map<int, String> _buildLocalNames(bool isStatic, String descriptor) {
    final names = <int, String>{};
    if (!isStatic) names[0] = 'this';

    final lvt = _method.attribute<LocalVariableTableAttribute>();
    if (lvt != null) {
      for (final e in lvt.localVariableTable) {
        if (e.startPc == 0 && !names.containsKey(e.index)) {
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
    final simple = RegExp(r'^[a-zA-Z_$][\w$]*$');
    if (!simple.hasMatch(value) && value != '/*stack underflow*/') {
      out.writeln('        $value;');
    }
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
          .join(', ');
      expr = 'invokedynamic $name($args)';
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
}
