/**
The format preview's backend-neutral core
([spec](../../../docs/specs/hue/format-preview.md)): the formatter provider
seam (`FPR1`–`FPR8`), the single-flight latest-wins dispatch flow (`FPR9`),
and the bounded width→digest format cache (`FPR11`). No UI, no `dmd.*`, no
raylib — the module compiles in every configuration; the in-process D
provider plugs in from `format_dmd` under `HueDmdFmt`.

Layering, innermost out:
$(LIST
    * $(LREF FormatterRegistry) — who can format what: the in-process
        provider first, then config-declared external argv templates (the
        opt-in trust boundary, `FPR4`), availability probed lazily and
        cached (`FPR5`).
    * $(LREF FormatFlow) — the pure single-flight state machine: a burst of
        `request` calls coalesces to the newest column; a completion applies
        and immediately re-dispatches when the target moved on. No timers,
        no thresholds — backpressure is the machine's shape (`FPR9`/`RUL4`).
    * $(LREF FormatCache) — width → content digest → shared text+highlights.
        Width→output is a step function, so distinct widths dedupe to one
        stored copy; LRU over distinct outputs, byte + entry caps (`FPR11`).
    * $(LREF FormatService) — the worker thread the provider runs on (the
        interim execution backend; the event-horizon `ForkServer` replaces
        it for in-process work, `FPR10`). The UI thread never formats.
)
*/
module format_preview;

import core.lifetime : move;

import expected : Expected, err, ok;

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.syntax : HighlightEvent;

// ── the provider seam (FPR1–FPR8) ───────────────────────────────────────────

/// How a formatter runs: linked into hue, or spawned per request.
enum FormatterKind
{
    inProcess,
    external,
}

/// One formatter the registry can offer for a language.
struct FormatterInfo
{
    string name;            /// e.g. `dmd-fmt`, `dfmt`
    string language;        /// canonical language key it accepts (e.g. `d`)
    FormatterKind kind;
    /// External only: the argv template; `{width}` and `{path}` substitute
    /// per request, the source streams over stdin, the result returns on
    /// stdout (`FPR3`).
    string[] argvTemplate;
}

/// Why a format failed (`FPR8`: an error never blanks the view — the caller
/// keeps the last good buffer and surfaces `message`).
enum FormatErrorKind
{
    noFormatter,   /// no provider matches the language
    spawnFailed,   /// external binary missing / not executable
    nonZeroExit,   /// external formatter rejected the input
    unsupported,   /// provider present but cannot run in this build
}

/// ditto
struct FormatError
{
    FormatErrorKind kind;
    int exitCode;
    string message;
}

/// A formatter's output buffer. `N = 1` deliberately: the payload is a whole
/// file, so inline capacity can never win, and 1 rides free inside the heap
/// descriptor's union — the type stays 3 words instead of pages (large value
/// types have blown macOS's 512 KiB test-thread stacks before).
alias FormatBuffer = SmallBuffer!(char, 1);

/// The provider outcome: the formatted bytes, or why not.
alias FormatResult = Expected!(FormatBuffer, FormatError);

/// The in-process provider's shape (`format_dmd.formatDSource` under
/// `HueDmdFmt`).
alias InProcessFormat = string function(
    const(char)[] source, string path, ushort widthCols) @system;

version (HueDmdFmt)
{
    import format_dmd : formatDSource;

    private enum string builtinInProcessName = "dmd-fmt";
    private enum string builtinInProcessLang = "d";
}

/**
The formatter registry (`FPR1`): language match, lazy cached availability
probing, deterministic ordering (in-process first, then the config-declared
external allowlist in declaration order — `FPR6`), and `run`.
*/
struct FormatterRegistry
{
    private FormatterInfo[] external_;
    private byte[string] probeCache; // name → +1 available / −1 missing

    version (HueDmdFmt)
        private InProcessFormat inProcessFn = &formatDSource;

    /// The registry with the built-in in-process provider (when this build
    /// carries one) plus the config-declared external allowlist (`FPR4` —
    /// callers pass only user-approved entries).
    static FormatterRegistry withExternal(FormatterInfo[] externalAllowlist)
        => FormatterRegistry(external_: externalAllowlist);

