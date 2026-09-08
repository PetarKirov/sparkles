#!/usr/bin/env dub
/+ dub.sdl:
    name "tutorial_vibe_tcp_echo"
    dependency "vibe-core" version="2.14.0"
    platforms "linux"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import std.stdio : writeln;
import vibe.core.net : connectTCP, listenTCP, TCPConnection;
import vibe.core.sync : createManualEvent;

void main() @system
{
    auto finished = createManualEvent();
    Exception serverError;
    auto listener = listenTCP(0, (TCPConnection peer) nothrow @safe {
        scope(exit) finished.emit();
        scope(exit) peer.close();
        try
        {
            ubyte[5] frame;
            peer.read(frame[]); // Five-byte framing; all-mode handles short reads.
            peer.write(frame[]);
        }
        catch (Exception error) { serverError = error; }
    }, "127.0.0.1");
    scope(exit) listener.stopListening();
    auto client = connectTCP("127.0.0.1", listener.bindAddress.port);
    scope(exit) client.close();
    ubyte[5] reply;
    try
    {
        client.write(cast(const(ubyte)[]) "hello");
        client.read(reply[]);
    }
    finally
    {
        client.close(); // Unblock the server even if the exchange failed.
        finished.waitUninterruptible(0); // Includes an earlier completion emit.
    }
    if (serverError !is null) throw serverError;
    writeln("echoed: ", cast(const(char)[]) reply[]);
}
