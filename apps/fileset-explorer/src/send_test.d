/// The names in Stats and Send, recorded (`FXS1`–`FXS6`, `FXS8`).
module send_test;

import core.time : msecs;
import std.algorithm.searching : canFind;
import std.array : join, replicate, split;
import std.conv : text;
import std.digest.sha : SHA1, SHA256;

import sparkles.base.vfs.handles : ambientAuthority, openRoot;
import sparkles.base.vfs.mem : MemVfs;
import sparkles.base.vfs.types : Rights;
import sparkles.build_primitives.content_addressing.castore : CastoreScheme, toCastoreText;
import sparkles.build_primitives.content_addressing.collection : collectionOf, IrohCollectionScheme;
import sparkles.build_primitives.content_addressing.git : GitTreeScheme, toGitSri, toHex, toSwhid;
import sparkles.build_primitives.content_addressing.nar : NarScheme, toSri;
import sparkles.build_primitives.content_addressing.store_path : nixStorePath;
import sparkles.build_primitives.fileset.driver : InlineExecutor;
import sparkles.build_primitives.fileset.pattern : CasePolicy;
import sparkles.build_primitives.fileset.scheme : FsoRef, resolveScheme;
import sparkles.build_primitives.fileset.tree_literal : memTree;
import sparkles.build_primitives.fileset.value : Filesets;
import sparkles.input : charEvent, Event, Key, keyEvent, PointerAction, PointerButton, PointerEvent, Point;
import sparkles.iroh_send : SendFile, SendPhase, SendState;
import sparkles.test_runner.attributes : serial;
import sparkles.ui.geometry : Size;
import sparkles.ui_app.host : RunConfig;
import sparkles.ui_app.record : RecordingHost;
import sparkles.ui_app.run_app : runAppRecorded;

import evaluate : Root;
import explorer : ExplorerApp;
import render : keyScript, renderFrame;
import send : BlobProvider, SendStage;

private enum wide = Size(220, 60);

// What a scheme names the whole tree of `literal`, alone.
private auto alone(S)(string literal)
{
    auto tree = memTree(literal);
    auto dir = openRoot!(Rights.readOnly)(&tree.value.get().vfs, "", ambientAuthority());
    auto sets = Filesets(CasePolicy.sensitive);
    InlineExecutor exec;
    S scheme;
    return resolveScheme(dir.value.borrow, sets, sets.everything, scheme, exec).value;
}

/// FXS1: with the ids computed, Stats shows every name as the library
/// computes it alone, and the link a collection leaves out.
@("fileset_explorer.FXS1.namesInStats")
@system unittest
{
    enum literal = "src/a.d = module a;\nsrc/b.d = module b;\nREADME.md = hi\nl -> src/a.d\n";
    auto app = new ExplorerApp(Root(literal: literal, name: "t"), "all()");
    const o = app.shown;
    assert(o.hasIds);
    alias Ref = FsoRef!(MemVfs, Rights.readOnly);
    const nar = alone!(NarScheme!(SHA256, Ref))(literal);
    const git = alone!(GitTreeScheme!SHA1)(literal).digest;
    const collection = collectionOf(alone!IrohCollectionScheme(literal), "t").value;
    assert(o.castore == toCastoreText(alone!CastoreScheme(literal).digest)[]);
    assert(o.narHash == toSri(nar.digest)[]);
    assert(o.storePath == nixStorePath(nar.digest, "source").value);
    assert(o.gitTree == toHex(git)[] && o.gitSri == toGitSri(git)[] && o.swhid == toSwhid(git)[]);
    assert(o.collection == toHex(collection.root)[] && o.collectionLinks == 1);

    const frame = renderFrame(*app, "", wide);
    foreach (name; [o.castore, o.narHash, o.storePath, o.gitTree, o.gitSri, o.swhid, o.collection])
        assert(frame.canFind(name), name ~ "\n" ~ frame);
    assert(frame.canFind("iroh skips  1 link"), frame);
}

