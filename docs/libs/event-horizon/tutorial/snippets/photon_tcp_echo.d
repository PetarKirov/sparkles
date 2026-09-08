#!/usr/bin/env dub
/+ dub.sdl:
    name "photon_tcp_echo"
    dependency "photon" version="0.19.3"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
    platforms "linux"
+/
import core.sys.posix.netinet.in_;
import core.sys.posix.sys.socket;
import core.sys.posix.unistd : close, read, write;
import std.stdio : writeln;
import photon;

void main()
{
    initPhoton();

    go({
        // Standard POSIX socket: Photon hooks socket, bind, listen, accept, read, write
        int serverFd = socket(AF_INET, SOCK_STREAM, 0);
        assert(serverFd >= 0);
        scope (exit) close(serverFd);

        sockaddr_in addr;
        addr.sin_family = AF_INET;
        addr.sin_port = 0; // ephemeral port
        addr.sin_addr.s_addr = 0x0100007F; // loopback on this Linux little-endian fixture

        assert(bind(serverFd, cast(sockaddr*)&addr, addr.sizeof) == 0);
        assert(listen(serverFd, 1) == 0);

        socklen_t len = addr.sizeof;
        assert(getsockname(serverFd, cast(sockaddr*)&addr, &len) == 0);

        // Server fiber: accepts and echoes data using borrowed slices
        go({
            sockaddr_in clientAddr;
            socklen_t clientLen = clientAddr.sizeof;
            int connFd = accept(serverFd, cast(sockaddr*)&clientAddr, &clientLen);
            if (connFd >= 0)
            {
                scope (exit) close(connFd);
                ubyte[5] srvBuf;
                // Transparent pseudo-blocking read; buffer is borrowed in-place
                readExact(connFd, srvBuf[]);
                writeAll(connFd, srvBuf[]);
            }
        });

        // Client fiber: connects and sends message
        int clientFd = socket(AF_INET, SOCK_STREAM, 0);
        assert(clientFd >= 0);
        scope (exit) close(clientFd);

        sockaddr_in targetAddr;
        targetAddr.sin_family = AF_INET;
        targetAddr.sin_port = addr.sin_port;
        targetAddr.sin_addr.s_addr = 0x0100007F; // 127.0.0.1

        assert(connect(clientFd, cast(sockaddr*)&targetAddr, targetAddr.sizeof) == 0);

        const char[] msg = "hello";
        writeAll(clientFd, cast(const(ubyte)[]) msg);

        ubyte[5] recvBuf;
        readExact(clientFd, recvBuf[]);
        const received = recvBuf.length;
        assert(received == msg.length);
        assert(cast(const(char)[]) recvBuf[0 .. received] == "hello");

        writeln("echoed: ", cast(const(char)[]) recvBuf[0 .. received]);
    });

    runScheduler();
}

void readExact(int fd, ubyte[] buffer)
{
    import core.stdc.errno : errno, EINTR;
    size_t offset;
    while (offset < buffer.length)
    {
        const n = read(fd, buffer.ptr + offset, buffer.length - offset);
        if (n < 0 && errno == EINTR) continue;
        assert(n > 0);
        offset += n;
    }
}

void writeAll(int fd, const(ubyte)[] buffer)
{
    import core.stdc.errno : errno, EINTR;
    size_t offset;
    while (offset < buffer.length)
    {
        const n = write(fd, buffer.ptr + offset, buffer.length - offset);
        if (n < 0 && errno == EINTR) continue;
        assert(n > 0);
        offset += n;
    }
}
