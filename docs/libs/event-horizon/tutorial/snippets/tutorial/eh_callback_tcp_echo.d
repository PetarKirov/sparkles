#!/usr/bin/env dub
/+ dub.sdl:
    name "tutorial_eh_callback_tcp_echo"
    dependency "sparkles:event-horizon" path="../../../../../.."
    platforms "linux"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import core.lifetime : move;
import core.stdc.errno : EIO;
import std.socket : TcpSocket, InternetAddress;
import std.stdio : writeln, stderr;
import sparkles.event_horizon.loop : DefaultLoop;
import sparkles.event_horizon.op : Completion, OpRecv, OpSend;
import sparkles.event_horizon.buffer : Buf;

struct Transfer
{
    DefaultLoop* loop;
    bool* stopping;
    int fd;
    bool sending;
    size_t used;
    int error;
    ubyte[5] bytes;
}
void next(ref Transfer transfer) nothrow @nogc
{
    if (*transfer.stopping) return;
    auto window = Buf.fromForeign(transfer.bytes[transfer.used .. $], null);
    window.length = cast(uint) (transfer.bytes.length - transfer.used);
    if (transfer.sending)
    {
        auto sent = transfer.loop.submit!completed(OpSend(transfer.fd, move(window)), transfer);
        if (sent.hasError) transfer.error = sent.error.errnoValue;
    }
    else
    {
        auto received = transfer.loop.submit!completed(OpRecv(transfer.fd, move(window)), transfer);
        if (received.hasError) transfer.error = received.error.errnoValue;
    }
    if (transfer.error) { *transfer.stopping = true; transfer.loop.stop(); }
}
void completed(ref Transfer transfer, ref Completion done) nothrow @nogc
{
    if (*transfer.stopping) return; // Also prevents rearming during teardown.
    if (done.res <= 0)
    {
        transfer.error = done.res < 0 ? -done.res : EIO;
        *transfer.stopping = true;
        transfer.loop.stop();
        return;
    }
    transfer.used += done.res;
    if (transfer.used < transfer.bytes.length) next(transfer);
}
int main() @system
{
    // Synchronous loopback fixture setup. Data transfers use Tier-A callbacks.
    auto listener = new TcpSocket;
    scope(exit) listener.close();
    listener.bind(new InternetAddress("127.0.0.1", 0));
    listener.listen(1);
    auto client = new TcpSocket;
    scope(exit) client.close();
    client.connect(listener.localAddress);
    auto server = listener.accept();
    scope(exit) server.close();

    bool stopping;
    Transfer outgoing, incoming;
    DefaultLoop loop;
    auto started = DefaultLoop.create(loop);
    if (started.hasError) { stderr.writeln(started.error); return 1; }
    scope(exit) { stopping = true; loop.destroy(); }
    outgoing.loop = incoming.loop = &loop;
    outgoing.stopping = incoming.stopping = &stopping;
    outgoing.fd = cast(int) client.handle;
    incoming.fd = cast(int) server.handle;
    outgoing.sending = true;
    outgoing.bytes[] = cast(const(ubyte)[]) "hello";
    foreach (exchange; 0 .. 2)
    {
        next(outgoing);
        if (!outgoing.error) next(incoming);
        auto ran = loop.run(); // Fan-in for this five-byte exchange.
        if (ran.hasError) { stderr.writeln(ran.error); return 1; }
        if (outgoing.error || incoming.error)
        { stderr.writeln("transfer failed: ", outgoing.error, " / ", incoming.error); return 1; }
        outgoing.bytes = incoming.bytes;
        outgoing.used = incoming.used = 0;
        outgoing.fd = cast(int) server.handle;
        incoming.fd = cast(int) client.handle;
    }
    writeln("echoed: ", cast(const(char)[]) incoming.bytes[]);
    return 0;
}
