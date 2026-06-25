import 'dart:typed_data';

import 'attributes/attribute_parser.dart';
import 'class_file.dart';
import 'constants/constant_pool.dart';
import 'constants/constant_pool_parser.dart';
import 'io/class_reader.dart';

class ClassFileParser {
  final ClassReader _reader;

  ClassFileParser(Uint8List bytes) : _reader = ClassReader(bytes);

  ClassFile parse() {
    _reader.expectMagic(0xCAFEBABE);
    final minor = _reader.u2();
    final major = _reader.u2();
    final pool = ConstantPoolParser(_reader).parse();
    final accessFlags = _reader.u2();
    final thisClass = _reader.u2();
    final superClass = _reader.u2();
    final interfaces = _readInterfaces();
    final fields = _readFields(pool);
    final methods = _readMethods(pool);
    final attributes = AttributeParser(_reader, pool).parseAttributes();
    return ClassFile(
      minorVersion: minor,
      majorVersion: major,
      accessFlags: accessFlags,
      thisClass: thisClass,
      superClass: superClass,
      interfaces: interfaces,
      fields: fields,
      methods: methods,
      attributes: attributes,
      constantPool: pool,
    );
  }

  List<int> _readInterfaces() {
    final count = _reader.u2();
    return List.generate(count, (_) => _reader.u2());
  }

  List<FieldInfo> _readFields(ConstantPool pool) {
    final count = _reader.u2();
    return List.generate(count, (_) => _readMember<FieldInfo>(pool));
  }

  List<MethodInfo> _readMethods(ConstantPool pool) {
    final count = _reader.u2();
    return List.generate(count, (_) => _readMember<MethodInfo>(pool));
  }

  T _readMember<T extends MemberInfo>(ConstantPool pool) {
    final accessFlags = _reader.u2();
    final nameIndex = _reader.u2();
    final descriptorIndex = _reader.u2();
    final attributes = AttributeParser(_reader, pool).parseAttributes();
    if (T == FieldInfo) {
      return FieldInfo(
            accessFlags: accessFlags,
            nameIndex: nameIndex,
            descriptorIndex: descriptorIndex,
            attributes: attributes,
          )
          as T;
    }
    return MethodInfo(
          accessFlags: accessFlags,
          nameIndex: nameIndex,
          descriptorIndex: descriptorIndex,
          attributes: attributes,
        )
        as T;
  }
}
