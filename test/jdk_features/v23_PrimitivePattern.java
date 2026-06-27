// JDK 23 (preview): 原始类型模式匹配。case 须按窄->宽顺序排列避免支配。
public class v23_PrimitivePattern {

    public String classify(Object o) {
        return switch (o) {
            case int i when i > 0 -> "positive int: " + i;
            case int i -> "int: " + i;
            case long l -> "long: " + l;
            case float f -> "float: " + f;
            case double d -> "double: " + d;
            case null -> "null";
            default -> "other";
        };
    }

    public double toDouble(Object o) {
        if (o instanceof int i) return i;
        if (o instanceof long l) return l;
        if (o instanceof double d) return d;
        return 0;
    }
}
