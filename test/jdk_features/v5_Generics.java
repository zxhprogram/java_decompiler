// JDK 5: 泛型、枚举、注解、可变参数、自动装箱、增强 for、静态导入、协变返回类型。
import static java.lang.Math.abs;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;

public class v5_Generics {

    @Retention(RetentionPolicy.RUNTIME)
    @interface MyAnno {
        String value() default "";
        int count() default 0;
    }

    public enum Color {
        RED, GREEN, BLUE
    }

    static abstract class Shape {
        abstract double area();
    }

    static class Circle extends Shape {
        double r;
        Circle(double r) { this.r = r; }
        @Override
        double area() { return Math.PI * r * r; }
        // 协变返回类型
        @Override
        public Circle clone() { return new Circle(r); }
    }

    @MyAnno(value = "demo", count = 3)
    public int sum(java.util.List<Integer> nums) {
        int total = 0;
        // 增强for + 自动装箱/拆箱
        for (Integer n : nums) {
            total += n;
        }
        return total;
    }

    @SafeVarargs
    public final String concat(String... parts) {
        StringBuilder sb = new StringBuilder();
        for (String p : parts) {
            sb.append(p);
        }
        return sb.toString();
    }

    public int useEnum(Color c) {
        switch (c) {
            case RED: return 1;
            case GREEN: return 2;
            case BLUE: return 3;
            default: return 0;
        }
    }

    public int staticImport(int x) {
        return abs(x) + 1;
    }

    public java.util.Map<String, Integer> genericMap() {
        java.util.Map<String, Integer> m = new java.util.HashMap<String, Integer>();
        m.put("a", 1);
        return m;
    }
}
