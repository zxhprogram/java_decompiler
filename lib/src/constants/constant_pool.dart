import 'constant_pool_tags.dart';

/// 常量池项基类。
abstract class CpInfo {
  final int tag;
  const CpInfo(this.tag);
}

class CpUtf8 extends CpInfo {
  final String value;
  CpUtf8(this.value) : super(ConstantPoolTags.utf8);
}

class CpInteger extends CpInfo {
  final int value;
  CpInteger(this.value) : super(ConstantPoolTags.integer);
}

class CpFloat extends CpInfo {
  final double value;
  CpFloat(this.value) : super(ConstantPoolTags.float);
}

class CpLong extends CpInfo {
  final int value;
  CpLong(this.value) : super(ConstantPoolTags.long);
}

class CpDouble extends CpInfo {
  final double value;
  CpDouble(this.value) : super(ConstantPoolTags.double);
}

class CpClass extends CpInfo {
  final int nameIndex;
  CpClass(this.nameIndex) : super(ConstantPoolTags.classInfo);
}

class CpString extends CpInfo {
  final int stringIndex;
  CpString(this.stringIndex) : super(ConstantPoolTags.string);
}

class CpFieldref extends CpInfo {
  final int classIndex;
  final int nameAndTypeIndex;
  CpFieldref(this.classIndex, this.nameAndTypeIndex)
      : super(ConstantPoolTags.fieldref);
}

class CpMethodref extends CpInfo {
  final int classIndex;
  final int nameAndTypeIndex;
  CpMethodref(this.classIndex, this.nameAndTypeIndex)
      : super(ConstantPoolTags.methodref);
}

class CpInterfaceMethodref extends CpInfo {
  final int classIndex;
  final int nameAndTypeIndex;
  CpInterfaceMethodref(this.classIndex, this.nameAndTypeIndex)
      : super(ConstantPoolTags.interfaceMethodref);
}

class CpNameAndType extends CpInfo {
  final int nameIndex;
  final int descriptorIndex;
  CpNameAndType(this.nameIndex, this.descriptorIndex)
      : super(ConstantPoolTags.nameAndType);
}

class CpMethodHandle extends CpInfo {
  final int referenceKind;
  final int referenceIndex;
  CpMethodHandle(this.referenceKind, this.referenceIndex)
      : super(ConstantPoolTags.methodHandle);
}

class CpMethodType extends CpInfo {
  final int descriptorIndex;
  CpMethodType(this.descriptorIndex) : super(ConstantPoolTags.methodType);
}

class CpDynamic extends CpInfo {
  final int bootstrapMethodAttrIndex;
  final int nameAndTypeIndex;
  CpDynamic(this.bootstrapMethodAttrIndex, this.nameAndTypeIndex)
      : super(ConstantPoolTags.dynamic);
}

class CpInvokeDynamic extends CpInfo {
  final int bootstrapMethodAttrIndex;
  final int nameAndTypeIndex;
  CpInvokeDynamic(this.bootstrapMethodAttrIndex, this.nameAndTypeIndex)
      : super(ConstantPoolTags.invokeDynamic);
}

class CpModule extends CpInfo {
  final int nameIndex;
  CpModule(this.nameIndex) : super(ConstantPoolTags.module);
}

class CpPackage extends CpInfo {
  final int nameIndex;
  CpPackage(this.nameIndex) : super(ConstantPoolTags.package);
}

/// 常量池包装，索引从 1 开始，下标 0 为 null。
class ConstantPool {
  final List<CpInfo?> _entries;

  ConstantPool(this._entries);

  int get length => _entries.length;

  CpInfo? get(int index) {
    if (index < 0 || index >= _entries.length) {
      throw RangeError.index(index, _entries);
    }
    return _entries[index];
  }

  String getString(int index) {
    final entry = get(index);
    if (entry is CpUtf8) return entry.value;
    throw FormatException('Expected UTF8 at index $index, got $entry');
  }

