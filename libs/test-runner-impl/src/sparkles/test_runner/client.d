/**
 * The standalone runner's I/O around a worker session (process-model TRM1):
 * it starts a test binary as a worker, reads its two channels on threads of
 * its own, feeds the bytes to the core's
 * $(MREF sparkles,test_runner,session) state machine, and writes the commands
 * the session returns. Callers block on a command's outcome.
 */
module sparkles.test_runner.client;

import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import std.json : JSONValue;
import std.process : ProcessPipes;

import sparkles.test_runner.model : Test, TestResult, Thrown;
import sparkles.test_runner.session;

public import sparkles.test_runner.session : decodeResult, describeEnding, Hello;

/// Thrown when a worker exits, or is killed, before a command's last frame;
/// and, with `outsideCommand`, when it ends between commands without being
/// asked to (TRP27) or ends badly once asked to (TRP22).
class WorkerDied : Exception
{
    /// How the worker ended: an exit status, a signal or an exception code.
    string ending;
    /// Output the worker wrote for the command that died with it.
    string output;
    /// Whether it ended with no command in flight: no test is to blame, and
    /// the run fails (TRP27).
    bool outsideCommand;

    this(string ending, string output) @safe pure nothrow
    {
        this(ending, output, "the test binary " ~ ending);
    }

    /// An ending outside any command; `when` says where ("between tests").
    static WorkerDied outside(string ending, string when) @safe pure nothrow
    {
        auto e = new WorkerDied(ending, null, "the test binary " ~ ending ~ " " ~ when);
        e.outsideCommand = true;
        return e;
    }

    private this(string ending, string output, string message) @safe pure nothrow
    {
        super(message);
        this.ending = ending;
        this.output = output;
    }
}

/// Thrown on a protocol error (TRP9, TRP11, TRP15).
class ProtocolError : Exception
{
    this(string msg) @safe pure nothrow
    {
        super(msg);
    }
}

/// Where unattributed worker output goes; the runner prints it.
alias StrayHandler = void delegate(string text);

/// One worker process.
final class Worker
{
    private ProcessPipes pipes;
    private Mutex mutex;
    private Condition changed;
    private WorkerSession session;
    private RunnerEvent[] queue;
    private StrayHandler onStray;
    private bool outputClosed;
    private bool processEnded; // the frames reader has reaped the worker
    private Thread framesReader;
    private Thread outputReader;

    /// Whether the process has ended.
    bool dead;

    /// What the handshake said.
    Hello hello() => session.hello;
    /// The listing (TRP13), each test's `ptr` null.
    Test[] listing() => session.listing;

    /**
    Starts `binary` as a worker and completes the handshake. `druntimeOptions`
    are passed through (TRS5). Throws `ProtocolError` on a version mismatch or
    a binary that does not speak the protocol.
    */
    this(string binary, string[] druntimeOptions, StrayHandler onStray)
    {
        import std.process : Config, pipeProcess, Redirect;

        this.onStray = onStray;
        mutex = new Mutex;
        changed = new Condition(mutex);
        session = WorkerSession(binary);
        Config config;
        version (Posix)
        {
            ignoreBrokenPipes();
            config.preExecFunction = &restoreBrokenPipes;
        }
        pipes = pipeProcess(workerArguments(binary, druntimeOptions), Redirect.all, null, config);
        framesReader = new Thread(&readFrames);
        framesReader.isDaemon = true;
        framesReader.start();
        outputReader = new Thread(&readOutput);
        outputReader.isDaemon = true;
        outputReader.start();

        foreach (ref e; await((ref RunnerEvent e) => e.kind == EventKind.workerReady))
            cast(void) e;
    }

    /// Sends a bench or probe command and returns its frames, up to and
    /// including the one of type `last`. Throws `WorkerDied` when the worker
    /// ends first.
    JSONValue[] request(JSONValue command, string last)
    {
        string bytes;
        synchronized (mutex)
            if (!session.over)
                bytes = session.request(command, last);
        if (!bytes.length || !send(bytes))
            endedBetweenCommands();
        JSONValue[] frames;
        foreach (ref e; await((ref RunnerEvent e) => e.kind == EventKind.commandFinished))
            if (e.kind == EventKind.commandFrame)
                frames ~= e.frame;
        return frames;
    }

