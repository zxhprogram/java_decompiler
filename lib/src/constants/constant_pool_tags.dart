/// 常量池项的 tag 常量（JVM Specification §4.4）。
abstract class ConstantPoolTags {
  static const int utf8 = 1;
  static const int integer = 3;
  static const int float = 4;
  static const int long = 5;
  static const int double = 6;
  static const int classInfo = 7;
  static const int string = 8;
  static const int fieldref = 9;
  static const int methodref = 10;
  static const int interfaceMethodref = 11;
  static const int nameAndType = 12;
  static const int methodHandle = 15;
  static const int methodType = 16;
  static const int dynamic = 17;
  static const int invokeDynamic = 18;
  static const int module = 19;
  static const int package = 20;
}
