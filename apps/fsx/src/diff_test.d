/// `fsdiff` (`XD1`–`XD3`, docs/specs/fsx), over fixture pairs whose
/// differences are written by hand.
module diff_test;

version (unittest):
version (Posix):
version (FsxDiff):

import std.algorithm.searching : canFind, startsWith;
import std.conv : octal, text;
import std.file : exists, mkdirRecurse, rmdirRecurse, setAttributes, symlink, tempDir, write;
import std.path : buildPath;
import std.process : thisProcessID;

import cli : runFsxTo;

private struct Pair
{
    string top, a, b;

    // `a` and `b` differ in one file each way, one changed file, one
    // executable bit, and one file turned into a link; `same` is in both.
    static Pair make(string label)
    {
        Pair p;
        p.top = buildPath(tempDir, text("fsdiff-", thisProcessID, "-", label));
        if (exists(p.top))
            rmdirRecurse(p.top);
        p.a = buildPath(p.top, "a");
        p.b = buildPath(p.top, "b");
        foreach (d; [p.a, p.b])
        {
            mkdirRecurse(buildPath(d, "dir"));
            write(buildPath(d, "same"), "same\n");
            write(buildPath(d, "dir", "run"), "#!/bin/sh\n");
        }
        write(buildPath(p.a, "gone"), "only in a\n");
        write(buildPath(p.b, "new"), "only in b\n");
        write(buildPath(p.a, "text"), "one\ntwo\nthree\n");
        write(buildPath(p.b, "text"), "one\n2\nthree\n");
        setAttributes(buildPath(p.b, "dir", "run"), octal!755);
        write(buildPath(p.a, "kind"), "a file\n");
        symlink("same", buildPath(p.b, "kind"));
        return p;
    }

    void remove() => rmdirRecurse(top);
}

private struct Run
{
    int status;
    string output, error;
}

private Run run(string[] args...)
{
    Run r;
    r.status = runFsxTo(args.dup, r.output, r.error);
    return r;
}

/// XD1, XD3: the five differences, in byte order, and status 1; a source
/// against itself is equal, status 0; a missing source is trouble, 2.
@("fsx.XD.nameStatus")
@system unittest
{
    auto p = Pair.make("status");
    scope (exit) p.remove();
    const r = run("fsdiff", p.a, p.b);
    assert(r.status == 1, r.error);
    assert(r.output == "M\tdir/run\nD\tgone\nT\tkind\nA\tnew\nM\ttext\n", r.output);

    const same = run("fsx", "diff", p.a, p.a);
    assert(same.status == 0 && same.output.length == 0, same.output ~ same.error);
    assert(run("fsdiff", p.a, buildPath(p.top, "missing")).status == 2);
    assert(run("fsdiff", p.a).status == 2, "two sources");

    // The filter applies to both sides.
    const only = run("fsdiff", p.a, p.b, "--filter", "text");
    assert(only.status == 1 && only.output == "M\ttext\n", only.output);
}

/// XD2: --patch adds a unified diff of each changed text file.
@("fsx.XD.patch")
@system unittest
{
    auto p = Pair.make("patch");
    scope (exit) p.remove();
    const r = run("fsdiff", p.a, p.b, "--filter", "text", "-p");
    assert(r.status == 1, r.error);
    assert(r.output.startsWith("M\ttext\ndiff --git a/text b/text\n--- a/text\n+++ b/text\n@@ "), r.output);
    assert(r.output.canFind("\n-two\n+2\n"), r.output);
}

/// XD2: a local tree against a ticket is compared from digests, fetching
/// nothing of any file; --patch fetches the changed file alone.
@("fsx.XD.againstATicket")
@system unittest
{
    import core.thread : Thread;
    import core.time : msecs, seconds, MonoTime;
    import std.process : environment;
    import sparkles.iroh_send.bridge : loadIrohSend, SendFile, SendPhase, SendState;
    import sparkles.test_runner.skip : skipTest;

    const path = environment.get("SPARKLES_IROH_SEND_LIB");
    if (path is null)
        return skipTest("SPARKLES_IROH_SEND_LIB is not set");
    auto lib = loadIrohSend(path);
    assert(lib.hasValue, lib.error);
    auto p = Pair.make("ticket");
    scope (exit) p.remove();
    write(buildPath(p.b, "big"), new ubyte[100_000]);
    SendFile[] files;
    foreach (name; ["same", "dir/run", "text", "new", "big"])
        files ~= SendFile("b/" ~ name, buildPath(p.b, name));
    mkdirRecurse(buildPath(p.top, "store"));
    auto session = lib.value.start(files, buildPath(p.top, "store"), noRelay: true);
    scope (exit) session.stop();
    SendState st;
    const deadline = MonoTime.currTime + 60.seconds;
    do
    {
        Thread.sleep(50.msecs);
        st = session.poll();
    }
    while (st.phase < SendPhase.serving && MonoTime.currTime < deadline);
    assert(st.phase == SendPhase.serving, st.error);

    // A collection has no executable bit and no link: `dir/run` differs from
    // the executable local one only by its bit, which the peer cannot carry.
    const r = run("fsdiff", p.b, "iroh:" ~ st.ticket, "--filter", "same | text | big | dir/run");
    assert(r.status == 1 && r.output == "M\tdir/run\n", r.output ~ r.error);
    Thread.sleep(200.msecs);
    assert(session.poll().bytesSent < 4096, text(session.poll().bytesSent));

    const patched = run("fsdiff", p.a, "iroh:" ~ st.ticket, "--filter", "text", "-p");
    assert(patched.output.canFind("\n-two\n+2\n"), patched.output ~ patched.error);
    Thread.sleep(200.msecs);
    assert(session.poll().bytesSent < 8192, "the changed file and the names, not the big one");
}
