import 'dart:typed_data';

/// 所有属性的基类。实际子类保存了解析后的结构化数据。
abstract class AttributeInfo {
  final String name;
  AttributeInfo(this.name);
}

class ConstantValueAttribute extends AttributeInfo {
  final int constantValueIndex;
  ConstantValueAttribute(this.constantValueIndex) : super('ConstantValue');
}

class CodeAttribute extends AttributeInfo {
  final int maxStack;
  final int maxLocals;
  final Uint8List code;
  final List<ExceptionTableEntry> exceptionTable;
  final List<AttributeInfo> attributes;
  CodeAttribute({
    required this.maxStack,
    required this.maxLocals,
    required this.code,
    required this.exceptionTable,
    required this.attributes,
  }) : super('Code');
}

class ExceptionTableEntry {
  final int startPc;
  final int endPc;
  final int handlerPc;
  final int catchType;
  ExceptionTableEntry(this.startPc, this.endPc, this.handlerPc, this.catchType);
}

abstract class VerificationTypeInfo {
  final int tag;
  VerificationTypeInfo(this.tag);
}

class TopVariableInfo extends VerificationTypeInfo {
  TopVariableInfo() : super(0);
}

class IntegerVariableInfo extends VerificationTypeInfo {
  IntegerVariableInfo() : super(1);
}

class FloatVariableInfo extends VerificationTypeInfo {
  FloatVariableInfo() : super(2);
}

class LongVariableInfo extends VerificationTypeInfo {
  LongVariableInfo() : super(4);
}

class DoubleVariableInfo extends VerificationTypeInfo {
  DoubleVariableInfo() : super(3);
}

class NullVariableInfo extends VerificationTypeInfo {
  NullVariableInfo() : super(5);
}

class UninitializedThisVariableInfo extends VerificationTypeInfo {
  UninitializedThisVariableInfo() : super(6);
}

class ObjectVariableInfo extends VerificationTypeInfo {
  final int cpoolIndex;
  ObjectVariableInfo(this.cpoolIndex) : super(7);
}

class UninitializedVariableInfo extends VerificationTypeInfo {
  final int offset;
  UninitializedVariableInfo(this.offset) : super(8);
}

abstract class StackMapFrame {
  final int frameType;
  StackMapFrame(this.frameType);
}

class SameFrame extends StackMapFrame {
  SameFrame(super.frameType);
}

class SameLocals1StackItemFrame extends StackMapFrame {
  final VerificationTypeInfo stackItem;
  SameLocals1StackItemFrame(super.frameType, this.stackItem);
}

class SameLocals1StackItemFrameExtended extends StackMapFrame {
  final int offsetDelta;
  final VerificationTypeInfo stackItem;
  SameLocals1StackItemFrameExtended(this.offsetDelta, this.stackItem)
      : super(247);
}

class ChopFrame extends StackMapFrame {
  final int offsetDelta;
  ChopFrame(super.frameType, this.offsetDelta);
}

class SameFrameExtended extends StackMapFrame {
  final int offsetDelta;
  SameFrameExtended(this.offsetDelta) : super(251);
}

class AppendFrame extends StackMapFrame {
  final int offsetDelta;
  final List<VerificationTypeInfo> locals;
  AppendFrame(super.frameType, this.offsetDelta, this.locals);
}

class FullFrame extends StackMapFrame {
  final int offsetDelta;
  final List<VerificationTypeInfo> locals;
  final List<VerificationTypeInfo> stack;
  FullFrame(this.offsetDelta, this.locals, this.stack) : super(255);
}

class StackMapTableAttribute extends AttributeInfo {
  final List<StackMapFrame> entries;
  StackMapTableAttribute(this.entries) : super('StackMapTable');
}

class ExceptionsAttribute extends AttributeInfo {
  final List<int> exceptionIndexTable;
  ExceptionsAttribute(this.exceptionIndexTable) : super('Exceptions');
}

class InnerClassEntry {
  final int innerClassInfoIndex;
  final int outerClassInfoIndex;
  final int innerNameIndex;
  final int innerClassAccessFlags;
  InnerClassEntry(
    this.innerClassInfoIndex,
    this.outerClassInfoIndex,
    this.innerNameIndex,
    this.innerClassAccessFlags,
  );
}

class InnerClassesAttribute extends AttributeInfo {
  final List<InnerClassEntry> classes;
  InnerClassesAttribute(this.classes) : super('InnerClasses');
}

