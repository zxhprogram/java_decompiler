// JDK 18: 无新语言语法；基础回归。
import java.util.List;

public class v18_Simple {

    public int sum(List<Integer> nums) {
        int total = 0;
        for (Integer n : nums) {
            total += n;
        }
        return total;
    }

    public String repeat(String s, int n) {
        return s.repeat(n);
    }

    public List<Integer> sorted(List<Integer> in) {
        return in.stream().sorted().toList();
    }
}
