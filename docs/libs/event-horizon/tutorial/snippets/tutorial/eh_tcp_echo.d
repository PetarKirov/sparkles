#!/usr/bin/env dub
/+ dub.sdl:
    name "tutorial_eh_tcp_echo"
    dependency "sparkles:event-horizon" path="../../../../../.."
    platforms "linux"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import core.lifetime : move;
import std.stdio : writeln, stderr;
import sparkles.base.buffer : UniqueBuffer;
import sparkles.event_horizon;

// A five-byte frame: the helpers handle short transfers, not message framing.
IoResult!void echo(ref Listener listener) @system
{
    auto accepted = listener.accept();
    if (accepted.hasError) return ioErr!void(accepted.error);
    auto peer = accepted.value;
    scope(exit) peer.close();
    UniqueBuffer!(ubyte, 5) frame;
    frame.length = 5;
    auto received = peer.readExactly(move(frame));
    if (received.res.hasError) return received.res;
    return peer.sendAll(move(received.buf)).res;
}

int main() @system
{
    Listener listener; // Outlives the joined root and every server operation.
    scope(exit) listener.close();
    auto result = runApplication((ref RootScope root, ref Env env) {
        auto opened = env.net.listen(ipv4("127.0.0.1", 0));
        if (opened.hasError) return ioErr!void(opened.error);
        listener = opened.value;
        auto address = listener.localAddress();
        if (address.hasError) return ioErr!void(address.error);
        if (!root.spawn({
            auto served = echo(listener);
            if (served.hasError) root.fail(Cause!IoError.fromFailure(served.error));
        })) return ioOk(); // Rejection already records the scope failure.

        auto connected = env.net.connect(address.value);
        if (connected.hasError) return ioErr!void(connected.error);
        auto client = connected.value;
        scope(exit) client.close();
        UniqueBuffer!(ubyte, 5) frame;
        frame ~= cast(const(ubyte)[]) "hello";
        auto sent = client.sendAll(move(frame));
        if (sent.res.hasError) return sent.res;
        auto reply = client.readExactly(move(sent.buf));
        if (reply.res.hasError) return reply.res;
        writeln("echoed: ", cast(const(char)[]) reply.buf[]);
        return ioOk();
    });
    if (result.hasError) stderr.writeln(result.error);
    return result.hasError ? 1 : 0;
}
