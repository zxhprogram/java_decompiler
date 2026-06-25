import '../attributes/attribute_models.dart';
import '../bytecode/bytecode_decoder.dart';
import '../bytecode/instructions.dart';
import '../class_file.dart';
import '../constants/constant_pool.dart';
import '../descriptor_parser.dart';
import '../flags/access_flags.dart';
import 'code_printer.dart';

class Decompiler {
  final ClassFile _cf;
  final bool hideEmptyPublicConstructors;
  late final ConstantPool _pool;

  Decompiler(this._cf, {this.hideEmptyPublicConstructors = false}) {
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

    RecordAttribute? recordAttr;
    for (final attr in _cf.attributes) {
      if (attr is RecordAttribute) {
        recordAttr = attr;
        break;
      }
    }
    _writeClassAnnotations(sb);
    if (recordAttr != null) {
      _writeRecordDeclaration(sb, className, recordAttr);
    } else {
      _writeClassDeclaration(sb, className);
    }
    sb.writeln(' {');

    if (recordAttr != null) {
      _writeRecordBody(sb, className, recordAttr);
    } else {
      for (final field in _cf.fields) {
        _writeField(sb, field);
      }
      if (_cf.fields.isNotEmpty && _cf.methods.isNotEmpty) sb.writeln();
      for (final method in _cf.methods) {
        _writeMethod(sb, method, className);
      }
    }

    sb.writeln('}');
    final raw = sb.toString();
    return _addImports(raw, className, package);
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

  void _writeRecordDeclaration(
      StringBuffer sb, String className, RecordAttribute recordAttr) {
    final flags = _cf.accessFlags;
    final mods = AccessFlagFormatter.classFlags(flags);
    final decl = <String>[];
    if (mods.contains('public')) decl.add('public');
    // record 隐式 final，不需要写出
    decl.add('record');
    decl.add(_simpleName(className));
    sb.write(decl.join(' '));

    sb.write('(');
    for (var i = 0; i < recordAttr.components.length; i++) {
      if (i > 0) sb.write(', ');
      final comp = recordAttr.components[i];
      final name = _pool.getString(comp.nameIndex);
      final type = DescriptorParser.parseFieldDescriptor(
          _pool.getString(comp.descriptorIndex));
      sb.write('$type $name');
    }
    sb.write(')');

    if (_cf.interfaces.isNotEmpty) {
      final ifaces = _cf.interfaces
          .map((idx) =>
              DescriptorParser.internalToSourceName(_pool.getClassName(idx)))
          .join(', ');
      sb.write(' implements $ifaces');
    }
  }

  void _writeRecordBody(
      StringBuffer sb, String className, RecordAttribute recordAttr) {
    final componentNames =
        recordAttr.components.map((c) => _pool.getString(c.nameIndex)).toList();
    final componentTypes = recordAttr.components
        .map((c) => DescriptorParser.parseFieldDescriptor(
            _pool.getString(c.descriptorIndex)))
        .toList();

    for (final field in _cf.fields) {
      final name = _pool.getString(field.nameIndex);
      // 记录组件生成的 private final 字段不再输出；静态字段保留
      if ((field.accessFlags & AccessFlags.ACC_STATIC) != 0 ||
          !componentNames.contains(name)) {
        _writeField(sb, field);
      }
    }

    if (_cf.fields.isNotEmpty && _cf.methods.isNotEmpty) sb.writeln();

    for (final method in _cf.methods) {
      if (_isRecordGeneratedMethod(method, componentNames, componentTypes)) {
        continue;
      }
      _writeMethod(sb, method, className);
    }
  }

  bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  bool _isRecordGeneratedMethod(MethodInfo method, List<String> componentNames,
      List<String> componentTypes) {
    final rawName = _pool.getString(method.nameIndex);
    final desc = _pool.getString(method.descriptorIndex);
    final (paramTypes, returnType) =
        DescriptorParser.parseMethodDescriptor(desc);

    // 规范构造器
    if (rawName == '<init>' &&
        paramTypes.length == componentTypes.length &&
        _listEquals(paramTypes, componentTypes)) {
      return true;
    }

    // 访问器
    if (paramTypes.isEmpty &&
        componentNames.contains(rawName) &&
        componentTypes[componentNames.indexOf(rawName)] == returnType) {
      return true;
    }

    // Object 方法
    if (rawName == 'toString' && paramTypes.isEmpty && returnType == 'String') {
      return true;
    }
    if (rawName == 'hashCode' && paramTypes.isEmpty && returnType == 'int') {
      return true;
    }
    if (rawName == 'equals' &&
        paramTypes.length == 1 &&
        paramTypes[0] == 'Object' &&
        returnType == 'boolean') {
      return true;
    }

    return false;
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
    if (hideEmptyPublicConstructors &&
        _isEmptyPublicDefaultConstructor(method)) {
      return;
    }

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

  bool _isEmptyPublicDefaultConstructor(MethodInfo method) {
    if ((method.accessFlags & AccessFlags.ACC_PUBLIC) == 0) return false;
    if (_pool.getString(method.nameIndex) != '<init>') return false;
    if (_pool.getString(method.descriptorIndex) != '()V') return false;
    if (_cf.superClass == 0) return false;
    final superName = _pool.getClassName(_cf.superClass);
    if (superName != 'java/lang/Object') return false;

    final code = method.attribute<CodeAttribute>();
    if (code == null) return false;

    final ins = BytecodeDecoder(code.code).decode();
    if (ins.length != 3) return false;
    if (ins[0].opcode != Opcodes.aload_0) return false;
    if (ins[1].opcode != Opcodes.invokespecial) return false;
    if (ins[2].opcode != Opcodes.return_) return false;

    final ref = _pool.getMethodref(ins[1].operands[0] as int);
    final cls = DescriptorParser.internalToSourceName(
      _pool.getClassName(ref.classIndex),
    );
    final nt = _pool.getNameAndType(ref.nameAndTypeIndex);
    final name = _pool.getString(nt.nameIndex);
    return cls == 'java.lang.Object' && name == '<init>';
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

  String _addImports(String source, String thisClassName, String thisPackage) {
    final refs = _collectReferencedClasses();
    final imports = <String>[];
    final replacements = <String, String>{};
    final usedSimple = <String>{};
    final thisClassDot = DescriptorParser.internalToSourceName(thisClassName);

    String simpleOf(String fqcn) {
      final idx = fqcn.lastIndexOf('.');
      return idx == -1 ? fqcn : fqcn.substring(idx + 1);
    }

    String packageOf(String fqcn) {
      final idx = fqcn.lastIndexOf('.');
      return idx == -1 ? '' : fqcn.substring(0, idx);
    }

    for (final fqcn in refs) {
      if (fqcn == thisClassDot) {
        replacements[fqcn] = simpleOf(fqcn);
        continue;
      }
      final pkg = packageOf(fqcn);
      final simple = simpleOf(fqcn);
      if (pkg == thisPackage || pkg == 'java.lang' || pkg.isEmpty) {
        replacements[fqcn] = simple;
        continue;
      }
      if (!usedSimple.add(simple)) {
        // 同名类冲突，保留全限定名避免歧义
        continue;
      }
      imports.add(fqcn);
      replacements[fqcn] = simple;
    }

    var result = source;
    final sorted = replacements.entries.toList()
      ..sort((a, b) => b.key.length.compareTo(a.key.length));
    for (final e in sorted) {
      result = result.replaceAll(e.key, e.value);
    }

    if (imports.isEmpty) return result;

    imports.sort();
    final block = '\n${imports.map((i) => 'import $i;').join('\n')}\n';
    if (thisPackage.isNotEmpty) {
      final firstNewline = result.indexOf('\n');
      final insertAt = firstNewline + 1;
      return result.substring(0, insertAt) + block + result.substring(insertAt);
    }
    return '${block.trimLeft()}\n$result';
  }

  Set<String> _collectReferencedClasses() {
    final refs = <String>{};

    void addFqcn(String? raw) {
      if (raw == null) return;
      var fqcn = raw;
      if (fqcn.startsWith('L') && fqcn.endsWith(';')) {
        fqcn = fqcn.substring(1, fqcn.length - 1);
      }
      if (fqcn.startsWith('[')) return;
      fqcn = DescriptorParser.internalToSourceName(fqcn);
      if (_isPrimitiveName(fqcn)) return;
      if (!fqcn.contains('.')) return;
      refs.add(fqcn);
    }

    void addType(String type) {
      var t = type.trim();
      while (t.endsWith('[]')) {
        t = t.substring(0, t.length - 2);
      }
      if (_isPrimitiveName(t)) return;
      if (t.contains('.')) addFqcn(t);
    }

    void addDescriptor(String desc) {
      try {
        addType(DescriptorParser.parseFieldDescriptor(desc));
      } catch (_) {}
    }

    void addMethodDescriptor(String desc) {
      try {
        final (params, ret) = DescriptorParser.parseMethodDescriptor(desc);
        for (final p in params) {
          addType(p);
        }
        addType(ret);
      } catch (_) {}
    }

    String? classNameFromIndex(int index) {
      final entry = _pool.get(index);
      return switch (entry) {
        CpClass(:final nameIndex) => _pool.getString(nameIndex),
        CpUtf8(:final value) => value,
        _ => null,
      };
    }

    void collectFromElementValue(ElementValue value) {
      switch (value) {
        case ConstElementValue(:final tag, :final constValueIndex):
          if (tag == 'c'.codeUnitAt(0)) {
            final raw = classNameFromIndex(constValueIndex);
            if (raw != null && !raw.startsWith('[')) {
              addFqcn(DescriptorParser.internalToSourceName(raw));
            }
          }
        case ClassElementValue(:final classInfoIndex):
          final raw = classNameFromIndex(classInfoIndex);
          if (raw != null && !raw.startsWith('[')) {
            addFqcn(DescriptorParser.internalToSourceName(raw));
          }
        case ArrayElementValue(:final values):
          for (final v in values) {
            collectFromElementValue(v);
          }
        case AnnotationElementValue(:final annotationValue):
          addDescriptor(_pool.getString(annotationValue.typeIndex));
          for (final pair in annotationValue.elementValuePairs) {
            collectFromElementValue(pair.value);
          }
      }
    }

    void collectFromAnnotation(Annotation ann) {
      addDescriptor(_pool.getString(ann.typeIndex));
      for (final pair in ann.elementValuePairs) {
        collectFromElementValue(pair.value);
      }
    }

    void collectFromAttributes(List<AttributeInfo> attrs) {
      for (final attr in attrs) {
        List<Annotation> anns = const [];
        if (attr is RuntimeVisibleAnnotationsAttribute) {
          anns = attr.annotations;
        } else if (attr is RuntimeInvisibleAnnotationsAttribute) {
          anns = attr.annotations;
        }
        for (final ann in anns) {
          collectFromAnnotation(ann);
        }

        List<List<Annotation>> paramAnns = const [];
        if (attr is RuntimeVisibleParameterAnnotationsAttribute) {
          paramAnns = attr.parameterAnnotations;
        } else if (attr is RuntimeInvisibleParameterAnnotationsAttribute) {
          paramAnns = attr.parameterAnnotations;
        }
        for (final list in paramAnns) {
          for (final ann in list) {
            collectFromAnnotation(ann);
          }
        }
      }
    }

    for (var i = 1; i < _pool.length; i++) {
      final e = _pool.get(i);
      if (e is CpClass) {
        final raw = _pool.getString(e.nameIndex);
        if (!raw.startsWith('[')) {
          addFqcn(DescriptorParser.internalToSourceName(raw));
        }
      }
    }

    addFqcn(_cf.superClass == 0
        ? null
        : DescriptorParser.internalToSourceName(
            _pool.getClassName(_cf.superClass)));
    for (final idx in _cf.interfaces) {
      addFqcn(DescriptorParser.internalToSourceName(_pool.getClassName(idx)));
    }

    for (final f in _cf.fields) {
      addDescriptor(_pool.getString(f.descriptorIndex));
      collectFromAttributes(f.attributes);
    }
    for (final m in _cf.methods) {
      addMethodDescriptor(_pool.getString(m.descriptorIndex));
      collectFromAttributes(m.attributes);
    }
    collectFromAttributes(_cf.attributes);

    return refs;
  }

  bool _isPrimitiveName(String name) {
    return const {
      'void',
      'boolean',
      'byte',
      'char',
      'short',
      'int',
      'long',
      'float',
      'double',
    }.contains(name);
  }
}
