// JDK 1.3: 无新语言语法；本例使用动态代理 API 做回归。
import java.lang.reflect.InvocationHandler;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;

public class v1_3_Proxy {

    public interface Echo {
        String echo(String s);
    }

    public Echo newProxy() {
        return (Echo) Proxy.newProxyInstance(
                v1_3_Proxy.class.getClassLoader(),
                new Class<?>[]{Echo.class},
                new InvocationHandler() {
                    @Override
                    public Object invoke(Object proxy, Method method, Object[] args) {
                        return "[proxy] " + args[0];
                    }
                });
    }

    public String run() {
        return newProxy().echo("hi");
    }
}
