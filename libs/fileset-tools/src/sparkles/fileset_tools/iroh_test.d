/**
Copying from an iroh peer (`XS3`, `XS4`, `XV3`, `XR`, docs/specs/fsx), the
peer being the bridge's own send half in this process, on loopback with
relays disabled. `$SPARKLES_IROH_SEND_LIB` names the bridge.
*/
module sparkles.fileset_tools.iroh_test;

version (unittest):
version (Posix):

import core.thread : Thread;
import core.time : msecs, seconds, MonoTime;
import std.algorithm.searching : canFind;
import std.conv : text;
import std.file : exists, mkdirRecurse, read, rmdirRecurse, tempDir, write;
import std.format : format;
import std.path : buildPath, dirName;
import std.process : environment, thisProcessID;

import sparkles.iroh_send.bridge : IrohSend, loadIrohSend, SendFile, SendPhase, SendSession, SendState;
import sparkles.test_runner.skip : skipTest;

import sparkles.fileset_tools.commands : copyCommand, CopyOptions;
import sparkles.fileset_tools.evaluate : evaluate, Root;

// Serves `files` and waits until the ticket is ready.
private SendSession serve(IrohSend lib, SendFile[] files, string store, out string ticket)
{
    auto session = lib.start(files, store, noRelay: true);
    SendState st;
    const deadline = MonoTime.currTime + 60.seconds;
    do
    {
        Thread.sleep(50.msecs);
        st = session.poll();
    }
    while (st.phase < SendPhase.serving && MonoTime.currTime < deadline);
    assert(st.phase == SendPhase.serving, st.error);
    ticket = st.ticket;
    return session;
}

/**
XR3, XV3: `fscp` from a ticket writes the filter's files alone, verified
against the collection's digests, with the label removed; the provider
sends them and the names, and nothing of the others. XS4: a git call is
refused, and nothing is fetched.
*/
@("fileset_tools.iroh.XR.copyFromPeer")
@system unittest
{
    const path = environment.get("SPARKLES_IROH_SEND_LIB");
    if (path is null)
        return skipTest("SPARKLES_IROH_SEND_LIB is not set");
    auto lib = loadIrohSend(path);
    assert(lib.hasValue, lib.error);

    const base = buildPath(tempDir, text("fst-iroh-", thisProcessID));
    if (exists(base))
        rmdirRecurse(base);
    const src = buildPath(base, "src"), store = buildPath(base, "store");
    scope (exit) rmdirRecurse(base);
    SendFile[] files;
    ulong selected;
    foreach (i; 0 .. 50)
    {
        const rel = format!"%s/f%02d.txt"(i < 5 ? "a" : "b", i);
        auto bytes = new ubyte[i == 2 ? 200_000 : 50 + 13 * i];
        foreach (k, ref b; bytes)
            b = cast(ubyte)(k * 7 + i);
        mkdirRecurse(dirName(buildPath(src, rel)));
        write(buildPath(src, rel), bytes);
        files ~= SendFile("tree/" ~ rel, buildPath(src, rel));
        if (i < 5)
            selected += bytes.length;
    }
    mkdirRecurse(store);
    string ticket;
    auto session = serve(lib.value, files, store, ticket);
    scope (exit) session.stop();

    CopyOptions o;
    o.ticket = ticket;
    o.noRelay = true;
    o.bridgePath = path;
    o.filter = "a/**";
    o.dest = buildPath(base, "out");
    o.stats = true;
    string output, error;
    assert(copyCommand(o, output, error) == 0, error);
    assert(error.canFind("`tree` from the peer lists 50 files; the filter selects 5"), error);
    assert(error.canFind("fscp: copied 5 files"), error);
    assert(error.canFind("fscp: verified: castore blake3-"), error);
    foreach (i; 0 .. 5)
    {
        const rel = format!"a/f%02d.txt"(i);
        assert(read(buildPath(o.dest, rel)) == read(buildPath(src, rel)), rel);
    }
    assert(!exists(buildPath(o.dest, "b")) && !exists(buildPath(o.dest, "tree")), "the label is not copied");

    // The castore id is the one the same files have locally (XV3).
    const local = evaluate(Root(dir: buildPath(src)), "a/**", withIds: true);
    assert(error.canFind("castore " ~ local.castore), error ~ "\n" ~ local.castore);

    // The provider sent the five files and the names, nothing of the 45 others.
    Thread.sleep(200.msecs);
    const sent = session.poll().bytesSent;
    assert(sent >= selected && sent < selected + 4096, text(sent, " for ", selected));

    // XS4: gitTracked() has no meaning over a collection.
    o.filter = "gitTracked()";
    o.dest = buildPath(base, "git");
    assert(copyCommand(o, output, error) == 1);
    assert(error.canFind("needs a git repository"), error);
    assert(!exists(o.dest));
}
