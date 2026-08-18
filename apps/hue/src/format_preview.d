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

import viewer_model : ViewerModel;

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
    static FormatterRegistry withExternal(FormatterInfo[] externalAllowlist) @safe
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
    /// Mutable: a hit whose highlights were never computed memoizes them in
    /// place on first display.
    CachedFormat* lookup(ushort width) @safe
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

// ── the session: the one owner of preview state (FMV / RUL8) ────────────────

/// The ruler's sane range (`RUL5`); drag, nudge and CLI all pass through it.
enum ushort minRulerCol = 40;
/// ditto
enum ushort maxRulerCol = 300;

/// ditto
ushort clampRulerCol(long col) @safe pure nothrow @nogc
    => col < minRulerCol ? minRulerCol
        : col > maxRulerCol ? maxRulerCol : cast(ushort) col;

/**
The per-document format-preview session (`FMV1`–`FMV7`) — every decision
lives here, owned by the `ViewerModel` both backends share (`RUL8`). A class:
the `FormatService` worker keeps the registry's address, so the state must
not move.

Backends interact only through the free functions below (`formatPreview*`) —
their command arms are one-liners, and anything decision-shaped that tries to
grow in an adapter belongs here instead.
*/
final class FormatPreviewSession
{
    FormatterRegistry registry;
    FormatService service;
    FormatFlow flow;
    FormatCache cache;

    bool active;
    size_t formatterIndex;
    FormatterInfo[] candidates;
    string error;        /// last provider failure (`FPR8`); empty = healthy
    long lastFormatMs;   /// status display only — never a throttle
    ushort rulerCol = 120;

    private string sourceText;                    // the original, as the formatter input
    private string docPath;                       // for configFor / argv {path}
    private const(char)[] originalSource;         // the FMV4 instant-restore pair
    private const(HighlightEvent)[] originalEvents;

    this(FormatterInfo[] externalAllowlist = null) @safe
    {
        registry = FormatterRegistry.withExternal(externalAllowlist);
        service = new FormatService((() @trusted => &registry)());
    }

    private ref const(FormatterInfo) formatter() const return @safe pure nothrow @nogc
        => candidates[formatterIndex];

    /// Enter the preview (`FMV2`/`FMV3`). Empty return = entered; otherwise
    /// the reason it stayed off.
    private string enter(ref ViewerModel vm) @system
    {
        import std.conv : text;

        if (vm.diff.files.length || vm.tw.code.length || vm.preview.present)
            return "format preview: only for plain code views";
        candidates = registry.candidatesFor(vm.lang);
        if (candidates.length == 0)
            return text("no formatter for '",
                vm.lang.length ? vm.lang : "plain text", "'");
        if (formatterIndex >= candidates.length)
            formatterIndex = 0;

        originalSource = vm.source;
        originalEvents = vm.events;
        sourceText = vm.source.idup;
        docPath = vm.docPath;
        error = null;
        active = true;

        version (HueDmdFmt)
        {
            import format_dmd : discoveredWidth;

            if (formatter.kind == FormatterKind.inProcess)
                rulerCol = clampRulerCol(discoveredWidth(vm.docPath));
        }

        cache.rekey(FormatterRegistry.fingerprint(formatter), originalSource);
        requestWidth(vm, rulerCol);
        return null;
    }

    /// Exit: the `FMV4` instant restore — a swap, never a reformat. The
    /// cache and any in-flight format survive for re-entry.
    private void exit_(ref ViewerModel vm) @system
    {
        active = false;
        error = null;
        vm.swapContent(originalSource, originalEvents);
    }

    /// The drag/nudge/CLI width entry point (`RUL4`/`RUL5`): clamp, try the
    /// cache (a hit applies synchronously and skips the worker, `FPR11`),
    /// else run the single-flight flow.
    void requestWidth(ref ViewerModel vm, long col) @system
    {
        const clamped = clampRulerCol(col);
        rulerCol = clamped;
        if (!active)
            return;
        if (auto hit = cache.lookup(clamped))
        {
            if (hit.events is null)
                hit.events = rehighlight(vm, hit.text);
            flow.shownFromCache(clamped);
            vm.swapContent(hit.text, hit.events);
            return;
        }
        if (flow.request(clamped) == FlowAction.dispatch)
            dispatch();
    }

