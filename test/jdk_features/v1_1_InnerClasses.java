// JDK 1.1: 内部类、匿名类、局部类、成员类。
public class v1_1_InnerClasses {

    private int outerField = 5;

    class MemberInner {
        int get() {
            return outerField;
        }
    }

    static class StaticNested {
        int value = 7;
    }

    public Runnable anonymous() {
        return new Runnable() {
            @Override
            public void run() {
                System.out.println("anon: " + outerField);
            }
        };
    }

    public int localClass(int x) {
        class Local {
            int square() {
                return x * x;
            }
        }
        Local l = new Local();
        return l.square();
    }

    public int useInner() {
        MemberInner m = new MemberInner();
        StaticNested s = new StaticNested();
        return m.get() + s.value;
    }
}
