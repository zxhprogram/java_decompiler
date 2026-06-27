part of 'code_printer.dart';

/// Lambda 表达式与方法引用解析。
extension on CodePrinter {


  /// 解析 LambdaMetafactory.metafactory 调用，返回方法引用或 lambda 表达式字符串。
  /// 返回 null 表示无法解析。
  String? _tryParseLambda(CpInvokeDynamic id, List<String> capturedArgs) {
    BootstrapMethodsAttribute? bmAttr;
    for (final attr in _cf.attributes) {
      if (attr is BootstrapMethodsAttribute) {
        bmAttr = attr;
        break;
      }
    }
    if (bmAttr == null) return null;
    if (id.bootstrapMethodAttrIndex >= bmAttr.bootstrapMethods.length) {
      return null;
    }
    final bm = bmAttr.bootstrapMethods[id.bootstrapMethodAttrIndex];
    final bsmRef = _pool.get(bm.bootstrapMethodRef);
    if (bsmRef is! CpMethodHandle) return null;
    // 检查是否为 LambdaMetafactory.metafactory
    final bsmRefMethod = _pool.get(bsmRef.referenceIndex);
    String bsmCls = '', bsmName = '';
    if (bsmRefMethod is CpMethodref) {
      bsmCls = _pool.getClassName(bsmRefMethod.classIndex);
      final nt = _pool.getNameAndType(bsmRefMethod.nameAndTypeIndex);
      bsmName = _pool.getString(nt.nameIndex);
    } else if (bsmRefMethod is CpInterfaceMethodref) {
      bsmCls = _pool.getClassName(bsmRefMethod.classIndex);
      final nt = _pool.getNameAndType(bsmRefMethod.nameAndTypeIndex);
      bsmName = _pool.getString(nt.nameIndex);
    }
    if (bsmCls != 'java/lang/invoke/LambdaMetafactory' ||
        bsmName != 'metafactory') {
      return null;
    }
    if (bm.bootstrapArguments.length < 3) return null;

    // arg[1]: 实现方法的 MethodHandle
    final implMhInfo = _pool.get(bm.bootstrapArguments[1]);
    if (implMhInfo is! CpMethodHandle) return null;
    final implRef = _pool.get(implMhInfo.referenceIndex);
    String implCls = '', implName = '', implDesc = '';
    if (implRef is CpMethodref) {
      implCls = _pool.getClassName(implRef.classIndex);
      final nt = _pool.getNameAndType(implRef.nameAndTypeIndex);
      implName = _pool.getString(nt.nameIndex);
      implDesc = _pool.getString(nt.descriptorIndex);
    } else if (implRef is CpInterfaceMethodref) {
      implCls = _pool.getClassName(implRef.classIndex);
      final nt = _pool.getNameAndType(implRef.nameAndTypeIndex);
      implName = _pool.getString(nt.nameIndex);
      implDesc = _pool.getString(nt.descriptorIndex);
    } else {
      return null;
    }

    final refKind = implMhInfo.referenceKind;
    final implClsSimple = DescriptorParser.internalToSourceName(implCls);
    final (implParams, _) = DescriptorParser.parseMethodDescriptor(implDesc);

    // 判断是 lambda 还是方法引用：
    // - 方法名形如 lambda$xxx$N 的是 lambda 表达式
    // - 其他情况视为方法引用
    final isLambda = RegExp(r'^lambda\$.*\$\d+$').hasMatch(implName);

    if (isLambda) {
      // Lambda 表达式：反编译 lambda 方法以提取 body
      // arg[2]: 实例化后的方法签名
      final instantiatedTypeInfo = _pool.get(bm.bootstrapArguments[2]);
      String instantiatedDesc = '';
      if (instantiatedTypeInfo is CpMethodType) {
        instantiatedDesc =
            _pool.getString(instantiatedTypeInfo.descriptorIndex);
      }
      final (instParams, _) =
          DescriptorParser.parseMethodDescriptor(instantiatedDesc);

      // 生成参数名
      final paramNames = <String>[];
      for (var i = 0; i < instParams.length; i++) {
        paramNames.add(String.fromCharCode(0x61 + i)); // a, b, c, ...
      }
      final paramsStr = paramNames.join(', ');

      // 尝试反编译 lambda 方法
      final lambdaBody = _decompileLambdaBody(implCls, implName, implDesc);
      if (lambdaBody != null) {
        return '($paramsStr) -> $lambdaBody';
      }
      return '($paramsStr) -> { /* lambda body */ }';
    }

    // 方法引用：根据 refKind 和捕获参数构造
    // refKind: 5=invokeVirtual, 6=invokeStatic, 7=invokeSpecial,
    //          8=newInvokeSpecial, 9=invokeInterface
    if (refKind == 6) {
      // invokeStatic: Type::method
      return '$implClsSimple::$implName';
    }
    if (refKind == 8) {
      // newInvokeSpecial: Type::new
      return '$implClsSimple::new';
    }
    if (refKind == 5 || refKind == 7 || refKind == 9) {
      // 实例方法：instance::method 或 Type::method
      // 如果有捕获参数（如 System.out），使用第一个捕获参数作为接收者
      if (capturedArgs.isNotEmpty) {
        // 检查实现方法的第一个参数是否为接收者
        // 对于 bound 方法引用，capturedArgs[0] 就是接收者
        return '${capturedArgs.first}::$implName';
      }
      // 无捕获参数：unbound 方法引用，第一个参数是接收者
      // 形式：Type::method（如 String::length）
      return '$implClsSimple::$implName';
    }
    return null;
  }

