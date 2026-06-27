// JDK 7: try-with-resources, multi-catch, diamond, switch-on-String, 数字字面量下划线/二进制。
import java.io.BufferedReader;
import java.io.FileReader;
import java.io.IOException;

public class v7_TryResources {

    public String readFirst(String path) throws IOException {
        try (BufferedReader br = new BufferedReader(new FileReader(path))) {
            return br.readLine();
        }
    }

    public String switchString(String cmd) {
        switch (cmd) {
            case "start": return "starting";
            case "stop": return "stopping";
            case "pause":
            case "resume": return "toggling";
            default: return "unknown";
        }
    }

    public String multiCatch(String s) {
        try {
            int v = Integer.parseInt(s);
            return "int:" + v;
        } catch (NumberFormatException | IllegalStateException e) {
            return "bad";
        }
    }

    public java.util.List<String> diamond() {
        java.util.List<String> list = new java.util.ArrayList<>();
        list.add("a");
        return list;
    }

    public int literals() {
        int big = 1_000_000;
        int bin = 0b1010;
        long hex = 0xFFL;
        return big + bin + (int) hex;
    }
}
