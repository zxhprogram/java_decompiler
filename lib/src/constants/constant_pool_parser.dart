import 'dart:convert';

import '../io/class_reader.dart';
import 'constant_pool.dart';
import 'constant_pool_tags.dart';

class ConstantPoolParser {
  final ClassReader _reader;

  ConstantPoolParser(this._reader);

  ConstantPool parse() {
    final count = _reader.u2();
    final entries = List<CpInfo?>.filled(count, null);
    for (var i = 1; i < count; i++) {
      final entry = _parseEntry();
      entries[i] = entry;
      // Long 与 Double 占用两个槽位。
      if (entry is CpLong || entry is CpDouble) {
        i++;
      }
    }
    return ConstantPool(entries);
  }

  CpInfo _parseEntry() {
    final tag = _reader.u1();
    switch (tag) {
      case ConstantPoolTags.utf8:
        return CpUtf8(
          utf8.decode(_reader.readUtf8Bytes(), allowMalformed: true),
        );
      case ConstantPoolTags.integer:
        return CpInteger(_reader.s4());
      case ConstantPoolTags.float:
        return CpFloat(_reader.f4());
      case ConstantPoolTags.long:
        return CpLong(_reader.s8());
      case ConstantPoolTags.double:
        return CpDouble(_reader.f8());
      case ConstantPoolTags.classInfo:
        return CpClass(_reader.u2());
      case ConstantPoolTags.string:
        return CpString(_reader.u2());
      case ConstantPoolTags.fieldref:
        return CpFieldref(_reader.u2(), _reader.u2());
      case ConstantPoolTags.methodref:
        return CpMethodref(_reader.u2(), _reader.u2());
      case ConstantPoolTags.interfaceMethodref:
        return CpInterfaceMethodref(_reader.u2(), _reader.u2());
      case ConstantPoolTags.nameAndType:
        return CpNameAndType(_reader.u2(), _reader.u2());
      case ConstantPoolTags.methodHandle:
        return CpMethodHandle(_reader.u1(), _reader.u2());
      case ConstantPoolTags.methodType:
        return CpMethodType(_reader.u2());
      case ConstantPoolTags.dynamic:
        return CpDynamic(_reader.u2(), _reader.u2());
      case ConstantPoolTags.invokeDynamic:
        return CpInvokeDynamic(_reader.u2(), _reader.u2());
      case ConstantPoolTags.module:
        return CpModule(_reader.u2());
      case ConstantPoolTags.package:
        return CpPackage(_reader.u2());
      default:
        throw FormatException(
          'Unknown constant pool tag: $tag at offset '
          '${_reader.offset - 1}',
        );
    }
  }
}
