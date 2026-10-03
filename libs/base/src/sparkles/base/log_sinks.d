/**
Log sinks that keep a copy: a bounded in-memory ring and a rotating file.

Both are [ForwardingCoreLogger]s, installed in front of whatever sink was
there (stderr, logcat), so installing one changes nothing else — each entry
is recorded, then handed on:

---
installFileLog(buildPath(stateDir, "app.log"));  // file → stderr
auto ring = installRingLog();                      // ring → file → stderr
---

The ring is what an in-app log page reads ([RingCoreLogger.each]); the file
is what survives a crash ([RotatingFileCoreLogger]). Writing to either is
`@safe nothrow @nogc`.
*/
module sparkles.base.log_sinks;

import core.stdc.stdio : FILE;
import core.sync.mutex : Mutex;

import sparkles.base.logger : coreGlobalLogLevel, CoreLogEntry, CoreLogger,
    ForwardingCoreLogger, LogLevel, sharedCoreLog;

/**
One entry as the ring hands it to a reader. `message` is borrowed from the
ring and is valid only inside the [RingCoreLogger.each] callback.
*/
struct RingLogRecord
{
    /// Position in the run's log, from 0; a gap means entries were dropped.
    ulong seq;

    LogLevel level; /// severity
    string file; /// source file of the call
    int line; /// source line of the call
    string moduleName; /// module of the call — the entry's source

    long monotonicTicks; /// `MonoTime` ticks when it was logged
    int hour; /// local wall-clock hour
    int minute; /// local wall-clock minute
    int second; /// local wall-clock second

    /// The (possibly truncated) message. Borrowed; copy it to keep it.
    const(char)[] message;

    /// Whether the message was cut at [RingCoreLogger.entryBytes].
    bool truncated;
}

/**
Keeps the last `capacity` log entries in memory and forwards every entry to
the sink it replaced.

Storage is allocated once, at construction: a slot array of `capacity`
entries and a circular text arena of `textBytes`. A message longer than
`entryBytes` is cut at a UTF-8 boundary and marked truncated. When either the
slots or the arena are full, the oldest entries are overwritten and counted in
[dropped] — a reader can tell "nothing happened" from "it scrolled away".

Thread-safe: writers and readers serialise on one mutex, held only for the
copy into the arena and never while forwarding.
*/
final class RingCoreLogger : ForwardingCoreLogger
{
    /// The entry count a log page keeps by default.
    enum size_t defaultCapacity = 10_000;

    /// Longer messages are truncated to this many bytes.
    enum size_t defaultEntryBytes = 4 * 1024;

    /// The default text arena: room for the default capacity at ~200 bytes
    /// an entry, a little more than real logs average.
    enum size_t defaultTextBytes = 2 * 1024 * 1024;

    private static struct Slot
    {
        ulong textStart; // absolute arena position (monotonic)
        uint textLength;
        bool truncated;
        LogLevel level;
        int line;
        string file;
        string moduleName;
        long monotonicTicks;
        int hour, minute, second;
    }

    private Slot[] slots;
    private char[] arena;
    private immutable size_t _entryBytes;
    private ulong head; // seq of the next entry
    private ulong tail; // seq of the oldest live entry
    private ulong textEnd; // absolute arena position after the newest entry
    private ulong dropCount;
    private Mutex mutex;

    /**
    A ring of `capacity` entries and `textBytes` of message text, recording
    at `level` and forwarding to `next` (`null`: record only).
    */
    this(
        LogLevel level,
        shared(CoreLogger) next = null,
        size_t capacity = defaultCapacity,
        size_t entryBytes = defaultEntryBytes,
        size_t textBytes = defaultTextBytes,
    ) @safe
    in (capacity > 0, "a ring needs at least one slot")
    in (entryBytes > 0 && textBytes >= entryBytes, "the arena must hold one whole entry")
    {
        super(level, next);
        slots = new Slot[capacity];
        arena = new char[textBytes];
        _entryBytes = entryBytes;
        mutex = new Mutex;
    }

