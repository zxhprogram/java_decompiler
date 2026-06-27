// JDK 12: switch 表达式（12 preview，本例用 14 final 的 yield 语法编译以产生等价字节码）。
public class v12_SwitchExpr {

    public int dayLength(String day) {
        int len = switch (day) {
            case "MONDAY", "FRIDAY", "SUNDAY" -> 6;
            case "TUESDAY" -> 7;
            case "THURSDAY", "SATURDAY" -> 8;
            case "WEDNESDAY" -> 9;
            default -> -1;
        };
        return len;
    }

    public String withBlock(int n) {
        String s = switch (n) {
            case 1 -> {
                String v = "one";
                yield v.toUpperCase();
            }
            default -> "other";
        };
        return s;
    }
}
