import '../attributes/attribute_models.dart';
import '../bytecode/bytecode_decoder.dart';
import '../bytecode/instructions.dart';
import '../class_file.dart';
import '../constants/constant_pool.dart';
import '../descriptor_parser.dart';
import '../flags/access_flags.dart';

part 'code_printer_stack.dart';
part 'code_printer_control_flow.dart';
part 'code_printer_switch.dart';
part 'code_printer_patterns.dart';
part 'code_printer_try_catch.dart';
part 'code_printer_simplify.dart';
part 'code_printer_lambda.dart';
part 'code_printer_utils.dart';

class _TypedValue {
  final String expr;
  final String type;
  _TypedValue(this.expr, {this.type = ''});
}

class _CountingSink implements StringSink {
  final StringBuffer _buf;
  int lineCount;
  _CountingSink(this._buf) : lineCount = 0;

  @override
  void write(Object? obj) => _buf.write(obj);

  @override
  void writeln([Object? obj = '']) {
    _buf.writeln(obj);
    lineCount++;
  }

  @override
  void writeAll(Iterable objects, [String separator = '']) =>
      _buf.writeAll(objects, separator);

  @override
  void writeCharCode(int charCode) => _buf.writeCharCode(charCode);
}

class CodePrinter {
  final MethodInfo _method;
  final CodeAttribute _code;
  final ClassFile _cf;
  late final ConstantPool _pool = _cf.constantPool;

  CodePrinter(this._method, this._code, this._cf);

  static final Set<int> _branchOpcodes = {
    Opcodes.ifeq,
    Opcodes.ifne,
    Opcodes.iflt,
    Opcodes.ifge,
    Opcodes.ifgt,
    Opcodes.ifle,
    Opcodes.if_icmpeq,
    Opcodes.if_icmpne,
    Opcodes.if_icmplt,
    Opcodes.if_icmpge,
    Opcodes.if_icmpgt,
    Opcodes.if_icmple,
    Opcodes.if_acmpeq,
    Opcodes.if_acmpne,
    Opcodes.goto_,
    Opcodes.jsr,
    Opcodes.ifnull,
    Opcodes.ifnonnull,
    Opcodes.goto_w,
    Opcodes.jsr_w,
  };

  String printBody() {
    final instructions = BytecodeDecoder(_code.code).decode();
    if (instructions.isEmpty) {
      return '        // empty code\n';
    }

    final simple = _trySimplePattern(instructions);
    if (simple != null) return simple;

    final (raw, offsetToLine) = _printStackBased(instructions);
    var text = _preprocessPatternMatching(raw);
    text = _structureTryCatch(text, offsetToLine);
    text = _liftIfGotoToTerminator(text);
    text = _structureIfs(text);
    text = _structurePatternSwitch(text);
    text = _structureSimpleSwitch(text);
    text = _structureIfElse(text);
    text = _structureIfElseIfChain(text);
    text = _structureForEach(text);
    text = _structureWhileLoops(text);
    text = _structureForLoops(text);
    text = _structureDoWhileLoops(text);
    text = _structureArrayInit(text);
    text = _cleanupBreakContinue(text);
    text = _removeUnusedLabels(text);
    text = _simplifyEmptyIfElse(text);
    text = _cleanupTryCatchResidue(text);
    text = _cleanupPatternMatchingResidue(text);
    text = _simplifyInstanceofRecordPattern(text);
    text = _removeStackUnderflow(text);
    text = _simplifyBoxing(text);
    text = _simplifyConditions(text);
    text = _flattenShortCircuitReturns(text);
    text = _simplifyBooleanReturns(text);
    text = _restoreVariableNames(text);
    return text;
  }
}
