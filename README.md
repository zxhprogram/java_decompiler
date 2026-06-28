# java_decompiler

A Dart library and CLI for parsing and decompiling Java `.class` files back into readable Java source code.

支持 JDK 1.0 → 24 的语法特性反编译，包括泛型、Lambda、record、sealed 类、switch 模式匹配、原始类型模式等。

## 特性

- **跨版本兼容**：从 JDK 1.0 到 JDK 24 的 `.class` 文件均可解析，不再崩溃
- **语法重建**：还原 record、sealed、switch 模式、`instanceof` 模式、文本块、Lambda、方法引用等
- **库 + CLI 双形态**：可作为 Dart 库嵌入，也可作为命令行工具直接使用
- **诊断能力**：支持反汇编字节码、打印常量池、查看 class 文件版本

## 安装

```bash
dart pub get
```

或克隆仓库后直接使用：

```bash
git clone <repo-url>
cd java_decompiler
dart pub get
```

## 命令行用法

```bash
dart run bin/java_decompiler.dart [选项] <class文件>
```

### 选项

| 选项 | 缩写 | 说明 |
|------|------|------|
| `--help` | `-h` | 显示帮助 |
| `--source` | `-s` | 反编译为 Java 源码（默认行为） |
| `--disassemble` | `-d` | 仅反汇编字节码（含指令、操作数、异常表） |
| `--methods` | `-m` | 输出所有方法签名（每行一个） |
| `--fields` | `-f` | 输出所有字段 |
| `--verbose` | `-v` | 输出 class 文件版本信息（major/minor/Java 版本） |
| `--hide-empty-public-ctors` | — | 省略空的 public 默认构造方法 |
| `--dump-pool` | — | 打印常量池完整内容 |

### 示例

```bash
# 反编译 .class 到 Java 源码
dart run bin/java_decompiler.dart path/to/MyClass.class

# 查看 class 文件版本
dart run bin/java_decompiler.dart -v path/to/MyClass.class
# 输出:
#   class: MyClass
#   major version: 65
#   minor version: 0
#   java version: 21

# 反汇编字节码
dart run bin/java_decompiler.dart -d path/to/MyClass.class

# 输出方法签名
dart run bin/java_decompiler.dart -m path/to/MyClass.class

# 打印常量池
dart run bin/java_decompiler.dart --dump-pool path/to/MyClass.class
```

## 作为库使用

```dart
import 'package:java_decompiler/java_decompiler.dart';
import 'dart:io';

void main() {
  final bytes = File('MyClass.class').readAsBytesSync();
  final classFile = ClassFileParser(bytes).parse();
  final source = Decompiler(classFile).decompile();
  print(source);
}
```

### 主要 API

| 类型 | 作用 |
|------|------|
| `ClassFileParser` | 解析 `.class` 字节流为 `ClassFile` 模型 |
| `ClassFile` | class 文件顶层模型，含版本、常量池、字段、方法、属性 |
| `Decompiler` | 反编译 `ClassFile` 为 Java 源码字符串 |
| `ConstantPool` | 常量池访问接口 |
| `BytecodeDecoder` | 字节码指令解码器（用于反汇编场景） |

`Decompiler` 支持可选参数：

```dart
final source = Decompiler(
  classFile,
  hideEmptyPublicConstructors: true,  // 省略空 public 默认构造
).decompile();
```

## 项目结构

```
java_decompiler/
├── bin/java_decompiler.dart     # CLI 入口
├── lib/
│   ├── java_decompiler.dart     # 库导出
│   └── src/
│       ├── class_file.dart      # ClassFile/FieldInfo/MethodInfo 模型
│       ├── parser.dart          # ClassFileParser
│       ├── descriptor_parser.dart  # 描述符/泛型签名解析
│       ├── attributes/          # 属性解析（Code、Signature、Record 等）
│       ├── bytecode/            # 字节码解码
│       ├── constants/           # 常量池
│       ├── decompiler/          # 反编译核心
│       │   ├── decompiler.dart      # Decompiler 顶层
│       │   ├── code_printer.dart    # 方法体打印入口
│       │   ├── code_printer_stack.dart      # 栈式指令模拟
│       │   ├── code_printer_control_flow.dart  # 控制流结构化
│       │   ├── code_printer_switch.dart       # switch 模式匹配重建
│       │   ├── code_printer_patterns.dart     # record/原始类型模式
│       │   ├── code_printer_lambda.dart       # Lambda/方法引用
│       │   └── code_printer_try_catch.dart    # try-catch-finally 结构化
│       ├── flags/               # 访问标志
│       └── io/class_reader.dart # 字节读取
├── test/
│   ├── fixtures/                # 原有黄金回归基线
│   ├── jdk_features/            # JDK 1.0→24 语法特性测试
│   │   ├── manifest.json
│   │   ├── v1_0_Basics.java … v24_*.java
│   │   ├── build/               # javac 编译产物
│   │   └── golden/              # 反编译输出基线
│   ├── decompiler_golden_test.dart
│   └── jdk_features_test.dart
└── tool/
    ├── compile_jdk_features.dart   # javac 编译清单
    ├── analyze_jdk_goldens.dart    # 缺陷信号扫描
    └── split_code_printer.dart     # code_printer 拆分维护工具
```

## 测试

```bash
# 1. 编译 JDK 特性测试源码到 .class（前置步骤）
dart run tool/compile_jdk_features.dart

# 2. 运行 JDK 特性反编译测试
dart test test/jdk_features_test.dart

# 3. 运行原有黄金回归测试
dart test test/decompiler_golden_test.dart

# 4. 全量测试
dart test
```

### 刷新黄金基线

当反编译逻辑有**有意变更**时：

```bash
# PowerShell
$env:UPDATE_GOLDEN='true'; dart test
Remove-Item Env:UPDATE_GOLDEN

# bash
UPDATE_GOLDEN=true dart test
```

### 缺陷信号扫描

```bash
dart run tool/analyze_jdk_goldens.dart
```

扫描 `golden/*.txt`，统计 `goto/label`、`invokedynamic`、`/*exception*/` 等已知限制信号，用于回归监控。

## 已知限制

| 限制 | 说明 |
|------|------|
| `goto/label` 未结构化 | 复杂控制流（嵌套 switch 表达式、深层循环）部分仍以 `goto label_N` 形式输出 |
| `invokedynamic` 未解析 | 部分 pattern switch 的 `typeSwitch` bootstrap 未完全还原 |
| 异常变量名 `/*exception*/` | catch 变量名未从 `LocalVariableTable` 还原 |

详见 [test/jdk_features/REPORT.md](test/jdk_features/REPORT.md)。

## 许可

MIT
