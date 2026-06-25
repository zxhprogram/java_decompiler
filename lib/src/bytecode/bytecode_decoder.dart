import 'dart:typed_data';

import '../io/class_reader.dart';
import 'instructions.dart';

class BytecodeDecoder {
  final Uint8List code;
  final ClassReader _reader;

  BytecodeDecoder(this.code) : _reader = ClassReader(code);

  List<Instruction> decode() {
    final instructions = <Instruction>[];
    while (_reader.offset < _reader.length) {
      final offset = _reader.offset;
      final opcode = _reader.u1();
      final mnemonic = opcodeNames[opcode] ?? 'unknown_$opcode';
      final operands = _readOperands(opcode, offset);
      instructions.add(Instruction(
        offset: offset,
        opcode: opcode,
        mnemonic: mnemonic,
        operands: operands,
      ));
    }
    return instructions;
  }

  List<dynamic> _readOperands(int opcode, int offset) {
    switch (opcode) {
      // 无操作数
      case 0x00: case 0x01: case 0x02: case 0x03: case 0x04: case 0x05:
      case 0x06: case 0x07: case 0x08: case 0x09: case 0x0a: case 0x0b:
      case 0x0c: case 0x0d: case 0x0e: case 0x0f: case 0x1a: case 0x1b:
      case 0x1c: case 0x1d: case 0x1e: case 0x1f: case 0x20: case 0x21:
      case 0x22: case 0x23: case 0x24: case 0x25: case 0x26: case 0x27:
      case 0x28: case 0x29: case 0x2a: case 0x2b: case 0x2c: case 0x2d:
      case 0x2e: case 0x2f: case 0x30: case 0x31: case 0x32: case 0x33:
      case 0x34: case 0x35: case 0x3b: case 0x3c: case 0x3d: case 0x3e:
      case 0x3f: case 0x40: case 0x41: case 0x42: case 0x43: case 0x44:
      case 0x45: case 0x46: case 0x47: case 0x48: case 0x49: case 0x4a:
      case 0x4b: case 0x4c: case 0x4d: case 0x4e: case 0x4f: case 0x50:
      case 0x51: case 0x52: case 0x53: case 0x54: case 0x55: case 0x56:
      case 0x57: case 0x58: case 0x59: case 0x5a: case 0x5b: case 0x5c:
      case 0x5d: case 0x5e: case 0x5f: case 0x60: case 0x61: case 0x62:
      case 0x63: case 0x64: case 0x65: case 0x66: case 0x67: case 0x68:
      case 0x69: case 0x6a: case 0x6b: case 0x6c: case 0x6d: case 0x6e:
      case 0x6f: case 0x70: case 0x71: case 0x72: case 0x73: case 0x74:
      case 0x75: case 0x76: case 0x77: case 0x78: case 0x79: case 0x7a:
      case 0x7b: case 0x7c: case 0x7d: case 0x7e: case 0x7f: case 0x80:
      case 0x81: case 0x82: case 0x83: case 0x85: case 0x86: case 0x87:
      case 0x88: case 0x89: case 0x8a: case 0x8b: case 0x8c: case 0x8d:
      case 0x8e: case 0x8f: case 0x90: case 0x91: case 0x92: case 0x93:
      case 0x94: case 0x95: case 0x96: case 0x97: case 0x98: case 0xac:
      case 0xad: case 0xae: case 0xaf: case 0xb0: case 0xb1: case 0xbe:
      case 0xbf: case 0xc2: case 0xc3: case 0xca: case 0xfe: case 0xff:
        return const [];
      // u1
      case 0x10: // bipush
        return [_reader.s1()];
      case 0x12: // ldc
      case 0x19: // aload
      case 0x15: // iload
      case 0x16: // lload
      case 0x17: // fload
      case 0x18: // dload
      case 0x36: // istore
      case 0x37: // lstore
      case 0x38: // fstore
      case 0x39: // dstore
      case 0x3a: // astore
      case 0xa9: // ret
      case 0xbc: // newarray
        return [_reader.u1()];
      // u2
      case 0x11: // sipush
        return [_reader.s2()];
      case 0x13: // ldc_w
      case 0x14: // ldc2_w
      case 0xb2: // getstatic
      case 0xb3: // putstatic
      case 0xb4: // getfield
      case 0xb5: // putfield
      case 0xb6: // invokevirtual
      case 0xb7: // invokespecial
      case 0xb8: // invokestatic
      case 0xbb: // new
      case 0xbd: // anewarray
      case 0xc0: // checkcast
      case 0xc1: // instanceof
        return [_reader.u2()];
      // s2 branch
      case 0x99: case 0x9a: case 0x9b: case 0x9c: case 0x9d: case 0x9e:
      case 0x9f: case 0xa0: case 0xa1: case 0xa2: case 0xa3: case 0xa4:
      case 0xa5: case 0xa6: case 0xa7: // goto
      case 0xa8: // jsr
      case 0xc6: // ifnull
      case 0xc7: // ifnonnull
        return [offset + _reader.s2()];
      // iinc
      case 0x84:
        return [_reader.u1(), _reader.s1()];
      // invokeinterface
      case 0xb9:
        return [_reader.u2(), _reader.u1(), _reader.u1()];
      // invokedynamic
      case 0xba:
        return [_reader.u2(), _reader.u2()];
      // multianewarray
      case 0xc5:
        return [_reader.u2(), _reader.u1()];
      // wide
      case 0xc4:
        final sub = _reader.u1();
        if (sub == 0x84) {
          // wide iinc
          return [sub, _reader.u2(), _reader.s2()];
        }
        return [sub, _reader.u2()];
      // goto_w / jsr_w
      case 0xc8: case 0xc9:
        return [offset + _reader.s4()];
      // tableswitch
      case 0xaa:
        return _readTableSwitch(offset);
      // lookupswitch
      case 0xab:
        return _readLookupSwitch(offset);
      default:
        return const [];
    }
  }

  List<dynamic> _readTableSwitch(int offset) {
    // 0-3 字节填充，使 default 偏移量从方法起始处 4 字节对齐。
    while ((_reader.offset & 3) != 0) _reader.u1();
    final defaultTarget = _reader.s4();
    final low = _reader.s4();
    final high = _reader.s4();
    final offsets = <int>[];
    for (var i = low; i <= high; i++) {
      offsets.add(offset + _reader.s4());
    }
    return [offset + defaultTarget, low, high, offsets];
  }

  List<dynamic> _readLookupSwitch(int offset) {
    while ((_reader.offset & 3) != 0) _reader.u1();
    final defaultTarget = _reader.s4();
    final npairs = _reader.u4();
    final pairs = <(int, int)>[];
    for (var i = 0; i < npairs; i++) {
      final match = _reader.s4();
      final target = offset + _reader.s4();
      pairs.add((match, target));
    }
    return [offset + defaultTarget, pairs];
  }
}