  int getInt(int index) {
    final entry = get(index);
    if (entry is CpInteger) return entry.value;
    throw FormatException('Expected Integer at index $index, got $entry');
  }

  double getFloat(int index) {
    final entry = get(index);
    if (entry is CpFloat) return entry.value;
    throw FormatException('Expected Float at index $index, got $entry');
  }

  int getLong(int index) {
    final entry = get(index);
    if (entry is CpLong) return entry.value;
    throw FormatException('Expected Long at index $index, got $entry');
  }

  double getDouble(int index) {
    final entry = get(index);
    if (entry is CpDouble) return entry.value;
    throw FormatException('Expected Double at index $index, got $entry');
  }

  CpClass getClass(int index) {
    final entry = get(index);
    if (entry is CpClass) return entry;
    throw FormatException('Expected Class at index $index, got $entry');
  }

  String getClassName(int index) => getString(getClass(index).nameIndex);

  CpNameAndType getNameAndType(int index) {
    final entry = get(index);
    if (entry is CpNameAndType) return entry;
    throw FormatException('Expected NameAndType at index $index, got $entry');
  }

  CpFieldref getFieldref(int index) {
    final entry = get(index);
    if (entry is CpFieldref) return entry;
    throw FormatException('Expected Fieldref at index $index, got $entry');
  }

  CpMethodref getMethodref(int index) {
    final entry = get(index);
    if (entry is CpMethodref) return entry;
    throw FormatException('Expected Methodref at index $index, got $entry');
  }

  CpInterfaceMethodref getInterfaceMethodref(int index) {
    final entry = get(index);
    if (entry is CpInterfaceMethodref) return entry;
    throw FormatException(
      'Expected InterfaceMethodref at index $index, got $entry',
    );
  }

  CpString getStringInfo(int index) {
    final entry = get(index);
    if (entry is CpString) return entry;
    throw FormatException('Expected String at index $index, got $entry');
  }

  CpMethodHandle getMethodHandle(int index) {
    final entry = get(index);
    if (entry is CpMethodHandle) return entry;
    throw FormatException('Expected MethodHandle at index $index, got $entry');
  }

  CpMethodType getMethodType(int index) {
    final entry = get(index);
    if (entry is CpMethodType) return entry;
    throw FormatException('Expected MethodType at index $index, got $entry');
  }

  CpDynamic getDynamic(int index) {
    final entry = get(index);
    if (entry is CpDynamic) return entry;
    throw FormatException('Expected Dynamic at index $index, got $entry');
  }

  CpInvokeDynamic getInvokeDynamic(int index) {
    final entry = get(index);
    if (entry is CpInvokeDynamic) return entry;
    throw FormatException('Expected InvokeDynamic at index $index, got $entry');
  }

  CpModule getModule(int index) {
    final entry = get(index);
    if (entry is CpModule) return entry;
    throw FormatException('Expected Module at index $index, got $entry');
  }

  CpPackage getPackage(int index) {
    final entry = get(index);
    if (entry is CpPackage) return entry;
    throw FormatException('Expected Package at index $index, got $entry');
  }

  /// 将索引处的值以 Java 字面量形式返回（用于 ldc、ConstantValue 等）。
  String getLiteral(int index) {
    final entry = get(index);
    return switch (entry) {
      CpInteger(:final value) => value.toString(),
      CpFloat(:final value) => '${value}f',
      CpLong(:final value) => '${value}L',
      CpDouble(:final value) => value.toString(),
      CpString(:final stringIndex) =>
        '"${getString(stringIndex).replaceAll('"', '\\"')}"',
      CpUtf8(:final value) => '"${value.replaceAll('"', '\\"')}"',
      CpClass(:final nameIndex) =>
        '${getString(nameIndex).replaceAll('/', '.')}.class',
      CpMethodType(:final descriptorIndex) =>
        'MethodType(${getString(descriptorIndex)})',
      _ => throw FormatException('Unsupported literal at index $index: $entry'),
    };
  }
}
