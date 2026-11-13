/**
The iroh bridge: `sendme send`, as a library loaded at run time.

`libsparkles_iroh_send.so` is iroh's own code, built inside `sendme`'s
source tree (`libs/iroh-send/rust`, `nix/packages/sparkles-iroh-send.nix`).
It imports the files it is given into an iroh-blobs store, names their
collection as `sendme` names a directory's, serves it over iroh's blobs
protocol, and hands out the ticket `sendme receive` takes. This module loads
it with `dlopen` and wraps its C interface: nothing links it, so a program
that uses it runs without it and says why sending is unavailable (fileset
explorer `FXS8`, decision `X18`).

$(UL
$(LI $(LREF loadIrohSend) opens the library, by the path in
    `$SPARKLES_IROH_SEND_LIB`, beside the program in `../lib`, or by its
    bare name.)
$(LI $(LREF IrohSend.start) starts a $(LREF SendSession), which runs on the
    library's own threads; $(LREF SendSession.poll) reads where it is.)
$(LI $(LREF IrohSend.collection) names the collection of a list of files
    with no network, as the send would.)
$(LI $(LREF IrohSend.receive) opens a collection a peer serves: its names,
    digests and proved sizes first, then the chosen files' verified bytes,
    as $(LREF Receiver.next) hands them out (`fsx` `XR`, docs/specs/fsx).)
)
*/
module sparkles.iroh_send.bridge;

import sparkles.base.expected : Expected, err, ok;

/// The interface version this module speaks; a library with another is refused.
enum uint irohSendAbi = 3;

/// The library's file name, as Rust names a `cdylib` on this platform;
/// `dlopen` searches for it when no path is given.
version (OSX)
    enum string irohSendLibraryName = "libsparkles_iroh_send.dylib";
else
    enum string irohSendLibraryName = "libsparkles_iroh_send.so";

/// One file to send: its name in the collection, and its path on disk.
struct SendFile
{
    string name; ///
    string path; ///
}

/// Where a send is.
enum SendPhase : uint
{
    importing, /// hashing the files into the store
    online,    /// the collection is named; finding the endpoint's addresses
    serving,   /// the ticket is ready and peers may fetch
    failed,    /// it ended with an error
    stopped,   /// it was stopped
}

/// What a send has done.
struct SendState
{
    SendPhase phase;  ///
    ulong filesDone;  /// files imported
    ulong filesTotal; ///
    ulong bytesDone;  /// bytes imported
    bool hasHash;     /// whether `hash` is the collection's name yet
    ubyte[32] hash;   /// the collection's name
    ulong peers;      /// peers connected now
    ulong requests;   /// requests served
    ulong bytesSent;  /// bytes sent to peers so far
    string ticket;    /// the `BlobTicket`, once serving
    string error;     /// why it failed
}

/// One file of a collection a peer serves.
struct ReceiveEntry
{
    string name;    /// as the collection lists it, the label first
    ubyte[32] hash; /// BLAKE3 of its bytes
}

/// What `Receiver.next` handed out.
enum ReceiveEvent : int
{
    done = 0,   /// every chosen file has ended
    start = 1,  /// a file begins: `index`, and the size the peer states in `length`
    data = 2,   /// `length` verified bytes of file `index` at `offset`
    end = 3,    /// file `index` has ended, its last chunk verified, so its size proved
    error = -1, /// `Receiver.error` says why; nothing more follows
}

/// The bytes read from the peer so far.
struct ReceiveStats
{
    ulong payloadBytesRead; /// file and metadata bytes
    ulong otherBytesRead;   /// hashes and headers
}

/// The loaded library.
struct IrohSend
{
    private Api api;

    /**
    Connects to the node `ticket` names and reads its collection's names and
    digests (`XR2`), and nothing else. The receiver holds
    the reason when that fails, and lists nothing.
    */
    Receiver receive(string ticket, bool noRelay = false) @trusted
    {
        auto r = api.receive_open(cast(const(ubyte)*) ticket.ptr, ticket.length, noRelay ? 1 : 0);
        return Receiver(api, r);
    }

    /**
    Starts sending `files`, keeping the library's store beneath
    `storeParent` (the system's temporary directory when empty); with
    `noRelay` the ticket carries direct addresses only.
    */
    SendSession start(in SendFile[] files, string storeParent = null, bool noRelay = false) @trusted
    {
        auto c = cFiles(files);
        auto s = api.start(c.ptr, c.length, storeParent.ptr, storeParent.length, noRelay ? 1 : 0);
        return SendSession(api, s);
    }

