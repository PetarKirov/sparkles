#!/usr/bin/env dub
/+ dub.sdl:
    name "editor-recovery-cadence"
    targetPath "../../../build"
    dependency "sparkles:base" path="../../.."
    dependency "sparkles:wired" path="../../.."
    dependency "sparkles:event-horizon" path="../../.."
    dependency "sparkles:recovery" path="../../.."
    dependency "sparkles:ui" path="../../.."
    dependency "sparkles:text-buffer" path="../../.."
    dflags "-preview=in" "-preview=dip1000" "-I$PACKAGE_DIR/../src"
    dflags "-i=editor_document" "-i=document_files"
    dflags "-i=session_record" "-i=session_archive"
    dflags "-i=session_snapshot" "-i=session_checkpoint" "-i=session_discovery" "-i=session_runtime"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/// Measure recovery under sustained edits, independently of shaping and drawing.
module editor_recovery_cadence;

import core.thread : Thread;
import core.time : Duration, MonoTime, msecs, seconds;
import core.sys.posix.sys.resource : getrusage, RUSAGE_SELF, rusage;
import editor_document : Document;
import session_runtime : RecoverySession;
import std.file : mkdir, rmdirRecurse, tempDir;
import std.getopt : getopt;
import std.path : buildPath;
import std.process : execute;
import std.stdio : writefln, writeln;
import std.string : strip;
import std.uuid : randomUUID;

void measure(string label, size_t bytes, bool longLine, uint editBudgetMicros) @system
{
    const root = buildPath(tempDir, "editor-cadence-" ~ randomUUID().toString());
    mkdir(root);
    scope (exit) rmdirRecurse(root);
    auto contents = new char[bytes];
    contents[] = 'x';
    if (!longLine)
        for (size_t index = 79; index < contents.length; index += 80) contents[index] = '\n';
    auto document = new Document(7, "cadence", cast(string) contents);
    Document[] documents = [document];
    auto recovery = new RecoverySession(buildPath(root, "sessions"), root);
    scope (exit) recovery.shutdown();
    MonoTime[] observed;
    Duration worstObservation, worstEdit, worstBatch;
    ulong previousDurable;
    size_t acknowledgments, edits, overdueSamples;
    void observe(MonoTime now)
    {
        const revision = recovery.currentRevision;
        const before = MonoTime.currTime;
        recovery.observe(documents, 7, "github-dark", now);
        const took = MonoTime.currTime - before;
        if (took > worstObservation) worstObservation = took;
        if (revision != recovery.currentRevision) observed ~= now;
    }
    void poll()
    {
        const now = MonoTime.currTime;
        recovery.poll(now);
        assert(!recovery.error.length, recovery.error);
        if (recovery.overdue(now)) ++overdueSamples;
        if (recovery.durableRevision > previousDurable)
        {
            const age = now - observed[cast(size_t) previousDurable];
            if (age > worstBatch) worstBatch = age;
            previousDurable = recovery.durableRevision;
            ++acknowledgments;
        }
    }
    const start = MonoTime.currTime;
    observe(start);
    while (MonoTime.currTime - start < 2.seconds)
    {
        const before = MonoTime.currTime;
        document.field.insert("a", now: before);
        const took = MonoTime.currTime - before;
        if (took > worstEdit) worstEdit = took;
        ++edits;
        observe(MonoTime.currTime);
        poll();
        Thread.sleep(8.msecs);
    }
    recovery.flush();
    const deadline = MonoTime.currTime + 5.seconds;
    while (recovery.pending && MonoTime.currTime < deadline)
    {
        poll();
        if (recovery.pending) Thread.sleep(1.msecs);
    }
    writefln("%s,%s,%s,%s,%s,%s,%s,%s", label, edits, acknowledgments,
        worstEdit.total!"usecs", worstObservation.total!"usecs", worstBatch.total!"msecs",
        overdueSamples, recovery.durableRevision);
    assert(!recovery.pending, "The latest recovery revision was not acknowledged.");
    assert(!overdueSamples && worstBatch < 1.seconds,
        "The one-second recovery bound was exceeded on this workload/host.");
    if (editBudgetMicros)
        assert(worstEdit.total!"usecs" <= editBudgetMicros,
            "The requested per-edit CPU budget was exceeded on this workload/host.");
}

int main(string[] args) @system
{
    bool singleOnly;
    uint editBudgetMicros;
    getopt(args, "single-line", &singleOnly, "edit-budget-us", &editBudgetMicros);
    assert(args.length == 1, "Options: --single-line --edit-budget-us=8000");
    const filesystem = execute(["stat", "-f", "-c", "%T", tempDir]);
    assert(filesystem.status == 0);
    writeln("filesystem,", filesystem.output.strip);
    writeln("workload,edits,acks,max_edit_us,max_observe_us,max_oldest_unacked_ms,overdue_samples,final_revision");
    if (!singleOnly)
    {
        measure("1MiB-80-columns", 1 * 1024 * 1024, false, editBudgetMicros);
        measure("10MiB-80-columns", 10 * 1024 * 1024, false, editBudgetMicros);
    }
    measure("1MiB-single-line", 1 * 1024 * 1024, true, editBudgetMicros);
    rusage usage;
    assert(getrusage(RUSAGE_SELF, &usage) == 0);
    writeln("process_peak_rss_kib,", usage.ru_maxrss);
    return 0;
}
