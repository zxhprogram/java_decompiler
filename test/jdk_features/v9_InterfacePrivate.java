// JDK 9: 接口私有方法、集合工厂方法、effectively-final try-with-resources。
import java.util.List;
import java.util.Map;

public class v9_InterfacePrivate {

    interface Validator {
        boolean valid(String s);

        default boolean validAndNonEmpty(String s) {
            return nonEmpty(s) && valid(s);
        }

        private boolean nonEmpty(String s) {
            return s != null && !s.isEmpty();
        }

        private static boolean isNull(Object o) {
            return o == null;
        }
    }

    public List<Integer> immutableList() {
        return List.of(1, 2, 3);
    }

    public Map<String, Integer> immutableMap() {
        return Map.of("a", 1, "b", 2);
    }

    public String tryWithEffectivelyFinal() throws Exception {
        java.io.BufferedReader br = new java.io.BufferedReader(new java.io.StringReader("hi"));
        try (br) {
            return br.readLine();
        }
    }

    public Validator nonEmptyValidator() {
        return s -> s != null && s.length() > 0;
    }
}
