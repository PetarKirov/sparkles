/**
Native tests of `RingVfs` (testing.md oracles 1 and 4), run on a scheduler
fiber so every blocking call takes the pool path.
*/
module sparkles.event_horizon.vfs_test;

version (unittest):
version (Posix):

import std.file : rmdirRecurse;

import sparkles.base.vfs;
import sparkles.base.vfs.testing : runAttackTable;
import sparkles.event_horizon.sched : Sched, schedOrSkip;
import sparkles.event_horizon.sys : BlockingVfs;
import sparkles.event_horizon.sys.testing : NativeFixture, differentialLog,
    differentialMemVfs, scratchDir;
import sparkles.event_horizon.vfs : RingVfs;

private void expectNoFailures(string[] failures, string what) @safe
{
    if (failures.length)
    {
        import std.array : join;

        assert(0, what ~ ":\n" ~ failures.join("\n"));
    }
}

/// The attack table, on the pool path, with each resolver.
@("vfs.ring.oracle1")
@safe unittest
{
    Sched s;
    schedOrSkip(s);
    foreach (force; [false, true])
    {
        string[] failures;
        size_t skipped;
        auto r = s.run(() {
            failures = runAttackTable!(NativeFixture!RingVfs)(
                () => NativeFixture!RingVfs.make(), skipped,
                (RingVfs* v) { v.forceComponentWalk = force; });
        });
        assert(!r.hasError);
        expectNoFailures(failures, force ? "ring, component walk" : "ring, default resolver");
        assert(skipped == 2 * 8, "only the two mount rows are skipped");
    }
}

/// Oracle 4 with all three backends: one transcript.
@("vfs.ring.oracle4.threeBackends")
@safe unittest
{
    auto mem = differentialMemVfs();
    mem.mkdirs("r");
    auto memRoot = openRoot!(Rights.all)(mem, "r", ambientAuthority());
    const memLog = differentialLog(memRoot.value);

    auto blockingDir = scratchDir("diff-blocking");
    scope (exit) rmdirRecurse(blockingDir);
    auto blocking = new BlockingVfs;
    auto blockingRoot = openRoot!(Rights.all)(blocking, blockingDir, ambientAuthority());
    const blockingLog = differentialLog(blockingRoot.value);

    Sched s;
    schedOrSkip(s);
    auto ringDir = scratchDir("diff-ring");
    scope (exit) rmdirRecurse(ringDir);
    string ringLog;
    auto r = s.run(() {
        auto ring = new RingVfs;
        auto ringRoot = openRoot!(Rights.all)(ring, ringDir, ambientAuthority());
        ringLog = differentialLog(ringRoot.value);
    });
    assert(!r.hasError);

    assert(memLog == blockingLog && blockingLog == ringLog,
        "\nMemVfs:      " ~ memLog ~ "\nBlockingVfs: " ~ blockingLog ~ "\nRingVfs:     " ~ ringLog);
}

/// On a scheduler fiber a mutation the kernel has a ring opcode for goes to
/// the ring, and any other call to the blocking pool; off a fiber every call
/// runs inline. The result is the same on every path (VFB5).
@("vfs.ring.pathPerCall")
@safe unittest
{
    auto dir = scratchDir("pool");
    scope (exit) rmdirRecurse(dir);
    auto ring = new RingVfs;
    auto root = openRoot!(Rights.all)(ring, dir, ambientAuthority());

    const pooled = RingVfs.poolCalls, ringed = RingVfs.ringCalls;
    assert(!root.value.mkdirAt("inline").hasError);
    assert(RingVfs.poolCalls == pooled && RingVfs.ringCalls == ringed,
        "no scheduler: inline");

    Sched s;
    schedOrSkip(s);
    bool ringable;
    auto r = s.run(() {
        import sparkles.base.io.errors : OpKind;
        import sparkles.event_horizon.sched : currentScheduler;

        ringable = currentScheduler().loop.caps().supports(OpKind.mkdirAt);
        assert(!root.value.mkdirAt("on-a-fiber").hasError);
        assert(root.value.mkdirAt("on-a-fiber").error.kind == ErrorKind.exists);
        assert(root.value.statAt("inline").value.kind == EntryKind.directory);
    });
    assert(!r.hasError);
    if (ringable)
        assert(RingVfs.ringCalls == ringed + 2 && RingVfs.poolCalls == pooled + 1,
            "the two mkdirs went to the ring, the stat to the pool");
    else
        assert(RingVfs.poolCalls == pooled + 3, "every call went to the pool");
}

/// Every `Dir` and `File` operation has an `Effect!T` form, generated from the
/// direct one, with the same result (SPEC §10.5).
@("vfs.ring.effectForms")
@safe unittest
{
    import core.lifetime : move;
    import sparkles.event_horizon.effect : effects, map, run;
    import sparkles.event_horizon.scope_ : withScope;

    auto dir = scratchDir("effects");
    scope (exit) rmdirRecurse(dir);

    Sched s;
    schedOrSkip(s);
    static struct EmptyCtx { }
    auto r = s.run(() {
        cast(void) withScope!((ref sc) {
            EmptyCtx ctx;
            auto ring = new RingVfs;
            auto root = openRoot!(Rights.all)(ring, dir, ambientAuthority());

            // mkdirAt, then a stat of what it made through a pipeline.
            assert(!run(root.value.effects.mkdirAt("out"), sc, ctx).hasError);
            auto kind = run(root.value.effects.statAt("out").map!(st => st.kind), sc, ctx);
            assert(!kind.hasError && kind.value == EntryKind.directory);

            // The same failure the direct form returns.
            auto again = run(root.value.effects.mkdirAt("out"), sc, ctx);
            assert(again.hasError);
            assert(again.error.failure.kind == root.value.mkdirAt("out").error.kind);

            // An operation with template arguments, and a File operation.
            auto created = run(root.value.effects.call!("openFile", OpenMode.createNew)("f"),
                sc, ctx);
            assert(!created.hasError);
            auto file = move(created.value);
            auto wrote = run(file.effects.write(cast(const(ubyte)[]) "effect"), sc, ctx);
            assert(!wrote.hasError && wrote.value == 6);
            assert(root.value.statAt("f").value.size == 6);
        })(s);
    });
    assert(!r.hasError);
}
