// JDK 11: Lambda 形参使用 var。
import java.util.function.Function;

public class v11_LambdaVar {

    public Function<Integer, Integer> addOne() {
        return (var x) -> x + 1;
    }

    public Function<String, String> upper() {
        return (var s) -> s.toUpperCase();
    }

    public Function<Integer, Integer> mixedAnnotated() {
        // var 形参可加注解
        return (@SuppressWarnings("unused") var x) -> x * 2;
    }

    public String notBlank(String s) {
        // JDK 11 String API
        return s.isBlank() ? "<blank>" : s.strip();
    }
}