    /// The most entries the ring holds.
    size_t capacity() const @safe pure nothrow @nogc => slots.length;

    /// The longest message kept whole.
    size_t entryBytes() const @safe pure nothrow @nogc => _entryBytes;

    /// The entries held now.
    size_t length() @safe nothrow @nogc
    {
        mutex.lock_nothrow();
        scope (exit) mutex.unlock_nothrow();
        return cast(size_t)(head - tail);
    }

    /// Entries overwritten to make room — the count since construction.
    ulong dropped() @safe nothrow @nogc
    {
        mutex.lock_nothrow();
        scope (exit) mutex.unlock_nothrow();
        return dropCount;
    }

    /// Entries ever written; the next entry's `seq`.
    ulong total() @safe nothrow @nogc
    {
        mutex.lock_nothrow();
        scope (exit) mutex.unlock_nothrow();
        return head;
    }

    /**
    Calls `fun(record)` for every held entry with `seq >= fromSeq`, oldest
    first — `fromSeq` is how a tailing reader asks for what is new since its
    last visit. The ring is locked for the duration: `fun` must not log.
    */
    void each(Fun)(scope Fun fun, ulong fromSeq = 0)
    {
        mutex.lock_nothrow();
        scope (exit) mutex.unlock_nothrow();
        for (ulong seq = fromSeq > tail ? fromSeq : tail; seq < head; ++seq)
        {
            const s = slots[cast(size_t)(seq % slots.length)];
            const at = cast(size_t)(s.textStart % arena.length);
            const record = RingLogRecord(
                seq: seq,
                level: s.level,
                file: s.file,
                line: s.line,
                moduleName: s.moduleName,
                monotonicTicks: s.monotonicTicks,
                hour: s.hour,
                minute: s.minute,
                second: s.second,
                message: arena[at .. at + s.textLength],
                truncated: s.truncated,
            );
            fun(record);
        }
    }

    override protected void writeCoreLog(
        const ref CoreLogEntry entry,
        scope const(char)[] message,
    ) @safe nothrow @nogc
    {
        record(entry, message);
        forwardToNext(entry, message);
    }

    private void record(const ref CoreLogEntry entry, scope const(char)[] message)
        @safe nothrow @nogc
    {
        const truncated = message.length > _entryBytes;
        const text = truncated ? message[0 .. utf8Floor(message, _entryBytes)] : message;

        mutex.lock_nothrow();
        scope (exit) mutex.unlock_nothrow();

        // A message never wraps: one that would cross the arena's end starts
        // at the beginning instead (the skipped tail is dead space).
        const arenaBytes = arena.length;
        ulong start = textEnd;
        if (start % arenaBytes + text.length > arenaBytes)
            start += arenaBytes - start % arenaBytes;
        const end = start + text.length;

        // Live text always lies in [textEnd - arena, textEnd); after this
        // write that window is [end - arena, end), so whatever starts below
        // it is overwritten — as is the oldest slot when every one is taken.
        while (tail < head
            && (head - tail >= slots.length
                || slots[cast(size_t)(tail % slots.length)].textStart + arenaBytes < end))
        {
            ++tail;
            ++dropCount;
        }

        const at = cast(size_t)(start % arenaBytes);
        arena[at .. at + text.length] = text[];
        slots[cast(size_t)(head % slots.length)] = Slot(
            textStart: start,
            textLength: cast(uint) text.length,
            truncated: truncated,
            level: entry.level,
            line: entry.line,
            file: entry.file,
            moduleName: entry.moduleName,
            monotonicTicks: entry.monotonicTicks,
            hour: entry.hour,
            minute: entry.minute,
            second: entry.second,
        );
        ++head;
        textEnd = end;
    }
}