    /// Runs test `id` (TRP16) and returns its result, with its output. A
    /// worker that dies during the test yields a failed result (TRP26), and
    /// this worker is then dead. One that ended since its last command, or
    /// before the test started, throws `WorkerDied` with `outsideCommand` set
    /// (TRP27).
    TestResult run(size_t id, bool mainThread)
    {
        string bytes;
        synchronized (mutex)
            if (!session.over)
                bytes = session.run(id, mainThread);
        if (!bytes.length || !send(bytes))
            endedBetweenCommands();
        TestResult result;
        try
            foreach (ref e; await((ref RunnerEvent e) => e.kind == EventKind.testFinished,
                    diesAfterResult: true))
                if (e.kind == EventKind.testFinished)
                    result = e.result;
        catch (WorkerDied e)
            // The session blames a test only once it has started: an end
            // before that raced the command, and no test is to blame.
            throw e.outsideCommand ? e : WorkerDied.outside(e.ending, "between tests");
        return result;
    }

    /// The failed result of `test`, whose worker died running it.
    static TestResult crashed(Test test, WorkerDied e)
    {
        auto result = TestResult(test: test);
        result.thrown = [Thrown(type: "worker crashed",
            message: "the test binary " ~ e.ending ~ " while running this test")];
        result.output = e.output;
        return result;
    }

    /**
    Asks the worker to exit (TRP22) and waits for it. Throws `WorkerDied`
    with `outsideCommand` set when the worker had already ended without
    being asked to (TRP27), or ends with anything but status 0 (TRP22), and
    `ProtocolError` when it broke the protocol since its last command.
    */
    void exit(bool coverageMerge)
    {
        string bytes;
        synchronized (mutex)
            if (!session.over)
                bytes = session.exit(coverageMerge);
        try
        {
            // A worker known to be gone is not written to; end of file alone
            // ends one that is still there (TRP22).
            if (bytes.length)
                cast(void) send(bytes);
            pipes.stdin.close();
        }
        catch (Exception)
        {
            // Already gone: its status is all that is left.
        }
        // However long it takes: a worker that is still exiting may yet fail
        // the run, as a module destructor that aborts late does (TRP22).
        synchronized (mutex)
            while (!session.over)
                changed.wait();
        dead = true;
        joinReaders();
        RunnerEvent[] batch;
        synchronized (mutex)
        {
            batch = queue;
            queue = null;
        }
        foreach (ref e; batch)
        {
            if (e.kind == EventKind.testOutput && e.test == noTest)
                onStray(e.text ~ "\n");
            else if (e.kind == EventKind.protocolError)
                throw new ProtocolError(e.text);
            else if (e.kind == EventKind.workerEnded && !e.expected)
                throw WorkerDied.outside(e.text, "between tests");
            else if (e.kind == EventKind.workerEnded && e.text != describeEnding(0))
                throw WorkerDied.outside(e.text, "after it was asked to exit");
        }
    }

    /**
    Waits for the two channel readers to finish, once the worker process has
    ended; a worker still running (one given up on after a protocol error)
    keeps them. They are daemon threads, which druntime does not join: one
    still finishing when the runner's `main` returns races druntime's
    termination, which destroys the thread-list lock the exiting thread
    takes — macOS aborts with "Error: pthread_mutex_destroy failed.", Linux
    dies of SIGSEGV. Each stops within `deadCutoff` of the worker's end
    (TRP28), so the wait is bounded. Idempotent.
    */
    void joinReaders()
    {
        synchronized (mutex)
            if (!processEnded)
                return;
        foreach (reader; [framesReader, outputReader])
            if (reader !is null)
                cast(void) reader.join(rethrow: false);
    }

    /// Writes `bytes` to the worker's commands; `false` when nothing reads
    /// them any more, the worker having ended or closed its end (TRP27).
    private bool send(string bytes)
    {
        try
        {
            pipes.stdin.write(bytes);
            pipes.stdin.flush();
            return true;
        }
        catch (Exception)
            return false; // EPIPE, which SIGPIPE no longer pre-empts
    }

    /// The session ended, or gave up on the worker, with no command in flight
    /// (TRP27): prints the worker's unattributed output and throws what ended
    /// it, a `ProtocolError` or a `WorkerDied` with `outsideCommand` set.
    private noreturn endedBetweenCommands()
    {
        try
            cast(void) await((ref RunnerEvent e) => false);
        catch (WorkerDied e)
            throw WorkerDied.outside(e.ending, "between tests");
        assert(0, "a session that is over has queued how it ended");
    }

