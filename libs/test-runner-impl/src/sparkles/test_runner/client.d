/**
 * The runner's end of the protocol (process-model §4–§5): starting a test
 * binary as a worker, the handshake, sending commands and collecting their
 * frames, reading the tests' output and attributing it, and noticing a worker
 * that died.
 */
module sparkles.test_runner.client;

import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import std.json : JSONValue;
import std.process : Pid, ProcessPipes;

import sparkles.test_runner.model : Test, TestResult, Thrown;
import sparkles.test_runner.protocol;

/// Thrown when a worker exits, or is killed, before a command's last frame.
class WorkerDied : Exception
{
    /// A description of how the worker ended: an exit status, a signal or an
    /// exception code.
    string ending;
    /// The output the worker wrote since its last attributed test.
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

/// The facts `hello` carries (TRP12).
struct Hello
{
    uint version_;
    VersionRange supported;
    string harness;
    string compilerVendor;
    string compilerVersion;
    bool asserts;
    bool coverage;
    string[] roots;
    string token;
}

/// Where unattributed worker output goes; the runner prints it.
alias StrayHandler = void delegate(string text);

/// One worker process.
final class Worker
{
    private ProcessPipes pipes;
    private Mutex mutex;
    private Condition changed;
    private JSONValue[] frames;
    private bool framesEnded;
    private bool outputEnded;
    private string pending;          // output since the last sentinel
    private string[size_t] finished; // a test's output, once its sentinel arrived
    private Thread frameReader, outputReader;
    private StrayHandler onStray;
    private bool exited;
    private int exitStatus;

    /// What the handshake said.
    Hello hello;
    /// The listing (TRP13), each test's `ptr` null.
    Test[] listing;
    /// Whether the process has ended.
    bool dead;

    /**
    Starts `binary` as a worker and completes the handshake. `druntimeOptions`
    are passed through (TRS5). Throws `ProtocolError` on a version mismatch or
    a binary that does not speak the protocol.
    */
    this(string binary, string[] druntimeOptions, StrayHandler onStray)
    {
        import std.conv : text;
        import std.process : pipeProcess, Redirect;

        this.onStray = onStray;
        mutex = new Mutex;
        changed = new Condition(mutex);
        pipes = pipeProcess([binary,
            text(protocolFlag, protocolMin, "-", protocolMax)] ~ druntimeOptions,
            Redirect.all);
        frameReader = new Thread(&readFrames);
        frameReader.isDaemon = true;
        frameReader.start();
        outputReader = new Thread(&readOutput);
        outputReader.isDaemon = true;
        outputReader.start();
        handshake(binary);
    }

    private void handshake(string binary)
    {
        import std.conv : text;
        import std.json : JSONType;

        JSONValue first;
        try
            first = nextFrame();
        catch (WorkerDied e)
            throw new ProtocolError(text("the test binary ", binary,
                " does not speak the runner protocol: it ", e.ending,
                " before saying hello", e.output.length ? ":\n" ~ e.output : ""));
        if (first["t"].str != "hello")
            throw new ProtocolError(text("the test binary ", binary,
                " does not speak the runner protocol: its first frame is ",
                first.toString));
        const supported = VersionRange(
            fromJson!uint(first["supported"][0]), fromJson!uint(first["supported"][1]));
        if (first["version"].type == JSONType.null_)
            throw new ProtocolError(text("the test binary ", binary,
                " speaks runner protocol ", supported.min, "–", supported.max,
                "; this runner speaks ", protocolMin, "–", protocolMax,
                ". Rebuild the binary against a matching sparkles:test-harness,",
                " or move the runner's pin (nix/test-runner-pin.json)"));
        hello = Hello(
            version_: fromJson!uint(first["version"]),
            supported: supported,
            harness: fromJson!string(first["harness"]),
            compilerVendor: fromJson!string(first["compiler"]["vendor"]),
            compilerVersion: first["compiler"]["version"].toString,
            asserts: fromJson!bool(first["build"]["asserts"]),
            coverage: fromJson!bool(first["build"]["coverage"]),
            roots: fromJson!(string[])(first["roots"]),
            token: fromJson!string(first["token"]),
        );
        const count = fromJson!size_t(first["tests"]);
        foreach (i; 0 .. count)
        {
            auto frame = nextFrame();
            if (frame["t"].str != "test")
                throw new ProtocolError("protocol error: expected a test frame, got "
                    ~ frame.toString);
            listing ~= fromJson!Test(frame);
        }
        if (nextFrame()["t"].str != "listed")
            throw new ProtocolError("protocol error: the listing does not end with listed");
    }

