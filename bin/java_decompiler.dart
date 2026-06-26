import 'dart:io';

import 'package:args/args.dart';
import 'package:java_decompiler/java_decompiler.dart';
import 'package:java_decompiler/src/attributes/attribute_models.dart';
import 'package:java_decompiler/src/bytecode/bytecode_decoder.dart';
import 'package:java_decompiler/src/bytecode/instructions.dart';

void main(List<String> args) {
  final parser = ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false, help: '显示帮助')
    ..addFlag('source', abbr: 's', negatable: false, help: '反编译为 Java 源码（默认行为）')
    ..addFlag('disassemble', abbr: 'd', negatable: false, help: '仅反汇编字节码')
    ..addFlag('methods', abbr: 'm', negatable: false, help: '输出所有方法签名')
    ..addFlag('fields', abbr: 'f', negatable: false, help: '输出所有字段')
    ..addFlag('hide-empty-public-ctors',
        negatable: false, help: '省略空的 public 默认构造方法')
    ..addFlag('dump-pool', negatable: false, help: '打印常量池内容');
  final results = parser.parse(args);

  if (results['help'] as bool || results.rest.isEmpty) {
    print('用法: dart run java_decompiler [选项] <class文件>');
    print(parser.usage);
    exitCode = results.rest.isEmpty ? 1 : 0;
    return;
  }

  final path = results.rest.first;
  final file = File(path);
  if (!file.existsSync()) {
    stderr.writeln('文件不存在: $path');
    exitCode = 1;
    return;
  }

  final bytes = file.readAsBytesSync();
  final classFile = ClassFileParser(bytes).parse();

  if (results['dump-pool'] as bool) {
    _dumpPool(classFile);
    return;
  }

  if (results['disassemble'] as bool) {
    _disassemble(classFile);
  } else if (results['methods'] as bool) {
    print(Decompiler(classFile).methodSignatures());
  } else if (results['fields'] as bool) {
    print(Decompiler(classFile).fieldList());
  } else {
    print(Decompiler(
      classFile,
      hideEmptyPublicConstructors: results['hide-empty-public-ctors'] as bool,
    ).decompile());
  }
}

void _disassemble(ClassFile cf) {
  final pool = cf.constantPool;
  print('// disassembled from ${pool.getClassName(cf.thisClass)}');
  for (final method in cf.methods) {
    final name = pool.getString(method.nameIndex);
    final desc = pool.getString(method.descriptorIndex);
    print('\n// method: $name$desc');
    final code = method.attributes.whereType<CodeAttribute>().firstOrNull;
    if (code == null) {
      print('    // (no Code attribute)');
      continue;
    }
    print('    // maxStack=${code.maxStack}, maxLocals=${code.maxLocals}');
    final instructions = BytecodeDecoder(code.code).decode();
    for (final ins in instructions) {
      print('    ${_formatInstruction(ins, pool)}');
    }
    if (code.exceptionTable.isNotEmpty) {
      print('    // exception table:');
      for (final e in code.exceptionTable) {
        final catchType =
            e.catchType == 0 ? 'finally' : pool.getClassName(e.catchType);
        print('    //   ${e.startPc}-${e.endPc} -> ${e.handlerPc}: $catchType');
      }
    }
  }
}

String _formatInstruction(Instruction ins, ConstantPool pool) {
  final buf =
      StringBuffer('${ins.offset.toString().padLeft(4)}: ${ins.mnemonic}');
  for (final op in ins.operands) {
    if (op is int) {
      buf.write(' $op');
      final extra = _resolveOperand(ins.opcode, op, pool);
      if (extra != null) buf.write(' // $extra');
    } else {
      buf.write(' $op');
    }
  }
  return buf.toString();
}