/// FXS1: a name that cannot be computed says why in its place.
@("fileset_explorer.FXS1.whyNot")
@system unittest
{
    auto app = new ExplorerApp(Root(literal: "a\\b = 1\n", name: "t"), "all()");
    assert(app.shown.collection.length == 0 && app.shown.collectionError.canFind("holds a `\\`"));
    assert(renderFrame(*app, "", wide).canFind("which a collection refuses"));
}

/// FXS2: a click on a name's line copies it and says so; Up and Down choose
/// a name and `y` copies it.
@("fileset_explorer.FXS2.copyAName")
@system unittest
{
    auto app = new ExplorerApp(Root(literal: "a = 1\n", name: "t"), "all()");
    Point at;
    foreach (y, line; renderFrame(*app, "", wide).split('\n'))
        if (const x = line.indexOfText(" store path"))
            at = Point(cast(int) x + 2, cast(int) y);
    assert(at.y > 0, "the store path's line is drawn");
    auto clicked = runAppRecorded(*app, RunConfig.init, [Event(PointerEvent(PointerAction.press,
        PointerButton.left, at)), Event(PointerEvent(PointerAction.release, PointerButton.left, at))],
        (ref RecordingHost h) @safe { h.size = wide; });
    assert(clicked.clipboardWrites == [app.shown.storePath], text(clicked.clipboardWrites));
    assert(renderFrame(*app, "", wide).canFind(app.shown.storePath ~ "  ✓ copied"));

    // The click left the side focused: Up to the first name, Down, y.
    auto keyed = runAppRecorded(*app, RunConfig.init, keyScript("<Up><Up><Up><Down>y"),
        (ref RecordingHost h) @safe { h.size = wide; });
    assert(keyed.clipboardWrites == [app.shown.narHash], text(keyed.clipboardWrites));
}

// ----------------------------------------------------------------- Send

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

// A directory of three files and a link, removed when the test ends.
private struct Fixture
{
    string dir;

    static Fixture make(string label)
    {
        import std.file : mkdirRecurse, symlink, tempDir, write;
        import std.path : buildPath;
        import std.process : thisProcessID;

        Fixture f;
        f.dir = buildPath(tempDir, text("fxs-", thisProcessID, "-", label), "proj");
        mkdirRecurse(buildPath(f.dir, "sub"));
        write(buildPath(f.dir, "a.d"), "module a;");
        write(buildPath(f.dir, "b.md"), "# b");
        write(buildPath(f.dir, "sub", "c.txt"), "c");
        symlink("a.d", buildPath(f.dir, "l"));
        return f;
    }