    /// Every available formatter for `lang`, deterministic order (`FPR6`).
    /// External entries are availability-probed on first ask, cached for the
    /// registry's lifetime (`FPR5`).
    FormatterInfo[] candidatesFor(string lang) @safe
    {
        FormatterInfo[] found;
        version (HueDmdFmt)
        {
            if (lang == builtinInProcessLang)
                found ~= FormatterInfo(
                    name: builtinInProcessName,
                    language: builtinInProcessLang,
                    kind: FormatterKind.inProcess);
        }
        foreach (f; external_)
        {
            if (f.language != lang || f.argvTemplate.length == 0)
                continue;
            if (probeAvailable(f))
                found ~= f;
        }
        return found;
    }

    /// A stable identity for cache keying (`FPR11`): the provider name plus
    /// its full invocation shape.
    static string fingerprint(in FormatterInfo f) @safe
    {
        import std.array : join;

        return f.name ~ "\0" ~ (f.kind == FormatterKind.external
            ? f.argvTemplate.join("\0") : "in-process");
    }

    /// Run `f` over `source` at `widthCols` (`FPR3`/`FPR7`). Never throws;
    /// failure comes back as a `FormatError` and the caller's buffer is
    /// untouched (`FPR8`).
    FormatResult run(in FormatterInfo f, in char[] source, in char[] path,
        ushort widthCols) @system
    {
        final switch (f.kind)
        {
        case FormatterKind.inProcess:
            version (HueDmdFmt)
            {
                const text = inProcessFn(source, path.idup, widthCols);
                FormatBuffer buf;
                buf ~= text;
                return ok!FormatError(move(buf));
            }
            else
            {
                return err!FormatBuffer(FormatError(FormatErrorKind.unsupported,
                    0, "this build carries no in-process formatter"));
            }
        case FormatterKind.external:
            return runExternal(f, source, path, widthCols);
        }
    }

    private bool probeAvailable(const FormatterInfo f) @safe
    {
        import sparkles.core_cli.process_utils : isInPath;

        if (auto cached = f.name in probeCache)
            return *cached > 0;
        const avail = f.argvTemplate.length && isInPath(f.argvTemplate[0]);
        probeCache[f.name] = avail ? 1 : -1;
        return avail;
    }

    private static FormatResult runExternal(in FormatterInfo f,
        in char[] source, in char[] path, ushort widthCols) @safe
    {
        import std.array : replace;
        import std.conv : to;

        import sparkles.core_cli.process_utils : runCaptured;

        string[] argv;
        argv.reserve(f.argvTemplate.length);
        foreach (piece; f.argvTemplate)
            argv ~= piece
                .replace("{width}", widthCols.to!string)
                .replace("{path}", path);

        const r = runCaptured(argv, stdinText: source.idup);
        if (r.status == 127)
            return err!FormatBuffer(FormatError(FormatErrorKind.spawnFailed,
                r.status, r.stderr));
        if (r.status != 0)
            return err!FormatBuffer(FormatError(FormatErrorKind.nonZeroExit,
                r.status, r.stderr));
        FormatBuffer buf;
        buf ~= r.stdout;
        return (() @trusted => ok!FormatError(move(buf)))();
    }
}

// ── the single-flight flow (FPR9 / RUL4) ────────────────────────────────────

/// What the flow asks its owner to do after an event.
enum FlowAction
{
    none,      /// nothing to do (idle at target, or a format is in flight)
    dispatch,  /// start formatting `FormatFlow.inFlightCol` on the backend
    apply,     /// show the completed buffer (it matches the current target)
}

/**
The pure single-flight, latest-wins state machine (`FPR9`): at most one
format in flight; a new request while busy only moves the target; a
completion re-dispatches immediately when the target moved on. Throughput
adapts to real format latency — no debounce interval, no size threshold.
*/
struct FormatFlow
{
    /// The newest requested column — what the drawn ruler tracks (`RUL4`).
    ushort pendingCol;
    /// Column being formatted right now; −1 = idle.
    int inFlightCol = -1;
    /// Column of the buffer currently shown; −1 = none yet.
    int shownCol = -1;