    /**
    Waits until an event satisfies `done`, and returns every event up to it.
    A protocol error throws `ProtocolError`; the worker's end throws
    `WorkerDied`, unless `diesAfterResult` and `done` already held for a
    crash. An end that follows a command that finished is left queued: the
    worker ended between commands, which the next command or `exit` reports
    (TRP27).
    */
    private RunnerEvent[] await(scope bool delegate(ref RunnerEvent) done,
        bool diesAfterResult = false)
    {
        RunnerEvent[] taken;
        bool finished;
        for (;;)
        {
            RunnerEvent[] batch;
            synchronized (mutex)
            {
                while (!queue.length)
                    changed.wait();
                batch = queue;
                queue = null;
            }
            foreach (i, ref e; batch)
            {
                if (e.kind == EventKind.testOutput && e.test == noTest)
                {
                    onStray(e.text ~ "\n");
                    continue;
                }
                if (e.kind == EventKind.protocolError)
                {
                    dead = true;
                    throw new ProtocolError(e.text);
                }
                if (e.kind == EventKind.workerEnded)
                {
                    if (finished && !(diesAfterResult && isCrash(taken)))
                    {
                        synchronized (mutex)
                            queue = batch[i .. $] ~ queue;
                        return taken;
                    }
                    dead = true;
                    if (finished)
                        return taken;
                    throw new WorkerDied(e.text, null);
                }
                taken ~= e;
                if (done(e))
                    finished = true;
            }
            if (finished && !(diesAfterResult && isCrash(taken)))
                return taken;
        }
    }

    /// Whether the last `testFinished` in `events` is a crash, after which
    /// the worker's end follows.
    private static bool isCrash(in RunnerEvent[] events)
    {
        foreach_reverse (ref e; events)
            if (e.kind == EventKind.testFinished)
                return e.result.thrown.length && e.result.thrown[0].type == "worker crashed";
        return false;
    }

    private void publish()
    {
        queue ~= session.takeEvents();
        changed.notifyAll();
    }

    private void readFrames()
    {
        import core.time : MonoTime, msecs;
        import std.process : wait;

        const fd = pipes.stdout.fileno;
        ubyte[4096] buffer;
        int status;
        bool exited;
        MonoTime exitedAt;
        for (;;)
        {
            version (Posix)
            {
                // A child the test forked may hold this pipe open after the
                // worker died, so end of file cannot be what says it died
                // (TRP28): look for its end every tenth of a second, and once
                // it has ended read only the frames it left in the pipe.
                if (!exited)
                {
                    import std.process : tryWait;

                    const r = tryWait(pipes.pid);
                    if (r.terminated)
                    {
                        exited = true;
                        status = r.status;
                        exitedAt = MonoTime.currTime;
                    }
                }
                if (!readable(fd, exited ? 0 : 100))
                {
                    if (exited)
                        break;
                    continue;
                }
                if (exited && MonoTime.currTime - exitedAt >= deadCutoff)
                    break; // a descendant writing on: no longer this worker's frames
            }
            const n = readSome(fd, buffer[]);
            if (n <= 0)
                break;
            synchronized (mutex)
            {
                session.feedFrames(cast(const(char)[]) buffer[0 .. n]);
                publish();
            }
        }
        if (!exited)
        {
            status = wait(pipes.pid);
            exitedAt = MonoTime.currTime;
        }
        // A descendant still holding the pipe gets EPIPE on its next write.
        pipes.stdout.close();
        synchronized (mutex)
        {
            processEnded = true;
            session.feedEnd(describeEnding(status));
            publish();
            // Likewise for the output pipe: stop at end of file or at the
            // cutoff after the worker's end (TRP28). The output reader sees
            // the cutoff, publishes nothing more, and closes our end.
            const deadline = exitedAt + deadCutoff;
            while (!outputClosed && MonoTime.currTime < deadline)
                changed.wait(100.msecs);
            if (!outputClosed)
            {
                outputClosed = true;
                session.feedOutputClosed();
                publish();
            }
        }
    }

