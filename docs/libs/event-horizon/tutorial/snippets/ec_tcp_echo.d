#!/usr/bin/env dub
/+ dub.sdl:
    name "ec_tcp_echo"
    dependency "eventcore" version="0.9.39"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
    platforms "linux"
+/
import core.sys.posix.arpa.inet : ntohs;
import core.sys.posix.netinet.in_ : sockaddr_in;
import core.sys.posix.sys.socket : sockaddr;
import core.time : Duration;
import eventcore.core;
import std.socket : InternetAddress;
import std.stdio : writeln;

void main()
{
    ushort port;
    StreamListenSocketFD listener;
    StreamSocketFD serverConn;
    StreamSocketFD clientConn;
    ubyte[64] serverBuf;
    ubyte[64] clientBuf;
    bool done = false;

    // Server accept callback
    void onAccept(StreamListenSocketFD listenSock, StreamSocketFD conn, scope RefAddress) nothrow @safe
    {
        serverConn = conn;
        eventDriver.sockets.addRef(serverConn);

        // Read into borrowed serverBuf: caller must ensure serverBuf stays alive!
        eventDriver.sockets.read(serverConn, serverBuf[0 .. 5], IOMode.all,
            (StreamSocketFD sock, IOStatus status, size_t bytesRead) nothrow @safe {
                assert(status == IOStatus.ok && bytesRead == 5);
                if (status == IOStatus.ok && bytesRead > 0)
                {
                    // Echo bytes back to client
                    eventDriver.sockets.write(sock, serverBuf[0 .. bytesRead], IOMode.all,
                        (StreamSocketFD wrSock, IOStatus wrStatus, size_t bytesWritten) nothrow @safe {
                            assert(wrStatus == IOStatus.ok && bytesWritten == 5);
                            eventDriver.sockets.shutdown(wrSock, true, true);
                            eventDriver.sockets.releaseRef(wrSock);
                        });
                }
            });
    }

    auto bindAddr = new InternetAddress("127.0.0.1", 0);
    listener = eventDriver.sockets.listenStream(bindAddr, &onAccept);
    assert(listener != StreamListenSocketFD.invalid);

    // Retrieve bound ephemeral port
    sockaddr_in sin;
    scope refAddr = new RefAddress(cast(sockaddr*)&sin, sin.sizeof);
    bool ok = eventDriver.sockets.getLocalAddress(cast(SocketFD)listener, refAddr);
    assert(ok);
    port = ntohs(sin.sin_port);

    // Client connects to server
    auto connectAddr = new InternetAddress("127.0.0.1", port);
    clientConn = eventDriver.sockets.connectStream(connectAddr, null,
        (StreamSocketFD sock, ConnectStatus status) nothrow @safe {
            assert(status == ConnectStatus.connected);
            clientConn = sock;
            eventDriver.sockets.addRef(clientConn);

            static immutable ubyte[] msg = cast(immutable(ubyte)[]) "hello";
            eventDriver.sockets.write(sock, msg, IOMode.all,
                (StreamSocketFD wrSock, IOStatus wrStatus, size_t bytesWritten) nothrow @safe {
                    assert(wrStatus == IOStatus.ok);

                    // Read echo response into clientBuf
                    assert(bytesWritten == 5);
                    eventDriver.sockets.read(wrSock, clientBuf[0 .. 5], IOMode.all,
                        (StreamSocketFD rdSock, IOStatus rdStatus, size_t bytesRead) nothrow @safe {
                            assert(rdStatus == IOStatus.ok);
                            assert(cast(const(char)[]) clientBuf[0 .. bytesRead] == "hello");
                            try writeln("echoed: ", cast(const(char)[]) clientBuf[0 .. bytesRead]);
                            catch (Exception error) { assert(false, error.msg); }

                            done = true;
                            eventDriver.sockets.shutdown(rdSock, true, true);
                            eventDriver.sockets.releaseRef(rdSock);
                            eventDriver.sockets.releaseRef(listener);
                        });
                });
        });

    while (!done && eventDriver.core.waiterCount > 0)
        eventDriver.core.processEvents(Duration.max);

    assert(done);
}
