#!/usr/bin/env dub
/+ dub.sdl:
    name "eve_tcp_echo"
    dependency "eve" repository="git+https://codeberg.org/ddn/eve.git" version="c72f75135de636987e91bcd8ec5a22d32d34a197"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
    platforms "linux"
+/
import std.stdio : writeln;
import eve;
import eve.backend.common : Handle;

void main() @safe
{
    auto loop = EventLoop.create();
    scope (exit) loop.dispose();

    auto listener = TcpListener.create();
    auto server = TcpConnection.create();
    auto client = TcpConnection.create();

    string echoed;

    // Server echoes incoming borrowed data back
    server.onData = (ref TcpConnection c, scope const(ubyte)[] data) {
        assert(c.send(data) == SendResult.OK);
    };

    // Client sends "hello" on connect
    client.onConnect = (ref TcpConnection c) {
        assert(c.send(cast(const(ubyte)[]) "hello") == SendResult.OK);
    };

    // Client receives echoed data
    client.onData = (ref TcpConnection c, scope const(ubyte)[] data) {
        echoed ~= cast(string) data.idup; // accumulate arbitrary TCP chunks
        assert(echoed.length <= 5);
        if (echoed.length < 5) return;
        try writeln("echoed: ", echoed); catch (Exception error) { assert(false, error.msg); }
        c.close();
        server.close();
        listener.close();
        loop.stop();
    };

    // Listener adopts accepted client handle
    listener.onAccept = (ref TcpListener l, Handle clientHandle) {
        assert(server.adopt(loop, clientHandle) == AdoptResult.OK);
    };

    assert(listener.listen(loop, "127.0.0.1", 0) == ListenResult.OK);
    assert(client.connect(loop, "127.0.0.1", listener.localPort) == ConnectResult.OK);

    loop.run();
    assert(echoed == "hello");
}