    /// Drain worker completions and act on them (`FPR9`): cache every result
    /// (stale ones included — `FPR11`), apply the one still wanted, chain the
    /// next dispatch when the target moved. Runs every frame/tick; `true`
    /// when the visible buffer changed.
    bool pump(ref ViewerModel vm) @system
    {
        bool changed;
        FormatCompletion c;
        while (service.tryTake(c))
        {
            lastFormatMs = c.durMs;
            const action = flow.completed(c.width);
            if (!c.ok)
            {
                error = describeError(c.error);
                if (action == FlowAction.dispatch && active)
                    dispatch();
                continue;
            }
            error = null;
            cache.insert(c.width, c.text, null);
            final switch (action)
            {
            case FlowAction.apply:
                if (active)
                {
                    auto hit = cache.lookup(c.width);
                    if (hit.events is null)
                        hit.events = rehighlight(vm, hit.text);
                    vm.swapContent(hit.text, hit.events);
                    changed = true;
                }
                break;
            case FlowAction.dispatch:
                if (active)
                    dispatch();
                break;
            case FlowAction.none:
                break;
            }
        }
        return changed;
    }

    /// `FPR6`: the next available formatter, reformatting the current width
    /// under the new provider (its own cache key).
    private string cycle(ref ViewerModel vm) @system
    {
        import std.conv : text;

        if (!active || candidates.length == 0)
            return null;
        if (candidates.length == 1)
            return text(formatter.name, " is the only formatter for '",
                vm.lang, "'");
        formatterIndex = (formatterIndex + 1) % candidates.length;
        cache.rekey(FormatterRegistry.fingerprint(formatter), originalSource);
        flow.shownCol = -1; // force a fresh format under the new provider
        requestWidth(vm, rulerCol);
        return null;
    }

    /// The status chip both backends render (`FMV7`).
    string chip() const @safe
    {
        import std.conv : text;

        if (!active)
            return null;
        auto s = text("fmt: ", formatter.name, " · ", rulerCol);
        if (error.length)
            s ~= text(" · ", error);
        return s;
    }

    private void dispatch() @system
    {
        service.submit(FormatRequest(source: sourceText, path: docPath,
            width: cast(ushort) flow.inFlightCol,
            formatter: candidates[formatterIndex]));
    }

    private static string describeError(in FormatError e) @safe
    {
        import std.conv : text;
        import std.string : strip;

        final switch (e.kind)
        {
        case FormatErrorKind.noFormatter:
            return "no formatter";
        case FormatErrorKind.spawnFailed:
            return "formatter not runnable";
        case FormatErrorKind.nonZeroExit:
            const msg = e.message.strip;
            return msg.length
                ? text("formatter failed: ", msg)
                : text("formatter exited ", e.exitCode);
        case FormatErrorKind.unsupported:
            return "formatter unavailable in this build";
        }
    }

    private static HighlightEvent[] rehighlight(
        ref ViewerModel vm, string source) @system
    {
        import sparkles.syntax : highlightInjected;
        import sparkles.base.smallbuffer : SmallBuffer;

        SmallBuffer!HighlightEvent ev;
        if (vm.cache is null || vm.lang.length == 0
            || highlightInjected(*vm.cache, vm.lang, source, ev).hasError)
        {
            ev.clear();
            ev ~= HighlightEvent.sourceSpan(0, source.length);
        }
        return ev[].dup;
    }
}

// ── the shared backend surface: every arm is one of these calls ─────────────

/// `true` while the preview shows (drives `CtxFlag.formatPreviewActive` and
/// the ruler paint in both backends).
bool formatPreviewActive(ref const ViewerModel vm) @safe pure nothrow @nogc
    => vm.fmt !is null && vm.fmt.active;