    private void readOutput()
    {
        const fd = pipes.stderr.fileno;
        ubyte[4096] buffer;
        for (;;)
        {
            // Wait for bytes a tenth of a second at a time, so that the cutoff
            // (TRP28) ends this thread even while a descendant of a dead
            // worker keeps the pipe open and quiet.
            version (Posix)
                if (!readable(fd, 100))
                {
                    synchronized (mutex)
                        if (outputClosed)
                            break;
                    continue;
                }
            const n = readSome(fd, buffer[]);
            if (n <= 0)
                break;
            synchronized (mutex)
            {
                if (outputClosed)
                    break; // after the cutoff: no longer this worker's output
                session.feedOutput(cast(const(char)[]) buffer[0 .. n]);
                publish();
            }
        }
        synchronized (mutex)
        {
            if (!outputClosed)
            {
                outputClosed = true;
                session.feedOutputClosed();
                publish();
            }
        }
        // A descendant still holding the pipe gets EPIPE on its next write.
        pipes.stderr.close();
    }
}

/// How long after a worker's end its channels are still read: a descendant
/// may hold them open (TRP28).
private enum deadCutoff = imported!"core.time".seconds(1);

/// Reads what has arrived on `fd`, at most `buffer.length` bytes; `0` at end
/// of file, negative on an error. `File.rawRead` is `fread`, which blocks
/// until the buffer is full; a pipe needs what has arrived.
private ptrdiff_t readSome(int fd, ubyte[] buffer) @trusted
{
    version (Posix)
    {
        import core.stdc.errno : EINTR, errno;
        import core.sys.posix.unistd : read;

        for (;;)
        {
            const n = read(fd, buffer.ptr, buffer.length);
            if (n >= 0 || errno != EINTR)
                return n;
        }
    }
    else version (Windows)
        return _read(fd, buffer.ptr, cast(uint) buffer.length);
}

version (Windows)
    private extern (C) int _read(int, void*, uint) nothrow @nogc;

version (Posix)
{
    /// Makes a write to a worker that has gone fail with `EPIPE` instead of
    /// ending this process with `SIGPIPE`, so the run can report the end
    /// (TRP27). Process-wide, and idempotent.
    private void ignoreBrokenPipes() @trusted nothrow @nogc
    {
        import core.stdc.signal : signal, SIG_IGN;
        import core.sys.posix.signal : SIGPIPE;

        signal(SIGPIPE, SIG_IGN);
    }

    /// Run in the worker before it starts: an ignored signal stays ignored
    /// across `exec`, and the tests must get the default action they would
    /// get anywhere else.
    private bool restoreBrokenPipes() @trusted nothrow @nogc
    {
        import core.stdc.signal : signal, SIG_DFL, SIG_ERR;
        import core.sys.posix.signal : SIGPIPE;

        return signal(SIGPIPE, SIG_DFL) != SIG_ERR;
    }

    /// Whether `fd` has bytes, or its end, to read within `timeoutMs`.
    private bool readable(int fd, int timeoutMs) @trusted
    {
        import core.stdc.errno : EINTR, errno;
        import core.sys.posix.poll : poll, pollfd, POLLIN;

        auto p = pollfd(fd, POLLIN);
        for (;;)
        {
            const n = poll(&p, 1, timeoutMs);
            if (n >= 0 || errno != EINTR)
                return n != 0; // an error reads as readable: the read reports it
        }
    }
}

// ── A scripted worker ───────────────────────────────────────────────────────
//
// The tests below start `/bin/sh` scripts that speak just enough of the
// protocol to end the way each test needs: the frames come from files this
// module writes, so the session's parsing is the real one.

