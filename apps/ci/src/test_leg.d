/**
A test action run through the test runner's core (ci task-DAG CIC11,
test-runner process-model TRM5–TRM7): one leg of one test binary, driven as
supervised worker processes on the executor's scheduler, never through the
standalone runner or dub.

The build graph plans a test action as the process `binary [druntime options]
[runner options] -t N`. `ci` runs it as the in-process action `test:leg`
instead (`legAction`), whose handler (`runTestLeg`) parses the runner options
with the core's parser, starts workers on demand up to `N` (TRS1), places the
selected tests on them phase by phase (TRS2), ends them one at a time with
the coverage-merge rule (TRS4, TRS5), and reports the lines the core's
plain-text renderer makes of their events. The leg's outcome is the core's
verdict (TRM4).
*/
module test_leg;

import core.time : Duration, MonoTime, msecs;

import std.algorithm.searching : canFind, startsWith;
import std.conv : text, to;

import sparkles.build_primitives.task.action : InProcessAction, ProcessAction;
import sparkles.build_primitives.task.executor : TaskContext;
import sparkles.build_primitives.task.model : Failed, FailureReason, OutputStream, Succeeded, TaskOutcome;
import sparkles.event_horizon.sched : Sched;

/// The name ci registers the handler under.
enum legHandler = "test:leg";

/**
`p`, a test action's concrete process, as the in-process action that runs it
through the core: its working directory, time limit and environment, then
`--` and its argument vector.
*/
InProcessAction legAction(const ProcessAction p) @safe pure
{
    string[] arguments = ["cwd=" ~ p.cwd, text("timeout=", p.timeout.total!"msecs")];
    foreach (e; p.envDelta)
        arguments ~= "env=" ~ e.name ~ "=" ~ e.value;
    arguments ~= "--";
    arguments ~= p.argv.dup;
    return InProcessAction(legHandler, arguments);
}

/// What `legAction` encoded.
struct Leg
{
    string cwd;            ///
    Duration timeout;      /// `Duration.zero` is none
    string[] environment;  /// `NAME=value`, the whole environment
    string binary;         ///
    string[] druntime;     /// the `--DRT-` options every worker is started with
    string[] runnerArgs;   /// the rest: the runner's options
}

/// Decodes `legAction`'s arguments; null `why` when they hold.
Leg decodeLeg(const string[] arguments, out string why) @safe pure
{
    Leg leg;
    size_t i;
    for (; i < arguments.length && arguments[i] != "--"; ++i)
    {
        const a = arguments[i];
        if (a.startsWith("cwd="))
            leg.cwd = a["cwd=".length .. $];
        else if (a.startsWith("timeout="))
            leg.timeout = a["timeout=".length .. $].to!long.msecs;
        else if (a.startsWith("env="))
            leg.environment ~= a["env=".length .. $];
        else
        {
            why = "test:leg: an unknown argument " ~ a;
            return leg;
        }
    }
    if (i + 1 >= arguments.length)
    {
        why = "test:leg: no test binary";
        return leg;
    }
    leg.binary = arguments[i + 1];
    foreach (a; arguments[i + 2 .. $])
        if (a.startsWith("--DRT-"))
            leg.druntime ~= a;
        else
            leg.runnerArgs ~= a;
    return leg;
}

@("test_leg.legAction.roundTrip")
@safe pure
unittest
{
    import core.time : minutes;
    import sparkles.build_primitives.task.action : EnvEntry;

    auto p = ProcessAction(argv: ["/r/t", "--DRT-covopt=dstpath:/o", "-i", "x", "-t", "2"],
        envDelta: [EnvEntry("PATH", "/bin"), EnvEntry("HOME", "/h")], cwd: "/r", timeout: 20.minutes);
    const action = legAction(p);
    assert(action.handler == legHandler);
    string why;
    const leg = decodeLeg(action.arguments, why);
    assert(why is null, why);
    assert(leg.cwd == "/r" && leg.timeout == 20.minutes);
    assert(leg.environment == ["PATH=/bin", "HOME=/h"]);
    assert(leg.binary == "/r/t" && leg.druntime == ["--DRT-covopt=dstpath:/o"]);
    assert(leg.runnerArgs == ["-i", "x", "-t", "2"]);
}

