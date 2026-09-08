#!/usr/bin/env dub
/+ dub.sdl:
    name "collie_tcp_echo"
    dependency "collie" path=".deps/collie"
    dependency "kiss" path=".deps/kiss"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
    platforms "linux"
+/
import std.socket : InternetAddress, AddressFamily;
import std.stdio : writeln;
import kiss.event;
import kiss.net.TcpListener;
import kiss.net.TcpStream;

void main()
{
    auto loop = new EventLoop();
    scope(exit) loop.dispose();
    string response;

    // Server: listen and accept
    auto listener = new TcpListener(loop, AddressFamily.INET);
    listener.onConnectionAccepted((TcpListener sender, TcpStream serverStream) {
        serverStream.onDataReceived((in ubyte[] data) {
            // Collie borrows the slice during callback;
            // writing requires heap duplication or a ref-counted buffer.
            serverStream.write(cast(const(ubyte)[]) data.dup);
        });
        serverStream.start();
    });
    listener.bind(new InternetAddress("127.0.0.1", 0));
    const port = (cast(InternetAddress) listener.localAddress).port;
    listener.listen(128);
    listener.start();

    // Client: connect, send, receive
    auto client = new TcpStream(loop);
    client.onConnected((bool ok) {
        assert(ok);
        if (ok)
            client.write(cast(const(ubyte)[]) "hello");
    });
    client.onDataReceived((in ubyte[] data) {
        response ~= cast(string) data.dup;
        assert(response.length <= 5);
        if (response.length < 5) return;
        writeln("echoed: ", response);
        client.close();
        listener.close();
        loop.stop();
    });
    client.connect("127.0.0.1", port);

    loop.run();

    assert(response == "hello");
}