version (Posix) version (unittest)
{
    /**
    A directory holding `worker`, a script that writes a one-test opening
    and then runs `then` (shell), with `$D` naming the directory. `$D/ran`
    holds the frames of a passing run of test 0, `$D/sentinel` its sentinel.
    */
    private string scriptedWorker(string name, string then)
    {
        import std.conv : octal;
        import std.file : mkdirRecurse, setAttributes, tempDir, write;
        import std.path : buildPath;
        import std.process : thisProcessID;
        import sparkles.test_runner.protocol : frameOf, frameText, sentinelText, toJson;
        import std.conv : text;

        const dir = buildPath(tempDir, text("sparkles-client-", name, "-", thisProcessID));
        mkdirRecurse(dir);
        auto test = toJson(Test(fullName: "m.a", name: "a", id: 0));
        test["t"] = "test";
        write(buildPath(dir, "opening"), "\n" ~ frameText(frameOf("hello", [
            "version": JSONValue(1),
            "supported": JSONValue([JSONValue(1), JSONValue(1)]),
            "harness": JSONValue("script"),
            "compiler": JSONValue(["vendor": JSONValue("DMD"), "version": JSONValue(2112)]),
            "build": JSONValue(["asserts": JSONValue(true), "coverage": JSONValue(false)]),
            "roots": JSONValue(["src"]),
            "token": JSONValue("T"),
            "tests": JSONValue(1),
        ])) ~ frameText(test) ~ frameText(frameOf("listed")));
        write(buildPath(dir, "ran"), frameText(frameOf("started", ["id": JSONValue(0)]))
            ~ frameText(frameOf("result", [
                "id": JSONValue(0),
                "status": JSONValue("passed"),
                "durationNs": JSONValue(10),
                "failures": JSONValue(JSONValue[].init),
                "skip": JSONValue(""),
                "stackBudget": JSONValue(false),
            ])));
        write(buildPath(dir, "sentinel"), sentinelText(0, "T"));
        const script = buildPath(dir, "worker");
        write(script, "#!/bin/sh\nD='" ~ dir ~ "'\ncat \"$D/opening\"\n" ~ then ~ "\n");
        setAttributes(script, octal!755);
        return script;
    }

    /// Script lines that serve one `run` of test 0, which passes.
    private enum serveOneRun = "read -r command\ncat \"$D/ran\"\ncat \"$D/sentinel\" >&2";

    /// Blocks until `w`'s session is over, for at most `limit`.
    private bool awaitOver(Worker w, imported!"core.time".Duration limit)
    {
        import core.time : MonoTime;

        const deadline = MonoTime.currTime + limit;
        synchronized (w.mutex)
            while (!w.session.over)
                if (MonoTime.currTime >= deadline || !w.changed.wait(deadline - MonoTime.currTime))
                    return w.session.over;
        return true;
    }

    private Worker startScripted(string script, ref string strays)
    {
        return new Worker(script, null, (string text) { strays ~= text; });
    }
}

@("client.run.workerEndedBetweenCommandsFailsTheRun")
@system
unittest
{
    version (Posix)
    {
        import core.time : seconds;
        import std.algorithm.searching : canFind;

        // The worker serves one test, says something nobody asked for, and
        // exits on its own before the runner's next command (TRP27).
        string strays;
        auto w = startScripted(scriptedWorker("between",
            serveOneRun ~ "\necho 'on the way out' >&2\nexit 7"), strays);
        assert(w.run(0, mainThread: false).succeeded);
        assert(awaitOver(w, 10.seconds));
        try
        {
            cast(void) w.run(0, mainThread: false);
            assert(0, "a worker that ended between commands runs no test");
        }
        catch (WorkerDied e)
        {
            assert(e.outsideCommand && e.msg.canFind("exited with status 7"), e.msg);
            assert(e.msg.canFind("between tests"), e.msg);
        }
        assert(w.dead);
        assert(strays.canFind("on the way out"), "its unattributed output is shown: " ~ strays);
    }
}

@("client.run.commandsClosedBetweenCommandsFailsTheRun")
@system
unittest
{
    version (Posix)
    {
        import core.time : seconds;
        import std.algorithm.searching : canFind;

        // The worker closes its commands channel after serving one test and
        // lingers: the next command meets a pipe nobody reads. The write
        // must fail and the run report the end (TRP27), not die of SIGPIPE.
        string strays;
        auto w = startScripted(scriptedWorker("closedCommands",
            "read -r command\nexec 0<&-\ncat \"$D/ran\"\ncat \"$D/sentinel\" >&2\nsleep 1\nexit 0"),
            strays);
        assert(w.run(0, mainThread: false).succeeded);
        try
        {
            cast(void) w.run(0, mainThread: false);
            assert(0, "a worker that reads no commands runs no test");
        }
        catch (WorkerDied e)
            assert(e.outsideCommand && e.msg.canFind("exited with status 0 between tests"), e.msg);
        assert(w.dead);
    }
}

@("client.run.endBeforeTheTestStartsFailsTheRun")
@system
unittest
{
    version (Posix)
    {
        import std.algorithm.searching : canFind;

        // The worker ends as the command arrives, before its `started`: the
        // end raced the command, and no test is to blame (TRP27).
        string strays;
        auto w = startScripted(scriptedWorker("endBeforeStarted", "read -r command\nexit 3"),
            strays);
        try
        {
            cast(void) w.run(0, mainThread: false);
            assert(0, "no test ran, so none has a result");
        }
        catch (WorkerDied e)
            assert(e.outsideCommand && e.msg.canFind("exited with status 3 between tests"), e.msg);
    }
}

