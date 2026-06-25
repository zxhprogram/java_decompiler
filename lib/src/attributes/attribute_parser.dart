import 'dart:convert';

import '../constants/constant_pool.dart';
import '../io/class_reader.dart';
import 'attribute_models.dart';

class AttributeParser {
  final ClassReader _reader;
  final ConstantPool _pool;

  AttributeParser(this._reader, this._pool);

  List<AttributeInfo> parseAttributes() {
    final count = _reader.u2();
    final list = <AttributeInfo>[];
    for (var i = 0; i < count; i++) {
      list.add(_parseAttribute());
    }
    return list;
  }

  AttributeInfo _parseAttribute() {
    final nameIndex = _reader.u2();
    final name = _pool.getString(nameIndex);
    final length = _reader.u4();
    final start = _reader.offset;
    final attr = _parseNamed(name, length);
    // 跳过未消费的字节，保证健壮性。
    final consumed = _reader.offset - start;
    if (consumed < length) _reader.skip(length - consumed);
    return attr;
  }

  AttributeInfo _parseNamed(String name, int length) {
    switch (name) {
      case 'ConstantValue':
        return ConstantValueAttribute(_reader.u2());
      case 'Code':
        return _parseCode();
      case 'StackMapTable':
        return _parseStackMapTable();
      case 'Exceptions':
        return _parseExceptions();
      case 'InnerClasses':
        return _parseInnerClasses();
      case 'EnclosingMethod':
        return EnclosingMethodAttribute(_reader.u2(), _reader.u2());
      case 'Synthetic':
        return SyntheticAttribute();
      case 'Signature':
        return SignatureAttribute(_reader.u2());
      case 'SourceFile':
        return SourceFileAttribute(_reader.u2());
      case 'SourceDebugExtension':
        return SourceDebugExtensionAttribute(
          utf8.decode(_reader.readBytes(length), allowMalformed: true),
        );
      case 'LineNumberTable':
        return _parseLineNumberTable();
      case 'LocalVariableTable':
        return _parseLocalVariableTable();
      case 'LocalVariableTypeTable':
        return _parseLocalVariableTypeTable();
      case 'Deprecated':
        return DeprecatedAttribute();
      case 'RuntimeVisibleAnnotations':
        return RuntimeVisibleAnnotationsAttribute(_parseAnnotations());
      case 'RuntimeInvisibleAnnotations':
        return RuntimeInvisibleAnnotationsAttribute(_parseAnnotations());
      case 'RuntimeVisibleParameterAnnotations':
        return RuntimeVisibleParameterAnnotationsAttribute(
          _parseParameterAnnotations(),
        );
      case 'RuntimeInvisibleParameterAnnotations':
        return RuntimeInvisibleParameterAnnotationsAttribute(
          _parseParameterAnnotations(),
        );
      case 'AnnotationDefault':
        return AnnotationDefaultAttribute(_parseElementValue());
      case 'BootstrapMethods':
        return _parseBootstrapMethods();
      case 'MethodParameters':
        return _parseMethodParameters();
      case 'Module':
        return _parseModule();
      case 'ModulePackages':
        return _parseModulePackages();
      case 'ModuleMainClass':
        return ModuleMainClassAttribute(_reader.u2());
      case 'NestHost':
        return NestHostAttribute(_reader.u2());
      case 'NestMembers':
        return _parseNestMembers();
      case 'Record':
        return _parseRecord();
      case 'PermittedSubclasses':
        return _parsePermittedSubclasses();
      default:
        return UnknownAttribute(name, _reader.readBytes(length));
    }
  }

  CodeAttribute _parseCode() {
    final maxStack = _reader.u2();
    final maxLocals = _reader.u2();
    final codeLength = _reader.u4();
    final code = _reader.readBytes(codeLength);
    final exceptionCount = _reader.u2();
    final exceptions = <ExceptionTableEntry>[];
    for (var i = 0; i < exceptionCount; i++) {
      exceptions.add(
        ExceptionTableEntry(
          _reader.u2(),
          _reader.u2(),
          _reader.u2(),
          _reader.u2(),
        ),
      );
    }
    final attributes = AttributeParser(_reader, _pool).parseAttributes();
    return CodeAttribute(
      maxStack: maxStack,
      maxLocals: maxLocals,
      code: code,
      exceptionTable: exceptions,
      attributes: attributes,
    );
  }

