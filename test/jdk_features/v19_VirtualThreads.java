// JDK 19 (preview): 虚拟线程、record 模式、switch 模式匹配。
public class v19_VirtualThreads {

    public record Point(int x, int y) {}

    public sealed interface Shape permits Circle, Box {}
    public record Circle(double r) implements Shape {}
    public record Box(double w, double h) implements Shape {}

    public String describe(Object o) {
        return switch (o) {
            case Point(int x, int y) -> "point " + x + "," + y;
            case Circle c when c.r() > 0 -> "circle r=" + c.r();
            case Circle c -> "circle";
            case null -> "null";
            default -> "other";
        };
    }

    public double area(Shape s) {
        return switch (s) {
            case Circle c -> Math.PI * c.r() * c.r();
            case Box b -> b.w() * b.h();
        };
    }

    public String virtualThread() throws InterruptedException {
        Thread vt = Thread.startVirtualThread(() -> System.out.println("hi"));
        vt.join();
        return vt.toString();
    }
}
