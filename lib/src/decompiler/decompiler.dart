import '../attributes/attribute_models.dart';
import '../class_file.dart';
import '../constants/constant_pool.dart';
import '../descriptor_parser.dart';
import '../flags/access_flags.dart';
import 'code_printer.dart';

class Decompiler {
  final ClassFile _cf;
  late final ConstantPool _pool;

  Decompiler(this._cf) {
    _pool = _cf.constantPool;
  }

  String decompile() {
    final sb = StringBuffer();
    final className = _pool.getClassName(_cf.thisClass);
    final package = _packageOf(className);
    if (package.isNotEmpty) {
      sb.writeln('package $package;');
      sb.writeln();
    }

    _writeClassAnnotations(sb);
    _writeClassDeclaration(sb, className);
    sb.writeln(' {');

    for (final field in _cf.fields) {
      _writeField(sb, field);
    }
    if (_cf.fields.isNotEmpty && _cf.methods.isNotEmpty) sb.writeln();
    for (final method in _cf.methods) {
      _writeMethod(sb, method, className);
    }

    sb.writeln('}');
    return sb.toString();
  }

  String _packageOf(String className) {
    final dot = className.lastIndexOf('/');
    if (dot == -1) return '';
    return DescriptorParser.internalToSourceName(className.substring(0, dot));
  }

  String _simpleName(String className) {
    final dot = className.lastIndexOf('/');
    return dot == -1 ? className : className.substring(dot + 1);
  }

  void _writeClassAnnotations(StringBuffer sb) {
    for (final attr in _cf.attributes) {
      if (attr is RuntimeVisibleAnnotationsAttribute) {
        for (final ann in attr.annotations) {
          sb.writeln('  ${_annotationToString(ann)}');
        }
      }
    }
  }

  String _annotationToString(Annotation ann) {
    final type =
        DescriptorParser.parseFieldDescriptor(_pool.getString(ann.typeIndex));
    final pairs = ann.elementValuePairs.map((p) {
      final name = _pool.getString(p.elementNameIndex);
      return '$name = ${_elementValueToString(p.value)}';
    }).join(', ');
    return '@$type${pairs.isEmpty ? '' : '($pairs)'}';
  }

  String _elementValueToString(ElementValue value) {
    return switch (value) {
      ConstElementValue(:final tag, :final constValueIndex) =>
        tag == 'c'.codeUnitAt(0)
            ? _classLiteral(constValueIndex)
            : _pool.getLiteral(constValueIndex),
      EnumElementValue(:final typeNameIndex, :final constNameIndex) =>
        '${_pool.getString(typeNameIndex)}.${_pool.getString(constNameIndex)}',
      ClassElementValue(:final classInfoIndex) => _classLiteral(classInfoIndex),
      AnnotationElementValue(:final annotationValue) =>
        _annotationToString(annotationValue),
      ArrayElementValue(:final values) =>
        '{${values.map(_elementValueToString).join(', ')}}',
      _ => '?',
    };
  }

  String _classLiteral(int index) {
    final entry = _pool.get(index);
    final raw = switch (entry) {
      CpClass(:final nameIndex) => _pool.getString(nameIndex),
      CpUtf8(:final value) => value,
      _ => '/*class?*/',
    };
    if (raw == '/*class?*/') return raw;
    if (raw.startsWith('L') && raw.endsWith(';')) {
      return '${DescriptorParser.internalToSourceName(raw.substring(1, raw.length - 1))}.class';
    }
    if (raw.startsWith('[')) {
      return '${DescriptorParser.parseFieldDescriptor(raw)}.class';
    }
    return '${DescriptorParser.internalToSourceName(raw)}.class';
  }

  void _writeClassDeclaration(StringBuffer sb, String className) {
    final flags = _cf.accessFlags;
    final kind = _classKind(flags);
    final mods = AccessFlagFormatter.classFlags(flags);
    if (flags & AccessFlags.ACC_MODULE != 0) {
      // module-info 特殊处理
      sb.write('module ${_pool.getString(_cf.thisClass)}');
      return;
    }
    final decl = <String>[];
    if (mods.contains('public')) decl.add('public');
    if (mods.contains('final')) decl.add('final');
    if (mods.contains('abstract') &&
        kind != 'interface' &&
        kind != '@interface') {
      decl.add('abstract');
    }
    decl.add(kind == '@interface' ? '@interface' : kind);
    decl.add(_simpleName(className));
    sb.write(decl.join(' '));

    if (kind == 'class') {
      final superName =
          _cf.superClass == 0 ? null : _pool.getClassName(_cf.superClass);
      if (superName != null && superName != 'java/lang/Object') {
        sb.write(
            ' extends ${DescriptorParser.internalToSourceName(superName)}');
      }
    }
    if (_cf.interfaces.isNotEmpty) {
      final keyword = kind == 'interface' || kind == '@interface'
          ? ' extends '
          : ' implements ';
      final ifaces = _cf.interfaces
          .map((idx) =>
              DescriptorParser.internalToSourceName(_pool.getClassName(idx)))
          .join(', ');
      sb.write('$keyword$ifaces');
    }
  }