class EnclosingMethodAttribute extends AttributeInfo {
  final int classIndex;
  final int methodIndex;
  EnclosingMethodAttribute(this.classIndex, this.methodIndex)
      : super('EnclosingMethod');
}

class SyntheticAttribute extends AttributeInfo {
  SyntheticAttribute() : super('Synthetic');
}

class SignatureAttribute extends AttributeInfo {
  final int signatureIndex;
  SignatureAttribute(this.signatureIndex) : super('Signature');
}

class SourceFileAttribute extends AttributeInfo {
  final int sourcefileIndex;
  SourceFileAttribute(this.sourcefileIndex) : super('SourceFile');
}

class SourceDebugExtensionAttribute extends AttributeInfo {
  final String debugExtension;
  SourceDebugExtensionAttribute(this.debugExtension)
      : super('SourceDebugExtension');
}

class LineNumberEntry {
  final int startPc;
  final int lineNumber;
  LineNumberEntry(this.startPc, this.lineNumber);
}

class LineNumberTableAttribute extends AttributeInfo {
  final List<LineNumberEntry> lineNumberTable;
  LineNumberTableAttribute(this.lineNumberTable) : super('LineNumberTable');
}

class LocalVariableEntry {
  final int startPc;
  final int length;
  final int nameIndex;
  final int descriptorIndex;
  final int index;
  LocalVariableEntry(
    this.startPc,
    this.length,
    this.nameIndex,
    this.descriptorIndex,
    this.index,
  );
}

class LocalVariableTableAttribute extends AttributeInfo {
  final List<LocalVariableEntry> localVariableTable;
  LocalVariableTableAttribute(this.localVariableTable)
      : super('LocalVariableTable');
}

class LocalVariableTypeEntry {
  final int startPc;
  final int length;
  final int nameIndex;
  final int signatureIndex;
  final int index;
  LocalVariableTypeEntry(
    this.startPc,
    this.length,
    this.nameIndex,
    this.signatureIndex,
    this.index,
  );
}

class LocalVariableTypeTableAttribute extends AttributeInfo {
  final List<LocalVariableTypeEntry> localVariableTypeTable;
  LocalVariableTypeTableAttribute(this.localVariableTypeTable)
      : super('LocalVariableTypeTable');
}

class DeprecatedAttribute extends AttributeInfo {
  DeprecatedAttribute() : super('Deprecated');
}

/// 注解相关通用模型（简化版，保留原始元素值）。
class Annotation {
  final int typeIndex;
  final List<ElementValuePair> elementValuePairs;
  Annotation(this.typeIndex, this.elementValuePairs);
}

class ElementValuePair {
  final int elementNameIndex;
  final ElementValue value;
  ElementValuePair(this.elementNameIndex, this.value);
}

abstract class ElementValue {
  final int tag;
  ElementValue(this.tag);
}

class ConstElementValue extends ElementValue {
  final int constValueIndex;
  ConstElementValue(super.tag, this.constValueIndex);
}

class EnumElementValue extends ElementValue {
  final int typeNameIndex;
  final int constNameIndex;
  EnumElementValue(this.typeNameIndex, this.constNameIndex)
      : super('e'.codeUnitAt(0));
}

class ClassElementValue extends ElementValue {
  final int classInfoIndex;
  ClassElementValue(this.classInfoIndex) : super('c'.codeUnitAt(0));
}

class AnnotationElementValue extends ElementValue {
  final Annotation annotationValue;
  AnnotationElementValue(this.annotationValue) : super('@'.codeUnitAt(0));
}

class ArrayElementValue extends ElementValue {
  final List<ElementValue> values;
  ArrayElementValue(this.values) : super('['.codeUnitAt(0));
}

class RuntimeVisibleAnnotationsAttribute extends AttributeInfo {
  final List<Annotation> annotations;
  RuntimeVisibleAnnotationsAttribute(this.annotations)
      : super('RuntimeVisibleAnnotations');
}

class RuntimeInvisibleAnnotationsAttribute extends AttributeInfo {
  final List<Annotation> annotations;
  RuntimeInvisibleAnnotationsAttribute(this.annotations)
      : super('RuntimeInvisibleAnnotations');
}