    /// The drag/nudge/cache-miss entry point.
    FlowAction request(ushort col) @safe pure nothrow @nogc
    {
        pendingCol = col;
        if (inFlightCol != -1)
            return FlowAction.none; // latest-wins: the completion re-checks
        if (shownCol == col)
            return FlowAction.none;
        inFlightCol = col;
        return FlowAction.dispatch;
    }

    /// A cache hit applied synchronously — the shown buffer moved without a
    /// dispatch.
    void shownFromCache(ushort col) @safe pure nothrow @nogc
    {
        pendingCol = col;
        shownCol = col;
    }

    /// The backend finished `col`. `apply` when it is still wanted;
    /// `dispatch` (with `inFlightCol` updated) when the target moved on.
    FlowAction completed(ushort col) @safe pure nothrow @nogc
    {
        inFlightCol = -1;
        if (col == pendingCol)
        {
            shownCol = col;
            return FlowAction.apply;
        }
        inFlightCol = pendingCol;
        return FlowAction.dispatch;
    }
}

// ── the bounded cache (FPR11) ───────────────────────────────────────────────

/// One distinct formatter output, shared by every width that maps to it.
struct CachedFormat
{
    string text;
    HighlightEvent[] events;
}

/**
The bounded format cache (`FPR11`). Two levels — width → digest → entry — so
the step-function shape of width→output dedupes storage. LRU over distinct
outputs; both `maxBytes` and `maxEntries` cap it. Keyed contextually by
(formatter fingerprint, source identity): `rekey` clears on any change.
*/
struct FormatCache
{
    size_t maxBytes = 32 * 1024 * 1024;
    size_t maxEntries = 64;

    private static struct Entry
    {
        CachedFormat payload;
        size_t bytes;
        ulong lastUse;
    }

    private ulong[ushort] widthToDigest;
    private Entry[ulong] byDigest;
    private size_t totalBytes;
    private ulong tick;
    private string keyFingerprint;
    private const(void)* keySourcePtr;
    private size_t keySourceLen;

    /// Bind the cache to (formatter, source); a change drops everything.
    void rekey(string fingerprint, const(char)[] source) @trusted
    {
        if (fingerprint == keyFingerprint && source.ptr == keySourcePtr
            && source.length == keySourceLen)
            return;
        keyFingerprint = fingerprint;
        keySourcePtr = source.ptr;
        keySourceLen = source.length;
        clear();
    }

    void clear() @safe pure nothrow @nogc
    {
        widthToDigest = null;
        byDigest = null;
        totalBytes = 0;
    }

    /// The cached output for `width`, or `null`. A hit refreshes LRU.
    const(CachedFormat)* lookup(ushort width) @safe
    {
        const digest = width in widthToDigest;
        if (digest is null)
            return null;
        auto entry = *digest in byDigest;
        assert(entry !is null, "width map points at an evicted entry");
        entry.lastUse = ++tick;
        return &entry.payload;
    }

    /// Record `width`'s output (also called for stale completions — work
    /// done once becomes a hit on the way back).
    void insert(ushort width, string text, HighlightEvent[] events) @safe
    {
        const digest = hashOf(text);
        if (auto entry = digest in byDigest)
        {
            entry.lastUse = ++tick;
            widthToDigest[width] = digest;
            return;
        }
        const bytes = text.length + events.length * HighlightEvent.sizeof;
        byDigest[digest] = Entry(CachedFormat(text, events), bytes, ++tick);
        widthToDigest[width] = digest;
        totalBytes += bytes;
        evictOver();
    }

    /// Distinct outputs currently held.
    size_t entryCount() const @safe pure nothrow @nogc => byDigest.length;

    /// Bytes currently held.
    size_t bytesHeld() const @safe pure nothrow @nogc => totalBytes;

