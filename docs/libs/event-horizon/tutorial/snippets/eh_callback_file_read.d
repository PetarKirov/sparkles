#!/usr/bin/env dub
/+ dub.sdl:
    name "eh_callback_file_read"
    dependency "sparkles:event-horizon" path="../../../../.."
    platforms "linux"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
@system:
import core.lifetime : move;
import core.stdc.errno : ENOENT;
import core.sys.posix.fcntl : AT_FDCWD, O_RDONLY;
import core.sys.posix.stdlib : mkdtemp;
import std.file : tempDir, write, remove, rmdir;
import std.path : buildPath;
import std.string : toStringz, fromStringz;
import std.stdio : writeln;
import sparkles.event_horizon.loop : DefaultLoop;
import sparkles.event_horizon.op;
import sparkles.event_horizon.buffer : BufferPool;

struct State
{
    DefaultLoop* loop;
    BufferPool!()* pool;
    const(char)* path;
    int fd = -1;
    char[18] contents;
    size_t used;
    bool missingSeen, eof, closed;
}

void closed(void* context, ref Completion done) nothrow @nogc
{
    auto state = cast(State*) context;
    assert(done.res == 0 && state.eof);
    state.fd = -1;
    state.closed = true;
}

void readNext(State* state) nothrow @nogc
{
    auto buffer = state.pool.acquire();
    assert(buffer.hasValue);
    assert(state.loop.submit(OpRead(state.fd, move(buffer.value), state.used),
        &readDone, state).hasValue);
}

void readDone(void* context, ref Completion done) nothrow @nogc
{
    auto state = cast(State*) context;
    assert(done.res >= 0, "a read error is not EOF");
    if (done.res == 0)
    {
        state.eof = true;
        assert(state.loop.submit(OpClose(state.fd), &closed, context).hasValue);
        return;
    }
    assert(state.used + done.res <= state.contents.length);
    state.contents[state.used .. state.used + done.res] = cast(const(char)[]) done.buf[];
    state.used += done.res;
    // Reuse the returned owner instead of borrowing its slice after return.
    assert(state.loop.submit(OpRead(state.fd, move(done.buf), state.used),
        &readDone, context).hasValue);
}

void opened(void* context, ref Completion done) nothrow @nogc
{
    auto state = cast(State*) context;
    assert(done.res >= 0);
    state.fd = done.res;
    readNext(state);
}

void missing(void* context, ref Completion done) nothrow @nogc
{
    auto state = cast(State*) context;
    assert(done.res == -ENOENT);
    state.missingSeen = true;
    assert(state.loop.submit(OpOpenAt(AT_FDCWD, state.path, O_RDONLY), &opened, context).hasValue);
}

void main()
{
    auto pattern = (buildPath(tempDir(), "eh-callback-file-XXXXXX") ~ '\0').dup;
    assert(mkdtemp(pattern.ptr) !is null);
    auto directory = fromStringz(pattern.ptr).idup;
    scope(exit) rmdir(directory);
    auto path = buildPath(directory, "input");
    write(path, "hello from a file\n");
    scope(exit) remove(path);
    // Both NUL-terminated paths outlive their terminal open completions.
    auto name = path.toStringz;
    auto absent = buildPath(directory, "missing").toStringz;
    BufferPool!() pool;
    assert(!BufferPool!().create(pool, 1, 8).hasError);
    DefaultLoop loop;
    assert(!DefaultLoop.create(loop).hasError, "no completion backend");
    scope(exit) loop.destroy();
    State state;
    state.loop = &loop;
    state.pool = &pool;
    state.path = name;
    assert(loop.submit(OpOpenAt(AT_FDCWD, absent, O_RDONLY), &missing, &state).hasValue);
    assert(!loop.run().hasError);
    assert(loop.inFlight == 0 && pool.available == 1);
    assert(state.missingSeen && state.eof && state.closed && state.fd == -1);
    assert(state.used == 18 && state.contents[] == "hello from a file\n");
    writeln("read ", state.used, " bytes: ", state.contents[]);
}