/**
Appends every entry to a file, one line each, rotating it to `<path>.1` when
the next line would take it past `maxBytes` — so at most two files of
`maxBytes` exist, and the newest entries are always in `<path>`.

With `rotateOnOpen` (the default), an existing `<path>` is moved to `<path>.1`
when the sink opens: the previous run is then one whole file, readable after a
crash. Every line is flushed as it is written.

A failure — the directory cannot be created, the file cannot be opened, a
write or flush comes up short (a full disk) — disables the sink and logs one
warning through the process logger; entries keep flowing to [next]. It never
throws and never stops the app.
*/
final class RotatingFileCoreLogger : ForwardingCoreLogger
{
    /// The rotation threshold a log page's file keeps by default.
    enum ulong defaultMaxBytes = 1024 * 1024;

    /// Messages longer than this are cut (at a UTF-8 boundary), as in the ring.
    enum size_t entryBytes = RingCoreLogger.defaultEntryBytes;

    private string _path;
    private string pathz; // NUL-terminated copies for the C calls
    private string rotatedz;
    private immutable ulong maxBytes;
    private FILE* file;
    private ulong size;
    private bool failed;
    private Mutex mutex;

    /**
    Opens (creating its directory) `path` for appending, recording at `level`
    and forwarding to `next`.
    */
    this(
        LogLevel level,
        string path,
        shared(CoreLogger) next = null,
        ulong maxBytes = defaultMaxBytes,
        bool rotateOnOpen = true,
    ) @safe
    in (maxBytes > 0)
    {
        import std.file : mkdirRecurse;
        import std.path : dirName;

        super(level, next);
        _path = path;
        pathz = path ~ '\0';
        rotatedz = path ~ ".1\0";
        this.maxBytes = maxBytes;
        mutex = new Mutex;

        try
            mkdirRecurse(path.dirName);
        catch (Exception)
        {
            disable("cannot create its directory");
            return;
        }
        if (rotateOnOpen)
            renameToRotated();
        if (!open())
            disable("cannot open it");
    }

    /// The file entries are appended to.
    string path() const @safe pure nothrow @nogc => _path;

    /// The rotated file: `path ~ ".1"`.
    string rotatedPath() const @safe pure nothrow @nogc => rotatedz[0 .. $ - 1];

    /// Whether the sink still writes (`false` once a failure disabled it).
    bool active() @safe nothrow @nogc
    {
        mutex.lock_nothrow();
        scope (exit) mutex.unlock_nothrow();
        return file !is null;
    }

    ~this() @trusted nothrow @nogc
    {
        import core.stdc.stdio : fclose;

        if (file !is null)
            fclose(file);
        file = null;
    }

    override protected void writeCoreLog(
        const ref CoreLogEntry entry,
        scope const(char)[] message,
    ) @safe nothrow @nogc
    {
        const ok = append(entry, message);
        forwardToNext(entry, message);
        if (!ok)
            disable("cannot write it");
    }

    /// Closes the file; from here on the sink only forwards.
    void close() @safe nothrow @nogc
    {
        mutex.lock_nothrow();
        scope (exit) mutex.unlock_nothrow();
        closeFile();
    }

    // `false` only for a failure that just happened; a disabled sink is quiet.
    private bool append(const ref CoreLogEntry entry, scope const(char)[] message)
        @safe nothrow @nogc
    {
        import sparkles.base.buffer : SharedBuffer;
        import sparkles.base.logger : baseNameSlice, writeStyledLevel, writeTimeHms;
        import sparkles.base.text.writers : writeInteger;

        const truncated = message.length > entryBytes;
        const text = truncated ? message[0 .. utf8Floor(message, entryBytes)] : message;

        SharedBuffer!(char, 128) prefix;
        writeTimeHms(prefix, entry.hour, entry.minute, entry.second);
        prefix ~= ' ';
        writeStyledLevel!false(prefix, entry.level);
        prefix ~= ' ';
        prefix ~= baseNameSlice(entry.file);
        prefix ~= ':';
        writeInteger(prefix, entry.line);
        prefix ~= ": ";
        static immutable string tail = " […]\n";
        const lineBytes = prefix.length + text.length + (truncated ? tail.length : 1);

        mutex.lock_nothrow();
        scope (exit) mutex.unlock_nothrow();
        if (file is null)
            return true;
        if (size > 0 && size + lineBytes > maxBytes)
        {
            closeFile();
            renameToRotated();
            if (!open())
                return false;
        }
        const ok = writeAll(file, prefix[])
            && writeAll(file, text)
            && writeAll(file, truncated ? tail : "\n")
            && flushed(file);
        size += lineBytes;
        return ok;
    }

