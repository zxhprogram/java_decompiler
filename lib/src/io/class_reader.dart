import 'dart:typed_data';

/// 顺序读取 Java class 文件字节流（大端序）。
class ClassReader {
  final ByteData _data;
  int _offset = 0;

  ClassReader(Uint8List bytes) : _data = ByteData.sublistView(bytes);

  int get offset => _offset;
  int get length => _data.lengthInBytes;

  void skip(int n) => _offset += n;

  int u1() => _data.getUint8(_offset++);

  int u2() {
    final v = _data.getUint16(_offset, Endian.big);
    _offset += 2;
    return v;
  }

  int u4() {
    final v = _data.getUint32(_offset, Endian.big);
    _offset += 4;
    return v;
  }

  int s1() {
    final v = _data.getInt8(_offset);
    _offset += 1;
    return v;
  }

  int s2() {
    final v = _data.getInt16(_offset, Endian.big);
    _offset += 2;
    return v;
  }

  int s4() {
    final v = _data.getInt32(_offset, Endian.big);
    _offset += 4;
    return v;
  }

  double f4() {
    final v = _data.getFloat32(_offset, Endian.big);
    _offset += 4;
    return v;
  }

  double f8() {
    final v = _data.getFloat64(_offset, Endian.big);
    _offset += 8;
    return v;
  }

  int s8() {
    final v = _data.getInt64(_offset, Endian.big);
    _offset += 8;
    return v;
  }

  Uint8List readBytes(int n) {
    final bytes = Uint8List(n);
    for (var i = 0; i < n; i++) {
      bytes[i] = _data.getUint8(_offset++);
    }
    return bytes;
  }

  /// 读取 [n] 个字节但不推进游标。
  Uint8List peekBytes(int n) {
    final bytes = Uint8List(n);
    for (var i = 0; i < n; i++) {
      bytes[i] = _data.getUint8(_offset + i);
    }
    return bytes;
  }

  /// 按 u2 长度读取一段 UTF-8 字节。
  Uint8List readUtf8Bytes() => readBytes(u2());

  void expectMagic(int magic) {
    final m = u4();
    if (m != magic) {
      throw FormatException(
        'Expected magic 0x${magic.toRadixString(16)} '
        'but got 0x${m.toRadixString(16)} at offset 0',
      );
    }
  }
}
