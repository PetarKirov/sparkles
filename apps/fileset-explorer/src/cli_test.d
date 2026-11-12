/// The command line's subcommands (`FXC1`–`FXC3`).
module cli_test;

import std.algorithm.iteration : filter;
import std.algorithm.searching : canFind, startsWith;
import std.array : array, join, split;
import std.conv : text;
import std.sumtype : match;

import sparkles.core_cli.args : parseCli;
import sparkles.iroh_send : SendFile, SendPhase, SendState;

import copy : CopyVfs;
import cli : Cp, cpCommand, Emit, Explorer, SendCommand, sendCommand, SendIo, StatsCommand, statsCommand, View;
import evaluate : Root;
import explorer : ExplorerApp;
import send : BlobProvider;
import stats : formatStats;

/// FXC1: no subcommand is `view`; `--dir` and `--query` go on either side of
/// a subcommand; `--help` lists the four.
@("fileset_explorer.FXC1.subcommands")
@system unittest
{
    auto bare = parseCli!Explorer(["fileset-explorer", "--query", "src/**", "--render-plain"]);
    assert(bare, bare.error.message);
    assert(bare.value.query == "src/**");
    assert(bare.value.command.match!((ref View v) => v.renderPlain, (ref _) => false), "the default is view");

    foreach (args; [["fileset-explorer", "--dir", "d", "stats"], ["fileset-explorer", "stats", "--dir", "d"]])
    {
        auto parsed = parseCli!Explorer(args);
        assert(parsed, parsed.error.message);
        assert(parsed.value.dir == "d", args.join(" "));
        assert(parsed.value.command.match!((ref StatsCommand _) => true, (ref _) => false), args.join(" "));
    }
    auto emit = parseCli!Explorer(["fileset-explorer", "emit", "nix", "--query", "q", "--nix-globs", "expand"]);
    assert(emit, emit.error.message);
    assert(emit.value.command.match!((ref Emit e) => e.target == "nix" && e.nixGlobs == "expand", (ref _) => false));
    auto sending = parseCli!Explorer(["fileset-explorer", "send", "--yes", "--no-relay"]);
    assert(sending, sending.error.message);
    assert(sending.value.command.match!((ref SendCommand s) => s.yes && s.noRelay, (ref _) => false));

    auto help = parseCli!Explorer(["fileset-explorer", "--help"]);
    assert(!help && help.error.isHelp);
    auto cp = parseCli!Explorer(["fileset-explorer", "cp", "out", "--force", "--dry-run"]);
    assert(cp, cp.error.message);
    assert(cp.value.command.match!((ref Cp c) => c.dest == "out" && c.force && c.dryRun, (ref _) => false));

    foreach (sub; ["view", "stats", "send", "emit", "cp"])
        assert(help.error.help.canFind(sub), sub);
}

// A directory of files, removed when the test ends.
private struct Fixture
{
    string dir;

    static Fixture make(string label, string[string] files)
    {
        import std.file : mkdirRecurse, tempDir, write;
        import std.path : buildPath, dirName;
        import std.process : thisProcessID;

        Fixture f;
        f.dir = buildPath(tempDir, text("fxc-", thisProcessID, "-", label), "proj");
        foreach (name, contents; files)
        {
            mkdirRecurse(dirName(buildPath(f.dir, name)));
            write(buildPath(f.dir, name), contents);
        }
        return f;
    }

    void remove()
    {
        import std.file : rmdirRecurse;
        import std.path : dirName;

        rmdirRecurse(dirName(dir));
    }
}

// The lines but the wall time, which differs between two resolutions.
private string[] untimed(string s) => s.split('\n').filter!(l => !l.startsWith("resolved in")).array;

