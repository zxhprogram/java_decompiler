// JDK 17 (final): sealed 类 + permits。
public class v17_Sealed {

    public sealed abstract class Shape permits Circle, Rectangle, Triangle {}

    public final class Circle extends Shape {
        final double r;
        public Circle(double r) { this.r = r; }
    }

    public final class Rectangle extends Shape {
        final double w, h;
        public Rectangle(double w, double h) { this.w = w; this.h = h; }
    }

    public non-sealed class Triangle extends Shape {
        final double base, height;
        public Triangle(double base, double height) {
            this.base = base;
            this.height = height;
        }
    }

    public String classify(Shape s) {
        if (s instanceof Circle c) return "circle r=" + c.r;
        if (s instanceof Rectangle r) return "rect " + r.w + "x" + r.h;
        if (s instanceof Triangle t) return "tri " + t.base + "x" + t.height;
        return "unknown";
    }

    public double area(Shape s) {
        if (s instanceof Circle c) return Math.PI * c.r * c.r;
        if (s instanceof Rectangle r) return r.w * r.h;
        if (s instanceof Triangle t) return 0.5 * t.base * t.height;
        return 0;
    }
}