version (Posix):

import sparkles.event_horizon.proc : ProcessEvent, ProcessEventKind, ProcessStream, SupervisedProcessConfig;
import sparkles.event_horizon.supervise : StdinFeed, superviseFed;
import sparkles.test_runner.model : Test;
import sparkles.test_runner.options : RunnerOptions;
import sparkles.test_runner.session : EventKind, RunnerEvent, WorkerSession, describeEnding, workerArguments;

/// One worker process and its session.
private final class Worker
{
    WorkerSession session;
    StdinFeed feed;
    bool ready;      // its listing arrived
    bool waiting;    // idle, with no test left for it in its phase
    bool exitSent;
    bool ended;      // its supervised run returned
    size_t index;    // start order, which is also exit order (TRS4)

    this(string binary, size_t index) @safe
    {
        session = WorkerSession(binary);
        this.index = index;
    }
}

/// A leg in flight.
private struct LegRun
{
    Leg leg;
    Sched* sched;
    void delegate(string) @safe emit;  // one rendered line of the leg's output
    bool verbose;

    Test[] listing;       // the first worker's
    Test[] queue;         // the current phase's tests not yet taken
    bool mainThread;      // the current phase runs on the worker's main thread
    Worker[] workers;     // the current phase's
    size_t started, exited;
    size_t passed, failed, skipped, executed, done;
    MonoTime phaseStart, lastProgress;
    bool broken;          // a protocol error or a worker that would not start
    bool callerMerges;    // the druntime options already ask to merge (TRS5)
    bool coverage;        // the binary's hello reports coverage compiled in
    bool driverFailed;    // an extracted mode failed, or was skipped under --require-toolchain

    // Takes the session's events: renders them and counts results.
    void drain(Worker w)
    {
        import sparkles.test_runner.render : plainLines;

        foreach (ev; w.session.takeEvents())
        {
            final switch (ev.kind)
            {
                case EventKind.workerReady:
                    w.ready = true;
                    if (!listing.length)
                    {
                        listing = w.session.listing.dup;
                        coverage = w.session.hello.coverage;
                    }
                    break;
                case EventKind.testFinished:
                    ++done;
                    ++executed;
                    lastProgress = MonoTime.currTime;
                    if (ev.result.skipped)
                        ++skipped;
                    else if (ev.result.succeeded)
                        ++passed;
                    else
                        ++failed;
                    break;
                case EventKind.protocolError:
                    broken = true;
                    break;
                case EventKind.testStarted, EventKind.testOutput, EventKind.commandFrame,
                    EventKind.commandFinished, EventKind.workerEnded:
                    break;
            }
            foreach (line; plainLines(ev, verbose))
                emit(line);
        }
        // An idle worker takes the next test of its phase, or waits for its
        // turn to exit.
        if (w.session.idle && !w.exitSent)
        {
            if (queue.length)
            {
                const t = queue[0];
                queue = queue[1 .. $];
                cast(void) w.feed.tryPut(cast(immutable(ubyte)[]) w.session.run(t.id, mainThread));
                w.waiting = false;
            }
            else
                w.waiting = true;
        }
    }