class RuntimeVisibleParameterAnnotationsAttribute extends AttributeInfo {
  final List<List<Annotation>> parameterAnnotations;
  RuntimeVisibleParameterAnnotationsAttribute(this.parameterAnnotations)
      : super('RuntimeVisibleParameterAnnotations');
}

class RuntimeInvisibleParameterAnnotationsAttribute extends AttributeInfo {
  final List<List<Annotation>> parameterAnnotations;
  RuntimeInvisibleParameterAnnotationsAttribute(this.parameterAnnotations)
      : super('RuntimeInvisibleParameterAnnotations');
}

class AnnotationDefaultAttribute extends AttributeInfo {
  final ElementValue defaultValue;
  AnnotationDefaultAttribute(this.defaultValue) : super('AnnotationDefault');
}

class BootstrapMethodEntry {
  final int bootstrapMethodRef;
  final List<int> bootstrapArguments;
  BootstrapMethodEntry(this.bootstrapMethodRef, this.bootstrapArguments);
}

class BootstrapMethodsAttribute extends AttributeInfo {
  final List<BootstrapMethodEntry> bootstrapMethods;
  BootstrapMethodsAttribute(this.bootstrapMethods) : super('BootstrapMethods');
}

class MethodParameterEntry {
  final int nameIndex;
  final int accessFlags;
  MethodParameterEntry(this.nameIndex, this.accessFlags);
}

class MethodParametersAttribute extends AttributeInfo {
  final List<MethodParameterEntry> parameters;
  MethodParametersAttribute(this.parameters) : super('MethodParameters');
}

class ModuleRequireEntry {
  final int requiresIndex;
  final int requiresFlags;
  final int requiresVersionIndex;
  ModuleRequireEntry(
    this.requiresIndex,
    this.requiresFlags,
    this.requiresVersionIndex,
  );
}

class ModuleExportEntry {
  final int exportsIndex;
  final int exportsFlags;
  final List<int> exportsToIndexTable;
  ModuleExportEntry(
    this.exportsIndex,
    this.exportsFlags,
    this.exportsToIndexTable,
  );
}

class ModuleOpenEntry {
  final int opensIndex;
  final int opensFlags;
  final List<int> opensToIndexTable;
  ModuleOpenEntry(this.opensIndex, this.opensFlags, this.opensToIndexTable);
}

class ModuleProvideEntry {
  final int providesIndex;
  final List<int> providesWithIndexTable;
  ModuleProvideEntry(this.providesIndex, this.providesWithIndexTable);
}

class ModuleAttribute extends AttributeInfo {
  final int moduleNameIndex;
  final int moduleFlags;
  final int moduleVersionIndex;
  final List<ModuleRequireEntry> requires;
  final List<ModuleExportEntry> exports;
  final List<ModuleOpenEntry> opens;
  final List<int> usesIndexTable;
  final List<ModuleProvideEntry> provides;
  ModuleAttribute({
    required this.moduleNameIndex,
    required this.moduleFlags,
    required this.moduleVersionIndex,
    required this.requires,
    required this.exports,
    required this.opens,
    required this.usesIndexTable,
    required this.provides,
  }) : super('Module');
}

class ModulePackagesAttribute extends AttributeInfo {
  final List<int> packageIndexTable;
  ModulePackagesAttribute(this.packageIndexTable) : super('ModulePackages');
}

class ModuleMainClassAttribute extends AttributeInfo {
  final int mainClassIndex;
  ModuleMainClassAttribute(this.mainClassIndex) : super('ModuleMainClass');
}

class NestHostAttribute extends AttributeInfo {
  final int hostClassIndex;
  NestHostAttribute(this.hostClassIndex) : super('NestHost');
}

class NestMembersAttribute extends AttributeInfo {
  final List<int> classes;
  NestMembersAttribute(this.classes) : super('NestMembers');
}

class RecordComponentInfo {
  final int nameIndex;
  final int descriptorIndex;
  final List<AttributeInfo> attributes;
  RecordComponentInfo(this.nameIndex, this.descriptorIndex, this.attributes);
}

class RecordAttribute extends AttributeInfo {
  final List<RecordComponentInfo> components;
  RecordAttribute(this.components) : super('Record');
}

class PermittedSubclassesAttribute extends AttributeInfo {
  final List<int> classes;
  PermittedSubclassesAttribute(this.classes) : super('PermittedSubclasses');
}

class UnknownAttribute extends AttributeInfo {
  final Uint8List data;
  UnknownAttribute(super.name, this.data);
}
