// JDK 10: var 局部变量类型推断。
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

public class v10_Var {

    public int locals() {
        var x = 10;
        var list = new ArrayList<String>();
        var map = new HashMap<String, Integer>();
        list.add("a");
        map.put("a", 1);
        var sum = 0;
        for (var s : list) {
            sum += s.length();
        }
        return sum + x;
    }

    public List<String> typed() {
        var list = new ArrayList<String>();
        list.add("x");
        return list;
    }
}
