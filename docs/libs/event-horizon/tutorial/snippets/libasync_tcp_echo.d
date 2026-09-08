#!/usr/bin/env dub
/+ dub.sdl:
    name "libasync_tcp_echo"
    dependency "libasync" version="0.9.8"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
    platforms "linux"
+/
import std.stdio : writeln;
import libasync;

void main()
{
    auto evl = new EventLoop;
    scope (exit) { evl.exit(); evl.destroy(); }

    AsyncTCPConnection serverConn;
    string echoedMsg;
    bool clientFinished = false;
    ubyte[] pending;
    size_t serverSent, clientSent;

    void flush(AsyncTCPConnection connection, const(ubyte)[] data, ref size_t offset)
    {
        while (offset < data.length)
        {
            const n = connection.send(data[offset .. $]);
            if (n == 0) break; // resume on WRITE; ERROR is handled by the callback
            assert(n <= data.length - offset);
            offset += n;
        }
    }

    // Server listener
    auto listener = new AsyncTCPListener(evl);
    void delegate(TCPEvent) serverHandler(AsyncTCPConnection conn)
    {
        serverConn = conn;
        return (TCPEvent ev) {
            if (ev == TCPEvent.READ)
            {
                ubyte[] buf = new ubyte[64];
                const len = serverConn.recv(buf);
                if (len > 0)
                {
                    pending ~= buf[0 .. len];
                    flush(serverConn, pending, serverSent);
                }
            }
            else if (ev == TCPEvent.WRITE) flush(serverConn, pending, serverSent);
            else if (ev == TCPEvent.ERROR) assert(false, "server I/O failed");
        };
    }
    const listenOk = listener.host("127.0.0.1", 0).run(&serverHandler);
    assert(listenOk);
    const port = listener.local.port;

    // Client connection
    auto client = new AsyncTCPConnection(evl);
    client.peer = evl.resolveIP("127.0.0.1", port);
    client.run((TCPEvent ev) {
        final switch (ev)
        {
        case TCPEvent.CONNECT:
            flush(client, cast(const(ubyte)[]) "hello", clientSent);
            break;
        case TCPEvent.READ:
            ubyte[] buf = new ubyte[64];
            const len = client.recv(buf);
            if (len > 0)
            {
                echoedMsg ~= cast(string) buf[0 .. len].idup;
                assert(echoedMsg.length <= 5);
                clientFinished = echoedMsg.length == 5;
            }
            break;
        case TCPEvent.WRITE:
            flush(client, cast(const(ubyte)[]) "hello", clientSent);
            break;
        case TCPEvent.ERROR:
            assert(false, "client I/O failed");
        case TCPEvent.CLOSE:
            assert(clientFinished, "connection closed before the complete reply");
            break;
        case TCPEvent.DESTROY:
            break;
        }
    });

    while (!clientFinished)
        evl.loop();
    assert(clientSent == 5 && serverSent == 5);
    client.kill();

    if (serverConn)
        serverConn.kill();
    listener.kill();

    assert(echoedMsg == "hello");
    writeln("echoed: ", echoedMsg);
}