    // Closes the file and logs the one warning. Never called with the lock held.
    private void disable(string what) @safe nothrow @nogc
    {
        import sparkles.base.logger : warning;

        {
            mutex.lock_nothrow();
            scope (exit) mutex.unlock_nothrow();
            if (failed)
                return;
            failed = true;
            closeFile();
        }
        warning(i"log file $(_path): $(what) — file logging is off for this run");
    }

    private bool open() @trusted nothrow @nogc
    {
        import core.stdc.stdio : fopen, fseek, ftell, SEEK_END;

        // Binary: Windows' text mode would write each "\n" as "\r\n".
        file = fopen(pathz.ptr, "ab");
        if (file is null)
            return false;
        // "ab" positions writes at the end, but ftell reports 0 until the first
        // one: seek there to learn how much the file already holds.
        fseek(file, 0, SEEK_END);
        const at = ftell(file);
        size = at > 0 ? at : 0;
        return true;
    }

    private void closeFile() @trusted nothrow @nogc
    {
        import core.stdc.stdio : fclose;

        if (file !is null)
            fclose(file);
        file = null;
    }

    private void renameToRotated() @trusted nothrow @nogc
    {
        import core.stdc.stdio : rename;

        // A missing file has nothing to rotate; any other failure leaves the
        // old content in place, to be appended to — still a log.
        rename(pathz.ptr, rotatedz.ptr);
    }
}

/**
Installs a [RingCoreLogger] in front of the process logger (Phobos `sharedLog`
and `sharedCoreLog`) and returns it, for a log page to read.

It records at the current logger's level (everything, when none is installed)
and forwards to it.
*/
RingCoreLogger installRingLog(
    size_t capacity = RingCoreLogger.defaultCapacity,
    size_t entryBytes = RingCoreLogger.defaultEntryBytes,
    size_t textBytes = RingCoreLogger.defaultTextBytes,
) @safe
{
    auto previous = sharedCoreLog;
    auto ring = new RingCoreLogger(levelOf(previous), previous, capacity, entryBytes, textBytes);
    install(ring);
    return ring;
}

/**
Installs a [RotatingFileCoreLogger] on `path` in front of the process logger
and returns it. A sink that could not open its file is still installed: it
forwards, and its warning says why it does not write.
*/
RotatingFileCoreLogger installFileLog(
    string path,
    ulong maxBytes = RotatingFileCoreLogger.defaultMaxBytes,
    bool rotateOnOpen = true,
) @safe
{
    auto previous = sharedCoreLog;
    auto sink = new RotatingFileCoreLogger(levelOf(previous), path, previous, maxBytes, rotateOnOpen);
    install(sink);
    return sink;
}

private:

LogLevel levelOf(shared(CoreLogger) logger) @safe nothrow @nogc
{
    if (logger is null)
        return LogLevel.all;
    return () @trusted { return (cast() logger).coreLogLevel; }();
}

void install(CoreLogger logger) @safe
{
    import std.logger : sharedLog;

    auto s = () @trusted { return cast(shared) logger; }();
    sharedLog = s;
    sharedCoreLog = s;
}

// The longest prefix of `s` no longer than `limit` that ends on a code point
// boundary.
size_t utf8Floor(scope const(char)[] s, size_t limit) @safe pure nothrow @nogc
{
    if (s.length <= limit)
        return s.length;
    size_t n = limit;
    while (n > 0 && (s[n] & 0xC0) == 0x80)
        --n;
    return n;
}