    // Runs worker `w` to its end; the body of its fiber.
    void runWorker(Worker w)
    {
        SupervisedProcessConfig cfg;
        cfg.process.cwd = leg.cwd;
        cfg.process.env = leg.environment;
        cfg.timeout = leg.timeout;
        cfg.collectOutput = false;
        cfg.maxLineBytes = 64 * 1024 * 1024; // a frame is one line, and must arrive whole
        cfg.sampleInterval = Duration.zero;
        void onEvent(in ProcessEvent ev)
        {
            final switch (ev.kind)
            {
                case ProcessEventKind.line:
                    auto bytes = cast(const(char)[]) ev.line.bytes;
                    const nl = ev.line.terminated ? "\n" : "";
                    if (ev.line.stream == ProcessStream.stdout_)
                        w.session.feedFrames(bytes ~ nl);
                    else
                        w.session.feedOutput(bytes ~ nl);
                    break;
                case ProcessEventKind.sample:
                    break;
                case ProcessEventKind.exited:
                    w.session.feedOutputClosed();
                    w.session.feedEnd(describeEnding(ev.status.signaled ? -ev.status.code : ev.status.code));
                    break;
            }
            drain(w);
        }
        const argv = workerArguments(leg.binary, leg.druntime);
        auto got = (() @trusted => superviseFed(*sched, argv, cfg, &w.feed, &onEvent))();
        if (got.hasError || got.value.spawnError.code != 0)
        {
            broken = true;
            emit(text("error: cannot start ", leg.binary, got.hasError ? ": " ~ got.error.context : ""));
        }
        w.ended = true;
        w.waiting = true;
        if (!w.session.over)
        {
            w.session.feedOutputClosed();
            w.session.feedEnd("ended");
            drain(w);
        }
    }
}

