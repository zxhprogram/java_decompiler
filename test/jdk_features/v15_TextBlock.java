// JDK 15 (final): 文本块（标准）。
public class v15_TextBlock {

    public String html() {
        return """
                <html>
                  <body>Hello</body>
                </html>
                """;
    }

    public String withEscape() {
        // 行尾续行 \ 与去空白 \s
        String text = """
                line1 \
                line2 \s
                line3""";
        return text;
    }

    public String interpolate(String who) {
        return """
                greeting: %s
                """.formatted(who);
    }
}
