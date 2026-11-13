/** Background discovery of selectable highlighting languages. */
module sparkles.source_view.language_catalog;

import core.time : MonoTime, seconds;
import sparkles.event_horizon.raw_pool : CpuJob, RawCompletion, RawCpuPool, RawPoolResult;
import sparkles.syntax.ts.registry : GrammarRegistry;

/**
One background discovery for one registry. Call poll on the owning thread;
ready names exclude the application's explicit plain-text option. Discovery
failures are visible and never install a truncated result. Keep the catalog
alive until shutdown joins the worker and drains its completion.
*/
final class LanguageCatalog
{
    private alias Pool = RawCpuPool!(2, 2, CpuJob);
    private Pool pool;
    private Job job;
    private bool started, stopped, ready_;
    private string[] names_;
    private string error_;

    private final class Job
    {
        GrammarRegistry registry;
        string[] names;
        string error;
        bool complete;
    }

    /// Start bounded discovery; thread/queue failures are an immediately ready error.
    this(GrammarRegistry registry) @safe nothrow
    {
        job = new Job;
        job.registry = registry;
        started = Pool.start(pool, 1) == RawPoolResult.accepted;
        if (!started || pool.submit(CpuJob(&work, &completed,
            (() @trusted => cast(void*) job)(), 1)) != RawPoolResult.accepted)
        {
            error_ = "Language discovery could not start; Plain text remains available.";
            ready_ = true;
        }
    }

    /// Publish a completed discovery; names remain stable afterward.
    bool poll() @safe nothrow
    {
        if (stopped || ready_) return false;
        RawCompletion completion;
        while (pool.pollCompletion(completion) == RawPoolResult.accepted) completion.dispatch();
        if (!job.complete) return false;
        names_ = job.names;
        error_ = job.error;
        ready_ = true;
        return true;
    }

    /// True after completion or a visible startup failure.
    bool ready() const @safe pure nothrow @nogc => ready_;
    /// A worker is outstanding until publication or shutdown.
    bool busy() const @safe pure nothrow @nogc => !ready_ && !stopped;
    /// Sorted registry names, borrowed until this catalog is released.
    const(string)[] names() const @safe pure nothrow @nogc => names_;
    /// A discovery failure contains no document contents.
    string error() const @safe pure nothrow @nogc => error_;

    /// Join discovery before releasing its registry and job storage.
    void shutdown() @safe nothrow
    {
        if (stopped) return;
        stopped = true;
        if (!started) return;
        pool.shutdown(false);
        RawCompletion completion;
        while (pool.pollCompletion(completion) == RawPoolResult.accepted) completion.dispatch();
    }

    private static void work(void* raw) @safe nothrow
    {
        auto job = (() @trusted => cast(Job) raw)();
        try { job.names = job.registry.languages(); }
        catch (Exception) { job.error = "Language discovery failed; Plain text remains available."; }
    }

    private static void completed(void* raw, bool cancelled) @safe nothrow @nogc
    {
        auto job = (() @trusted => cast(Job) raw)();
        if (cancelled) job.error = "Language discovery was cancelled.";
        job.complete = true;
    }
}

/// Discovery stays off the frame thread; results are published only by poll.
@("source_view.languageCatalog.discoveryAndShutdown")
@safe unittest
{
    import core.thread : Thread;
    auto catalog = new LanguageCatalog(GrammarRegistry.fromDirs(["/nonexistent-grammar-root"]));
    scope (exit) catalog.shutdown();
    const deadline = MonoTime.currTime + 3.seconds;
    while (!catalog.ready && MonoTime.currTime < deadline)
    {
        catalog.poll();
        (() @trusted => Thread.yield())();
    }
    assert(catalog.ready && !catalog.error.length && !catalog.names.length);
    catalog.shutdown();
    assert(!catalog.busy);
}

/// A malformed registry root reports failure rather than presenting partial discovery as success.
@("source_view.languageCatalog.failedDiscovery")
@system unittest
{
    import core.thread : Thread;
    import std.file : remove, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;
    const path = buildPath(tempDir, "sparkles-language-root-" ~ randomUUID.toString());
    write(path, "This is a file, not a grammar directory.");
    scope (exit) remove(path);
    auto catalog = new LanguageCatalog(GrammarRegistry.fromDirs([path]));
    scope (exit) catalog.shutdown();
    const deadline = MonoTime.currTime + 3.seconds;
    while (!catalog.ready && MonoTime.currTime < deadline)
    {
        catalog.poll();
        Thread.yield();
    }
    assert(catalog.ready && catalog.error.length && !catalog.names.length);
}