  StackMapTableAttribute _parseStackMapTable() {
    final entryCount = _reader.u2();
    final entries = <StackMapFrame>[];
    for (var i = 0; i < entryCount; i++) {
      entries.add(_parseStackMapFrame());
    }
    return StackMapTableAttribute(entries);
  }

  StackMapFrame _parseStackMapFrame() {
    final frameType = _reader.u1();
    if (frameType >= 0 && frameType <= 63) {
      return SameFrame(frameType);
    } else if (frameType >= 64 && frameType <= 127) {
      return SameLocals1StackItemFrame(frameType, _parseVerificationTypeInfo());
    } else if (frameType == 247) {
      return SameLocals1StackItemFrameExtended(
        _reader.u2(),
        _parseVerificationTypeInfo(),
      );
    } else if (frameType >= 248 && frameType <= 250) {
      return ChopFrame(frameType, _reader.u2());
    } else if (frameType == 251) {
      return SameFrameExtended(_reader.u2());
    } else if (frameType >= 252 && frameType <= 254) {
      final offsetDelta = _reader.u2();
      final locals = <VerificationTypeInfo>[];
      for (var i = 0; i < frameType - 251; i++) {
        locals.add(_parseVerificationTypeInfo());
      }
      return AppendFrame(frameType, offsetDelta, locals);
    } else if (frameType == 255) {
      final offsetDelta = _reader.u2();
      final locals = _parseVerificationTypeInfoList();
      final stack = _parseVerificationTypeInfoList();
      return FullFrame(offsetDelta, locals, stack);
    }
    throw FormatException('Unknown stack map frame type: $frameType');
  }

  List<VerificationTypeInfo> _parseVerificationTypeInfoList() {
    final count = _reader.u2();
    return List.generate(count, (_) => _parseVerificationTypeInfo());
  }

  VerificationTypeInfo _parseVerificationTypeInfo() {
    final tag = _reader.u1();
    return switch (tag) {
      0 => TopVariableInfo(),
      1 => IntegerVariableInfo(),
      2 => FloatVariableInfo(),
      3 => DoubleVariableInfo(),
      4 => LongVariableInfo(),
      5 => NullVariableInfo(),
      6 => UninitializedThisVariableInfo(),
      7 => ObjectVariableInfo(_reader.u2()),
      8 => UninitializedVariableInfo(_reader.u2()),
      _ => throw FormatException('Unknown verification type tag: $tag'),
    };
  }

  ExceptionsAttribute _parseExceptions() {
    final count = _reader.u2();
    return ExceptionsAttribute(List.generate(count, (_) => _reader.u2()));
  }

  InnerClassesAttribute _parseInnerClasses() {
    final count = _reader.u2();
    final list = <InnerClassEntry>[];
    for (var i = 0; i < count; i++) {
      list.add(
        InnerClassEntry(_reader.u2(), _reader.u2(), _reader.u2(), _reader.u2()),
      );
    }
    return InnerClassesAttribute(list);
  }

  LineNumberTableAttribute _parseLineNumberTable() {
    final count = _reader.u2();
    final list = <LineNumberEntry>[];
    for (var i = 0; i < count; i++) {
      list.add(LineNumberEntry(_reader.u2(), _reader.u2()));
    }
    return LineNumberTableAttribute(list);
  }

  LocalVariableTableAttribute _parseLocalVariableTable() {
    final count = _reader.u2();
    final list = <LocalVariableEntry>[];
    for (var i = 0; i < count; i++) {
      list.add(
        LocalVariableEntry(
          _reader.u2(),
          _reader.u2(),
          _reader.u2(),
          _reader.u2(),
          _reader.u2(),
        ),
      );
    }
    return LocalVariableTableAttribute(list);
  }

  LocalVariableTypeTableAttribute _parseLocalVariableTypeTable() {
    final count = _reader.u2();
    final list = <LocalVariableTypeEntry>[];
    for (var i = 0; i < count; i++) {
      list.add(
        LocalVariableTypeEntry(
          _reader.u2(),
          _reader.u2(),
          _reader.u2(),
          _reader.u2(),
          _reader.u2(),
        ),
      );
    }
    return LocalVariableTypeTableAttribute(list);
  }