    private void evictOver() @safe
    {
        while (byDigest.length > 1
            && (totalBytes > maxBytes || byDigest.length > maxEntries))
        {
            ulong oldestDigest;
            ulong oldestUse = ulong.max;
            foreach (digest, ref entry; byDigest)
            {
                if (entry.lastUse < oldestUse)
                {
                    oldestUse = entry.lastUse;
                    oldestDigest = digest;
                }
            }
            totalBytes -= byDigest[oldestDigest].bytes;
            byDigest.remove(oldestDigest);
            ushort[] deadWidths;
            foreach (width, digest; widthToDigest)
                if (digest == oldestDigest)
                    deadWidths ~= width;
            foreach (width; deadWidths)
                widthToDigest.remove(width);
        }
    }
}

// ── the execution backend (FPR9) ────────────────────────────────────────────

/// What the worker hands back. Plain copyable data: the provider's
/// malloc-backed `FormatBuffer` is converted to a GC string on the worker —
/// the apply boundary needs a fresh GC string anyway (slice-identity
/// invalidation), and nothing malloc-owned crosses threads.
struct FormatCompletion
{
    ushort width;
    bool ok;
    string text;
    FormatError error;
    long durMs;
}

/// A format request as the worker sees it. Value-copied into the mailbox —
/// never a closure over UI state (the fiber/closure trap).
struct FormatRequest
{
    string source;
    string path;
    ushort width;
    FormatterInfo formatter;
}

/**
The interim execution backend (`FPR9`): one dedicated worker thread with a
one-slot mailbox. Single-flight is enforced by $(LREF FormatFlow) — the
mailbox never holds more than one request. The event-horizon `ForkServer`
replaces this for in-process work (`FPR10`); this stays as the fallback.
*/
final class FormatService
{
    import core.sync.condition : Condition;
    import core.sync.mutex : Mutex;
    import core.thread : Thread;

    private Mutex mtx;
    private Condition cond;
    private FormatRequest req;
    private FormatCompletion completion;
    private bool hasRequest, hasCompletion, stopping;
    private Thread worker;
    private FormatterRegistry* registry;

    this(FormatterRegistry* registry) @safe
    {
        this.registry = registry;
        mtx = new Mutex;
        cond = new Condition(mtx);
    }

    /// Queue `r` (asserts the previous request was consumed — the flow
    /// guarantees single-flight). Starts the worker lazily.
    void submit(FormatRequest r) @trusted
    {
        synchronized (mtx)
        {
            assert(!hasRequest, "FormatService is single-flight");
            req = r;
            hasRequest = true;
            cond.notifyAll();
        }
        if (worker is null)
        {
            worker = new Thread(&workerLoop);
            worker.isDaemon = true;
            worker.start();
        }
    }

    /// Non-blocking: the finished completion, if one is waiting.
    bool tryTake(out FormatCompletion c) @trusted
    {
        synchronized (mtx)
        {
            if (!hasCompletion)
                return false;
            c = completion;
            hasCompletion = false;
            return true;
        }
    }

    /// Stop and join the worker (idempotent).
    void shutdown() @trusted
    {
        if (worker is null)
            return;
        synchronized (mtx)
        {
            stopping = true;
            cond.notifyAll();
        }
        worker.join();
        worker = null;
        stopping = false;
    }

    private void workerLoop() @system
    {
        import std.datetime.stopwatch : AutoStart, StopWatch;

        for (;;)
        {
            FormatRequest r;
            synchronized (mtx)
            {
                while (!hasRequest && !stopping)
                    cond.wait();
                if (stopping)
                    return;
                r = req;
                hasRequest = false;
            }

            auto sw = StopWatch(AutoStart.yes);
            auto result = registry.run(r.formatter, r.source, r.path, r.width);
            const durMs = sw.peek.total!"msecs";

            FormatCompletion c = {width: r.width, durMs: durMs};
            if (result.hasError)
            {
                c.error = result.error;
            }
            else
            {
                c.ok = true;
                c.text = result.value[].idup;
            }

            synchronized (mtx)
            {
                completion = c;
                hasCompletion = true;
            }
        }
    }
}