/**
Runs the leg `action` encodes (`legAction`) on `ctx`'s scheduler, reporting
the core's plain-text lines as the task's output; its outcome is the core's
verdict.
*/
TaskOutcome runTestLeg(ref TaskContext!Sched ctx, const ref InProcessAction action)
{
    import sparkles.event_horizon.io : sleep;
    import sparkles.event_horizon.scope_ : withScope;
    import sparkles.test_runner.options : parseRunnerOptions;
    import sparkles.test_runner.plan : selectTests, testPhases, verdict, workersWanted;
    import sparkles.test_runner.render : summaryLine;

    string why;
    auto leg = decodeLeg(action.arguments, why);
    void say(string line) @safe
    {
        // `@trusted`: the context's writer is the executor's, which outlives the leg.
        (() @trusted => ctx.output(OutputStream.stdout, line))();
    }
    if (why.length)
    {
        say(why);
        return TaskOutcome(Failed(FailureReason.contract));
    }
    auto parsed = parseRunnerOptions(["ci"] ~ leg.runnerArgs);
    if (parsed.error.length || parsed.helpWanted)
    {
        say("error: " ~ (parsed.error.length ? parsed.error : "a test action cannot ask for help"));
        return TaskOutcome(Failed(FailureReason.contract));
    }
    const options = parsed.options;
    const cap = options.threads ? options.threads : 1;

    LegRun run;
    run.leg = leg;
    run.sched = ctx.exec;
    run.emit = &say;
    run.verbose = options.verbose;
    run.callerMerges = leg.druntime.canFind!(o => o.canFind("merge:1"));

    // A phase: workers on demand up to `threads`, each idle one taking the
    // next test, then ended one at a time.
    void runPhase(ref Sched s, Test[] tests, size_t threads, bool mainThread, Worker first)
    {
        run.queue = tests;
        run.mainThread = mainThread;
        run.phaseStart = run.lastProgress = MonoTime.currTime;
        run.done = 0;
        cast(void) withScope!((ref sc) {
            void start(Worker w)
            {
                run.workers ~= w;
                sc.spawn(() { run.runWorker(w); });
            }
            if (first !is null)
            {
                run.workers ~= first;
                run.drain(first); // the listing worker takes its first test
            }
            if (!run.workers.length)
                start(new Worker(leg.binary, run.started++));
            for (;;)
            {
                import std.algorithm.searching : all, count;

                // Cancelled (fail-fast, a timeout) or broken: the workers'
                // supervision tears their process trees down (TDE1, TDE2).
                if (run.broken || ctx.cancelRequested)
                {
                    sc.cancel();
                    return;
                }
                const live = run.workers.count!(w => !w.ended);
                const busy = run.workers.count!(w => !w.ended && !w.waiting);
                if (!run.queue.length && busy == 0)
                    break;
                // A worker that died mid-phase is replaced while tests wait.
                const now = MonoTime.currTime;
                const wanted = run.queue.length == 0 ? live
                    : workersWanted(run.queue.length, run.done, live ? live : 1, now - run.phaseStart,
                        now - run.lastProgress, threads);
                foreach (_; live .. (wanted > live ? wanted : live ? live : 1))
                    start(new Worker(leg.binary, run.started++));
                cast(void) sleep(s, 20.msecs);
            }
            // TRS4, TRS5: one at a time, the first without merging.
            foreach (w; run.workers)
            {
                if (w.ended)
                    continue;
                const merge = run.callerMerges || run.exited > 0;
                w.exitSent = true;
                if (w.session.idle)
                    cast(void) w.feed.tryPut(cast(immutable(ubyte)[]) w.session.exit(run.coverage && merge));
                w.feed.close();
                while (!w.ended)
                    cast(void) sleep(s, 5.msecs);
                ++run.exited;
            }
            run.workers = null;
        })(s);
    }

    // The first worker lists the binary's tests; the selection follows.
    auto first = new Worker(leg.binary, run.started++);
    cast(void) withScope!((ref sc) {
        sc.spawn(() { run.runWorker(first); });
        while (!first.ready && !first.ended && !run.broken && !ctx.cancelRequested)
            cast(void) sleep(*ctx.exec, 5.msecs);
        if (!first.ready || ctx.cancelRequested)
        {
            sc.cancel();
            return;
        }
        auto selection = selectTests(run.listing, options);
        if (selection.error.length)
        {
            say("error: " ~ selection.error);
            run.broken = true;
            return;
        }
        import std.algorithm.iteration : filter;
        import std.array : array;

        // The extracted modes (TRX, ci task-DAG §5.3): the listing worker
        // ends, and the core's driver compiles and runs the extracted tests
        // off the scheduler, on a blocking pool of the leg's own.
        if (options.betterC || options.wasm || options.wasmBare)
        {
            first.exitSent = true;
            if (first.session.idle)
                cast(void) first.feed.tryPut(cast(immutable(ubyte)[]) first.session.exit(false));
            first.feed.close();
            while (!first.ended && !ctx.cancelRequested)
                cast(void) sleep(*ctx.exec, 5.msecs);
            if (ctx.cancelRequested)
            {
                sc.cancel();
                return;
            }
            auto modes = runDriverModes(*ctx.exec, selection.tests, options, first.session.hello.roots);
            foreach (line; modes.lines)
                say(line);
            run.executed = modes.executed;
            run.passed = modes.passed;
            run.failed = modes.executed - modes.passed;
            run.broken = modes.failed && !modes.executed;
            run.driverFailed = modes.failed;
            return;
        }
        auto runnable = selection.tests
            .filter!(t => !t.traits.isCtfe && !t.traits.isBenchmark && !t.traits.isWorkload).array;
        Worker reuse = first;
        foreach (phase; testPhases(runnable, cap))
        {
            if (!phase.tests.length || run.broken)
                continue;
            import sparkles.test_runner.attributes : ThreadAffinity;

            // The last phase's tests run on a worker's main thread (TRP17).
            const onMain = phase.tests[0].traits.isSerial
                && phase.tests[0].traits.serialAffinity == ThreadAffinity.mainThread;
            runPhase(*ctx.exec, phase.tests, phase.threads, onMain, reuse);
            reuse = null;
            // The listing worker is this scope's: cancelled with it.
            if (ctx.cancelRequested || run.broken)
            {
                sc.cancel();
                return;
            }
        }
        // No phase took the listing worker: end it.
        if (reuse !is null && !reuse.ended)
        {
            reuse.exitSent = true;
            if (reuse.session.idle)
                cast(void) reuse.feed.tryPut(cast(immutable(ubyte)[]) reuse.session.exit(false));
            reuse.feed.close();
            while (!reuse.ended)
                cast(void) sleep(*ctx.exec, 5.msecs);
        }
    })(*ctx.exec);

    say(summaryLine(run.passed, run.failed, run.skipped));
    if (ctx.cancelRequested)
        return TaskOutcome(Failed(FailureReason.signal));
    if (run.broken || !run.listing.length && run.executed == 0 && run.started == 0)
        return TaskOutcome(Failed(FailureReason.exitStatus, 1));
    if (run.driverFailed)
        return TaskOutcome(Failed(FailureReason.exitStatus, 1));
    const status = verdict(run.executed, run.passed + run.skipped);
    return status == 0 ? TaskOutcome(Succeeded()) : TaskOutcome(Failed(FailureReason.exitStatus, status));
}

