// JDK 22 (final): 未命名变量与模式 _。
import java.util.stream.Stream;

public class v22_Unnamed {

    public record Point(int x, int y) {}

    public int count(Iterable<String> it) {
        int n = 0;
        for (var _ : it) {
            n++;
        }
        return n;
    }

    public int tryIgnore(String s) {
        int total = 0;
        try {
            total += Integer.parseInt(s);
        } catch (NumberFormatException _) {
            // 未命名异常变量
        }
        return total;
    }

    public String describe(Object o) {
        return switch (o) {
            case Point(int x, _) -> "x=" + x;
            case Integer _ -> "an int";
            case null -> "null";
            default -> "other";
        };
    }

    public long lambdaIgnore(Stream<String> s) {
        return s.filter(_ -> true).count();
    }
}