    /**
    Hands the library the app's `JavaVM` and a global reference to its
    application `Context`, which iroh reads the system's DNS servers through
    on Android; without them a send there aborts. Call it once, before the
    first `start`; it does nothing elsewhere.
    */
    void installAndroidContext(void* javaVm, void* applicationContext) @system
    {
        api.android_context(javaVm, applicationContext);
    }

    /// The name of the collection of `files`, as the send would import and
    /// name them, computed with no network.
    Expected!(ubyte[32], string) collection(in SendFile[] files) @trusted
    {
        auto c = cFiles(files);
        ubyte[32] hash;
        char[1024] why;
        size_t whyLength;
        if (api.collection(c.ptr, c.length, hash.ptr, why.ptr, why.length, &whyLength) == 0)
            return ok!string(hash);
        return err!(ubyte[32])(why[0 .. whyLength < why.length ? whyLength : why.length].idup);
    }
}

/// A running send; `stop` ends it and frees it.
struct SendSession
{
    private Api api;
    private void* session;

    /// Where the send is.
    SendState poll() @trusted
    {
        CStatus s;
        api.status(session, &s);
        SendState st;
        st.phase = cast(SendPhase) s.phase;
        st.filesDone = s.filesDone;
        st.filesTotal = s.filesTotal;
        st.bytesDone = s.bytesDone;
        st.hasHash = s.hasHash != 0;
        st.hash = s.hash;
        st.peers = s.peers;
        st.requests = s.requests;
        st.bytesSent = s.bytesSent;
        st.ticket = text(0);
        st.error = text(1);
        return st;
    }

    /// Stops the send and waits for it to end; the session is then gone.
    void stop() @trusted
    {
        if (session is null)
            return;
        api.stop(session);
        session = null;
    }

    /// Whether the session is still held.
    bool live() const @safe pure nothrow @nogc => session !is null;

    private string text(uint which) @system
    {
        char[512] buf;
        const n = api.text(session, which, cast(ubyte*) buf.ptr, buf.length);
        if (n <= buf.length)
            return buf[0 .. n].idup;
        auto big = new char[n];
        api.text(session, which, cast(ubyte*) big.ptr, big.length);
        return cast(string) big;
    }
}

/**
A collection a peer serves, open; `close` ends it and frees it.

After `fetch`, `next` hands out the chosen files in the collection's order:
each one's `start`, its `data` in order, every piece verified against the
file's BLAKE3 tree before it is handed out (`XR4`), and its `end`.
*/
struct Receiver
{
    private Api api;
    private void* receiver;

    /// Why it failed, or `null`.
    string error() @trusted
    {
        char[512] buf;
        const n = api.receive_text(receiver, cast(ubyte*) buf.ptr, buf.length);
        if (n == 0)
            return null;
        if (n <= buf.length)
            return buf[0 .. n].idup;
        auto big = new char[n];
        api.receive_text(receiver, cast(ubyte*) big.ptr, big.length);
        return cast(string) big;
    }

    /// The collection's files, in its order.
    ReceiveEntry[] entries() @trusted
    {
        auto list = new ReceiveEntry[api.receive_count(receiver)];
        foreach (i, ref e; list)
        {
            CEntry c;
            api.receive_entry(receiver, i, &c);
            e = ReceiveEntry(c.name[0 .. c.nameLength].idup, c.hash);
        }
        return list;
    }

    /// Asks for the files at `indices`, ascending, whole (`XR3`).
    Expected!(bool, string) fetch(const(ulong)[] indices) @trusted
    {
        if (api.receive_fetch(receiver, indices.ptr, indices.length) == 0)
            return ok!string(true);
        return err!bool(error());
    }

    /// Waits for what arrives next; `data` writes into `buffer`.
    ReceiveEvent next(out ulong index, out ulong offset, ubyte[] buffer, out size_t length) @trusted
    {
        return cast(ReceiveEvent) api.receive_next(receiver, &index, &offset, buffer.ptr, buffer.length, &length);
    }