    void remove()
    {
        import std.file : rmdirRecurse;
        import std.path : dirName;

        rmdirRecurse(dirName(dir));
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

private SendState state(SendPhase phase, string collection, string ticket = null)
{
    SendState s;
    s.phase = phase;
    s.filesDone = phase == SendPhase.importing ? 1 : 3;
    s.bytesDone = 9;
    if (phase != SendPhase.importing)
    {
        s.hasHash = true;
        s.hash = fromHex(collection);
    }
    s.ticket = ticket;
    s.peers = phase == SendPhase.serving ? 1 : 0;
    s.requests = s.peers;
    s.bytesSent = phase == SendPhase.serving ? 19 : 0;
    return s;
}

// The explorer on the fixture, sending through `provider`.
private ExplorerApp* sender(ref Fixture f, Scripted provider)
{
    auto app = new ExplorerApp(Root(dir: f.dir), "all()");
    app.sending.makeProvider = (out string why) => cast(BlobProvider) provider;
    return app;
}

/// FXS3: `s` shows what would be sent and starts nothing; Escape returns;
/// `s` and Enter start the provider once, with each file's labelled name
/// and path, the link left out.
@("fileset_explorer.FXS3.asksFirst")
@system unittest
{
    import std.path : buildPath;

    auto f = Fixture.make("asks");
    scope (exit) f.remove();
    auto provider = new Scripted;
    provider.script = [SendState.init];
    auto app = sender(f, provider);

    const asking = renderFrame(*app, "\t\ts", wide);
    assert(app.sending.stage == SendStage.asking);
    assert(asking.canFind("files       3 (") && asking.canFind("left out    1 link"), asking);
    assert(asking.canFind(app.shown.collection) && asking.canFind("anyone with the ticket"), asking);
    renderFrame(*app, "<Esc>", wide);
    assert(app.sending.stage == SendStage.idle && provider.starts == 0, "Escape sent nothing");

    renderFrame(*app, "s<Enter>", wide);
    assert(provider.starts == 1 && app.sending.stage == SendStage.running);
    assert(provider.started == [SendFile("proj/a.d", buildPath(f.dir, "a.d")),
        SendFile("proj/b.md", buildPath(f.dir, "b.md")), SendFile("proj/sub/c.txt", buildPath(f.dir, "sub/c.txt"))],
        text(provider.started));
}

/// FXS4: each phase shows, the receive command once serving, wrapped whole;
/// frames come back with no input while it runs; `y` copies the command and
/// `x` stops the provider.
@("fileset_explorer.FXS4.whileSending")
@system unittest
{
    auto f = Fixture.make("while");
    scope (exit) f.remove();
    auto provider = new Scripted;
    auto app = sender(f, provider);
    const c = app.shown.collection;
    enum ticket = "blob" ~ "abcdefghij" ~ "abcdefghij" ~ "abcdefghij" ~ "abcdefghij" ~ "abcdefghij" ~ "abcdefghij"
        ~ "abcdefghij" ~ "abcdefghij" ~ "abcdefghij" ~ "abcdefghij" ~ "END";
    provider.script = [state(SendPhase.importing, c), state(SendPhase.online, c),
        state(SendPhase.serving, c, ticket)];

    const importing = renderFrame(*app, "\t\ts<Enter>", wide);
    assert(importing.canFind("importing 1 of 3 files"), importing);
    auto idle = runAppRecorded(*app, RunConfig.init, null, (ref RecordingHost h) @safe { h.size = wide; });
    assert(idle.frames[$ - 1].wakeAsk == 250.msecs, "a running send wakes the explorer");
    const serving = renderFrame(*app, "", wide);
    assert(serving.canFind("serving") && serving.canFind("sendme receive blobabcdefghij"), serving);
    assert(serving.canFind("abcdefghijEND"), "the ticket wraps, whole:\n" ~ serving);
    assert(serving.canFind("1 connected · 1 requests · 19 B sent"), serving);

    auto copied = runAppRecorded(*app, RunConfig.init, keyScript("y"),
        (ref RecordingHost h) @safe { h.size = wide; });
    assert(copied.clipboardWrites == ["sendme receive " ~ ticket], text(copied.clipboardWrites));
    renderFrame(*app, "x", wide);
    assert(provider.stopped && app.sending.stage == SendStage.idle);
}

/// FXS5: an edit while sending changes nothing sent, and names the sent query.
@("fileset_explorer.FXS5.snapshot")
@system unittest
{
    auto f = Fixture.make("snapshot");
    scope (exit) f.remove();
    auto provider = new Scripted;
    auto app = sender(f, provider);
    provider.script = [state(SendPhase.serving, app.shown.collection, "blobT")];
    renderFrame(*app, "\t\ts<Enter>", wide);
    const sent = provider.started.dup;
    // Tab back to the query, and narrow it.
    const edited = renderFrame(*app, "\t - **/*.md", wide);
    assert(app.shown.found.members.length < 4, text(app.shown.found.members.length));
    assert(provider.started == sent && provider.starts == 1);
    assert(edited.canFind("sent query  all()"), edited);
}

/// FXS6: a provider that names another collection is stopped, and the error
/// shows both names.
@("fileset_explorer.FXS6.theCollectionsAgree")
@system unittest
{
    auto f = Fixture.make("agree");
    scope (exit) f.remove();
    auto provider = new Scripted;
    auto app = sender(f, provider);
    enum other = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff";
    provider.script = [state(SendPhase.online, other)];
    const frame = renderFrame(*app, "\t\ts<Enter>", wide);
    assert(provider.stopped && app.sending.stage == SendStage.unavailable);
    assert(frame.canFind("the provider named the collection"), frame);
    assert(app.sending.note.canFind(other) && app.sending.note.canFind(app.shown.collection), app.sending.note);
}

/// FXS8: without the bridge, Send says why and starts nothing; the names stay.
@("fileset_explorer.FXS8.withoutTheBridge")
@serial @system unittest
{
    import std.process : environment;

    auto f = Fixture.make("bridge");
    scope (exit) f.remove();
    const was = environment.get("SPARKLES_IROH_SEND_LIB");
    environment["SPARKLES_IROH_SEND_LIB"] = "/nonexistent/libsparkles_iroh_send.so";
    scope (exit)
    {
        if (was is null)
            environment.remove("SPARKLES_IROH_SEND_LIB");
        else
            environment["SPARKLES_IROH_SEND_LIB"] = was;
    }
    auto app = new ExplorerApp(Root(dir: f.dir), "all()");
    const frame = renderFrame(*app, "\t\ts<Enter>", wide);
    assert(app.sending.stage == SendStage.unavailable, text(app.sending.stage));
    assert(frame.canFind("sending is unavailable: cannot load /nonexistent"), frame);
    assert(frame.canFind(app.shown.storePath), "the names are still shown");
}

/// FXS3: a tutorial's tree is in memory, so there is nothing to send.
@("fileset_explorer.FXS3.notFromMemory")
@system unittest
{
    auto app = new ExplorerApp(Root(literal: "a = 1\n", name: "t"), "all()");
    const frame = renderFrame(*app, "\t\ts", wide);
    assert(app.sending.stage == SendStage.unavailable && frame.canFind("held in memory"), frame);
}

/// FXS3, FXS4 on the touch layout: Send, then Send again, starts the
/// provider; Copy copies the receive command and Stop stops it.
@("fileset_explorer.FXS3.touchButtons")
@system unittest
{
    auto f = Fixture.make("touch");
    scope (exit) f.remove();
    auto provider = new Scripted;
    auto app = sender(f, provider);
    app.layout = ExplorerApp.Layout.touch;
    provider.script = [state(SendPhase.serving, app.shown.collection, "blobTOUCH")];
    enum tablet = Size(140, 60);

    RecordingHost tapOn(string label, size_t nth = 0)
    {
        Point at;
        size_t seen;
        foreach (y, line; renderFrame(*app, "", tablet).split('\n'))
            if (const x = line.indexOfText(label))
                if (seen++ == nth)
                {
                    at = Point(cast(int) x + 1, cast(int) y);
                    break;
                }
        assert(at.y > 0, label ~ " is not on the frame:\n" ~ renderFrame(*app, "", tablet));
        return runAppRecorded(*app, RunConfig.init, [Event(PointerEvent(PointerAction.press, PointerButton.left, at)),
            Event(PointerEvent(PointerAction.release, PointerButton.left, at))],
            (ref RecordingHost h) @safe { h.size = tablet; });
    }

    tapOn("Send");
    assert(app.sending.stage == SendStage.asking && provider.starts == 0, text(app.sending.stage));
    tapOn("Send");
    assert(provider.starts == 1 && app.sending.stage == SendStage.running);
    // A Stats tab longer than its pane drops its last lines rather than
    // drawing its first ones over each other (as the tablet did with a
    // ticket of five lines).
    auto longTicket = new SendState[1];
    longTicket[0] = state(SendPhase.serving, app.shown.collection, "blob" ~ "x".replicate(400));
    provider.script = longTicket;
    foreach (short_; [Size(140, 30), Size(140, 24)])
    {
        const frame = renderFrame(*app, "", short_);
        assert(frame.canFind("members     4") && frame.canFind("files       3"), frame);
    }
    provider.script = [state(SendPhase.serving, app.shown.collection, "blobTOUCH")];
    renderFrame(*app, "", tablet);
    const copied = tapOn("Copy");
    assert(copied.clipboardWrites == ["sendme receive blobTOUCH"], text(copied.clipboardWrites));
    tapOn("Stop");
    assert(provider.stopped && app.sending.stage == SendStage.idle);
}

// Where `needle` starts in `line`, in cells; 0 when it does not (the line's
// first cell is the frame's border, never a match).
private size_t indexOfText(string line, string needle) @safe
{
    import std.string : indexOf;
    import std.utf : count;

    const at = line.indexOf(needle);
    return at < 0 ? 0 : line[0 .. at].count;
}
