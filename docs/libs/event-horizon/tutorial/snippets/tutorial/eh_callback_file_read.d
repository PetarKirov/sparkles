#!/usr/bin/env dub
/+ dub.sdl:
    name "tutorial_eh_callback_file_read"
    dependency "sparkles:event-horizon" path="../../../../../.."
    platforms "linux"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import core.lifetime : move;
import core.stdc.errno : EFBIG;
import std.stdio : File, writeln, stderr;
import sparkles.event_horizon.loop : DefaultLoop;
import sparkles.event_horizon.op : Completion, OpRead;
import sparkles.event_horizon.buffer : Buf;

struct Reader
{
    DefaultLoop* loop;
    int fd, error;
    bool stopping;
    size_t used;
    ubyte[128] bytes; // A bounded example, not an unbounded file loader.
}
void readNext(ref Reader reader) nothrow @nogc
{
    if (reader.used == reader.bytes.length) { reader.error = EFBIG; return; }
    auto window = Buf.fromForeign(reader.bytes[reader.used .. $], null);
    auto submitted = reader.loop.submit!readDone(OpRead(reader.fd, move(window), reader.used), reader);
    if (submitted.hasError) reader.error = submitted.error.errnoValue;
}
void readDone(ref Reader reader, ref Completion done) nothrow @nogc
{
    if (reader.stopping) return;
    if (done.res < 0) reader.error = -done.res;
    else if (done.res > 0) { reader.used += done.res; readNext(reader); }
    // Zero is EOF. A failed read is not EOF.
}
int main() @system
{
    auto fixture = File.tmpfile(); // Synchronous fixture setup; reads below are native callbacks.
    fixture.write("hello from a file\n");
    fixture.flush();
    Reader reader;
    DefaultLoop loop;
    auto started = DefaultLoop.create(loop);
    if (started.hasError) { stderr.writeln(started.error); return 1; }
    scope(exit) { reader.stopping = true; loop.destroy(); }
    reader.loop = &loop;
    reader.fd = fixture.fileno;
    readNext(reader);
    auto ran = loop.run();
    if (ran.hasError) { stderr.writeln(ran.error); return 1; }
    if (reader.error) { stderr.writeln("read failed: ", reader.error); return 1; }
    writeln("read ", reader.used, " bytes: ", cast(const(char)[]) reader.bytes[0 .. reader.used]);
    return 0;
}