    /// The bytes read so far.
    ReceiveStats stats() @trusted
    {
        CReceiveStats s;
        api.receive_stats(receiver, &s);
        return ReceiveStats(s.payloadBytesRead, s.otherBytesRead);
    }

    /// Closes the connection; the receiver is then gone.
    void close() @trusted
    {
        if (receiver is null)
            return;
        api.receive_close(receiver);
        receiver = null;
    }
}

/**
Opens the iroh bridge: at `path`, else at `$SPARKLES_IROH_SEND_LIB`, else in
`../lib` beside the running program, where a package installs it, else by
its bare name, which the dynamic loader searches for. Fails with the
loader's reason, or when the library speaks another interface version.
*/
Expected!(IrohSend, string) loadIrohSend(string path = null) @trusted
{
    import std.process : environment;
    import std.string : fromStringz, toStringz;

    if (path.length == 0)
        path = environment.get("SPARKLES_IROH_SEND_LIB");
    if (path.length == 0)
        path = besideProgram();
    version (Posix)
    {
        import core.sys.posix.dlfcn : dlerror, dlopen, dlsym, RTLD_LOCAL, RTLD_NOW;

        auto handle = dlopen(path.toStringz, RTLD_NOW | RTLD_LOCAL);
        if (handle is null)
            return err!IrohSend("cannot load " ~ path ~ ": " ~ dlerror().fromStringz.idup);
        IrohSend lib;
        static foreach (m; __traits(allMembers, Api))
        {{
            auto sym = dlsym(handle, ("sparkles_iroh_" ~ symbolOf!m).toStringz);
            if (sym is null)
                return err!IrohSend(path ~ " has no sparkles_iroh_" ~ symbolOf!m);
            __traits(getMember, lib.api, m) = cast(typeof(__traits(getMember, lib.api, m))) sym;
        }}
        const abi = lib.api.abi();
        if (abi != irohSendAbi)
        {
            import std.conv : to;

            return err!IrohSend(path ~ " speaks interface " ~ abi.to!string ~ ", not "
                ~ irohSendAbi.to!string);
        }
        return ok!string(lib);
    }
    else
        return err!IrohSend("sending needs a platform with dlopen");
}

// ---------------------------------------------------------------------------

// `../lib/<library>` beside the running program when it is there, as a
// package lays them out; else the bare name.
private string besideProgram() @safe
{
    import std.file : exists, thisExePath;
    import std.path : buildNormalizedPath, dirName;

    try
    {
        const candidate = buildNormalizedPath(dirName(thisExePath), "..", "lib", irohSendLibraryName);
        if (exists(candidate))
            return candidate;
    }
    catch (Exception)
    {
    }
    return irohSendLibraryName;
}

// The library's C interface (`sparkles_iroh_send.rs`).
private extern (C) nothrow @nogc
{
    struct CFile
    {
        const(char)* name;
        size_t nameLength;
        const(char)* path;
        size_t pathLength;
    }

    struct CStatus
    {
        uint phase;
        uint hasHash;
        ulong filesDone;
        ulong filesTotal;
        ulong bytesDone;
        ubyte[32] hash;
        ulong peers;
        ulong requests;
        ulong bytesSent;
    }

    alias AbiFn = uint function();
    alias StartFn = void* function(const(CFile)*, size_t, const(char)*, size_t, uint);
    alias StatusFn = void function(const(void)*, CStatus*);
    alias TextFn = size_t function(const(void)*, uint, ubyte*, size_t);
    alias StopFn = void function(void*);
    alias CollectionFn = int function(const(CFile)*, size_t, ubyte*, char*, size_t, size_t*);
    alias AndroidContextFn = void function(void*, void*);

    struct CEntry
    {
        const(char)* name;
        size_t nameLength;
        ubyte[32] hash;
    }

    struct CReceiveStats
    {
        ulong payloadBytesRead;
        ulong otherBytesRead;
    }

    alias ReceiveOpenFn = void* function(const(ubyte)*, size_t, uint);
    alias ReceiveCountFn = size_t function(const(void)*);
    alias ReceiveEntryFn = void function(const(void)*, size_t, CEntry*);
    alias ReceiveStatsFn = void function(const(void)*, CReceiveStats*);
    alias ReceiveTextFn = size_t function(const(void)*, ubyte*, size_t);
    alias ReceiveFetchFn = int function(void*, const(ulong)*, size_t);
    alias ReceiveNextFn = int function(void*, ulong*, ulong*, ubyte*, size_t, size_t*);
    alias ReceiveCloseFn = void function(void*);
}

