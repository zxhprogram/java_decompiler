/// JVM 访问标志位（JVM Specification §4.1/§4.5/§4.6）。
abstract class AccessFlags {
  static const int ACC_PUBLIC = 0x0001;
  static const int ACC_PRIVATE = 0x0002;
  static const int ACC_PROTECTED = 0x0004;
  static const int ACC_STATIC = 0x0008;
  static const int ACC_FINAL = 0x0010;
  static const int ACC_SUPER = 0x0020;
  static const int ACC_SYNCHRONIZED = 0x0020; // 方法
  static const int ACC_VOLATILE = 0x0040; // 字段
  static const int ACC_BRIDGE = 0x0040; // 方法
  static const int ACC_TRANSIENT = 0x0080; // 字段
  static const int ACC_VARARGS = 0x0080; // 方法
  static const int ACC_NATIVE = 0x0100;
  static const int ACC_INTERFACE = 0x0200;
  static const int ACC_ABSTRACT = 0x0400;
  static const int ACC_STRICT = 0x0800;
  static const int ACC_SYNTHETIC = 0x1000;
  static const int ACC_ANNOTATION = 0x2000;
  static const int ACC_ENUM = 0x4000;
  static const int ACC_MODULE = 0x8000;
}

class AccessFlagFormatter {
  static bool has(int flags, int bit) => (flags & bit) != 0;

  static List<String> classFlags(int flags) {
    final list = <String>[];
    if (has(flags, AccessFlags.ACC_PUBLIC)) list.add('public');
    if (has(flags, AccessFlags.ACC_FINAL)) list.add('final');
    if (has(flags, AccessFlags.ACC_ABSTRACT)) list.add('abstract');
    if (has(flags, AccessFlags.ACC_INTERFACE)) list.add('interface');
    if (has(flags, AccessFlags.ACC_ANNOTATION)) list.add('@interface');
    if (has(flags, AccessFlags.ACC_ENUM)) list.add('enum');
    if (has(flags, AccessFlags.ACC_MODULE)) list.add('module');
    return list;
  }

  static List<String> fieldFlags(int flags) {
    final list = <String>[];
    if (has(flags, AccessFlags.ACC_PUBLIC)) list.add('public');
    if (has(flags, AccessFlags.ACC_PRIVATE)) list.add('private');
    if (has(flags, AccessFlags.ACC_PROTECTED)) list.add('protected');
    if (has(flags, AccessFlags.ACC_STATIC)) list.add('static');
    if (has(flags, AccessFlags.ACC_FINAL)) list.add('final');
    if (has(flags, AccessFlags.ACC_VOLATILE)) list.add('volatile');
    if (has(flags, AccessFlags.ACC_TRANSIENT)) list.add('transient');
    return list;
  }

  static List<String> methodFlags(int flags, {bool includeAbstract = true}) {
    final list = <String>[];
    if (has(flags, AccessFlags.ACC_PUBLIC)) list.add('public');
    if (has(flags, AccessFlags.ACC_PRIVATE)) list.add('private');
    if (has(flags, AccessFlags.ACC_PROTECTED)) list.add('protected');
    if (has(flags, AccessFlags.ACC_STATIC)) list.add('static');
    if (has(flags, AccessFlags.ACC_FINAL)) list.add('final');
    if (has(flags, AccessFlags.ACC_SYNCHRONIZED)) list.add('synchronized');
    if (has(flags, AccessFlags.ACC_NATIVE)) list.add('native');
    if (includeAbstract && has(flags, AccessFlags.ACC_ABSTRACT)) {
      list.add('abstract');
    }
    if (has(flags, AccessFlags.ACC_STRICT)) list.add('strictfp');
    return list;
  }

  static List<String> nestedClassFlags(int flags) {
    final list = classFlags(flags);
    if (has(flags, AccessFlags.ACC_STATIC)) list.add('static');
    if (has(flags, AccessFlags.ACC_PROTECTED)) list.add('protected');
    if (has(flags, AccessFlags.ACC_PRIVATE)) list.add('private');
    return list;
  }
}