/// FXC2: `stats` prints the Stats tab's lines without its Send section,
/// names included; a query that does not parse exits 1.
@("fileset_explorer.FXC2.stats")
@system unittest
{
    auto f = Fixture.make("stats", ["src/a.d": "module a;", "src/b.d": "module b;", "README.md": "# r"]);
    scope (exit) f.remove();
    string output, error;
    assert(statsCommand(Root(dir: f.dir), "src/**", false, output, error) == 0, error);
    auto app = new ExplorerApp(Root(dir: f.dir), "src/**");
    assert(untimed(output) == untimed(formatStats(app.statsLinesAlone())), output);
    assert(output.canFind("members     2\n") && output.canFind("store path  /nix/store/"), output);
    assert(output.canFind("iroh        " ~ app.shown.collection), output);
    assert(!output.canFind("send"), "no Send section");

    assert(statsCommand(Root(dir: f.dir), "(src", false, output, error) == 1);
    assert(error.startsWith("fileset-explorer: ") && output.length == 0, error);
}

/// FXC2: over the live limit the names wait for `--ids`.
@("fileset_explorer.FXC2.ids")
@system unittest
{
    import evaluate : autoIdBytes;

    char[] big = new char[autoIdBytes + 1];
    big[] = 'x';
    auto f = Fixture.make("ids", ["big": big.idup]);
    scope (exit) f.remove();
    string output, error;
    assert(statsCommand(Root(dir: f.dir), "all()", false, output, error) == 0, error);
    assert(output.canFind("ids         over 32.0 MiB: stats --ids computes them") && !output.canFind("castore"),
        output);
    assert(statsCommand(Root(dir: f.dir), "all()", true, output, error) == 0, error);
    assert(output.canFind("castore     blake3-") && output.canFind("store path  /nix/store/"), output);
}

// ----------------------------------------------------------------- send

// A provider that plays `script`, one state a poll, and records its calls.
private final class Scripted : BlobProvider
{
    SendFile[] started;
    size_t starts;
    bool stopped;
    SendState[] script;
    private size_t at;

    void start(in SendFile[] files)
    {
        started = files.dup;
        ++starts;
    }

    SendState poll()
    {
        const s = script[at < script.length ? at : $ - 1];
        if (at < script.length)
            ++at;
        return s;
    }

    void stop()
    {
        stopped = true;
    }
}

// `send`'s outputs, and an interrupt after `polls` waits.
private struct Recorded
{
    string[] out_, err;
    size_t waits;
    size_t polls = 3;
    bool asked;
    bool answer;

    SendIo io(bool interactive) return
    {
        SendIo io;
        io.out_ = (string s) { out_ ~= s; };
        io.err = (string s) { err ~= s; };
        io.interrupted = () => waits >= polls;
        io.wait = (d) { ++waits; };
        io.interactive = interactive;
        io.ask = (string q) { asked = true; return answer; };
        return io;
    }
}

private ubyte[32] fromHex(string hex) @safe pure
{
    import std.conv : to;

    ubyte[32] b;
    foreach (i; 0 .. 32)
        b[i] = hex[2 * i .. 2 * i + 2].to!ubyte(16);
    return b;
}

private SendState serving(string collection, string ticket)
{
    SendState s;
    s.phase = SendPhase.serving;
    s.hasHash = true;
    s.hash = fromHex(collection);
    s.ticket = ticket;
    s.peers = 1;
    s.bytesSent = 42;
    return s;
}

/// FXC3: `send --yes` starts the provider once with the members, prints the
/// receive command alone on standard output, and stops it when interrupted.
@("fileset_explorer.FXC3.sendYes")
@system unittest
{
    import std.path : buildPath;

    auto f = Fixture.make("send", ["a.d": "module a;", "sub/b.md": "# b"]);
    scope (exit) f.remove();
    const collection = new ExplorerApp(Root(dir: f.dir), "all()").shown.collection; // the ids, live
    auto provider = new Scripted;
    provider.script = [serving(collection, "blobCLI")];
    Recorded r;
    auto io = r.io(interactive: false);
    const status = sendCommand(Root(dir: f.dir), "all()", true, (out string why) => cast(BlobProvider) provider, io);
    assert(status == 0, r.err.join);
    assert(r.out_ == ["sendme receive blobCLI\n"], text(r.out_));
    assert(provider.starts == 1 && provider.stopped);
    assert(provider.started == [SendFile("proj/a.d", buildPath(f.dir, "a.d")),
        SendFile("proj/sub/b.md", buildPath(f.dir, "sub/b.md"))], text(provider.started));
    const err = r.err.join;
    assert(err.canFind("send: 2 files") && err.canFind("send: collection " ~ collection)
        && err.canFind("anyone with the ticket") && err.canFind("send: serving")
        && err.canFind("1 connected") && err.canFind("send: stopped"), err);
}

