// JDK 6: 无新语言语法；@Override 可用于接口方法实现。
public class v6_Legacy implements Runnable {

    private final String name;

    public v6_Legacy(String name) {
        this.name = name;
    }

    @Override
    public void run() {
        System.out.println("running: " + name);
    }

    public java.util.List<String> toList(String[] arr) {
        java.util.List<String> list = new java.util.ArrayList<String>();
        for (String s : arr) {
            list.add(s);
        }
        return list;
    }
}