String? _resolveOperand(int opcode, int op, ConstantPool pool) {
  try {
    if (opcode == Opcodes.ldc ||
        opcode == Opcodes.ldc_w ||
        opcode == Opcodes.ldc2_w) {
      final e = pool.get(op);
      return switch (e) {
        CpString() => '"${pool.getString(e.stringIndex)}"',
        CpClass() => pool.getString(e.nameIndex).replaceAll('/', '.'),
        CpInteger(:final value) => value.toString(),
        CpFloat(:final value) => '${value}f',
        CpLong(:final value) => '${value}L',
        CpDouble(:final value) => value.toString(),
        _ => null,
      };
    }
    if (opcode == Opcodes.getstatic ||
        opcode == Opcodes.putstatic ||
        opcode == Opcodes.getfield ||
        opcode == Opcodes.putfield) {
      final ref = pool.getFieldref(op);
      final cls = pool.getClassName(ref.classIndex);
      final nt = pool.getNameAndType(ref.nameAndTypeIndex);
      return '$cls.${pool.getString(nt.nameIndex)}:${pool.getString(nt.descriptorIndex)}';
    }
    if (opcode == Opcodes.invokevirtual ||
        opcode == Opcodes.invokespecial ||
        opcode == Opcodes.invokestatic) {
      final ref = pool.getMethodref(op);
      final cls = pool.getClassName(ref.classIndex);
      final nt = pool.getNameAndType(ref.nameAndTypeIndex);
      return '$cls.${pool.getString(nt.nameIndex)}${pool.getString(nt.descriptorIndex)}';
    }
    if (opcode == Opcodes.invokeinterface) {
      final ref = pool.getInterfaceMethodref(op);
      final cls = pool.getClassName(ref.classIndex);
      final nt = pool.getNameAndType(ref.nameAndTypeIndex);
      return '$cls.${pool.getString(nt.nameIndex)}${pool.getString(nt.descriptorIndex)}';
    }
    if (opcode == Opcodes.invokedynamic) {
      final id = pool.getInvokeDynamic(op);
      final nt = pool.getNameAndType(id.nameAndTypeIndex);
      return '${pool.getString(nt.nameIndex)}${pool.getString(nt.descriptorIndex)}';
    }
    if (opcode == Opcodes.new_ ||
        opcode == Opcodes.anewarray ||
        opcode == Opcodes.checkcast ||
        opcode == Opcodes.instanceof) {
      return pool.getClassName(op);
    }
  } catch (_) {
    // ignore malformed or unknown refs
  }
  return null;
}

void _dumpPool(ClassFile cf) {
  final pool = cf.constantPool;
  print('Constant pool count: ${pool.length}');
  for (var i = 1; i < pool.length; i++) {
    final entry = pool.get(i);
    if (entry == null) continue;
    print('  #$i = ${_formatEntry(pool, entry)}');
    if (entry is CpLong || entry is CpDouble) i++;
  }
}

String _formatEntry(ConstantPool pool, CpInfo entry) {
  return switch (entry) {
    CpUtf8(:final value) => 'Utf8 "$value"',
    CpInteger(:final value) => 'Integer $value',
    CpFloat(:final value) => 'Float $value',
    CpLong(:final value) => 'Long $value',
    CpDouble(:final value) => 'Double $value',
    CpClass() => 'Class #${entry.nameIndex} ${pool.getString(entry.nameIndex)}',
    CpString() =>
      'String #${entry.stringIndex} ${pool.getString(entry.stringIndex)}',
    CpFieldref() => 'Fieldref #${entry.classIndex}.#${entry.nameAndTypeIndex}',
    CpMethodref() =>
      'Methodref #${entry.classIndex}.#${entry.nameAndTypeIndex}',
    CpInterfaceMethodref() =>
      'InterfaceMethodref #${entry.classIndex}.#${entry.nameAndTypeIndex}',
    CpNameAndType() =>
      'NameAndType #${entry.nameIndex}:#${entry.descriptorIndex}',
    CpMethodHandle(:final referenceKind, :final referenceIndex) =>
      'MethodHandle kind=$referenceKind index=$referenceIndex',
    CpMethodType() => 'MethodType #${entry.descriptorIndex}',
    CpDynamic(:final bootstrapMethodAttrIndex, :final nameAndTypeIndex) =>
      'Dynamic bsm=$bootstrapMethodAttrIndex nat=$nameAndTypeIndex',
    CpInvokeDynamic(:final bootstrapMethodAttrIndex, :final nameAndTypeIndex) =>
      'InvokeDynamic bsm=$bootstrapMethodAttrIndex nat=$nameAndTypeIndex',
    CpModule() => 'Module #${entry.nameIndex}',
    CpPackage() => 'Package #${entry.nameIndex}',
    _ => 'Unknown ${entry.runtimeType}',
  };
}
