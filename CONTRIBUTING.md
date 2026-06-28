# 贡献指南

感谢参与 `java_decompiler` 的开发。本文档说明代码组织、测试流程与新增 JDK 特性的标准做法。

## 开发环境

- **Dart SDK**: `^3.0.0`
- **JDK**: 24（`javac` 需在 PATH 中，用于编译 JDK 特性测试源码）
- **依赖安装**: `dart pub get`

## 代码组织

反编译核心位于 `lib/src/decompiler/`，采用 `part` 拆分以共享私有成员：

```
code_printer.dart                  # 入口：CodePrinter.printBody()
├── code_printer_stack.dart        # 栈式字节码模拟（核心表达式重建）
├── code_printer_control_flow.dart # if/while/for 结构化
├── code_printer_switch.dart       # switch 表达式 + 模式匹配
├── code_printer_patterns.dart     # record/primitive instanceof 模式预处理
├── code_printer_try_catch.dart    # try-catch-finally 结构化
├── code_printer_lambda.dart       # Lambda/方法引用还原
├── code_printer_simplify.dart     # 表达式简化
└── code_printer_utils.dart        # 工具函数
```

### 修改 code_printer 时的注意事项

1. **`part of` 关系**：所有 `code_printer_*.dart` 都是 `part of 'code_printer.dart';`，共享私有成员（`_pool`、`_cf`、`_method` 等）。修改某个文件时，注意是否影响其他 part 的调用。
2. **新增大段逻辑**：建议新写到对应的 `code_printer_*.dart` 中，避免 `code_printer.dart` 主文件膨胀。如需进一步拆分，使用 `tool/split_code_printer.dart`。
3. **保持向后兼容**：`Decompiler` 的公开 API（`decompile()`、`methodSignatures()`、`fieldList()`）签名稳定，扩展功能请通过可选参数。

## 测试流程

### 1. 完整测试链路

```bash
# 编译 JDK 1.0→24 特性源码到 .class（前置）
dart run tool/compile_jdk_features.dart

# 运行全部测试
dart test
```

期望输出：`All tests passed!`（当前 36 个测试）。

### 2. 单版本编译

```bash
dart run tool/compile_jdk_features.dart 22   # 仅编译 v22
```

### 3. 黄金基线刷新

**仅当反编译逻辑有有意变更时**才刷新基线：

```bash
# PowerShell
$env:UPDATE_GOLDEN='true'; dart test test/jdk_features_test.dart
remove-Item Env:UPDATE_GOLDEN

# bash
UPDATE_GOLDEN=true dart test test/jdk_features_test.dart
```

> ⚠️ 不要无脑刷新基线。若测试失败但不是有意变更，应修复反编译逻辑而非刷新基线。

### 4. 回归监控

```bash
dart run tool/analyze_jdk_goldens.dart
```

扫描 `golden/*.txt` 中 `goto/label`、`invokedynamic`、`/*exception*/` 等信号，每个版本输出统计。**理想情况下，修复 bug 应使信号数量下降或不变，不应上升。**

## 新增 JDK 特性测试

当反编译器支持新的 JDK 语法特性时，需补充测试用例。

### 步骤

1. **编写 Java 源码**：在 `test/jdk_features/` 新建 `v<版本>_<特性名>.java`，文件首行注释说明该版本引入的特性。

2. **更新 manifest.json**：在 `sources` 数组添加条目：

   ```json
   {
     "file": "v25_SomeFeature.java",
     "release": 25,
     "preview": true,
     "version": "25",
     "features": ["特性1", "特性2"]
   }
   ```

   - `release`：`javac --release` 值
   - `preview`：true 时附加 `--enable-preview`
   - `version`：测试所代表的 JDK 版本字符串
   - `features`：该测试覆盖的语法特性列表

3. **编译**：

   ```bash
   dart run tool/compile_jdk_features.dart 25
   ```

4. **生成黄金基线**：

   ```bash
   $env:UPDATE_GOLDEN='true'; dart test test/jdk_features_test.dart --plain-name v25_SomeFeature
   remove-Item Env:UPDATE_GOLDEN
   ```

5. **审查 golden 文件**：打开 `test/jdk_features/golden/v25_SomeFeature.txt`，确认反编译输出符合预期。**不应出现 `goto label_N` 或 `invokedynamic`**（除非该特性尚未完全支持，需在 REPORT.md 中记录）。

6. **运行全量测试**：

   ```bash
   dart test
   ```

### 内部类测试

若一个 `.java` 文件包含多个值得独立验证的类（如 `Outer$Inner.class`），在 manifest 中添加额外条目，指定 `classFile`：

```json
{
  "file": "v24_FlexibleConstructor.java",
  "classFile": "v24_FlexibleConstructor$Derived.class",
  "release": 24,
  "preview": true,
  "version": "24",
  "features": ["灵活构造器体内部类"]
}
```

## 跨版本编译说明

JDK 24 的 `javac` 无法用 `--enable-preview` 重新编译历史预览特性。因此：

- **已转正的预览特性**：用其 final 版本编译（如 switch 表达式用 `--release 14`）
- **仍为预览的特性**：用 `--release 24 --enable-preview` 编译

manifest 中的 `release` 和 `preview` 字段已据此设置，无需手动调整。

## 修复 bug 的工作流

1. **复现**：用 `dart run bin/java_decompiler.dart -d <class文件>` 反汇编字节码，定位问题。
2. **诊断**：必要时在 `code_printer.dart` 的 `printBody()` 中临时插入 `print()` 或写文件调试。
3. **修复**：在对应的 `code_printer_*.dart` 修改。
4. **验证**：
   - 受影响的 golden 文件应**变好**（信号减少）或保持不变
   - 不能引入新的 `goto/label` 或 `invokedynamic` 残留
5. **回归**：`dart test` 必须全绿。

## 代码风格

- 运行 `dart format .` 格式化
- 运行 `dart analyze` 通过静态检查
- 注释使用中文（与现有代码一致），仅在逻辑非自明处添加
- 正则表达式复杂时，注释说明匹配的字节码模式

## 已知限制（修改需谨慎）

以下信号在原黄金测试集同样存在，属于反编译器既有限制。修改需重写核心引擎：

| 信号 | 影响版本 |
|------|----------|
| `goto/label` 未结构化 | 1.0, 1.2, 5, 6, 7, 10, 12, 13, 14, 18 |
| `invokedynamic` 未解析 | 19–24（pattern switch 的 `typeSwitch`） |
| 异常变量 `/*exception*/` | 1.0 |

修复这些限制属于重大变更，需单独提案并确保原有黄金测试无回归。

## 版本映射参考

class 文件 major version → JDK 版本：

| major | JDK | major | JDK |
|-------|-----|-------|-----|
| 45 | 1.0/1.1 | 52 | 8 |
| 46 | 1.2 | 55 | 11 |
| 47 | 1.3 | 61 | 17 |
| 48 | 1.4 | 65 | 21 |
| 49 | 5 | 67 | 23 |
| 50 | 6 | 68 | 24 |
| 51 | 7 | 69 | 25 |

完整映射见 [bin/java_decompiler.dart](bin/java_decompiler.dart) 的 `_majorToJavaVersion`。
