// JDK 8: Lambda、方法引用、接口默认/静态方法、Stream、Optional、类型注解。
import java.util.List;
import java.util.Optional;
import java.util.function.Function;
import java.util.function.Supplier;
import java.util.stream.Collectors;

public class v8_Lambdas {

    interface Ops {
        int apply(int a, int b);
        default int twice(int a, int b) { return apply(a, b) * 2; }
        static Ops add() { return (a, b) -> a + b; }
    }

    private final List<String> data;

    public v8_Lambdas(List<String> data) {
        this.data = data;
    }

    public Function<Integer, Integer> curriedAdd(int x) {
        return y -> x + y;
    }

    public Supplier<String> methodRef() {
        return this::toString;
    }

    public List<String> processed() {
        return data.stream()
                .filter(s -> s != null && s.length() > 1)
                .map(String::toUpperCase)
                .sorted()
                .collect(Collectors.toList());
    }

    public Optional<String> first(String prefix) {
        return data.stream().filter(s -> s.startsWith(prefix)).findFirst();
    }

    public int reduce() {
        return data.stream().mapToInt(String::length).sum();
    }

    public @Nullable String typed() {
        return data.isEmpty() ? null : data.get(0);
    }

    @interface Nullable {}
}
