// JDK 24: 灵活构造器体 (24 final) + 模块导入声明 (24 preview) + 原始类型模式 (2nd preview)。
import module java.base;
import java.util.List;

public class v24_FlexibleConstructor {

    public record Range(int low, int high) {
        public Range {
            if (low > high) throw new IllegalArgumentException();
        }
    }

    static class Base {
        final int v;
        Base(int v) { this.v = v; }
    }

    static class Derived extends Base {
        final int scaled;
        // 灵活构造器体：super 之前可有不引用实例的语句。
        Derived(int v, int factor) {
            int computed = v * factor;
            if (computed < 0) {
                computed = 0;
            }
            super(computed);
            this.scaled = computed;
        }
    }

    public String classify(Object o) {
        return switch (o) {
            case int i when i > 0 -> "positive int: " + i;
            case int i -> "int: " + i;
            case long l -> "long: " + l;
            case double d -> "double: " + d;
            case null -> "null";
            default -> "other";
        };
    }

    public List<String> moduleImported() {
        return List.of("a", "b");
    }
}
