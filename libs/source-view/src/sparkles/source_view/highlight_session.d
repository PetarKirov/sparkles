/** Bounded background highlighting with document/revision-safe publication. */
module sparkles.source_view.highlight_session;

import core.atomic : atomicLoad, atomicStore;
import core.time : msecs;
import sparkles.event_horizon.raw_pool : CpuJob, RawCompletion, RawCpuPool, RawPoolResult;
import sparkles.syntax.event : byStyledSpan, HighlightEvent, StyledSpan;
import sparkles.syntax.label : LabelSet;
import sparkles.syntax.ts.config : TsHighlightConfig;
import sparkles.syntax.ts.highlighter : highlight, HighlightOptions;
import sparkles.syntax.ts.registry : GrammarRegistry;
import sparkles.tree_sitter.errors : TsError;
import sparkles.text_buffer.text : Text;

/// A completed snapshot: source owns the byte ranges referred to by spans.
class HighlightSnapshot
{
    Text revision;
    string source;
    string language;
    ulong document, generation;
    StyledSpan[] spans;
    string error;
    private shared bool cancelled;
    private bool complete;
}

/// One running job and one latest request; obsolete work is cancelled, never queued without bound.
/// Keep the session alive through shutdown. Call shutdown before releasing the host's last reference.
class HighlightSession
{
    private alias Pool = RawCpuPool!(2, 2, CpuJob);
    private Pool pool;
    private bool started, stopped, startFailed;
    private HighlightSnapshot pending, wanted, accepted;
    private ulong generation;
    string error;

    /// Observe a new document revision without copying its bytes on the frame thread.
    void request(in Text revision, string language, ulong document) @safe
    {
        if (stopped) return;
        if (wanted !is null && wanted.revision == revision
            && wanted.language == language && wanted.document == document) return;
        if (generation == ulong.max) { error = "Highlight generation exhausted."; return; }
        wanted = new HighlightSnapshot;
        wanted.revision = Text(revision);
        wanted.language = language;
        wanted.document = document;
        wanted.generation = ++generation;
        if (pending !is null) atomicStore(pending.cancelled, true);
        launch();
    }

    /// Drain completions on the frame thread; old documents/revisions are never published.
    bool poll() @safe
    {
        bool changed;
        RawCompletion completion;
        while (pool.pollCompletion(completion) == RawPoolResult.accepted)
            completion.dispatch();
        if (pending !is null && pending.complete)
        {
            if (wanted is pending)
            {
                accepted = pending;
                error = accepted.error;
                changed = true;
            }
            pending = null;
        }
        launch();
        return changed;
    }

    /// The last completed snapshot, only when it still matches the caller's current identity.
    const(HighlightSnapshot) snapshot(in Text revision, string language, ulong document) const @safe
    {
        return accepted !is null && accepted.revision == revision
            && accepted.language == language && accepted.document == document ? accepted : null;
    }

    bool busy() const scope @safe pure nothrow @nogc => pending !is null;

    /// Cancel queued work and join the running parser before releasing its inputs.
    void shutdown() @safe nothrow
    {
        if (stopped) return;
        stopped = true;
        if (pending !is null) atomicStore(pending.cancelled, true);
        if (started)
        {
            pool.shutdown(false);
            RawCompletion completion;
            while (pool.pollCompletion(completion) == RawPoolResult.accepted) completion.dispatch();
        }
        pending = null;
        wanted = null;
    }

    private void launch() @safe
    {
        if (stopped || startFailed || pending !is null || wanted is null || wanted is accepted) return;
        if (!started)
        {
            if (Pool.start(pool, 1) != RawPoolResult.accepted)
            {
                error = "Background highlighting could not start; displaying plain text.";
                startFailed = true;
                return;
            }
            started = true;
        }
        const queued = pool.submit(CpuJob(&work, &completed,
            (() @trusted => cast(void*) wanted)(), wanted.generation));
        if (queued == RawPoolResult.accepted) pending = wanted;
        else error = "Highlight queue is busy; displaying plain text.";
    }