    /// Sends `command` and returns every frame up to and including the first
    /// one of type `last`. Throws `WorkerDied` when the worker ends first.
    JSONValue[] request(JSONValue command, string last)
    {
        send(command);
        JSONValue[] reply;
        for (;;)
        {
            auto frame = nextFrame();
            reply ~= frame;
            const type = frame["t"].str;
            if (type == "error")
                throw new ProtocolError("protocol error reported by the test binary: "
                    ~ frame["message"].str);
            if (type == last)
                return reply;
        }
    }

    /// Runs test `id` (TRP16) and returns its result, with the output it
    /// wrote. A worker that dies during the test yields a failed result
    /// (TRP26), and this worker is then dead.
    TestResult run(size_t id, bool mainThread)
    {
        import core.time : nsecs;

        auto test = listing[id];
        JSONValue[] reply;
        try
            reply = request(frameOf("run", [
                "id": JSONValue(id),
                "mainThread": JSONValue(mainThread),
            ]), "result");
        catch (WorkerDied e)
            return crashed(test, e);
        auto result = decodeResult(test, reply[$ - 1]);
        result.output = outputOf(id);
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

        try
            send(frameOf("exit", ["coverageMerge": JSONValue(coverageMerge)]));
        catch (Exception)
        {
            // Already gone: its status is all that is left.
        }
        try
            pipes.stdin.close();
        catch (Exception)
        {
        }
        wait(pipes.pid);
        dead = true;
        // The readers are daemon threads: a child the last test started may
        // hold the output pipe open, so give its output a second, no more.
        string rest;
        synchronized (mutex)
        {
            import core.time : seconds;

            if (!outputEnded)
                changed.wait(1.seconds);
            rest = pending;
            pending = null;
        }
        if (rest.length)
            onStray(rest);
    }

    private void send(JSONValue command)
    {
        pipes.stdin.write(frameText(command));
        pipes.stdin.flush();
    }

    /// The next frame, or `WorkerDied` once the frames channel has ended.
    private JSONValue nextFrame()
    {
        synchronized (mutex)
        {
            while (!frames.length && !framesEnded)
                changed.wait();
            if (frames.length)
            {
                auto frame = frames[0];
                frames = frames[1 .. $];
                return frame;
            }
        }
        throw died();
    }

    /// The output of test `id`: up to its sentinel, or, when the worker died,
    /// whatever arrived before its output ended (TRP28).
    private string outputOf(size_t id)
    {
        import core.time : seconds;

        synchronized (mutex)
        {
            for (;;)
            {
                if (auto p = id in finished)
                {
                    auto text = *p;
                    finished.remove(id);
                    return text;
                }
                if (outputEnded)
                    break;
                changed.wait(1.seconds);
            }
            auto text = pending;
            pending = null;
            return text;
        }
    }

    /// The `WorkerDied` for a worker whose frames channel ended.
    private WorkerDied died()
    {
        import core.time : MonoTime, msecs, seconds;
        import std.conv : text;
        import std.process : wait;

        const status = wait(pipes.pid);
        dead = true;
        string output;
        synchronized (mutex)
        {
            // A child the test started may hold the output pipe open after
            // the worker died: stop at end of file or after a second of
            // silence, whichever is first (TRP28).
            auto quietSince = MonoTime.currTime;
            size_t seen = pending.length;
            while (!outputEnded && MonoTime.currTime - quietSince < 1.seconds)
            {
                changed.wait(100.msecs);
                if (pending.length != seen)
                {
                    seen = pending.length;
                    quietSince = MonoTime.currTime;
                }
            }
            output = pending;
            pending = null;
        }
        return new WorkerDied(describeEnding(status), output);
    }

