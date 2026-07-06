#!/usr/bin/env dub
/+ dub.sdl:
    name "http_plaintext_server"
    dependency "sparkles:http" path="../../.."
    platforms "linux"
    targetPath "build"
+/
/**
 * The M13 gate: an HTTP/1.1 plaintext server on the event loop, exercised by
 * an in-process client — all on one ring, under a structured scope.
 *
 *   1. A `LoopGroup` (single topology) hands the root fiber the live `Env`.
 *   2. `env.net.listen` binds an ephemeral loopback port; a daemon runs the
 *      `serve` accept loop, dispatching each connection to a fiber that
 *      parses the request and replies "Hello, World!".
 *   3. A client fiber connects, sends a GET, and verifies the response body.
 *   4. The scope is cancelled to reap the server daemon; the group joins.
 *
 * Run with: `dub run --single plaintext-server.d`
 *
 * SKIPs (prints a SKIP line, exits 0) if io_uring is unavailable.
 */
module http_plaintext_server;

import core.lifetime : move;
import std.stdio : writefln, writeln;

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.event_horizon;
import sparkles.http;

enum body_ = "Hello, World!";

int main()
{
    LoopGroup group;
    if (LoopGroup.start(group, LoopGroupConfig(topology: Topology.single)).hasError)
    {
        writeln("SKIP: io_uring unavailable");
        return 0;
    }
    scope (exit) group.shutdown();

    bool verified;
    ushort gotStatus;
    group.run((ref RootScope sc, ref Env env) {
        auto listener = env.net.listen(ipv4("127.0.0.1", 0)).value;
        const port = boundPort(listener.fd);

        // The server: one daemon running the accept loop; each connection is
        // served by its own fiber. `serve` returns when the scope cancels.
        sc.spawnDaemon({
            Handler handler = (ref const Request req) @safe {
                return req.target == "/"
                    ? Response.ok(body_)
                    : Response.notFound();
            };
            cast(void) serve(sc, listener, handler);
        });

        // The client: a raw HTTP/1.1 GET, then read + verify the response.
        auto conn = env.net.connect(ipv4("127.0.0.1", port)).value;
        scope (exit) conn.close();

        SmallBuffer!(ubyte, 128) reqBuf;
        reqBuf ~= cast(const(ubyte)[])
            ("GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
        auto w = conn.send(move(reqBuf));
        assert(!w.res.hasError);

        // Read the whole response (server closes after replying).
        SmallBuffer!(ubyte, 512) respBuf;
        size_t total;
        for (;;)
        {
            SmallBuffer!(ubyte, 256) chunk;
            chunk.length = 256;
            auto got = conn.recv(move(chunk));
            chunk = move(got.buf);
            if (got.res.hasError || got.res.value == 0)
                break;
            respBuf ~= chunk[][0 .. got.res.value];
            total += got.res.value;
        }

        auto text = cast(const(char)[]) respBuf[][0 .. total];
        gotStatus = statusOf(text);
        verified = gotStatus == 200 && endsWith(text, body_);

        listener.close();
        sc.cancel(Interrupt(InterruptKind.shutdown));
    });

    if (verified)
        writefln("ok: server replied %d with %d-byte body", gotStatus, body_.length);
    else
        writeln("FAILED: unexpected response");
    return verified ? 0 : 1;
}

ushort boundPort(int fd) @trusted
{
    import core.sys.posix.arpa.inet : ntohs;
    import core.sys.posix.netinet.in_ : sockaddr_in;
    import core.sys.posix.sys.socket : getsockname, sockaddr, socklen_t;

    sockaddr_in a;
    socklen_t len = a.sizeof;
    getsockname(fd, cast(sockaddr*) &a, &len);
    return ntohs(a.sin_port);
}

ushort statusOf(const(char)[] resp) @safe
{
    import sparkles.base.text.readers : readInteger;

    // "HTTP/1.1 200 OK\r\n..." — the code follows the first space.
    size_t sp;
    while (sp < resp.length && resp[sp] != ' ')
        ++sp;
    if (sp >= resp.length)
        return 0;
    auto cursor = resp[sp + 1 .. $];
    auto n = readInteger!ushort(cursor);
    return n.hasValue ? n.value : 0;
}

bool endsWith(const(char)[] hay, const(char)[] needle) @safe
    => hay.length >= needle.length && hay[$ - needle.length .. $] == needle;