    private static void work(void* raw) @safe nothrow
    {
        auto job = (() @trusted => cast(HighlightSnapshot) raw)();
        try
        {
            if (atomicLoad(job.cancelled)) return;
            auto bytes = new char[job.revision.length];
            job.revision.copyTo(0, bytes.length, bytes);
            job.source = (() @trusted => cast(string) bytes)();
            if (atomicLoad(job.cancelled)) return;
            if (!job.language.length || job.language == "text") return;
            auto registry = GrammarRegistry.fromEnvironment();
            auto grammar = registry.grammar(job.language);
            if (grammar.hasError) { job.error = "Grammar unavailable; displaying plain text."; return; }
            auto query = registry.queryText(job.language, "highlights");
            if (query.hasError) { job.error = "Highlight query unavailable; displaying plain text."; return; }
            TsError configError;
            auto config = TsHighlightConfig.create(grammar.value, query.value, configError);
            if (configError || !config.valid) { job.error = "Highlight configuration failed."; return; }
            const labels = LabelSet.standard();
            config.configure(labels);
            import sparkles.base.buffer : UniqueBuffer;
            UniqueBuffer!(HighlightEvent, 64) events;
            const result = (() @trusted => highlight(config, job.source, events,
                HighlightOptions(parseBudget: 100.msecs, queryBudget: 100.msecs,
                    cancelFlag: &job.cancelled)))();
            if (result.hasError) { job.error = "Highlighting interrupted; displaying plain text."; return; }
            size_t count;
            foreach (span; byStyledSpan(events[]))
            {
                if ((count++ & 127) == 0 && atomicLoad(job.cancelled)) return;
                job.spans ~= span;
            }
        }
        catch (Exception)
        {
            job.error = "Highlighting failed; displaying plain text.";
        }
    }

    private static void completed(void* raw, bool cancelled) @safe nothrow @nogc
    {
        auto job = (() @trusted => cast(HighlightSnapshot) raw)();
        if (cancelled) job.error = "Highlighting cancelled.";
        job.complete = true;
    }
}

/// Superseded work cannot publish into the newest document, even if it completes first.
@("source_view.highlightSession.latestRevisionWins")
@safe unittest
{
    import core.thread : Thread;
    import core.time : MonoTime, seconds;
    auto session = new HighlightSession;
    scope (exit) session.shutdown();
    const oldText = Text("old bytes");
    const current = Text("new bytes");
    session.request(oldText, "text", 1);
    session.request(current, "text", 2);
    const until = MonoTime.currTime + 3.seconds;
    while (session.snapshot(current, "text", 2) is null && MonoTime.currTime < until)
    {
        session.poll();
        (() @trusted => Thread.yield())();
    }
    const snapshot = session.snapshot(current, "text", 2);
    assert(snapshot !is null && snapshot.source == "new bytes");
    assert(session.snapshot(oldText, "text", 1) is null);
    assert(session.snapshot(current, "text", 1) is null);
    assert(!session.busy);
    session.shutdown();
    session.request(Text("after shutdown"), "text", 3);
    assert(!session.busy);
}

/// The real grammar produces labeled source runs through the same background interface.
@("source_view.highlightSession.realGrammar")
@safe unittest
{
    import core.thread : Thread;
    import core.time : MonoTime, seconds;
    import std.process : environment;
    import sparkles.test_runner.skip : skipTest;
    if (!environment.get("SPARKLES_TS_GRAMMAR_PATH", "").length)
        skipTest("The derived grammar bundle is not configured.");
    auto session = new HighlightSession;
    scope (exit) session.shutdown();
    const revision = Text("int value = 42;\n");
    session.request(revision, "d", 7);
    const until = MonoTime.currTime + 3.seconds;
    while (session.snapshot(revision, "d", 7) is null && MonoTime.currTime < until)
    {
        session.poll();
        (() @trusted => Thread.yield())();
    }
    const snapshot = session.snapshot(revision, "d", 7);
    assert(snapshot !is null && !snapshot.error.length);
    bool labeled;
    foreach (span; snapshot.spans) labeled |= cast(bool) span.label;
    assert(labeled && snapshot.source == "int value = 42;\n");
}