  String _classKind(int flags) {
    if ((flags & AccessFlags.ACC_ANNOTATION) != 0) return '@interface';
    if ((flags & AccessFlags.ACC_INTERFACE) != 0) return 'interface';
    if ((flags & AccessFlags.ACC_ENUM) != 0) return 'enum';
    return 'class';
  }

  void _writeField(StringBuffer sb, FieldInfo field) {
    final name = _pool.getString(field.nameIndex);
    final desc = _pool.getString(field.descriptorIndex);
    final type = DescriptorParser.parseFieldDescriptor(desc);
    final mods = AccessFlagFormatter.fieldFlags(field.accessFlags);
    _writeMemberAnnotations(sb, field);
    sb.write('    ${mods.join(' ')}${mods.isEmpty ? '' : ' '}$type $name');
    final cv = field.attribute<ConstantValueAttribute>();
    if (cv != null && (field.accessFlags & AccessFlags.ACC_STATIC) != 0) {
      sb.write(' = ${_pool.getLiteral(cv.constantValueIndex)}');
    }
    sb.writeln(';');
  }

  void _writeMethod(StringBuffer sb, MethodInfo method, String className) {
    final rawName = _pool.getString(method.nameIndex);
    final desc = _pool.getString(method.descriptorIndex);
    final (paramTypes, returnType) =
        DescriptorParser.parseMethodDescriptor(desc);
    final isStatic = (method.accessFlags & AccessFlags.ACC_STATIC) != 0;
    final isAbstract = (method.accessFlags & AccessFlags.ACC_ABSTRACT) != 0;
    final isNative = (method.accessFlags & AccessFlags.ACC_NATIVE) != 0;
    final displayName = rawName == '<init>' ? _simpleName(className) : rawName;
    final displayReturn = rawName == '<init>' ? '' : returnType;
    final mods = AccessFlagFormatter.methodFlags(method.accessFlags);
    _writeMemberAnnotations(sb, method);
    sb.write(
        '    ${mods.join(' ')}${mods.isEmpty ? '' : ' '}${displayReturn.isEmpty ? '' : '$displayReturn '}$displayName(');

    final params = _parameterNames(method, paramTypes.length, isStatic);
    for (var i = 0; i < paramTypes.length; i++) {
      if (i > 0) sb.write(', ');
      sb.write('${paramTypes[i]} ${params[i]}');
    }
    sb.write(')');

    final exceptions = method.attribute<ExceptionsAttribute>();
    if (exceptions != null && exceptions.exceptionIndexTable.isNotEmpty) {
      final names = exceptions.exceptionIndexTable
          .map((idx) =>
              DescriptorParser.internalToSourceName(_pool.getClassName(idx)))
          .join(', ');
      sb.write(' throws $names');
    }

    if (isAbstract || isNative) {
      sb.writeln(';');
      return;
    }

    sb.writeln(' {');
    final code = method.attribute<CodeAttribute>();
    if (code != null) {
      final printer = CodePrinter(method, code, _pool);
      sb.write(printer.printBody());
    } else {
      sb.writeln('        // no Code attribute');
    }
    sb.writeln('    }');
  }

  void _writeMemberAnnotations(StringBuffer sb, MemberInfo member) {
    for (final attr in member.attributes) {
      if (attr is RuntimeVisibleAnnotationsAttribute) {
        for (final ann in attr.annotations) {
          sb.writeln('    ${_annotationToString(ann)}');
        }
      }
    }
  }

  List<String> _parameterNames(MethodInfo method, int count, bool isStatic) {
    final lvt = method.attribute<LocalVariableTableAttribute>();
    final names = List<String>.filled(count, '', growable: false);
    if (lvt != null) {
      for (final e in lvt.localVariableTable) {
        final slot = e.index;
        final paramSlot = isStatic ? slot : slot - 1;
        if (e.startPc == 0 &&
            paramSlot >= 0 &&
            paramSlot < count &&
            names[paramSlot].isEmpty) {
          names[paramSlot] = _pool.getString(e.nameIndex);
        }
      }
    }
    for (var i = 0; i < count; i++) {
      if (names[i].isEmpty) names[i] = 'p$i';
    }
    return names;
  }
}