@("client.exit.afterAnEndBetweenCommands")
@system
unittest
{
    version (Posix)
    {
        import core.time : seconds;
        import std.algorithm.searching : canFind;

        // After the last test: `exit` must not swallow the end (TRP27).
        string strays;
        auto w = startScripted(scriptedWorker("beforeExit", serveOneRun ~ "\nexit 7"), strays);
        assert(w.run(0, mainThread: false).succeeded);
        assert(awaitOver(w, 10.seconds));
        try
        {
            w.exit(coverageMerge: false);
            assert(0, "the end was reported");
        }
        catch (WorkerDied e)
            assert(e.outsideCommand && e.msg.canFind("exited with status 7 between tests"), e.msg);
    }
}

@("client.exit.abortWhileExitingFailsTheRun")
@system
unittest
{
    version (Posix)
    {
        import std.algorithm.searching : canFind;

        // Asked to exit, the worker aborts (a module destructor, say):
        // TRP22's status 0 is not met, and the run must not pass.
        string strays;
        auto w = startScripted(scriptedWorker("abortOnExit",
            "read -r command\nkill -ABRT $$"), strays);
        try
        {
            w.exit(coverageMerge: false);
            assert(0, "an abort while exiting is reported");
        }
        catch (WorkerDied e)
        {
            assert(e.outsideCommand && e.msg.canFind("signal 6 (SIGABRT)"), e.msg);
            assert(e.msg.canFind("asked to exit"), e.msg);
        }

        // A clean exit is not.
        auto clean = startScripted(scriptedWorker("cleanExit", "read -r command\nexit 0"), strays);
        clean.exit(coverageMerge: false);
        assert(clean.dead);
    }
}

@("client.exit.aLateAbortFailsTheRun")
@system
unittest
{
    version (Posix)
    {
        import std.algorithm.searching : canFind;

        // Asked to exit, the worker takes six seconds and then aborts: the
        // runner waits for that end rather than giving up and passing.
        string strays;
        auto w = startScripted(scriptedWorker("lateAbortOnExit",
            "read -r command\nsleep 6\nkill -ABRT $$"), strays);
        try
        {
            w.exit(coverageMerge: false);
            assert(0, "an abort while exiting is reported, however late");
        }
        catch (WorkerDied e)
            assert(e.outsideCommand && e.msg.canFind("signal 6 (SIGABRT)"), e.msg);
    }
}

@("client.frames.deathSeenWhileADescendantHoldsThePipe")
@system
unittest
{
    version (Posix)
    {
        import core.time : seconds;
        import std.algorithm.searching : canFind;

        // The worker dies leaving a descendant that holds both the frames and
        // the output pipe open for five seconds: its end is seen when it
        // happens, not at the frames' end of file (TRP28).
        string strays;
        auto w = startScripted(scriptedWorker("framesHeld", "sleep 5 &\nexit 7"), strays);
        assert(awaitOver(w, 3.seconds), "the end waited for the descendant");
        try
        {
            cast(void) w.run(0, mainThread: false);
            assert(0, "a dead worker runs no test");
        }
        catch (WorkerDied e)
            assert(e.outsideCommand && e.msg.canFind("exited with status 7"), e.msg);
    }
}

@("client.output.cutoffStopsTheReader")
@system
unittest
{
    version (Posix)
    {
        import core.thread : Thread;
        import core.time : msecs, MonoTime, seconds;

        // The worker dies leaving a descendant that holds the output pipe
        // open, quiet, for three seconds; after the cutoff (TRP28) the
        // reader must stop rather than wait for it.
        string strays;
        auto w = startScripted(scriptedWorker("cutoff",
            "(sleep 3; echo late >&2) >/dev/null &\nexit 7"), strays);
        assert(awaitOver(w, 10.seconds));
        const deadline = MonoTime.currTime + 500.msecs;
        while (w.outputReader.isRunning && MonoTime.currTime < deadline)
            Thread.sleep(10.msecs);
        assert(!w.outputReader.isRunning, "the output reader outlived the cutoff");
    }
}
