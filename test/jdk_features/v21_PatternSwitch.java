// JDK 21 (final): switch 模式匹配、record 模式、虚拟线程、SequencedCollection。
import java.util.LinkedHashMap;
import java.util.SequencedCollection;

public class v21_PatternSwitch {

    public record Point(int x, int y) {}

    public sealed interface Shape permits Circle, Rect {}
    public record Circle(double r) implements Shape {}
    public record Rect(double w, double h) implements Shape {}

    public String describe(Object o) {
        return switch (o) {
            case Point(int x, int y) -> "point " + x + "," + y;
            case Circle c when c.r() > 0 -> "circle r=" + c.r();
            case Circle c -> "circle";
            case Rect r -> "rect " + r.w() + "x" + r.h();
            case null -> "null";
            case Integer i -> "int " + i;
            default -> "other";
        };
    }

    public double area(Shape s) {
        return switch (s) {
            case Circle c -> Math.PI * c.r() * c.r();
            case Rect r -> r.w() * r.h();
        };
    }

    public String firstLast(SequencedCollection<String> c) {
        return c.getFirst() + "..." + c.getLast();
    }

    public String virtualThread() throws InterruptedException {
        Thread vt = Thread.ofVirtual().start(() -> System.out.println("v"));
        vt.join();
        return "done";
    }

    public LinkedHashMap<String, Integer> sequencedMap() {
        LinkedHashMap<String, Integer> m = new LinkedHashMap<>();
        m.put("a", 1);
        m.put("b", 2);
        m.putFirst("z", 0);
        return m;
    }
}
