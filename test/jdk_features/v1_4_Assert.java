// JDK 1.4: assert 断言语句。
public class v1_4_Assert {

    public int assertCheck(int x) {
        assert x >= 0 : "negative value: " + x;
        assert x < 100;
        return x * 2;
    }

    public int withSideEffect(int[] arr, int idx) {
        assert idx >= 0 && idx < arr.length;
        return arr[idx];
    }
}