bool writeAll(FILE* f, scope const(char)[] data) @trusted nothrow @nogc
{
    import core.stdc.stdio : fwrite;

    return data.length == 0 || fwrite(data.ptr, 1, data.length, f) == data.length;
}

bool flushed(FILE* f) @trusted nothrow @nogc
{
    import core.stdc.stdio : fflush;

    return fflush(f) == 0;
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

version (unittest)
{
    import sparkles.base.logger : lockLoggerGlobalTests, unlockLoggerGlobalTests;

    CoreLogEntry entryAt(LogLevel level, int line) @safe pure nothrow @nogc
        => CoreLogEntry(level: level, file: "dir/sinks_test.d", line: line,
            moduleName: "sinks.test", hour: 1, minute: 2, second: 3);

    // Every message the ring holds, in order, joined by '|'.
    string ringText(RingCoreLogger ring) @safe
    {
        string s;
        ring.each((scope const ref RingLogRecord r) {
            if (s.length)
                s ~= '|';
            s ~= r.message;
        });
        return s;
    }

    // The sink a ring or file is installed in front of: keeps the first few
    // messages it is handed, in fixed storage (`writeCoreLog` is `@nogc`).
    final class Recorder : CoreLogger
    {
        private char[128][8] texts;
        private size_t[8] lengths;
        private size_t count;

        this(LogLevel level) @safe { super(level); }

        override protected void writeCoreLog(const ref CoreLogEntry, scope const(char)[] message)
            @safe nothrow @nogc
        {
            if (count == texts.length)
                return;
            const n = message.length < texts[0].length ? message.length : texts[0].length;
            texts[count][0 .. n] = message[0 .. n];
            lengths[count++] = n;
        }

        override protected void writeLogMsg(ref Logger.LogEntry) @safe {}

        string[] messages() const @safe
        {
            string[] r;
            foreach (i; 0 .. count)
                r ~= texts[i][0 .. lengths[i]].idup;
            return r;
        }
    }

    import std.logger : Logger;

    string scratchDir(string name) @safe
    {
        import std.conv : text;
        import std.file : tempDir;
        import std.path : buildPath;
        import std.process : thisProcessID;

        return buildPath(tempDir, text("sparkles-log-sinks-", thisProcessID, "-", name));
    }
}

@("log_sinks.RingCoreLogger.wrapCountsDrops")
@safe
unittest
{
    // `forwardCoreLog` reads the global level, which `logger`'s tests change.
    lockLoggerGlobalTests();
    scope (exit)
        unlockLoggerGlobalTests();

    auto ring = new RingCoreLogger(LogLevel.all, null, capacity: 4);
    foreach (i; 0 .. 6)
    {
        const e = entryAt(LogLevel.info, i);
        char[1] m = cast(char)('a' + i);
        ring.forwardCoreLog(e, m[]);
    }
    assert(ring.length == 4);
    assert(ring.total == 6);
    assert(ring.dropped == 2, "two entries overwritten");
    assert(ringText(ring) == "c|d|e|f", "oldest first, the first two gone");

    ulong first = ulong.max;
    ring.each((scope const ref RingLogRecord r) { if (first == ulong.max) first = r.seq; });
    assert(first == 2, "seq survives the wrap: a reader sees the gap");

    string fresh;
    ring.each((scope const ref RingLogRecord r) { fresh ~= r.message; }, fromSeq: 4);
    assert(fresh == "ef", "a tailing reader asks for what is new");
}

@("log_sinks.RingCoreLogger.truncatesAtACodePoint")
@safe
unittest
{
    // `forwardCoreLog` reads the global level, which `logger`'s tests change.
    lockLoggerGlobalTests();
    scope (exit)
        unlockLoggerGlobalTests();

    auto ring = new RingCoreLogger(LogLevel.all, null, capacity: 4, entryBytes: 4, textBytes: 64);
    const e = entryAt(LogLevel.info, 1);
    ring.forwardCoreLog(e, "abcé!"); // 'é' is two bytes at offsets 3–4
    bool truncated;
    string text;
    ring.each((scope const ref RingLogRecord r) { truncated = r.truncated; text = r.message.idup; });
    assert(truncated);
    assert(text == "abc", "never half a code point");
}

@("log_sinks.RingCoreLogger.textPressureEvicts")
@safe
unittest
{
    // `forwardCoreLog` reads the global level, which `logger`'s tests change.
    lockLoggerGlobalTests();
    scope (exit)
        unlockLoggerGlobalTests();

    // Eight slots but sixteen bytes of text: the arena, not the slot count,
    // is what overwrites here — and the skipped tail never splits a message.
    auto ring = new RingCoreLogger(LogLevel.all, null, capacity: 8, entryBytes: 6, textBytes: 16);
    const e = entryAt(LogLevel.info, 1);
    // a [0,5) b [5,10) c [10,15); d would cross the end, so it starts at 16
    // (physical 0) and overwrites a; e at physical [5,10) overwrites b.
    foreach (m; ["aaaaa", "bbbbb", "ccccc", "ddddd"])
        ring.forwardCoreLog(e, m);
    assert(ringText(ring) == "bbbbb|ccccc|ddddd");
    assert(ring.dropped == 1);
    ring.forwardCoreLog(e, "eeeee");
    assert(ringText(ring) == "ccccc|ddddd|eeeee");
    assert(ring.dropped == 2);
    assert(ring.length == 3);
}

@("log_sinks.RingCoreLogger.writeIsNogc")
@safe
unittest
{
    // `forwardCoreLog` reads the global level, which `logger`'s tests change.
    lockLoggerGlobalTests();
    scope (exit)
        unlockLoggerGlobalTests();

    static void write(RingCoreLogger ring) @safe nothrow @nogc
    {
        const e = entryAt(LogLevel.warning, 7);
        ring.forwardCoreLog(e, "from a @nogc path");
    }

    auto ring = new RingCoreLogger(LogLevel.all, null, capacity: 2);
    write(ring);
    assert(ringText(ring) == "from a @nogc path");
}

@("log_sinks.RingCoreLogger.forwardsToTheSinkItReplaced")
@safe
unittest
{
    import sparkles.base.logger : info, trace;
    import std.logger : sharedLog;

    lockLoggerGlobalTests();
    auto oldLog = sharedCoreLog;
    auto oldShared = sharedLog;
    auto oldLevel = coreGlobalLogLevel;
    scope (exit)
    {
        sharedCoreLog = oldLog;
        sharedLog = oldShared;
        coreGlobalLogLevel = oldLevel;
        unlockLoggerGlobalTests();
    }

    auto rec = new Recorder(LogLevel.info);
    sharedCoreLog = () @trusted { return cast(shared) rec; }();
    coreGlobalLogLevel = LogLevel.all;

    auto ring = installRingLog(capacity: 16);
    assert(sharedCoreLog is () @trusted { return cast(shared) ring; }());
    assert(ring.next is () @trusted { return cast(shared) rec; }());

    info(i"hello $(42)");
    trace(i"filtered by the recorder's own level");
    assert(rec.messages == ["hello 42"], "the sink it replaced sees what it saw before");
    assert(ringText(ring) == "hello 42", "the ring took the recorder's level");
}

@("log_sinks.initLogger.levelsTheWholeChain")
@safe
unittest
{
    import sparkles.base.logger : initLogger;
    import std.logger : sharedLog;

    lockLoggerGlobalTests();
    auto oldLog = sharedCoreLog;
    auto oldShared = sharedLog;
    auto oldLevel = coreGlobalLogLevel;
    scope (exit)
    {
        sharedCoreLog = oldLog;
        sharedLog = oldShared;
        coreGlobalLogLevel = oldLevel;
        unlockLoggerGlobalTests();
    }

    auto rec = new Recorder(LogLevel.warning);
    sharedCoreLog = () @trusted { return cast(shared) rec; }();
    auto ring = installRingLog(capacity: 4);

    initLogger(LogLevel.trace);
    assert(ring.coreLogLevel == LogLevel.trace);
    assert(rec.coreLogLevel == LogLevel.trace, "the forwarded-to sink follows");
}

@("log_sinks.RotatingFileCoreLogger.appendsAndRotates")
@safe
unittest
{
    // `forwardCoreLog` reads the global level, which `logger`'s tests change.
    lockLoggerGlobalTests();
    scope (exit)
        unlockLoggerGlobalTests();

    import std.algorithm.searching : canFind, count;
    import std.file : exists, getSize, readText, rmdirRecurse;
    import std.path : buildPath;

    const dir = scratchDir("rotate");
    scope (exit) if (dir.exists) rmdirRecurse(dir);
    const path = buildPath(dir, "nested", "app.log");

    auto sink = new RotatingFileCoreLogger(LogLevel.all, path, null, maxBytes: 200);
    assert(sink.active, "the directory is created");
    const e = entryAt(LogLevel.error, 12);
    sink.forwardCoreLog(e, "first line");
    assert(readText(path) == "01:02:03 ERR sinks_test.d:12: first line\n");

    foreach (i; 0 .. 10)
        if (!sink.rotatedPath.exists)
            sink.forwardCoreLog(e, "padding padding padding");
    assert(sink.rotatedPath.exists, "past maxBytes the file rotates");
    assert(getSize(path) <= 200 && getSize(sink.rotatedPath) <= 200);
    assert(readText(sink.rotatedPath).canFind("first line"));
    assert(!readText(path).canFind("first line"));

    foreach (i; 0 .. 10)
        sink.forwardCoreLog(e, "padding padding padding");
    assert(!readText(sink.rotatedPath).canFind("first line"),
        "a second rotation replaces the one older file");
    assert(getSize(path) <= 200 && getSize(sink.rotatedPath) <= 200);

    // The next run moves this run's file aside whole.
    sink.close();
    const lastRun = readText(path);
    auto next = new RotatingFileCoreLogger(LogLevel.all, path, null, maxBytes: 200);
    scope (exit) next.close();
    assert(readText(next.rotatedPath) == lastRun, "the previous run is readable");
    assert(getSize(path) == 0);
    assert(lastRun.count('\n') > 0);
}

@("log_sinks.RotatingFileCoreLogger.failureDisablesWithOneWarning")
@safe
unittest
{
    import std.algorithm.searching : canFind;
    import std.file : exists;

    import sparkles.test_runner.skip : skipTest;

    import std.logger : sharedLog;

    if (!"/dev/full".exists)
        skipTest("no /dev/full to fail writes on");

    lockLoggerGlobalTests();
    auto oldLog = sharedCoreLog;
    auto oldShared = sharedLog;
    auto oldLevel = coreGlobalLogLevel;
    scope (exit)
    {
        sharedCoreLog = oldLog;
        sharedLog = oldShared;
        coreGlobalLogLevel = oldLevel;
        unlockLoggerGlobalTests();
    }

    auto rec = new Recorder(LogLevel.all);
    sharedCoreLog = () @trusted { return cast(shared) rec; }();
    coreGlobalLogLevel = LogLevel.all;

    // Every write to /dev/full fails with ENOSPC — a full disk, on demand.
    auto sink = installFileLog("/dev/full", rotateOnOpen: false);
    assert(sink.active);
    const e = entryAt(LogLevel.info, 1);
    sink.forwardCoreLog(e, "one");
    sink.forwardCoreLog(e, "two");

    assert(!sink.active, "the failure disabled the sink");
    assert(rec.messages.length == 3, "both entries still forwarded, plus one warning");
    assert(rec.messages[0] == "one" && rec.messages[2] == "two");
    assert(rec.messages[1].canFind("file logging is off"));
}
