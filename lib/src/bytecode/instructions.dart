/// 解码后的单条 JVM 字节码指令。
class Instruction {
  final int offset;
  final int opcode;
  final String mnemonic;
  final List<dynamic> operands;

  Instruction({
    required this.offset,
    required this.opcode,
    required this.mnemonic,
    required this.operands,
  });

  @override
  String toString() {
    final ops = operands.map((o) {
      if (o is int) return '0x${o.toRadixString(16)}';
      return o.toString();
    }).join(', ');
    return '$offset: $mnemonic${operands.isEmpty ? '' : ' $ops'}';
  }
}

/// JVM 操作码常量（节选常用值，完整映射见 [opcodeNames]）。
abstract class Opcodes {
  static const int nop = 0x00;
  static const int aconst_null = 0x01;
  static const int iconst_m1 = 0x02;
  static const int iconst_0 = 0x03;
  static const int iconst_1 = 0x04;
  static const int iconst_2 = 0x05;
  static const int iconst_3 = 0x06;
  static const int iconst_4 = 0x07;
  static const int iconst_5 = 0x08;
  static const int lconst_0 = 0x09;
  static const int lconst_1 = 0x0a;
  static const int fconst_0 = 0x0b;
  static const int fconst_1 = 0x0c;
  static const int fconst_2 = 0x0d;
  static const int dconst_0 = 0x0e;
  static const int dconst_1 = 0x0f;
  static const int bipush = 0x10;
  static const int sipush = 0x11;
  static const int ldc = 0x12;
  static const int ldc_w = 0x13;
  static const int ldc2_w = 0x14;
  static const int iload = 0x15;
  static const int lload = 0x16;
  static const int fload = 0x17;
  static const int dload = 0x18;
  static const int aload = 0x19;
  static const int lstore = 0x37;
  static const int fstore = 0x38;
  static const int dstore = 0x39;
  static const int iload_0 = 0x1a;
  static const int iload_1 = 0x1b;
  static const int iload_2 = 0x1c;
  static const int iload_3 = 0x1d;
  static const int lload_0 = 0x1e;
  static const int lload_1 = 0x1f;
  static const int lload_2 = 0x20;
  static const int lload_3 = 0x21;
  static const int fload_0 = 0x22;
  static const int fload_1 = 0x23;
  static const int fload_2 = 0x24;
  static const int fload_3 = 0x25;
  static const int dload_0 = 0x26;
  static const int dload_1 = 0x27;
  static const int dload_2 = 0x28;
  static const int dload_3 = 0x29;
  static const int aload_0 = 0x2a;
  static const int aload_1 = 0x2b;
  static const int aload_2 = 0x2c;
  static const int aload_3 = 0x2d;
  static const int iaload = 0x2e;
  static const int laload = 0x2f;
  static const int faload = 0x30;
  static const int daload = 0x31;
  static const int aaload = 0x32;
  static const int baload = 0x33;
  static const int caload = 0x34;
  static const int saload = 0x35;
  static const int istore = 0x36;
  static const int astore = 0x3a;
  static const int istore_0 = 0x3b;
  static const int iastore = 0x4f;
  static const int lastore = 0x50;
  static const int fastore = 0x51;
  static const int dastore = 0x52;
  static const int aastore = 0x53;
  static const int bastore = 0x54;
  static const int castore = 0x55;
  static const int sastore = 0x56;
  static const int astore_0 = 0x4b;
  static const int astore_1 = 0x4c;
  static const int astore_2 = 0x4d;
  static const int astore_3 = 0x4e;
  static const int istore_1 = 0x3c;
  static const int istore_2 = 0x3d;
  static const int istore_3 = 0x3e;
  static const int lstore_0 = 0x3f;
  static const int lstore_1 = 0x40;
  static const int lstore_2 = 0x41;
  static const int lstore_3 = 0x42;
  static const int fstore_0 = 0x43;
  static const int fstore_1 = 0x44;
  static const int fstore_2 = 0x45;
  static const int fstore_3 = 0x46;
  static const int dstore_0 = 0x47;
  static const int dstore_1 = 0x48;
  static const int dstore_2 = 0x49;
  static const int dstore_3 = 0x4a;
  static const int pop = 0x57;
  static const int pop2 = 0x58;
  static const int dup = 0x59;
  static const int dup_x1 = 0x5a;
  static const int dup_x2 = 0x5b;
  static const int dup2 = 0x5c;
  static const int dup2_x1 = 0x5d;
  static const int dup2_x2 = 0x5e;
  static const int swap = 0x5f;
  static const int iadd = 0x60;
  static const int ladd = 0x61;
  static const int fadd = 0x62;
  static const int dadd = 0x63;
  static const int isub = 0x64;
  static const int lsub = 0x65;
  static const int fsub = 0x66;
  static const int dsub = 0x67;
  static const int imul = 0x68;
  static const int lmul = 0x69;
  static const int fmul = 0x6a;
  static const int dmul = 0x6b;
  static const int idiv = 0x6c;
  static const int ldiv = 0x6d;
  static const int fdiv = 0x6e;
  static const int ddiv = 0x6f;
  static const int irem = 0x70;
  static const int lrem = 0x71;
  static const int frem = 0x72;
  static const int drem = 0x73;
  static const int ineg = 0x74;
  static const int lneg = 0x75;
  static const int fneg = 0x76;
  static const int dneg = 0x77;
  static const int ishl = 0x78;
  static const int lshl = 0x79;
  static const int ishr = 0x7a;
  static const int lshr = 0x7b;
  static const int iushr = 0x7c;
  static const int lushr = 0x7d;
  static const int iand = 0x7e;
  static const int land = 0x7f;
  static const int ior = 0x80;
  static const int lor = 0x81;
  static const int ixor = 0x82;
  static const int lxor = 0x83;
  static const int iinc = 0x84;
  static const int i2l = 0x85;
  static const int i2f = 0x86;
  static const int i2d = 0x87;
  static const int l2i = 0x88;
  static const int l2f = 0x89;
  static const int l2d = 0x8a;
  static const int f2i = 0x8b;
  static const int f2l = 0x8c;
  static const int f2d = 0x8d;
  static const int d2i = 0x8e;
  static const int d2l = 0x8f;
  static const int d2f = 0x90;
  static const int i2b = 0x91;
  static const int i2c = 0x92;
  static const int i2s = 0x93;
  static const int lcmp = 0x94;
  static const int fcmpl = 0x95;
  static const int fcmpg = 0x96;
  static const int dcmpl = 0x97;
  static const int dcmpg = 0x98;
  static const int ifeq = 0x99;
  static const int ifne = 0x9a;
  static const int iflt = 0x9b;
  static const int ifge = 0x9c;
  static const int ifgt = 0x9d;
  static const int ifle = 0x9e;
  static const int if_icmpeq = 0x9f;
  static const int if_icmpne = 0xa0;
  static const int if_icmplt = 0xa1;
  static const int if_icmpge = 0xa2;
  static const int if_icmpgt = 0xa3;
  static const int if_icmple = 0xa4;
  static const int if_acmpeq = 0xa5;
  static const int if_acmpne = 0xa6;
  static const int goto_ = 0xa7;
  static const int jsr = 0xa8;
  static const int ret = 0xa9;
  static const int tableswitch = 0xaa;
  static const int lookupswitch = 0xab;
  static const int ireturn = 0xac;
  static const int lreturn = 0xad;
  static const int freturn = 0xae;
  static const int dreturn = 0xaf;
  static const int areturn = 0xb0;
  static const int return_ = 0xb1;
  static const int getstatic = 0xb2;
  static const int putstatic = 0xb3;
  static const int getfield = 0xb4;
  static const int putfield = 0xb5;
  static const int invokevirtual = 0xb6;
  static const int invokespecial = 0xb7;
  static const int invokestatic = 0xb8;
  static const int invokeinterface = 0xb9;
  static const int invokedynamic = 0xba;
  static const int new_ = 0xbb;
  static const int newarray = 0xbc;
  static const int anewarray = 0xbd;
  static const int arraylength = 0xbe;
  static const int athrow = 0xbf;
  static const int checkcast = 0xc0;
  static const int instanceof = 0xc1;
  static const int monitorenter = 0xc2;
  static const int monitorexit = 0xc3;
  static const int wide = 0xc4;
  static const int multianewarray = 0xc5;
  static const int ifnull = 0xc6;
  static const int ifnonnull = 0xc7;
  static const int goto_w = 0xc8;
  static const int jsr_w = 0xc9;
}

