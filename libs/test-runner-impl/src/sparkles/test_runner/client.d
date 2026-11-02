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

/// Thrown when a worker exits, or is killed, before a command's last frame.
class WorkerDied : Exception
{
    /// How the worker ended: an exit status, a signal or an exception code.
    string ending;
    /// Output the worker wrote for the command that died with it.
    string output;

    this(string ending, string output) @safe pure nothrow
    {
        super("the test binary " ~ ending);
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
        import std.process : pipeProcess, Redirect;

        this.onStray = onStray;
        mutex = new Mutex;
        changed = new Condition(mutex);
        session = WorkerSession(binary);
        pipes = pipeProcess(workerArguments(binary, druntimeOptions), Redirect.all);
        auto frames = new Thread(&readFrames);
        frames.isDaemon = true;
        frames.start();
        auto output = new Thread(&readOutput);
        output.isDaemon = true;
        output.start();

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
            bytes = session.request(command, last);
        send(bytes);
        JSONValue[] frames;
        foreach (ref e; await((ref RunnerEvent e) => e.kind == EventKind.commandFinished))
            if (e.kind == EventKind.commandFrame)
                frames ~= e.frame;
        return frames;
    }

    /// Runs test `id` (TRP16) and returns its result, with its output. A
    /// worker that dies during the test yields a failed result (TRP26), and
    /// this worker is then dead.
    TestResult run(size_t id, bool mainThread)
    {
        string bytes;
        synchronized (mutex)
            bytes = session.run(id, mainThread);
        send(bytes);
        TestResult result;
        foreach (ref e; await((ref RunnerEvent e) => e.kind == EventKind.testFinished,
                diesAfterResult: true))
            if (e.kind == EventKind.testFinished)
                result = e.result;
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

    /// Asks the worker to exit (TRP22) and waits for it.
    void exit(bool coverageMerge)
    {
        import std.process : wait;

        string bytes;
        synchronized (mutex)
            bytes = session.exit(coverageMerge);
        try
        {
            send(bytes);
            pipes.stdin.close();
        }
        catch (Exception)
        {
            // Already gone: its status is all that is left.
        }
        synchronized (mutex)
        {
            import core.time : seconds;

            while (!session.over)
                if (!changed.wait(5.seconds))
                    break;
        }
        dead = true;
        drainStrays();
    }

    private void send(string bytes)
    {
        pipes.stdin.write(bytes);
        pipes.stdin.flush();
    }

    /**
    Waits until an event satisfies `done`, and returns every event up to it.
    A protocol error throws `ProtocolError`; the worker's end throws
    `WorkerDied`, unless `diesAfterResult` and `done` already held.
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
            foreach (ref e; batch)
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
                    dead = true;
                    if (finished && diesAfterResult)
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

    private void drainStrays()
    {
        RunnerEvent[] batch;
        synchronized (mutex)
        {
            batch = queue;
            queue = null;
        }
        foreach (ref e; batch)
            if (e.kind == EventKind.testOutput && e.test == noTest)
                onStray(e.text ~ "\n");
    }

    private void publish()
    {
        queue ~= session.takeEvents();
        changed.notifyAll();
    }

    private void readFrames()
    {
        import core.time : MonoTime, msecs, seconds;
        import std.process : wait;

        ubyte[4096] buffer;
        for (;;)
        {
            const n = readSome(pipes.stdout.fileno, buffer[]);
            if (n <= 0)
                break;
            synchronized (mutex)
            {
                session.feedFrames(cast(const(char)[]) buffer[0 .. n]);
                publish();
            }
        }
        const status = wait(pipes.pid);
        synchronized (mutex)
        {
            session.feedEnd(describeEnding(status));
            publish();
            // A child the test started may hold the output pipe open after
            // the worker died: stop at end of file or after a second of
            // quiet (TRP28).
            const deadline = MonoTime.currTime + 1.seconds;
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
        ubyte[4096] buffer;
        for (;;)
        {
            const n = readSome(pipes.stderr.fileno, buffer[]);
            if (n <= 0)
                break;
            synchronized (mutex)
            {
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
    }
}

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