// ── tests ───────────────────────────────────────────────────────────────────

@("format_preview.flow.coalescesBurstToNewest")
@safe pure nothrow @nogc
unittest
{
    FormatFlow flow;

    // First request dispatches immediately.
    assert(flow.request(100) == FlowAction.dispatch);
    assert(flow.inFlightCol == 100);

    // A burst while busy only moves the target — nothing else dispatches.
    assert(flow.request(101) == FlowAction.none);
    assert(flow.request(102) == FlowAction.none);
    assert(flow.request(97) == FlowAction.none);
    assert(flow.inFlightCol == 100);
    assert(flow.pendingCol == 97);

    // The stale completion re-dispatches exactly the newest column.
    assert(flow.completed(100) == FlowAction.dispatch);
    assert(flow.inFlightCol == 97);

    // The wanted completion applies and goes idle.
    assert(flow.completed(97) == FlowAction.apply);
    assert(flow.inFlightCol == -1);
    assert(flow.shownCol == 97);

    // Re-requesting the shown column is a no-op; a new one dispatches.
    assert(flow.request(97) == FlowAction.none);
    assert(flow.request(80) == FlowAction.dispatch);
}

@("format_preview.flow.cacheHitSkipsDispatch")
@safe pure nothrow @nogc
unittest
{
    FormatFlow flow;
    flow.shownFromCache(120);
    assert(flow.shownCol == 120);
    assert(flow.request(120) == FlowAction.none);
}

@("format_preview.cache.stepFunctionDedupe")
@safe
unittest
{
    FormatCache cache;
    // Two widths, same output — one stored copy.
    cache.insert(100, "int a;\n", null);
    cache.insert(101, "int a;\n", null);
    assert(cache.entryCount == 1);
    assert(cache.lookup(100) !is null);
    assert(cache.lookup(101) !is null);
    assert(cache.lookup(100).text == cache.lookup(101).text);
    assert(cache.lookup(102) is null);
}

@("format_preview.cache.lruEvictionAtEntryCap")
@safe
unittest
{
    import std.conv : to;

    FormatCache cache;
    cache.maxEntries = 3;
    foreach (ushort w; 0 .. 3)
        cache.insert(w, "text-" ~ w.to!string, null);
    // Touch 0 so 1 becomes the LRU.
    assert(cache.lookup(0) !is null);
    cache.insert(3, "text-3", null);
    assert(cache.entryCount == 3);
    assert(cache.lookup(1) is null, "the LRU entry survives eviction");
    assert(cache.lookup(0) !is null);
    assert(cache.lookup(3) !is null);
}

@("format_preview.cache.byteCapEvicts")
@safe
unittest
{
    import std.array : replicate;

    FormatCache cache;
    cache.maxBytes = 1024;
    cache.insert(80, "x".replicate(700), null);
    cache.insert(90, "y".replicate(700), null);
    // Over the byte cap: the older 700-byte entry goes.
    assert(cache.entryCount == 1);
    assert(cache.lookup(80) is null);
    assert(cache.lookup(90) !is null);
}

@("format_preview.cache.rekeyClears")
@safe
unittest
{
    FormatCache cache;
    const src1 = "int a;\n";
    const src2 = "int b;\n";
    cache.rekey("f1", src1);
    cache.insert(80, "out", null);
    cache.rekey("f1", src1); // same key: kept
    assert(cache.lookup(80) !is null);
    cache.rekey("f1", src2); // source changed: dropped
    assert(cache.lookup(80) is null);
    cache.insert(80, "out2", null);
    cache.rekey("f2", src2); // formatter changed: dropped
    assert(cache.lookup(80) is null);
}

version (Posix)
@("format_preview.registry.externalRoundTrip")
@system
unittest
{
    // `cat` is the width-ignoring identity formatter: stdin → stdout.
    auto reg = FormatterRegistry.withExternal([
        FormatterInfo(name: "cat", language: "txt",
            kind: FormatterKind.external, argvTemplate: ["cat"]),
    ]);
    auto found = reg.candidatesFor("txt");
    assert(found.length == 1 && found[0].name == "cat");
    assert(reg.candidatesFor("rs").length == 0);

    auto r = reg.run(found[0], "hello\nworld\n", "x.txt", 80);
    assert(r.hasValue);
    assert(r.value[] == "hello\nworld\n");
}