/// FXC3: without `--yes`, nothing starts without a terminal, nor when the
/// person answers no; a failing provider exits 1 with its reason.
@("fileset_explorer.FXC3.sendRefuses")
@system unittest
{
    auto f = Fixture.make("refuse", ["a.d": "module a;"]);
    scope (exit) f.remove();
    auto provider = new Scripted;
    provider.script = [SendState.init];
    auto make = (out string why) => cast(BlobProvider) provider;

    Recorded noTerminal;
    auto io = noTerminal.io(interactive: false);
    assert(sendCommand(Root(dir: f.dir), "all()", false, make, io) == 1);
    assert(provider.starts == 0 && noTerminal.err.join.canFind("--yes"), noTerminal.err.join);

    Recorded no;
    auto asking = no.io(interactive: true);
    assert(sendCommand(Root(dir: f.dir), "all()", false, make, asking) == 1);
    assert(no.asked && provider.starts == 0);

    SendState failed;
    failed.phase = SendPhase.failed;
    failed.error = "boom";
    provider.script = [failed];
    Recorded r;
    auto io2 = r.io(interactive: false);
    assert(sendCommand(Root(dir: f.dir), "all()", true, make, io2) == 1);
    assert(r.err.join.canFind("the send failed: boom"), r.err.join);

    Recorded memory;
    auto io3 = memory.io(interactive: false);
    assert(sendCommand(Root(literal: "a = 1\n", name: "t"), "all()", true, make, io3) == 1);
    assert(memory.err.join.canFind("held in memory"), memory.err.join);
}

// ------------------------------------------------------------------- cp

/**
FXC5: `cp` copies an executable file and a link as they are, and leaves out
what the query does not select, so the copy, resolved whole, has the
fileset's castore, NAR and git ids; a second `cp` copies nothing over it,
naming the paths; `--force` replaces them; `--dry-run` copies nothing.
*/
@("fileset_explorer.FXC5.cp")
@system unittest
{
    import std.conv : octal;
    import std.file : exists, getAttributes, isSymlink, readLink, readText, setAttributes, symlink, write;
    import std.path : buildPath, dirName;

    import evaluate : evaluate;

    enum query = "src/** | l";
    auto f = Fixture.make("cp", ["src/a.d": "module a;", "src/deep/b.d": "module b;", "src/run": "#!/bin/sh",
        "skip.txt": "left out"]);
    scope (exit) f.remove();
    setAttributes(buildPath(f.dir, "src/run"), octal!755);
    symlink("src/a.d", buildPath(f.dir, "l"));
    const theirs = evaluate(Root(dir: f.dir), query, withIds: true);

    // Over each backend of the capability VFS, the same copy.
    foreach (vfs; [CopyVfs.blocking, CopyVfs.ring])
    {
        const dest = buildPath(dirName(f.dir), text("out-", vfs));
        string output, error;
        assert(cpCommand(Root(dir: f.dir), query, dest, false, false, output, error, vfs) == 0, error);
        assert(error.startsWith("cp: copied 3 files (27 B) and 1 link to " ~ dest ~ " in "), error);
        assert(error.canFind(vfs == CopyVfs.ring ? "(RingVfs, " : "(BlockingVfs)"), error);
        if (vfs == CopyVfs.ring) // the files overlap: their calls park fibers, not the thread
            assert(!error.canFind("(RingVfs, 0 ") && !error.canFind("(RingVfs, 1 "), error);
        assert(readText(buildPath(dest, "src/deep/b.d")) == "module b;");
        assert(getAttributes(buildPath(dest, "src/run")) & octal!100, "the executable bit");
        assert(!(getAttributes(buildPath(dest, "src/a.d")) & octal!100));
        assert(isSymlink(buildPath(dest, "l")) && readLink(buildPath(dest, "l")) == "src/a.d");
        assert(!exists(buildPath(dest, "skip.txt")), "a file the query leaves out is not copied");

        // The copy is the tree the ids name.
        const copied = evaluate(Root(dir: dest), "all()", withIds: true);
        assert(copied.castore == theirs.castore && copied.narHash == theirs.narHash
            && copied.gitTree == theirs.gitTree, text(vfs, ": ", copied.castore, " ", theirs.castore));

        // Again: every path exists, and nothing is copied over them.
        write(buildPath(dest, "src/a.d"), "changed");
        assert(cpCommand(Root(dir: f.dir), query, dest, false, false, output, error, vfs) == 1);
        assert(error.canFind("copied nothing: 4 paths exist") && error.canFind(buildPath(dest, "l")), error);
        assert(readText(buildPath(dest, "src/a.d")) == "changed");
        assert(cpCommand(Root(dir: f.dir), query, dest, true, false, output, error, vfs) == 0, error);
        assert(readText(buildPath(dest, "src/a.d")) == "module a;", "--force replaces it");
        assert(isSymlink(buildPath(dest, "l")), "and the link stays a link");
    }
    string output, error;

    // A dry run lists the paths, and copies nothing.
    const fresh = buildPath(dirName(f.dir), "fresh");
    assert(cpCommand(Root(dir: f.dir), query, fresh, false, true, output, error) == 0, error);
    assert(output.split('\n').length == 5 && output.canFind(buildPath(fresh, "src/run")), output);
    assert(error.canFind("would copy 3 files") && !exists(fresh), error);
}

