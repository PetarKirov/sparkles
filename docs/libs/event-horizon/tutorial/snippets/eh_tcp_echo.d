#!/usr/bin/env dub
/+ dub.sdl:
    name "eh_tcp_echo"
    dependency "sparkles:event-horizon" path="../../../../.."
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
    platforms "linux"
+/
import core.lifetime : move;
import std.stdio : writeln;
import sparkles.base.buffer : UniqueBuffer;
import sparkles.event_horizon;

void main()
{
    LoopGroup group;
    if (LoopGroup.start(group).hasError)
        assert(false, "no completion backend");
    scope (exit) group.shutdown();

    auto run = group.run((ref RootScope sc, ref Env env) {
        auto listening = env.net.listen(ipv4("127.0.0.1", 0));
        assert(listening.hasValue);
        auto listener = move(listening.value);
        scope (exit) listener.close();
        const port = boundPort(listener);

        // The server is a joined child, handling one five-byte exchange.
        assert(sc.spawn({
            auto conn = listener.accept; // parks until a client arrives
            assert(conn.hasValue);
            echo(conn.value);
        }));

        // The client, in the same loop.
        auto connected = env.net.connect(ipv4("127.0.0.1", port));
        assert(connected.hasValue);
        auto client = move(connected.value);
        scope (exit) client.close();
        sendText(client, "hello");

        UniqueBuffer!(ubyte, 64) back;
        string response;
        while (response.length < 5)
        {
            back.length = 64;
            auto got = client.recv(move(back));
            back = move(got.buf);
            assert(got.res.hasValue && got.res.value > 0);
            response ~= cast(const(char)[]) back[][0 .. got.res.value];
        }
        assert(response == "hello");
        writeln("echoed: ", response);
        return 0;
    });
    assert(run.hasValue);
}

void echo(Stream conn)
{
    scope (exit) conn.close();
    UniqueBuffer!(ubyte, 4096) buf;
    size_t received;
    while (received < 5)
    {
        buf.length = 4096;
        auto r = conn.recv(move(buf));
        buf = move(r.buf);
        assert(r.res.hasValue && r.res.value > 0);
        received += r.res.value;
        sendText(conn, cast(const(char)[]) buf[][0 .. r.res.value]);
    }
}

// Copies the unsent suffix into an owned buffer on each attempt. This is a
// small correctness example, not a claim of zero-copy networking.
void sendText(ref Stream conn, scope const(char)[] bytes)
{
    size_t offset;
    while (offset < bytes.length)
    {
        UniqueBuffer!(ubyte, 64) buf;
        buf ~= cast(const(ubyte)[]) bytes[offset .. $];
        auto sent = conn.send(move(buf));
        assert(sent.res.hasValue && sent.res.value > 0);
        offset += sent.res.value;
    }
}

ushort boundPort(ref Listener l) @trusted
{
    import core.sys.posix.arpa.inet : ntohs;
    import core.sys.posix.netinet.in_ : sockaddr_in;
    import core.sys.posix.sys.socket : getsockname, sockaddr, socklen_t;

    sockaddr_in a;
    socklen_t len = a.sizeof;
    assert(getsockname(l.fd, cast(sockaddr*) &a, &len) == 0);
    return ntohs(a.sin_port);
}
