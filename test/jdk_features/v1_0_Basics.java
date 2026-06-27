// JDK 1.0: 基础语法 —— 类、接口、基本类型、数组、控制流、异常、标签。
public class v1_0_Basics {

    static int staticField = 10;
    final double constant = 3.14;

    static {
        staticField = 20;
    }

    {
        System.out.println("instance init");
    }

    public int controlFlow(int n) {
        int sum = 0;
        if (n > 0) {
            sum = n;
        } else if (n < 0) {
            sum = -n;
        } else {
            sum = 0;
        }

        for (int i = 0; i < n; i++) {
            sum += i;
        }

        int j = 0;
        while (j < n) {
            sum += j;
            j++;
        }

        int k = 0;
        do {
            sum += k;
            k++;
        } while (k < n);

        switch (n) {
            case 0:
                sum = 0;
                break;
            case 1:
            case 2:
                sum = 100;
                break;
            default:
                sum = -1;
        }

        int[] arr = new int[]{1, 2, 3};
        int[][] matrix = new int[2][2];
        matrix[0][0] = arr[0];

        outer:
        for (int a = 0; a < 3; a++) {
            for (int b = 0; b < 3; b++) {
                if (b == 1) {
                    continue outer;
                }
                if (a == 2) {
                    break outer;
                }
            }
        }
        return sum;
    }

    public String tryCatch(String s) {
        try {
            int v = Integer.parseInt(s);
            return "ok:" + v;
        } catch (NumberFormatException e) {
            return "bad";
        } catch (RuntimeException e) {
            return "runtime";
        } finally {
            System.out.println("finally");
        }
    }

    public interface Handler {
        int handle(int x);
    }

    static class StaticNested implements Handler {
        public int handle(int x) {
            return x * 2;
        }
    }
}