/// 操作码 -> 助记符完整映射。
const Map<int, String> opcodeNames = {
  0x00: 'nop',
  0x01: 'aconst_null',
  0x02: 'iconst_m1',
  0x03: 'iconst_0',
  0x04: 'iconst_1',
  0x05: 'iconst_2',
  0x06: 'iconst_3',
  0x07: 'iconst_4',
  0x08: 'iconst_5',
  0x09: 'lconst_0',
  0x0a: 'lconst_1',
  0x0b: 'fconst_0',
  0x0c: 'fconst_1',
  0x0d: 'fconst_2',
  0x0e: 'dconst_0',
  0x0f: 'dconst_1',
  0x10: 'bipush',
  0x11: 'sipush',
  0x12: 'ldc',
  0x13: 'ldc_w',
  0x14: 'ldc2_w',
  0x15: 'iload',
  0x16: 'lload',
  0x17: 'fload',
  0x18: 'dload',
  0x19: 'aload',
  0x1a: 'iload_0',
  0x1b: 'iload_1',
  0x1c: 'iload_2',
  0x1d: 'iload_3',
  0x1e: 'lload_0',
  0x1f: 'lload_1',
  0x20: 'lload_2',
  0x21: 'lload_3',
  0x22: 'fload_0',
  0x23: 'fload_1',
  0x24: 'fload_2',
  0x25: 'fload_3',
  0x26: 'dload_0',
  0x27: 'dload_1',
  0x28: 'dload_2',
  0x29: 'dload_3',
  0x2a: 'aload_0',
  0x2b: 'aload_1',
  0x2c: 'aload_2',
  0x2d: 'aload_3',
  0x2e: 'iaload',
  0x2f: 'laload',
  0x30: 'faload',
  0x31: 'daload',
  0x32: 'aaload',
  0x33: 'baload',
  0x34: 'caload',
  0x35: 'saload',
  0x36: 'istore',
  0x37: 'lstore',
  0x38: 'fstore',
  0x39: 'dstore',
  0x3a: 'astore',
  0x3b: 'istore_0',
  0x3c: 'istore_1',
  0x3d: 'istore_2',
  0x3e: 'istore_3',
  0x3f: 'lstore_0',
  0x40: 'lstore_1',
  0x41: 'lstore_2',
  0x42: 'lstore_3',
  0x43: 'fstore_0',
  0x44: 'fstore_1',
  0x45: 'fstore_2',
  0x46: 'fstore_3',
  0x47: 'dstore_0',
  0x48: 'dstore_1',
  0x49: 'dstore_2',
  0x4a: 'dstore_3',
  0x4b: 'astore_0',
  0x4c: 'astore_1',
  0x4d: 'astore_2',
  0x4e: 'astore_3',
  0x4f: 'iastore',
  0x50: 'lastore',
  0x51: 'fastore',
  0x52: 'dastore',
  0x53: 'aastore',
  0x54: 'bastore',
  0x55: 'castore',
  0x56: 'sastore',
  0x57: 'pop',
  0x58: 'pop2',
  0x59: 'dup',
  0x5a: 'dup_x1',
  0x5b: 'dup_x2',
  0x5c: 'dup2',
  0x5d: 'dup2_x1',
  0x5e: 'dup2_x2',
  0x5f: 'swap',
  0x60: 'iadd',
  0x61: 'ladd',
  0x62: 'fadd',
  0x63: 'dadd',
  0x64: 'isub',
  0x65: 'lsub',
  0x66: 'fsub',
  0x67: 'dsub',
  0x68: 'imul',
  0x69: 'lmul',
  0x6a: 'fmul',
  0x6b: 'dmul',
  0x6c: 'idiv',
  0x6d: 'ldiv',
  0x6e: 'fdiv',
  0x6f: 'ddiv',
  0x70: 'irem',
  0x71: 'lrem',
  0x72: 'frem',
  0x73: 'drem',
  0x74: 'ineg',
  0x75: 'lneg',
  0x76: 'fneg',
  0x77: 'dneg',
  0x78: 'ishl',
  0x79: 'lshl',
  0x7a: 'ishr',
  0x7b: 'lshr',
  0x7c: 'iushr',
  0x7d: 'lushr',
  0x7e: 'iand',
  0x7f: 'land',
  0x80: 'ior',
  0x81: 'lor',
  0x82: 'ixor',
  0x83: 'lxor',
  0x84: 'iinc',
  0x85: 'i2l',
  0x86: 'i2f',
  0x87: 'i2d',
  0x88: 'l2i',
  0x89: 'l2f',
  0x8a: 'l2d',
  0x8b: 'f2i',
  0x8c: 'f2l',
  0x8d: 'f2d',
  0x8e: 'd2i',
  0x8f: 'd2l',
  0x90: 'd2f',
  0x91: 'i2b',
  0x92: 'i2c',
  0x93: 'i2s',
  0x94: 'lcmp',
  0x95: 'fcmpl',
  0x96: 'fcmpg',
  0x97: 'dcmpl',
  0x98: 'dcmpg',
  0x99: 'ifeq',
  0x9a: 'ifne',
  0x9b: 'iflt',
  0x9c: 'ifge',
  0x9d: 'ifgt',
  0x9e: 'ifle',
  0x9f: 'if_icmpeq',
  0xa0: 'if_icmpne',
  0xa1: 'if_icmplt',
  0xa2: 'if_icmpge',
  0xa3: 'if_icmpgt',
  0xa4: 'if_icmple',
  0xa5: 'if_acmpeq',
  0xa6: 'if_acmpne',
  0xa7: 'goto',
  0xa8: 'jsr',
  0xa9: 'ret',
  0xaa: 'tableswitch',
  0xab: 'lookupswitch',
  0xac: 'ireturn',
  0xad: 'lreturn',
  0xae: 'freturn',
  0xaf: 'dreturn',
  0xb0: 'areturn',
  0xb1: 'return',
  0xb2: 'getstatic',
  0xb3: 'putstatic',
  0xb4: 'getfield',
  0xb5: 'putfield',
  0xb6: 'invokevirtual',
  0xb7: 'invokespecial',
  0xb8: 'invokestatic',
  0xb9: 'invokeinterface',
  0xba: 'invokedynamic',
  0xbb: 'new',
  0xbc: 'newarray',
  0xbd: 'anewarray',
  0xbe: 'arraylength',
  0xbf: 'athrow',
  0xc0: 'checkcast',
  0xc1: 'instanceof',
  0xc2: 'monitorenter',
  0xc3: 'monitorexit',
  0xc4: 'wide',
  0xc5: 'multianewarray',
  0xc6: 'ifnull',
  0xc7: 'ifnonnull',
  0xc8: 'goto_w',
  0xc9: 'jsr_w',
  0xca: 'breakpoint',
  0xfe: 'impdep1',
  0xff: 'impdep2',
};