/**
FXC5, `VFO10`: a link with an absolute target stops `cp` before it copies
anything, naming it, unless the target falls beneath a `--link-root`; then
it is made through that root, holding the root's real path, over each
backend. A root that cannot be opened stops it too.
*/
@("fileset_explorer.FXC5.cpLinkRoot")
@system unittest
{
    import std.algorithm.searching : endsWith;
    import std.file : exists, isSymlink, mkdirRecurse, readLink, readText, symlink, write;
    import std.path : buildPath, dirName;

    auto f = Fixture.make("cp-link-root", ["a.d": "module a;"]);
    scope (exit) f.remove();
    const store = buildPath(dirName(f.dir), "store-real");
    mkdirRecurse(buildPath(store, "pkg"));
    write(buildPath(store, "pkg", "x"), "x");
    const via = buildPath(dirName(f.dir), "store");
    symlink(store, via);
    symlink(buildPath(via, "pkg/x"), buildPath(f.dir, "abs"));
    symlink("/etc/hostname", buildPath(f.dir, "etc"));

    string output, error;
    const refused = buildPath(dirName(f.dir), "out-refused");
    assert(cpCommand(Root(dir: f.dir), "all()", refused, false, false, output, error) == 1);
    assert(error.canFind("copied nothing: 2 links point outside") && error.canFind("abs -> " ~ via), error);
    assert(!exists(refused), "nothing copied, not even the directory");
    assert(cpCommand(Root(dir: f.dir), "all()", refused, false, true, output, error, CopyVfs.blocking, 16,
        [via]) == 1, "a dry run refuses as the copy would");
    assert(error.canFind("1 link points") && error.canFind("etc -> /etc/hostname"), error);
    assert(cpCommand(Root(dir: f.dir), "all()", refused, false, false, output, error, CopyVfs.blocking, 16,
        [buildPath(dirName(f.dir), "absent")]) == 1);
    assert(error.startsWith("cp: --link-root "), error);

    foreach (vfs; [CopyVfs.blocking, CopyVfs.ring])
    {
        const dest = buildPath(dirName(f.dir), text("out-root-", vfs));
        assert(cpCommand(Root(dir: f.dir), "a.d | abs", dest, false, false, output, error, vfs, 16, [via]) == 0,
            error);
        assert(error.canFind("1 file (9 B) and 1 link"), error);
        assert(isSymlink(buildPath(dest, "abs")));
        const held = readLink(buildPath(dest, "abs"));
        assert(held.endsWith("/store-real/pkg/x"), "the root's real path, not the text in the tree: " ~ held);
        assert(readText(buildPath(dest, "abs")) == "x");
    }
}
