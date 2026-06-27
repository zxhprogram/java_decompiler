// JDK 1.2: strictfp, Comparable, Iterator, 集合框架。
import java.util.ArrayList;
import java.util.Collection;
import java.util.Collections;
import java.util.Iterator;
import java.util.List;

public class v1_2_Collections implements Comparable<v1_2_Collections> {

    private final int key;

    public v1_2_Collections(int key) {
        this.key = key;
    }

    public strictfp double computeStrict(double a, double b) {
        return a * b + a / b;
    }

    @Override
    public int compareTo(v1_2_Collections o) {
        return Integer.compare(this.key, o.key);
    }

    public List<Integer> sortAndIterate(Collection<Integer> input) {
        List<Integer> list = new ArrayList<>(input);
        Collections.sort(list);
        Iterator<Integer> it = list.iterator();
        int sum = 0;
        while (it.hasNext()) {
            sum += it.next();
        }
        return list;
    }

    public int sum(Collection<Integer> c) {
        int total = 0;
        for (Integer v : c) {
            total += v;
        }
        return total;
    }
}