private struct Api
{
    AbiFn abi;
    StartFn start;
    StatusFn status;
    TextFn text;
    StopFn stop;
    CollectionFn collection;
    AndroidContextFn android_context;
    ReceiveOpenFn receive_open;
    ReceiveCountFn receive_count;
    ReceiveEntryFn receive_entry;
    ReceiveStatsFn receive_stats;
    ReceiveTextFn receive_text;
    ReceiveFetchFn receive_fetch;
    ReceiveNextFn receive_next;
    ReceiveCloseFn receive_close;
}

// Each member's exported name, after `sparkles_iroh_`.
private enum string symbolOf(string member) = member == "collection" ? "collection"
    : member.length > 8 && member[0 .. 8] == "receive_" ? member : "send_" ~ member;

private CFile[] cFiles(in SendFile[] files) @trusted
{
    auto c = new CFile[files.length];
    foreach (i, ref f; files)
        c[i] = CFile(f.name.ptr, f.name.length, f.path.ptr, f.path.length);
    return c;
}

/// A library that is not there is reported, not thrown.
@("iroh_send.loadMissing")
@safe unittest
{
    const r = loadIrohSend("/nonexistent/libsparkles_iroh_send.so");
    assert(r.hasError);
    assert(r.error.length > 0);
}

// The bridge, when the shell names it (`$SPARKLES_IROH_SEND_LIB`).
private Expected!(IrohSend, string) bridge() @safe
{
    import std.process : environment;

    const path = environment.get("SPARKLES_IROH_SEND_LIB");
    return path is null ? err!IrohSend("SPARKLES_IROH_SEND_LIB is not set") : loadIrohSend(path);
}

/// The collection a send would name, with no network, is the one the
/// offline call names.
@("iroh_send.collectionOffline")
@system unittest
{
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;

    import sparkles.test_runner.skip : skipTest;

    auto lib = bridge();
    if (lib.hasError)
        return skipTest(lib.error);
    const dir = buildPath(tempDir, "iroh-send-collection");
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    write(buildPath(dir, "a"), "one");
    write(buildPath(dir, "b"), "two");
    const files = [SendFile("t/b", buildPath(dir, "b")), SendFile("t/a", buildPath(dir, "a"))];
    const one = lib.value.collection(files);
    assert(one.hasValue, one.error);
    // Order does not matter: the collection is sorted by name.
    const two = lib.value.collection([files[1], files[0]]);
    assert(two.hasValue && two.value == one.value);
    assert(lib.value.collection([SendFile("t/x", buildPath(dir, "missing"))]).hasError);
}

/**
FXS7: a fileset sent by the bridge, on loopback with relays disabled, is
written out by `sendme receive` from `sendme` 0.37, exactly: each file under
its name, and nothing else; the ticket's hash is the collection's name.
`$SPARKLES_SENDME` names the receiver.
*/
@("iroh_send.FXS7.sendmeReceives")
@system unittest
{
    import core.thread : Thread;
    import core.time : msecs, seconds, MonoTime;
    import std.algorithm.sorting : sort;
    import std.array : array, join;
    import std.file : dirEntries, mkdirRecurse, readText, rmdirRecurse, SpanMode, tempDir, write;
    import std.path : buildPath, relativePath;
    import std.process : Config, environment, execute;

    import sparkles.test_runner.skip : skipTest;

    auto lib = bridge();
    if (lib.hasError)
        return skipTest(lib.error);
    const sendme = environment.get("SPARKLES_SENDME");
    if (sendme is null)
        return skipTest("SPARKLES_SENDME is not set");

    const base = buildPath(tempDir, "iroh-send-fxs7");
    const src = buildPath(base, "src"), dst = buildPath(base, "dst"), store = buildPath(base, "store");
    foreach (d; [src, buildPath(src, "deep/er"), dst, store])
        mkdirRecurse(d);
    scope (exit) rmdirRecurse(base);
    string[string] want = ["a.txt": "alpha", "deep/b.d": "module b;", "deep/er/c": "", "big": ""];
    char[] big = new char[100_000];
    foreach (i, ref c; big)
        c = cast(char)('a' + i % 26);
    want["big"] = big.idup;
    SendFile[] files;
    foreach (name, contents; want)
    {
        write(buildPath(src, name), contents);
        files ~= SendFile("fileset/" ~ name, buildPath(src, name));
    }
    // A file beside them that is not in the fileset is not sent.
    write(buildPath(src, "secret"), "no");

    auto session = lib.value.start(files, store, noRelay: true);
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
    assert(st.hasHash && st.filesDone == want.length);
    assert(st.hash == lib.value.collection(files).value, "the send names the offline collection");

    const r = execute([sendme, "receive", "--relay", "disabled", st.ticket], null, Config.stderrPassThrough,
        size_t.max, dst);
    assert(r.status == 0, r.output);
    string[] got;
    foreach (e; dirEntries(dst, SpanMode.depth))
        if (e.isFile)
            got ~= relativePath(e.name, dst);
    got.sort();
    string[] expected = want.keys.array;
    foreach (ref k; expected)
        k = "fileset/" ~ k;
    expected.sort();
    assert(got == expected, got.join(", "));
    foreach (name, contents; want)
        assert(readText(buildPath(dst, "fileset", name)) == contents, name);
    assert(session.poll().bytesSent > 100_000, "the provider counted what it sent");
}

