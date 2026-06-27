// JDK 16 (final): record + instanceof 模式匹配。
public class v16_Records {

    public record Point(int x, int y) {
        public Point {
            if (x < 0 || y < 0) throw new IllegalArgumentException();
        }

        public static Point origin() {
            return new Point(0, 0);
        }
    }

    public interface Shape {}

    public record Circle(double r) implements Shape {}
    public record Square(double side) implements Shape {}

    public String describe(Object o) {
        // instanceof 模式匹配
        if (o instanceof Point p) {
            return "point " + p.x() + "," + p.y();
        }
        if (o instanceof String s && s.length() > 3) {
            return "long string: " + s;
        }
        if (o instanceof Integer i) {
            return "int: " + i;
        }
        return "other";
    }

    public double area(Shape s) {
        if (s instanceof Circle c) return Math.PI * c.r() * c.r();
        if (s instanceof Square sq) return sq.side() * sq.side();
        return 0;
    }
}
