// JDK 13 (preview): 文本块 + switch 表达式 yield。
public class v13_TextBlock {

    public String json() {
        return """
                {
                  "name": "Java 13",
                  "preview": true
                }
                """;
    }

    public String multiLine() {
        String sql = """
                SELECT *
                FROM users
                WHERE active = true
                """;
        return sql.trim();
    }

    public int withYield(int n) {
        int r = switch (n) {
            case 1 -> 10;
            case 2 -> {
                int doubled = n * 2;
                yield doubled;
            }
            default -> 0;
        };
        return r;
    }
}