/**
`fsx` M4's spike (`XR2`, `XR3`, docs/specs/fsx): a collection of 50 files is
opened with its names and digests and no byte of any file; one large file
fetched alone arrives whole and verified, and the provider sends little
beyond it.
*/
@("iroh_send.XR.receiveSpike")
@system unittest
{
    import core.thread : Thread;
    import core.time : msecs, seconds, MonoTime;
    import std.conv : text;
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.format : format;
    import std.path : buildPath;

    import sparkles.base.hash.blake3 : blake3;
    import sparkles.test_runner.skip : skipTest;

    auto lib = bridge();
    if (lib.hasError)
        return skipTest(lib.error);
    const base = buildPath(tempDir, "iroh-receive-spike");
    const src = buildPath(base, "src"), store = buildPath(base, "store");
    mkdirRecurse(src);
    mkdirRecurse(store);
    scope (exit) rmdirRecurse(base);

    enum n = 50, bigIndex = 17;
    SendFile[] files;
    ubyte[][] contents;
    foreach (i; 0 .. n)
    {
        auto bytes = new ubyte[i == bigIndex ? 300_000 : 100 + 37 * i];
        foreach (k, ref b; bytes)
            b = cast(ubyte)(k * 31 + i);
        const name = format!"f%02d"(i);
        write(buildPath(src, name), bytes);
        files ~= SendFile("spike/" ~ name, buildPath(src, name));
        contents ~= bytes;
    }

    auto session = lib.value.start(files, store, noRelay: true);
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

    auto r = lib.value.receive(st.ticket, noRelay: true);
    scope (exit) r.close();
    assert(r.error is null, r.error);
    const entries = r.entries();
    assert(entries.length == n);
    foreach (i, ref e; entries)
    {
        assert(e.name == format!"spike/f%02d"(i), e.name);
        assert(e.hash == blake3(contents[i]), e.name);
    }
    // The names and the sequence only: a few KiB, against the files' 380 KB.
    const opened = r.stats();
    assert(opened.payloadBytesRead < 4096, text(opened));

    assert(r.fetch([ulong(bigIndex)]).hasValue);
    ubyte[] got;
    auto buffer = new ubyte[64 * 1024];
    ulong index, offset;
    size_t length;
    bool started, ended;
    for (;;)
    {
        const ev = r.next(index, offset, buffer, length);
        if (ev == ReceiveEvent.done)
            break;
        assert(ev != ReceiveEvent.error, r.error);
        assert(index == bigIndex);
        if (ev == ReceiveEvent.start)
        {
            started = true;
            assert(length == contents[bigIndex].length);
        }
        else if (ev == ReceiveEvent.data)
        {
            assert(offset == got.length, "in order");
            got ~= buffer[0 .. length];
        }
        else
            ended = true;
    }
    assert(started && ended);
    assert(got == contents[bigIndex], "the file, whole");

    // The provider sent the file, the names and the sequence, and nothing of
    // the 49 others.
    Thread.sleep(200.msecs);
    const sent = session.poll().bytesSent;
    assert(sent >= 300_000 && sent < 300_000 + 4096, text(sent));
}