@("format_preview.registry.missingBinaryProbesOutAndFailsClean")
@system
unittest
{
    auto ghost = FormatterInfo(name: "ghost", language: "txt",
        kind: FormatterKind.external,
        argvTemplate: ["definitely-not-a-real-binary-7f3a"]);

    auto reg = FormatterRegistry.withExternal([ghost]);
    // The probe excludes it from candidates (FPR5)…
    assert(reg.candidatesFor("txt").length == 0);
    // …and a direct run still fails clean, buffer-untouched (FPR3/FPR8).
    auto r = reg.run(ghost, "x", "x.txt", 80);
    assert(r.hasError);
    assert(r.error.kind == FormatErrorKind.spawnFailed);
    assert(r.error.exitCode == 127);
}

version (Posix)
@("format_preview.registry.nonZeroExitReportsStderr")
@system
unittest
{
    auto failing = FormatterInfo(name: "sh-fail", language: "txt",
        kind: FormatterKind.external,
        argvTemplate: ["sh", "-c", "echo bad-input >&2; exit 3"]);

    auto reg = FormatterRegistry.withExternal([failing]);
    auto r = reg.run(failing, "x", "x.txt", 80);
    assert(r.hasError);
    assert(r.error.kind == FormatErrorKind.nonZeroExit);
    assert(r.error.exitCode == 3);
    import std.algorithm.searching : canFind;

    assert(r.error.message.canFind("bad-input"));
}

version (Posix)
@("format_preview.registry.argvTemplateSubstitutes")
@system
unittest
{
    auto echoing = FormatterInfo(name: "sh-echo", language: "txt",
        kind: FormatterKind.external,
        argvTemplate: ["sh", "-c", `printf '%s %s' "$0" "$1"`, "{width}", "{path}"]);

    auto reg = FormatterRegistry.withExternal([echoing]);
    auto r = reg.run(echoing, "", "some/file.txt", 92);
    assert(r.hasValue);
    assert(r.value[] == "92 some/file.txt");
}

version (Posix)
@("format_preview.service.endToEndOffThread")
@system
unittest
{
    import core.thread : Thread;
    import core.time : msecs;

    auto reg = FormatterRegistry.withExternal([
        FormatterInfo(name: "cat", language: "txt",
            kind: FormatterKind.external, argvTemplate: ["cat"]),
    ]);
    auto svc = new FormatService(&reg);
    scope (exit)
        svc.shutdown();

    svc.submit(FormatRequest(source: "one\n", path: "x.txt", width: 80,
        formatter: reg.candidatesFor("txt")[0]));

    FormatCompletion c;
    foreach (_; 0 .. 500)
    {
        if (svc.tryTake(c))
            break;
        Thread.sleep(2.msecs);
    }
    assert(c.ok, "worker never completed: " ~ c.error.message);
    assert(c.width == 80);
    assert(c.text == "one\n");
}

version (HueDmdFmt)
@("format_preview.service.inProcessDmdFmtOffThread")
@system
unittest
{
    import core.thread : Thread;
    import core.time : msecs;

    auto reg = FormatterRegistry.withExternal(null);
    auto found = reg.candidatesFor("d");
    assert(found.length == 1 && found[0].kind == FormatterKind.inProcess);

    auto svc = new FormatService(&reg);
    scope (exit)
        svc.shutdown();
    svc.submit(FormatRequest(source: "int  a;\n", path: "x.d", width: 80,
        formatter: found[0]));

    FormatCompletion c;
    foreach (_; 0 .. 2500)
    {
        if (svc.tryTake(c))
            break;
        Thread.sleep(2.msecs);
    }
    assert(c.ok, "worker never completed: " ~ c.error.message);
    assert(c.text == "int a;\n");
}