/// Toggle (`FMV1`). Returns the user-facing notice ("format preview off",
/// "no formatter for 'x'"), or null when entering succeeded quietly.
string formatPreviewToggle(ref ViewerModel vm) @system
{
    if (vm.fmt is null)
        vm.fmt = new FormatPreviewSession();
    if (vm.fmt.active)
    {
        vm.fmt.exit_(vm);
        return "format preview off";
    }
    return vm.fmt.enter(vm);
}

/// Per-frame/tick drain (`FPR9`); `true` when the visible buffer changed
/// (the caller repaints).
bool formatPreviewPump(ref ViewerModel vm) @system
    => vm.fmt !is null && vm.fmt.pump(vm);

/// `<`/`>`: nudge the ruler through the same clamp as the drag (`RUL5`).
void formatPreviewNudge(ref ViewerModel vm, int delta) @system
{
    if (formatPreviewActive(vm))
        vm.fmt.requestWidth(vm, cast(long) vm.fmt.rulerCol + delta);
}

/// Cycle the formatter (`FPR6`); the notice, or null.
string formatPreviewCycle(ref ViewerModel vm) @system
    => vm.fmt is null ? null : vm.fmt.cycle(vm);

/// The status chip, or null when the preview is off (`FMV7`).
string formatPreviewChip(ref const ViewerModel vm) @safe
    => vm.fmt is null ? null : vm.fmt.chip();

version (HueDmdFmt)
@("format_preview.toggle.roundTripRestoresOriginal")
@system unittest
{
    import core.thread : Thread;
    import core.time : msecs;

    import sparkles.syntax : builtinDark, LabelSet;

    import gui_preview : PreviewModel;
    import sparkles.twoslash.protocol : TwoslashReturn;

    ViewerModel vm;
    vm.names = ["dark"];
    vm.themes = [builtinDark];
    vm.labels = LabelSet.standard();
    vm.widthCols = 80;
    vm.applyTheme(0);

    enum src = "int  answer   = 42;\nint  more  =  1;\n";
    vm.setDocument("t.d", "", src,
        [HighlightEvent.sourceSpan(0, src.length)], PreviewModel.init,
        TwoslashReturn.init, "d");

    // Enter: quiet, active, and the format applies once pumped (FMV1/FMV3).
    assert(formatPreviewToggle(vm) is null);
    assert(formatPreviewActive(vm));
    bool applied;
    foreach (_; 0 .. 2500)
    {
        if (formatPreviewPump(vm))
        {
            applied = true;
            break;
        }
        Thread.sleep(2.msecs);
    }
    assert(applied, "the preview never applied");
    assert(vm.source == "int answer = 42;\nint more = 1;\n");
    assert(formatPreviewChip(vm) !is null);

    // Exit: the FMV4 instant restore — the original slice, by identity.
    assert(formatPreviewToggle(vm) == "format preview off");
    assert(!formatPreviewActive(vm));
    assert(vm.source is src);

    // Re-enter: the cache still holds this width (FPR11) — the formatted
    // buffer shows synchronously, no worker round-trip.
    assert(formatPreviewToggle(vm) is null);
    assert(vm.source == "int answer = 42;\nint more = 1;\n");
    formatPreviewToggle(vm);
    vm.fmt.service.shutdown();
}

@("format_preview.toggle.refusesWithoutFormatter")
@system unittest
{
    import sparkles.syntax : builtinDark, LabelSet;

    import gui_preview : PreviewModel;
    import sparkles.twoslash.protocol : TwoslashReturn;

    ViewerModel vm;
    vm.names = ["dark"];
    vm.themes = [builtinDark];
    vm.labels = LabelSet.standard();
    vm.widthCols = 80;
    vm.applyTheme(0);
    vm.setDocument("t.xyz", "", "no formatter here\n",
        [HighlightEvent.sourceSpan(0, 18)], PreviewModel.init,
        TwoslashReturn.init, "xyz");

    // FMV2: reports why, stays off, view untouched.
    const msg = formatPreviewToggle(vm);
    assert(msg !is null && msg.length);
    assert(!formatPreviewActive(vm));
    assert(vm.source == "no formatter here\n");
}