  List<Annotation> _parseAnnotations() {
    final count = _reader.u2();
    return List.generate(count, (_) => _parseAnnotation());
  }

  Annotation _parseAnnotation() {
    final typeIndex = _reader.u2();
    final pairCount = _reader.u2();
    final pairs = <ElementValuePair>[];
    for (var i = 0; i < pairCount; i++) {
      pairs.add(ElementValuePair(_reader.u2(), _parseElementValue()));
    }
    return Annotation(typeIndex, pairs);
  }

  List<List<Annotation>> _parseParameterAnnotations() {
    final paramCount = _reader.u1();
    return List.generate(paramCount, (_) => _parseAnnotations());
  }

  ElementValue _parseElementValue() {
    final tag = _reader.u1();
    final tagChar = String.fromCharCode(tag);
    switch (tagChar) {
      case 'B':
      case 'C':
      case 'D':
      case 'F':
      case 'I':
      case 'J':
      case 'S':
      case 'Z':
      case 's':
        return ConstElementValue(tag, _reader.u2());
      case 'e':
        return EnumElementValue(_reader.u2(), _reader.u2());
      case 'c':
        return ClassElementValue(_reader.u2());
      case '@':
        return AnnotationElementValue(_parseAnnotation());
      case '[':
        final count = _reader.u2();
        return ArrayElementValue(
          List.generate(count, (_) => _parseElementValue()),
        );
      default:
        throw FormatException('Unknown annotation element value tag: $tagChar');
    }
  }

  BootstrapMethodsAttribute _parseBootstrapMethods() {
    final count = _reader.u2();
    final list = <BootstrapMethodEntry>[];
    for (var i = 0; i < count; i++) {
      final ref = _reader.u2();
      final argCount = _reader.u2();
      final args = List.generate(argCount, (_) => _reader.u2());
      list.add(BootstrapMethodEntry(ref, args));
    }
    return BootstrapMethodsAttribute(list);
  }

  MethodParametersAttribute _parseMethodParameters() {
    final count = _reader.u1();
    final list = <MethodParameterEntry>[];
    for (var i = 0; i < count; i++) {
      list.add(MethodParameterEntry(_reader.u2(), _reader.u2()));
    }
    return MethodParametersAttribute(list);
  }

  ModuleAttribute _parseModule() {
    final nameIndex = _reader.u2();
    final flags = _reader.u2();
    final versionIndex = _reader.u2();
    final requires = _parseList(
      () => ModuleRequireEntry(_reader.u2(), _reader.u2(), _reader.u2()),
    );
    final exports = _parseList(
      () => ModuleExportEntry(_reader.u2(), _reader.u2(), _parseU2List()),
    );
    final opens = _parseList(
      () => ModuleOpenEntry(_reader.u2(), _reader.u2(), _parseU2List()),
    );
    final uses = _parseU2List();
    final provides = _parseList(
      () => ModuleProvideEntry(_reader.u2(), _parseU2List()),
    );
    return ModuleAttribute(
      moduleNameIndex: nameIndex,
      moduleFlags: flags,
      moduleVersionIndex: versionIndex,
      requires: requires,
      exports: exports,
      opens: opens,
      usesIndexTable: uses,
      provides: provides,
    );
  }

  ModulePackagesAttribute _parseModulePackages() {
    return ModulePackagesAttribute(_parseU2List());
  }

  NestMembersAttribute _parseNestMembers() {
    return NestMembersAttribute(_parseU2List());
  }

  RecordAttribute _parseRecord() {
    final count = _reader.u2();
    final list = <RecordComponentInfo>[];
    for (var i = 0; i < count; i++) {
      list.add(
        RecordComponentInfo(
          _reader.u2(),
          _reader.u2(),
          AttributeParser(_reader, _pool).parseAttributes(),
        ),
      );
    }
    return RecordAttribute(list);
  }

  PermittedSubclassesAttribute _parsePermittedSubclasses() {
    return PermittedSubclassesAttribute(_parseU2List());
  }

  List<int> _parseU2List() {
    final count = _reader.u2();
    return List.generate(count, (_) => _reader.u2());
  }

  List<T> _parseList<T>(T Function() parse) {
    final count = _reader.u2();
    return List.generate(count, (_) => parse());
  }
}