  /// 简化类型描述符为可读形式（用于 lambda 签名）
  String _simplifyTypeForLambda(String desc) {
    if (desc == 'void') return 'void';
    if (desc == 'int') return 'int';
    if (desc == 'long') return 'long';
    if (desc == 'boolean') return 'boolean';
    if (desc == 'java.lang.String') return 'String';
    if (desc == 'java.lang.Integer') return 'Integer';
    if (desc == 'java.lang.Object') return 'Object';
    return desc;
  }

  /// 反编译 lambda 方法，返回 body 表达式或语句块。
  /// 对于简单 lambda（单个表达式），返回表达式字符串（不带花括号和分号）。
  /// 返回 null 表示无法反编译。
  String? _decompileLambdaBody(
      String implCls, String implName, String implDesc) {
    // 在当前类中查找 lambda 方法
    MethodInfo? lambdaMethod;
    for (final m in _cf.methods) {
      final name = _pool.getString(m.nameIndex);
      final desc = _pool.getString(m.descriptorIndex);
      if (name == implName && desc == implDesc) {
        lambdaMethod = m;
        break;
      }
    }
    if (lambdaMethod == null) return null;
    final code = lambdaMethod.attribute<CodeAttribute>();
    if (code == null) return null;

    // 使用 CodePrinter 反编译
    final printer = CodePrinter(lambdaMethod, code, _cf);
    final body = printer.printBody();
    // printBody 返回带缩进的代码，需要清理
    final lines = body.split('\n').where((l) => l.trim().isNotEmpty).toList();
    if (lines.isEmpty) return null;

    // 计算参数数量（从方法描述符）
    final (paramTypes, _) = DescriptorParser.parseMethodDescriptor(implDesc);
    // 构建 p0->a, p1->b, ... 的映射
    // 静态 lambda 方法的参数从 local 0 开始
    final isStatic = (lambdaMethod.accessFlags & 0x0008) != 0;
    final paramOffset = isStatic ? 0 : 1;
    final varReplacements = <String, String>{};
    for (var i = 0; i < paramTypes.length; i++) {
      final lambdaVar = 'p${i + paramOffset}';
      final paramName = String.fromCharCode(0x61 + i); // a, b, c...
      varReplacements[lambdaVar] = paramName;
    }

    // 替换变量名
    final processedLines = lines.map((line) {
      var result = line;
      for (final entry in varReplacements.entries) {
        result = result.replaceAll(
          RegExp(r'\b' + RegExp.escape(entry.key) + r'\b'),
          entry.value,
        );
      }
      return result;
    }).toList();

    // 简单 lambda：只有一个表达式语句
    if (processedLines.length == 1) {
      var line = processedLines[0].trim();
      // return expr; -> expr
      final returnRe = RegExp(r'^return (.*);$');
      final m = returnRe.firstMatch(line);
      if (m != null) {
        return m.group(1)!;
      }
      // 单条语句（无 return，如 void lambda）
      // 去掉末尾分号
      if (line.endsWith(';')) {
        return line.substring(0, line.length - 1);
      }
      return line;
    }

    // 多行 lambda：包装为代码块
    final indented = processedLines.map((l) {
      var s = l.replaceFirst(RegExp(r'^ +'), '');
      return '  $s';
    }).join('\n');
    return '{\n$indented\n}';
  }

  /// 把 StringConcatFactory.makeConcatWithConstants 的 recipe 还原成字符串拼接表达式。
}
