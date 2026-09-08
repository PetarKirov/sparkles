#!/usr/bin/env dub
/+ dub.sdl:
    name "vibe_tcp_echo"
    dependency "vibe-core" version="2.14.0"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
    platforms "linux"
+/
import std.stdio : writeln;
import vibe.core.net : connectTCP, listenTCP, TCPConnection, TCPListener;
import vibe.core.stream : IOMode;

void echo(TCPConnection conn) @safe
{
    scope (exit) conn.close();
    ubyte[64] buf;
    size_t total;
    while (total < 5)
    {
        const len = conn.read(buf[0 .. 5 - total], IOMode.once);
        assert(len > 0);
        conn.write(buf[0 .. len]);
        total += len;
    }
}

void main()
{
    auto listener = listenTCP(0, (TCPConnection conn) nothrow @safe {
        try echo(conn); catch (Exception error) { assert(false, error.msg); }
    }, "127.0.0.1");
    scope (exit) listener.stopListening();

    const port = listener.bindAddress.port;

    auto client = connectTCP("127.0.0.1", port);
    scope (exit) client.close();

    client.write(cast(const(ubyte)[]) "hello");

    ubyte[64] back;
    size_t len;
    while (len < 5)
    {
        const n = client.read(back[len .. 5], IOMode.once);
        assert(n > 0);
        len += n;
    }

    assert(cast(const(char)[]) back[0 .. len] == "hello");
    writeln("echoed: ", cast(const(char)[]) back[0 .. len]);
}