/// What the extracted modes did: their lines, and their counts.
private struct DriverRun
{
    string[] lines;
    size_t executed, passed;
    bool failed;
}

/**
The `--better-c`, `--wasm` and `--wasm-bare` modes of the core's driver over
`tests` (the binary's listing, with its harness's `roots`), as the standalone
runner's `runDriverModes` runs them: a skipped mode, its toolchain missing,
fails under `--require-toolchain`. The driver compiles and runs programs with
blocking calls, so it runs on a blocking pool, parking the leg's fiber.
*/
private DriverRun runDriverModes(ref Sched s, Test[] tests, const RunnerOptions options, const string[] roots)
{
    import sparkles.event_horizon.blocking_pool : BlockingPool;
    import sparkles.test_runner.driver : DriverOptions, DriverOutcome, ModeReport, runBetterCTests,
        runWasmBareTests, runWasmTests;

    static struct Job
    {
        Test[] tests;
        RunnerOptions options;
        string[] roots;
        DriverRun result;
        string pending;
    }

    static void call(void* context) nothrow
    {
        auto job = cast(Job*) context;
        try
        {
            import std.algorithm.iteration : filter, splitter;
            import std.array : array;

            void take(string text) @trusted
            {
                job.pending ~= text;
            }
            const o = job.options;
            auto driver = DriverOptions(compiler: o.compiler, importPaths: o.importPaths.dup,
                includeImports: o.includeImports.dup, noAutoInclude: o.noAutoInclude, keep: o.keep,
                verbose: o.verbose, report: ModeReport(&take, &take), stringImportPaths: o.stringImportPaths.dup,
                versions: o.versions.dup, dflags: o.dflags.dup, probeDir: o.probeDir, noDub: o.noDub,
                harnessRoots: job.roots);
            void account(DriverOutcome outcome)
            {
                if (outcome.skipped)
                {
                    job.result.failed |= o.requireToolchain;
                    return;
                }
                job.result.executed += outcome.testCount;
                job.result.passed += outcome.succeeded ? outcome.testCount : 0;
                job.result.failed |= !outcome.succeeded;
            }
            if (o.betterC)
                account(runBetterCTests(job.tests.filter!(t => t.traits.isBetterC).array, job.tests, driver));
            if (o.wasm)
                account(runWasmTests(job.tests.filter!(t => t.traits.isWasm).array, job.tests, driver));
            if (o.wasmBare)
                account(runWasmBareTests(job.tests.filter!(t => t.traits.isWasm).array, job.tests, driver));
            foreach (line; job.pending.splitter('\n'))
                job.result.lines ~= line;
        }
        catch (Throwable t)
        {
            job.result.failed = true;
            job.result.lines ~= "error: the extracted modes failed: " ~ t.msg;
        }
    }

    auto job = new Job(tests, cast(RunnerOptions) options, roots.dup);
    BlockingPool pool;
    if (BlockingPool.create(pool, 1, 2).hasError)
        return DriverRun(["error: no blocking pool for the extracted modes"], 0, 0, true);
    scope (exit)
        cast(void) pool.shutdown();
    const ran = (() @trusted => pool.run(s, &call, cast(void*) job))();
    if (ran.hasError)
        return DriverRun(["error: the extracted modes did not run: " ~ ran.error.context], 0, 0, true);
    return job.result;
}
