// JDK 14 (final): switch 表达式（标准）。
public class v14_SwitchExprFinal {

    public int dayLength(String day) {
        int len = switch (day) {
            case "MONDAY", "FRIDAY", "SUNDAY" -> 6;
            case "TUESDAY" -> 7;
            case "THURSDAY", "SATURDAY" -> 8;
            case "WEDNESDAY" -> 9;
            default -> throw new IllegalArgumentException("invalid: " + day);
        };
        return len;
    }

    public String yieldBlock(int n) {
        return switch (n) {
            case 1 -> {
                String v = "one";
                yield v;
            }
            case 2 -> "two";
            default -> "many";
        };
    }

    public int exhaustive(int n) {
        return switch (n) {
            case 1, 2, 3 -> n * 10;
            default -> n;
        };
    }
}
