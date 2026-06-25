import 'attributes/attribute_models.dart';
import 'constants/constant_pool.dart';

/// class 文件顶层模型。
class ClassFile {
  final int minorVersion;
  final int majorVersion;
  final int accessFlags;
  final int thisClass;
  final int superClass;
  final List<int> interfaces;
  final List<FieldInfo> fields;
  final List<MethodInfo> methods;
  final List<AttributeInfo> attributes;
  final ConstantPool constantPool;

  ClassFile({
    required this.minorVersion,
    required this.majorVersion,
    required this.accessFlags,
    required this.thisClass,
    required this.superClass,
    required this.interfaces,
    required this.fields,
    required this.methods,
    required this.attributes,
    required this.constantPool,
  });
}

abstract class MemberInfo {
  final int accessFlags;
  final int nameIndex;
  final int descriptorIndex;
  final List<AttributeInfo> attributes;

  MemberInfo({
    required this.accessFlags,
    required this.nameIndex,
    required this.descriptorIndex,
    required this.attributes,
  });

  T? attribute<T extends AttributeInfo>() {
    for (final attr in attributes) {
      if (attr is T) return attr;
    }
    return null;
  }

  List<T> attributesOfType<T extends AttributeInfo>() {
    return attributes.whereType<T>().toList();
  }
}

class FieldInfo extends MemberInfo {
  FieldInfo({
    required super.accessFlags,
    required super.nameIndex,
    required super.descriptorIndex,
    required super.attributes,
  });
}

class MethodInfo extends MemberInfo {
  MethodInfo({
    required super.accessFlags,
    required super.nameIndex,
    required super.descriptorIndex,
    required super.attributes,
  });
}
