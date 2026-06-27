// JDK 20 (2nd preview): record 模式 + switch 模式增强。
public class v20_RecordPatterns {

    public record Point(int x, int y) {}
    public record Colored(Point p, String color) {}

    public String nested(Object o) {
        if (o instanceof Colored(Point(int x, int y), String color)) {
            return color + ":" + x + "," + y;
        }
        return "n/a";
    }

    public String describe(Object o) {
        return switch (o) {
            case Colored(Point(int x, int y), String color) -> color + "@" + x + "," + y;
            case Point p -> "point " + p.x() + "," + p.y();
            case null -> "null";
            default -> "other";
        };
    }

    public int sumComponents(Object o) {
        return switch (o) {
            case Point(int x, int y) -> x + y;
            case Colored(Point(int x, int y), String c) -> x + y + c.length();
            default -> 0;
        };
    }
}