    private void readFrames()
    {
        import std.stdio : KeepTerminator;

        try
            foreach (line; pipes.stdout.byLineCopy(KeepTerminator.no))
            {
                string stray;
                JSONValue frame;
                bool isFrame;
                try
                    isFrame = splitFrame(line, stray, frame);
                catch (Exception e)
                {
                    stray = line;
                    onStray("protocol error from the test binary: " ~ e.msg ~ "\n");
                }
                if (stray.length)
                    onStray(stray ~ "\n");
                if (isFrame)
                    synchronized (mutex)
                    {
                        frames ~= frame;
                        changed.notifyAll();
                    }
            }
        catch (Exception)
        {
            // A closed pipe ends the channel like end of file.
        }
        synchronized (mutex)
        {
            framesEnded = true;
            changed.notifyAll();
        }
    }

    private void readOutput()
    {
        import std.conv : to;
        import std.string : indexOf;

        const marker = frameMark ~ sentinelWord ~ " ";
        string line;
        void take(string complete)
        {
            // A sentinel line: `marker id token`. Anything before the mark on
            // the same line is the test's last, unterminated output.
            const at = complete.indexOf(marker);
            if (at >= 0)
            {
                import std.algorithm.iteration : splitter;
                import std.array : array;

                auto words = complete[at + marker.length .. $].splitter(' ').array;
                if (words.length == 2 && words[1] == hello.token)
                {
                    synchronized (mutex)
                    {
                        pending ~= complete[0 .. at];
                        try
                            finished[words[0].to!size_t] = pending;
                        catch (Exception)
                        {
                        }
                        pending = null;
                        changed.notifyAll();
                    }
                    return;
                }
            }
            synchronized (mutex)
            {
                pending ~= complete ~ "\n";
                changed.notifyAll();
            }
        }

        try
        {
            ubyte[4096] buffer;
            for (;;)
            {
                // `File.rawRead` is `fread`, which blocks until the buffer is
                // full; a pipe needs what has arrived, so read the descriptor.
                const n = readSome(pipes.stderr.fileno, buffer[]);
                if (n <= 0)
                    break;
                line ~= cast(const(char)[]) buffer[0 .. n];
                for (;;)
                {
                    const nl = line.indexOf('\n');
                    if (nl < 0)
                        break;
                    take(line[0 .. nl]);
                    line = line[nl + 1 .. $];
                }
            }
        }
        catch (Exception)
        {
        }
        synchronized (mutex)
        {
            pending ~= line;
            outputEnded = true;
            changed.notifyAll();
        }
    }
}

/// How a process ended, from `std.process.wait`'s status.
string describeEnding(int status) @safe pure
{
    import std.conv : text, to;

    version (Posix)
        if (status < 0)
            return text("was killed by signal ", -status, signalName(-status));
    version (Windows)
        if (cast(uint) status >= 0xC0000000)
            return text("ended with exception code 0x", (cast(uint) status).to!string(16));
    return text("exited with status ", status);
}

private string signalName(int signal) @safe pure nothrow
{
    switch (signal)
    {
        case 4:  return " (SIGILL)";
        case 6:  return " (SIGABRT)";
        case 7:  return " (SIGBUS)";
        case 8:  return " (SIGFPE)";
        case 9:  return " (SIGKILL)";
        case 11: return " (SIGSEGV)";
        default: return "";
    }
}

@("client.describeEnding")
@safe pure
unittest
{
    assert(describeEnding(0) == "exited with status 0");
    version (Posix)
        assert(describeEnding(-11) == "was killed by signal 11 (SIGSEGV)");
}

/// The `TestResult` a `result` frame describes (TRP16).
TestResult decodeResult(Test test, in JSONValue frame)
{
    import core.time : nsecs;

    auto result = TestResult(test: test);
    const status = frame["status"].str;
    result.succeeded = status == "passed";
    result.skipped = status == "skipped";
    result.skipReason = fromJson!string(frame["skip"]);
    result.duration = fromJson!long(frame["durationNs"]).nsecs;
    result.thrown = fromJson!(immutable(Thrown)[])(frame["failures"]);
    result.stackBudgetExceeded = fromJson!bool(frame["stackBudget"]);
    return result;
}

/// Reads what has arrived on `fd`, at most `buffer.length` bytes; `0` at end
/// of file, negative on an error.
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
    {
        return _read(fd, buffer.ptr, cast(uint) buffer.length);
    }
}

version (Windows)
    private extern (C) int _read(int, void*, uint) nothrow @nogc;
