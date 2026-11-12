#!/usr/bin/env dub
/+ dub.sdl:
    name "editor-checkpoint-fault-probe"
    targetPath "../../../build"
    dependency "sparkles:base" path="../../.."
    dependency "sparkles:wired" path="../../.."
    dependency "sparkles:event-horizon" path="../../.."
    dependency "sparkles:ui" path="../../.."
    dependency "sparkles:text-buffer" path="../../.."
    dflags "-preview=in" "-preview=dip1000" "-I$PACKAGE_DIR/../src"
    dflags "-i=editor_document" "-i=document_text" "-i=document_files"
    dflags "-i=session_record" "-i=session_archive" "-i=session_directory"
    dflags "-i=session_snapshot" "-i=session_checkpoint"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/// Real worker-thread directory-sync failure followed by a new immutable retry generation.
module checkpoint_fault_probe;

import core.thread : Thread;
import core.time : MonoTime, seconds;
import editor_document : Document;
import session_archive : readSessionGeneration;
import session_checkpoint : CheckpointWriter;
import session_directory : SessionDirectory;
import session_snapshot : SessionSnapshot;
import std.conv : text;
import std.stdio : writeln;

int main(string[] args) @system
{
    assert(args.length == 2, "Pass a prepared private archive directory.");
    auto directory = SessionDirectory.claim(args[1]);
    assert(directory.hasValue);
    auto writer = new CheckpointWriter(directory.value);
    scope (exit) writer.shutdown();
    auto document = new Document(7, "draft");
    Document[] documents = [document];
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
    foreach (revision; 1UL .. 5UL)
    {
        document.field.insert(text(revision));
        writer.request(SessionSnapshot.capture(documents, 7, "github-dark", revision), clock);
        writer.flush(clock);
        drain();
        if (revision < 4) assert(!writer.pending && writer.durableRevision == revision);
    }
    assert(writer.pending && writer.error.length && writer.durableRevision == 3);
    const unconfirmed = readSessionGeneration(args[1], 4);
    assert(unconfirmed.hasValue && unconfirmed.value.tabs[0].content == "1234");
    const prior = readSessionGeneration(args[1], 3);
    assert(prior.hasValue && prior.value.tabs[0].content == "123");
    writer.flush(clock);
    drain();
    assert(!writer.pending && writer.durableRevision == 4 && writer.durableGeneration == 5);
    assert(!writer.error.length);
    const retry = readSessionGeneration(args[1], 5);
    assert(retry.hasValue && retry.value.tabs[0].content == "1234");
    assert(readSessionGeneration(args[1], 4).hasValue);
    writeln("unconfirmed generation retained; retry used generation 5; revision 4 acknowledged");
    return 0;
}
