#!/usr/bin/env dub
/+ dub.sdl:
    name "recovery-checkpoint-fault-probe"
    targetPath "../../../build"
    dependency "sparkles:base" path="../../.."
    dependency "sparkles:recovery" path="../../.."
    dflags "-preview=in" "-preview=dip1000"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/// Real worker-thread directory-sync failure followed by a new immutable retry generation.
module checkpoint_fault_probe;

import core.thread : Thread;
import core.time : MonoTime, seconds;
import sparkles.base.expected : Expected, ok;
import sparkles.recovery.archive : readGeneration;
import sparkles.recovery.directory : LeasedDirectory;
import sparkles.recovery.writer : CheckpointWriter;
import std.conv : text;
import std.stdio : writeln;

/// A snapshot whose payload is its text.
final class TextSnapshot
{
    string text_;
    ulong revision_;
    this(string text, ulong revision) @safe pure nothrow { text_ = text; revision_ = revision; }
    ulong revision() const @safe pure nothrow @nogc => revision_;
    Expected!string encode(ulong) const @safe nothrow
    {
        string payload = text_;
        return ok(payload);
    }
}

int main(string[] args) @system
{
    assert(args.length == 2, "Pass a prepared private archive directory.");
    auto directory = LeasedDirectory.claim(args[1]);
    assert(directory.hasValue);
    auto writer = new CheckpointWriter!TextSnapshot(directory.value);
    scope (exit) writer.shutdown();
    const clock = MonoTime.currTime;
    void drain() @system
    {
        const deadline = MonoTime.currTime + 5.seconds;
        while (writer.busy && MonoTime.currTime < deadline)
        {
            writer.poll(clock);
            Thread.yield();
        }
        assert(!writer.busy, "The worker did not complete.");
    }
    string contents;
    foreach (revision; 1UL .. 5UL)
    {
        contents ~= text(revision);
        writer.request(new TextSnapshot(contents, revision), clock);
        writer.flush(clock);
        drain();
        if (revision < 4) assert(!writer.pending && writer.durableRevision == revision);
    }
    assert(writer.pending && writer.error.length && writer.durableRevision == 3);
    assert(readGeneration(args[1], 4).value == "1234", "the unconfirmed generation is kept");
    assert(readGeneration(args[1], 3).value == "123");
    writer.flush(clock);
    drain();
    assert(!writer.pending && writer.durableRevision == 4 && writer.durableGeneration == 5);
    assert(!writer.error.length);
    assert(readGeneration(args[1], 5).value == "1234");
    assert(readGeneration(args[1], 4).hasValue);
    writeln("unconfirmed generation retained; retry used generation 5; revision 4 acknowledged");
    return 0;
}
