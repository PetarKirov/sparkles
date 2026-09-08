#!/usr/bin/env dub
/+ dub.sdl:
    name "eh_callback_tcp_echo"
    dependency "sparkles:event-horizon" path="../../../../.."
    platforms "linux"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
@system:
import core.lifetime : move;
import core.sys.posix.sys.socket;
import core.sys.posix.netinet.in_ : sockaddr_in, INADDR_LOOPBACK;
import core.sys.posix.arpa.inet : htonl;
import core.sys.posix.unistd : close;
import std.stdio : writeln;
import sparkles.event_horizon.loop : DefaultLoop;
import sparkles.event_horizon.op;
import sparkles.event_horizon.buffer : BufferPool;

enum payload = "hello";
struct Endpoint
{
    DefaultLoop* loop;
    BufferPool!()* pool;
    int fd = -1;
    bool server;
    size_t sent, received, pendingSend;
    char[5] bytes;
}

void receive(Endpoint* endpoint) nothrow @nogc
{
    auto buffer = endpoint.pool.acquire();
    assert(buffer.hasValue);
    assert(endpoint.loop.submit(OpRecv(endpoint.fd, move(buffer.value)),
        &received, endpoint).hasValue);
}

void send(Endpoint* endpoint) nothrow @nogc
{
    auto buffer = endpoint.pool.acquire();
    assert(buffer.hasValue);
    // Two-byte buffers force the five-byte frame through several operations.
    auto remaining = payload.length - endpoint.sent;
    auto count = remaining < 2 ? remaining : 2;
    const(char)[] outgoing = endpoint.server ? endpoint.bytes[] : payload;
    buffer.value.space()[0 .. count] = cast(const(ubyte)[]) outgoing[endpoint.sent .. endpoint.sent + count];
    buffer.value.length = cast(uint) count;
    endpoint.pendingSend = count;
    assert(endpoint.loop.submit(OpSend(endpoint.fd, move(buffer.value)),
        &sent, endpoint).hasValue);
}

void sent(void* context, ref Completion done) nothrow @nogc
{
    auto endpoint = cast(Endpoint*) context;
    assert(done.res > 0 && done.res <= endpoint.pendingSend);
    endpoint.sent += done.res;
    if (endpoint.sent < payload.length) send(endpoint);
    else if (!endpoint.server) receive(endpoint);
}

void received(void* context, ref Completion done) nothrow @nogc
{
    auto endpoint = cast(Endpoint*) context;
    assert(done.res > 0 && endpoint.received + done.res <= payload.length);
    endpoint.bytes[endpoint.received .. endpoint.received + done.res] = cast(const(char)[]) done.buf[];
    endpoint.received += done.res;
    if (endpoint.received < payload.length) receive(endpoint);
    else
    {
        assert(endpoint.bytes[] == payload);
        if (endpoint.server) send(endpoint);
    }
}

void accepted(void* context, ref Completion done) nothrow @nogc
{
    auto endpoint = cast(Endpoint*) context;
    assert(done.res >= 0);
    endpoint.fd = done.res;
    receive(endpoint);
}

void connected(void* context, ref Completion done) nothrow @nogc
{
    assert(done.res == 0);
    send(cast(Endpoint*) context);
}

void main()
{
    auto listener = socket(AF_INET, SOCK_STREAM, 0);
    assert(listener >= 0);
    scope(exit) close(listener);
    sockaddr_in address;
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    assert(bind(listener, cast(sockaddr*) &address, address.sizeof) == 0);
    assert(listen(listener, 1) == 0);
    socklen_t length = address.sizeof;
    assert(getsockname(listener, cast(sockaddr*) &address, &length) == 0);
    auto clientFd = socket(AF_INET, SOCK_STREAM, 0);
    assert(clientFd >= 0);
    scope(exit) close(clientFd);
    BufferPool!() pool;
    assert(!BufferPool!().create(pool, 4, 2).hasError);
    DefaultLoop loop;
    assert(!DefaultLoop.create(loop).hasError, "no completion backend");
    scope(exit) loop.destroy();
    Endpoint server = Endpoint(&loop, &pool, -1, true);
    Endpoint client = Endpoint(&loop, &pool, clientFd);
    scope(exit) if (server.fd >= 0) close(server.fd);
    SockAddr target;
    target.storage[0 .. address.sizeof] = (cast(ubyte*) &address)[0 .. address.sizeof];
    target.len = address.sizeof;
    assert(loop.submit(OpAccept(listener), &accepted, &server).hasValue);
    assert(loop.submit(OpConnect(clientFd, target), &connected, &client).hasValue);
    assert(!loop.run().hasError);
    assert(loop.inFlight == 0 && pool.available == 4);
    assert(server.sent == 5 && client.sent == 5);
    assert(server.received == 5 && client.received == 5);
    assert(client.bytes[] == payload);
    writeln("echoed: ", client.bytes[]);
}
