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

  final Map<String, String> _staticFinalInitializers = {};
  String? _clinitRemainingBody;
  bool _clinitSkip = false;

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

    final isEnum = (_cf.accessFlags & AccessFlags.ACC_ENUM) != 0;
    if (recordAttr != null) {
      _writeRecordBody(sb, className, recordAttr);
    } else if (isEnum && _isSimpleEnum()) {
      _prepareClinit();
      _writeEnumBody(sb, className);
    } else {
      _prepareClinit();
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

  /// 输出所有方法签名，每行一个。
  String methodSignatures() {
    final className = _pool.getClassName(_cf.thisClass);
    final simple = _simpleName(className);
    final sb = StringBuffer();
    for (final method in _cf.methods) {
      final rawName = _pool.getString(method.nameIndex);
      if (rawName == '<clinit>') continue;
      final desc = _pool.getString(method.descriptorIndex);
      final sigAttr = method.attribute<SignatureAttribute>();
      var (paramTypes, returnType) =
          DescriptorParser.parseMethodDescriptor(desc);
      String? typeParams;
      if (sigAttr != null) {
        try {
          final sig = _pool.getString(sigAttr.signatureIndex);
          (paramTypes, returnType) = SignatureParser.parseMethodSignature(sig);
          typeParams = SignatureParser.parseTypeParameters(sig);
        } catch (_) {}
      }
      final isStatic = (method.accessFlags & AccessFlags.ACC_STATIC) != 0;
      final isVarargs = (method.accessFlags & AccessFlags.ACC_VARARGS) != 0;
      final displayName = rawName == '<init>' ? simple : rawName;
      final displayReturn = rawName == '<init>' ? '' : returnType;
      final typeParamsPart =
          (typeParams != null && typeParams.isNotEmpty) ? '$typeParams ' : '';
      final mods = AccessFlagFormatter.methodFlags(method.accessFlags);
      final params = _parameterNames(method, paramTypes.length, isStatic);
      sb.write('  ${mods.join(' ')}${mods.isEmpty ? '' : ' '}'
          '${displayReturn.isEmpty ? '' : '$displayReturn '}$typeParamsPart$displayName(');
      for (var i = 0; i < paramTypes.length; i++) {
        if (i > 0) sb.write(', ');
        var type = paramTypes[i];
        if (isVarargs && i == paramTypes.length - 1 && type.endsWith('[]')) {
          type = '${type.substring(0, type.length - 2)}...';
        }
        sb.write('$type ${params[i]}');
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
      sb.writeln(';');
    }
    return _withImports(sb.toString());
  }

  /// 输出所有字段，每行一个。
  String fieldList() {
    final sb = StringBuffer();
    for (final field in _cf.fields) {
      final name = _pool.getString(field.nameIndex);
      final desc = _pool.getString(field.descriptorIndex);
      final type = DescriptorParser.parseFieldDescriptor(desc);
      final mods = AccessFlagFormatter.fieldFlags(field.accessFlags);
      sb.write('  ${mods.join(' ')}${mods.isEmpty ? '' : ' '}$type $name');
      final cv = field.attribute<ConstantValueAttribute>();
      if (cv != null && (field.accessFlags & AccessFlags.ACC_STATIC) != 0) {
        sb.write(' = ${_pool.getLiteral(cv.constantValueIndex)}');
      }
      sb.writeln(';');
    }
    return _withImports(sb.toString());
  }

  /// 把签名/字段列表文本套上类外壳走一遍 _addImports，再抽出主体，
  /// 使输出与反编译结果一致地使用简单名 + import。
  String _withImports(String body) {
    final className = _pool.getClassName(_cf.thisClass);
    final package = _packageOf(className);
    final simple = _simpleName(className);
    final wrapped =
        '${package.isEmpty ? '' : 'package $package;\n\n'}class $simple {\n$body}\n';
    final withImports = _addImports(wrapped, className, package);
    final start = withImports.indexOf('{') + 1;
    final end = withImports.lastIndexOf('}');
    if (start <= 0 || end < start) return body;
    return withImports.substring(start, end).trim();
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
        '${DescriptorParser.parseFieldDescriptor(_pool.getString(typeNameIndex))}.${_pool.getString(constNameIndex)}',
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
    PermittedSubclassesAttribute? permitted;
    for (final attr in _cf.attributes) {
      if (attr is PermittedSubclassesAttribute) {
        permitted = attr;
        break;
      }
    }

    final mods = AccessFlagFormatter.classFlags(flags);
    if (flags & AccessFlags.ACC_MODULE != 0) {
      // module-info 特殊处理
      sb.write('module ${_pool.getString(_cf.thisClass)}');
      return;
    }
    final decl = <String>[];
    if (mods.contains('public')) decl.add('public');
    if (permitted != null) decl.add('sealed');
    // enum 隐式 final，不需要写出
    if (mods.contains('final') && kind != 'enum') decl.add('final');
    if (mods.contains('abstract') &&
        kind != 'interface' &&
        kind != '@interface' &&
        kind != 'enum') {
      decl.add('abstract');
    }
    decl.add(kind == '@interface' ? '@interface' : kind);
    decl.add(_simpleName(className));
    sb.write(decl.join(' '));

    if (kind == 'class') {
      final superName =
          _cf.superClass == 0 ? null : _pool.getClassName(_cf.superClass);
      if (superName != null &&
          superName != 'java/lang/Object' &&
          !(kind == '@interface' &&
              superName == 'java/lang/annotation/Annotation')) {
        sb.write(
            ' extends ${DescriptorParser.internalToSourceName(superName)}');
      }
    }
    if (_cf.interfaces.isNotEmpty) {
      // 注解接口隐式继承 Annotation，不输出
      final filtered = kind == '@interface'
          ? _cf.interfaces
              .where((idx) =>
                  _pool.getClassName(idx) != 'java/lang/annotation/Annotation')
              .toList()
          : _cf.interfaces;
      if (filtered.isNotEmpty) {
        final keyword = kind == 'interface' || kind == '@interface'
            ? ' extends '
            : ' implements ';
        final ifaces = filtered
            .map((idx) =>
                DescriptorParser.internalToSourceName(_pool.getClassName(idx)))
            .join(', ');
        sb.write('$keyword$ifaces');
      }
    }
    if (permitted != null) {
      final names = permitted.classes
          .map((idx) =>
              DescriptorParser.internalToSourceName(_pool.getClassName(idx)))
          .join(', ');
      sb.write(' permits $names');
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
      // 规范构造器含用户代码时，还原为紧凑构造器
      if (_isCompactConstructor(method, componentNames, componentTypes)) {
        _writeCompactConstructor(sb, method, className, componentNames);
        continue;
      }
      _writeMethod(sb, method, className);
    }
  }

  /// 判断方法是否为含用户代码的 record 规范构造器（需还原为紧凑构造器）。
  bool _isCompactConstructor(MethodInfo method, List<String> componentNames,
      List<String> componentTypes) {
    final rawName = _pool.getString(method.nameIndex);
    if (rawName != '<init>') return false;
    final desc = _pool.getString(method.descriptorIndex);
    final (paramTypes, _) = DescriptorParser.parseMethodDescriptor(desc);
    if (paramTypes.length != componentTypes.length) return false;
    if (!_listEquals(paramTypes, componentTypes)) return false;
    // 已在 _isRecordGeneratedConstructor 中确认有用户代码
    return !_isRecordGeneratedConstructor(method, componentNames);
  }

  /// 将含用户代码的规范构造器还原为紧凑构造器。
  ///
  /// 紧凑构造器格式: `public Point { <用户代码> }`
  /// 自动生成的 super() 调用和字段赋值 (this.x = x) 被剥离。
  void _writeCompactConstructor(StringBuffer sb, MethodInfo method,
      String className, List<String> componentNames) {
    final code = method.attribute<CodeAttribute>();
    final mods = AccessFlagFormatter.methodFlags(method.accessFlags).toList();
    _writeMemberAnnotations(sb, method);
    sb.write('    ${mods.join(' ')}${mods.isEmpty ? '' : ' '}');
    sb.write(_simpleName(className));
    sb.writeln(' {');

    if (code != null) {
      final printer = CodePrinter(method, code, _cf);
      final body = printer.printBody();
      // 剥离自动生成的代码行
      final cleaned = _stripGeneratedConstructorCode(body, componentNames);
      sb.write(cleaned);
    }

    sb.writeln('    }');
  }

  /// 从构造器反编译结果中剥离编译器自动生成的代码：
  ///   - super() 调用
  ///   - this.<component> = <param>; 字段赋值
  String _stripGeneratedConstructorCode(
      String body, List<String> componentNames) {
    final lines = body.split('\n');
    final result = <String>[];
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      // 跳过 super() 调用
      if (trimmed == 'super();' || trimmed.startsWith('super(')) continue;
      // 跳过 this.<component> = <value>; 赋值
      bool isFieldAssignment = false;
      for (final name in componentNames) {
        if (trimmed.startsWith('this.$name =') && trimmed.endsWith(';')) {
          isFieldAssignment = true;
          break;
        }
      }
      if (isFieldAssignment) continue;
      result.add(line);
    }
    if (result.isEmpty) return '';
    return '${result.join('\n')}\n';
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

    // 规范构造器 - 仅当无用户代码时跳过
    if (rawName == '<init>' &&
        paramTypes.length == componentTypes.length &&
        _listEquals(paramTypes, componentTypes) &&
        _isRecordGeneratedConstructor(method, componentNames)) {
      return true;
    }

    // 访问器
    if (paramTypes.isEmpty &&
        componentNames.contains(rawName) &&
        componentTypes[componentNames.indexOf(rawName)] == returnType) {
      return true;
    }

    // Object 方法（注意 parseMethodDescriptor 返回全限定名）
    if (rawName == 'toString' &&
        paramTypes.isEmpty &&
        returnType == 'java.lang.String') {
      return true;
    }
    if (rawName == 'hashCode' && paramTypes.isEmpty && returnType == 'int') {
      return true;
    }
    if (rawName == 'equals' &&
        paramTypes.length == 1 &&
        paramTypes[0] == 'java.lang.Object' &&
        returnType == 'boolean') {
      return true;
    }

    return false;
  }

  /// 判断 record 规范构造器是否仅由编译器生成代码组成（无用户代码）。
  ///
  /// record 规范构造器的字节码模式：
  ///   1. aload_0; invokespecial Record.<init>  (super 调用)
  ///   2. [用户代码]                              (可选 - 紧凑构造器体)
  ///   3. 每个组件: aload_0; iload_n; putfield   (字段赋值)
  ///   4. return
  ///
  /// 若构造器只包含 1、3、4（无用户代码），则返回 true（可跳过）。
  /// 若包含用户代码（紧凑构造器体），则返回 false（需保留为紧凑构造器）。
  bool _isRecordGeneratedConstructor(
      MethodInfo method, List<String> componentNames) {
    final code = method.attribute<CodeAttribute>();
    if (code == null) return true;
    final ins = BytecodeDecoder(code.code).decode();
    if (ins.isEmpty) return true;

    int i = 0;
    // 1. 跳过 super() 调用: aload_0; invokespecial
    if (ins[i].opcode != Opcodes.aload_0) return false;
    i++;
    if (i >= ins.length || ins[i].opcode != Opcodes.invokespecial) return false;
    i++;

    // 2. 跳过字段赋值: aload_0; <load param>; putfield <component>
    //    字段赋值可能不按声明顺序，但通常按顺序。
    final assignedFields = <String>{};
    while (i < ins.length) {
      // 检查是否为字段赋值模式: aload_0; <load>; putfield
      if (ins[i].opcode == Opcodes.aload_0 &&
          i + 2 < ins.length &&
          ins[i + 2].opcode == Opcodes.putfield) {
        final fieldRef = _pool.getFieldref(ins[i + 2].operands[0] as int);
        final nt = _pool.getNameAndType(fieldRef.nameAndTypeIndex);
        final fieldName = _pool.getString(nt.nameIndex);
        if (componentNames.contains(fieldName)) {
          assignedFields.add(fieldName);
          i += 3;
          continue;
        }
      }
      // 检查是否为 return
      if (ins[i].opcode == Opcodes.return_ && i == ins.length - 1) {
        // 所有组件都被赋值，且无用户代码
        return assignedFields.length == componentNames.length;
      }
      // 其他指令 = 用户代码
      return false;
    }
    return false;
  }

  /// 判断是否为"简单枚举"：每个非 `$VALUES` 字段都是枚举常量，
  /// 且每个非合成方法都是枚举自动生成的方法（values/valueOf/$values/<init>）。
  /// 简单枚举才走 `_writeEnumBody` 还原为 `RED, GREEN, BLUE;` 形式；
  /// 带构造器参数、自定义方法或字段的复杂枚举回退到普通类输出。
  bool _isSimpleEnum() {
    for (final f in _cf.fields) {
      final isEnumConst = (f.accessFlags & AccessFlags.ACC_ENUM) != 0;
      final name = _pool.getString(f.nameIndex);
      if (!isEnumConst && name != r'$VALUES') return false;
    }
    for (final m in _cf.methods) {
      final name = _pool.getString(m.nameIndex);
      if (name == '<clinit>') continue;
      if (name == 'values' || name == 'valueOf' || name == r'$values') {
        continue;
      }
      if (name == '<init>') {
        // 仅允许默认无参构造器（synthetic 占位也算）
        final desc = _pool.getString(m.descriptorIndex);
        final (params, _) = DescriptorParser.parseMethodDescriptor(desc);
        if (params.length != 2) return false;
        continue;
      }
      return false;
    }
    return true;
  }

  void _writeEnumBody(StringBuffer sb, String className) {
    // 枚举常量：按字段顺序输出，最后一个加 `;` 其余加 `,`
    final consts = <String>[];
    for (final f in _cf.fields) {
      if ((f.accessFlags & AccessFlags.ACC_ENUM) == 0) continue;
      final name = _pool.getString(f.nameIndex);
      // 从 _staticFinalInitializers 中拿到 `new Color("RED", 0)` 形式
      // 提取其中的字符串字面量作为常量名（与字段名应一致）
      consts.add(name);
    }
    if (consts.isNotEmpty) {
      for (var i = 0; i < consts.length; i++) {
        final sep = i == consts.length - 1 ? ';' : ',';
        sb.writeln('    ${consts[i]}$sep');
      }
    }

    // 跳过 $VALUES 字段、values()/valueOf()/$values() 方法、默认 <init>、<clinit>
    final remaining = <MethodInfo>[];
    for (final m in _cf.methods) {
      final name = _pool.getString(m.nameIndex);
      if (name == '<clinit>') continue;
      if (name == 'values' || name == 'valueOf' || name == r'$values') continue;
      if (name == '<init>') {
        final desc = _pool.getString(m.descriptorIndex);
        final (params, _) = DescriptorParser.parseMethodDescriptor(desc);
        // 枚举默认构造器：(String, int) -> void，由 javac 自动生成
        if (params.length == 2 &&
            (params[0] == 'String' || params[0] == 'java.lang.String') &&
            params[1] == 'int') {
          continue;
        }
      }
      remaining.add(m);
    }
    if (remaining.isNotEmpty) {
      sb.writeln();
      for (final m in remaining) {
        _writeMethod(sb, m, className);
      }
    }
  }

  void _prepareClinit() {
    MethodInfo? clinit;
    for (final m in _cf.methods) {
      if (_pool.getString(m.nameIndex) == '<clinit>') {
        clinit = m;
        break;
      }
    }
    if (clinit == null) return;
    final code = clinit.attribute<CodeAttribute>();
    if (code == null) return;

    final body = CodePrinter(clinit, code, _cf).printBody();

    final thisClassDot = DescriptorParser.internalToSourceName(
        _pool.getClassName(_cf.thisClass));

    final targetFields = <String>{};
    for (final f in _cf.fields) {
      final isStaticFinal = (f.accessFlags & AccessFlags.ACC_STATIC) != 0 &&
          (f.accessFlags & AccessFlags.ACC_FINAL) != 0;
      if (!isStaticFinal) continue;
      if (f.attribute<ConstantValueAttribute>() != null) continue;
      targetFields.add(_pool.getString(f.nameIndex));
    }

    final keptLines = <String>[];
    final assignmentRe = RegExp(r'^        (\S+)\.(\w+) = (.+);$');
    for (final line in body.split('\n')) {
      final m = assignmentRe.firstMatch(line);
      if (m != null &&
          m.group(1) == thisClassDot &&
          targetFields.contains(m.group(2))) {
        final expr = m.group(3)!;
        if (!expr.contains(';') && !expr.contains('{')) {
          _staticFinalInitializers[m.group(2)!] = expr;
          continue;
        }
      }
      keptLines.add(line);
    }

    final nonBlank = keptLines.where((l) => l.trim().isNotEmpty).toList();
    final onlyReturn =
        nonBlank.length == 1 && nonBlank.single.trim() == 'return;';
    if (nonBlank.isEmpty || onlyReturn) {
      _clinitSkip = true;
    } else {
      _clinitRemainingBody = keptLines.join('\n');
    }
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
    } else if ((field.accessFlags & AccessFlags.ACC_STATIC) != 0 &&
        (field.accessFlags & AccessFlags.ACC_FINAL) != 0 &&
        _staticFinalInitializers.containsKey(name)) {
      sb.write(' = ${_staticFinalInitializers[name]}');
    }
    sb.writeln(';');
  }

  void _writeMethod(StringBuffer sb, MethodInfo method, String className) {
    if (hideEmptyPublicConstructors &&
        _isEmptyPublicDefaultConstructor(method)) {
      return;
    }

    final rawName = _pool.getString(method.nameIndex);

    if (rawName == '<clinit>') {
      if (_clinitSkip) return;
      sb.writeln('    static {');
      sb.write(_clinitRemainingBody);
      sb.writeln('    }');
      return;
    }

    final desc = _pool.getString(method.descriptorIndex);
    final sigAttr = method.attribute<SignatureAttribute>();
    var (paramTypes, returnType) = DescriptorParser.parseMethodDescriptor(desc);
    String? typeParams;
    if (sigAttr != null) {
      try {
        final sig = _pool.getString(sigAttr.signatureIndex);
        (paramTypes, returnType) = SignatureParser.parseMethodSignature(sig);
        typeParams = SignatureParser.parseTypeParameters(sig);
      } catch (_) {
        // 泛型签名解析失败时回退到擦除类型
      }
    }
    final isVarargs = (method.accessFlags & AccessFlags.ACC_VARARGS) != 0;
    final isStatic = (method.accessFlags & AccessFlags.ACC_STATIC) != 0;
    final isAbstract = (method.accessFlags & AccessFlags.ACC_ABSTRACT) != 0;
    final isNative = (method.accessFlags & AccessFlags.ACC_NATIVE) != 0;
    final displayName = rawName == '<init>' ? _simpleName(className) : rawName;
    final displayReturn = rawName == '<init>' ? '' : returnType;
    final typeParamsPart =
        (typeParams != null && typeParams.isNotEmpty) ? '$typeParams ' : '';
    // 接口方法默认抽象，不输出 abstract 关键字（与 javac 一致）。
    final isInterface = (_cf.accessFlags & AccessFlags.ACC_INTERFACE) != 0;
    final mods = AccessFlagFormatter.methodFlags(method.accessFlags)
        .where((m) => !(isInterface && m == 'abstract'))
        .toList();
    _writeMemberAnnotations(sb, method);
    sb.write(
        '    ${mods.join(' ')}${mods.isEmpty ? '' : ' '}${displayReturn.isEmpty ? '' : '$displayReturn '}$typeParamsPart$displayName(');

    final params = _parameterNames(method, paramTypes.length, isStatic);
    for (var i = 0; i < paramTypes.length; i++) {
      if (i > 0) sb.write(', ');
      var type = paramTypes[i];
      if (isVarargs && i == paramTypes.length - 1 && type.endsWith('[]')) {
        type = '${type.substring(0, type.length - 2)}...';
      }
      sb.write('$type ${params[i]}');
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
      final printer = CodePrinter(method, code, _cf);
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

    // 过滤掉未在代码中实际使用的 import（如 record 跳过的 ObjectMethods 等）
    imports.removeWhere((fqcn) {
      final simple = simpleOf(fqcn);
      // 检查简单名是否在替换后的文本中出现（排除 import 行本身）
      final bodyOnly =
          result.replaceAll(RegExp(r'^import .+;$', multiLine: true), '');
      return !bodyOnly.contains(simple);
    });

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

    void collectFromSignature(String? sig) {
      if (sig == null) return;
      // 泛型签名的原始形式如 Lcom/example/Foo<Lcom/example/Bar;>;
      final re = RegExp(r'\b[A-Za-z_$][\w$]*(?:/[A-Za-z_$][\w$]*)+\b');
      for (final m in re.allMatches(sig)) {
        var raw = m.group(0)!;
        if (raw.startsWith('L')) raw = raw.substring(1);
        if (raw.endsWith(';')) raw = raw.substring(0, raw.length - 1);
        addFqcn(raw);
      }
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

    final skipAnnotation = (_cf.accessFlags & AccessFlags.ACC_ANNOTATION) != 0;
    for (var i = 1; i < _pool.length; i++) {
      final e = _pool.get(i);
      if (e is CpClass) {
        final raw = _pool.getString(e.nameIndex);
        if (!raw.startsWith('[')) {
          // 注解接口隐式继承 Annotation，不收集为引用
          if (skipAnnotation && raw == 'java/lang/annotation/Annotation') {
            continue;
          }
          addFqcn(DescriptorParser.internalToSourceName(raw));
        }
      }
    }

    addFqcn(_cf.superClass == 0
        ? null
        : DescriptorParser.internalToSourceName(
            _pool.getClassName(_cf.superClass)));
    final isAnnotation = (_cf.accessFlags & AccessFlags.ACC_ANNOTATION) != 0;
    for (final idx in _cf.interfaces) {
      final ifaceName = _pool.getClassName(idx);
      // 注解接口隐式继承 Annotation，不收集为引用
      if (isAnnotation && ifaceName == 'java/lang/annotation/Annotation') {
        continue;
      }
      addFqcn(DescriptorParser.internalToSourceName(ifaceName));
    }

    for (final f in _cf.fields) {
      addDescriptor(_pool.getString(f.descriptorIndex));
      final sigAttr = f.attribute<SignatureAttribute>();
      if (sigAttr != null) {
        collectFromSignature(_pool.getString(sigAttr.signatureIndex));
      }
      collectFromAttributes(f.attributes);
    }
    for (final m in _cf.methods) {
      addMethodDescriptor(_pool.getString(m.descriptorIndex));
      final sigAttr = m.attribute<SignatureAttribute>();
      if (sigAttr != null) {
        collectFromSignature(_pool.getString(sigAttr.signatureIndex));
      }
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
