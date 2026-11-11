/**
 * Worker mode: a test binary serving a runner over the protocol
 * (process-model §4). It lists its tests, then runs the commands it reads on
 * its standard input, one at a time, writing frames to a duplicate of its
 * original standard output and leaving the tests' own output on standard
 * error, which the runner reads.
 */
module sparkles.test_runner.worker;

import std.json : JSONValue;

import sparkles.test_runner.model : Test, TestResult;
import sparkles.test_runner.protocol;

/// Serves `tests` to the runner that started this binary with
/// `--sparkles-test-protocol=<range>`, and returns the exit status.
int serveWorker(Test[] tests, string rangeText)
{
    import std.json : parseJSON;

    VersionRange runnerRange;
    const parsed = parseVersionRange(rangeText, runnerRange);
    const ours = VersionRange(protocolMin, protocolMax);
    const chosen = parsed ? selectVersion(runnerRange, ours) : 0;

    auto channel = FrameChannel.open();
    auto commands = openCommandChannel();
    channel.writeRaw("\n"); // a stray line from a module constructor ends here (TRP7)

    if (!chosen)
    {
        channel.write(frameOf("hello", [
            "version": JSONValue(null),
            "supported": JSONValue([JSONValue(ours.min), JSONValue(ours.max)]),
        ]));
        return incompatibleStatus;
    }

    makeStdioUnbuffered();
    const token = newToken();
    channel.write(helloFrame(chosen, ours, token, tests.length));
    foreach (ref test; tests)
    {
        auto frame = toJson(test);
        frame["t"] = "test";
        channel.write(frame);
    }
    channel.write(frameOf("listed"));

    auto server = Server(tests, &channel, token);
    scope (exit)
        server.close();

    foreach (line; commands.byLineCopy)
    {
        string stray;
        JSONValue command;
        try
        {
            if (!splitFrame(line, stray, command))
                continue; // a blank line, or bytes a test pushed back at us
        }
        catch (Exception e)
            return server.protocolError("a malformed command: " ~ e.msg);
        const type = command["t"].str;
        if (type == "exit")
            return server.exit(command);
        if (const error = server.dispatch(type, command))
            return server.protocolError(error);
    }
    return 0; // end of file between commands (TRP22)
}

/// The `hello` frame (TRP12).
private JSONValue helloFrame(uint chosen, VersionRange ours, string token, size_t count)
{
    bool asserts, coverage;
    version (assert)
        asserts = true;
    version (D_Coverage)
        coverage = true;
    return frameOf("hello", [
        "version": JSONValue(chosen),
        "supported": JSONValue([JSONValue(ours.min), JSONValue(ours.max)]),
        "harness": JSONValue(harnessVersion),
        "compiler": JSONValue([
            "vendor": JSONValue(__VENDOR__),
            "version": JSONValue(__VERSION__),
        ]),
        "build": JSONValue(["asserts": JSONValue(asserts), "coverage": JSONValue(coverage)]),
        "roots": JSONValue(harnessRoots),
        "token": JSONValue(token),
        "tests": JSONValue(count),
    ]);
}

/// The harness's version string, carried in `hello` for diagnostics.
enum string harnessVersion = "sparkles:test-harness, protocol "
    ~ imported!"std.conv".to!string(protocolMin) ~ "-" ~ imported!"std.conv".to!string(protocolMax);

/// The source roots of the attributes, the harness and the shim as this
/// binary was compiled (TRP12), which the runner's compile-time modes import
/// instead of its own (TRX4).
private string[] harnessRoots()
{
    import sparkles.test_runner.roots : attributesRoot, harnessRoot;

    return [attributesRoot, harnessRoot];
}

/// A token that marks this worker's output sentinels (TRP24).
private string newToken()
{
    import core.time : MonoTime;
    import std.conv : to;
    import std.process : thisProcessID;

    return (MonoTime.currTime.ticks ^ (cast(long) thisProcessID << 32)).to!string(16);
}

/// The commands' state: the tests, and the bench run's open sources and
/// registered cases.
private struct Server
{
    import sparkles.test_runner.bench : RegisteredCase;
    import sparkles.test_runner.bench_session : BenchSession;
    import sparkles.profiling.counters.psi : PsiSource;
    import sparkles.test_runner.workload : WallSource;

    Test[] tests;
    FrameChannel* channel;
    string token;

    RegisteredCase[] cases;
    BenchSession session;
    bool sessionOpen;
    size_t provenanceSent;
    WallSource wall;
    PsiSource psi;
    bool workloadSourcesOpen;

    void close()
    {
        if (sessionOpen)
            session.close();
        if (workloadSourcesOpen)
        {
            wall.close();
            psi.close();
        }
    }

    /// Runs one command; returns a protocol error's text, or `null`.
    string dispatch(string type, in JSONValue command)
    {
        switch (type)
        {
            case "run":      return run(command);
            case "register": return register(command);
            case "measure":  return measure(command);
            case "workload": return workload(command);
            case "probe":    return probe(command);
            default:         return "an unknown command \"" ~ type ~ "\"";
        }
    }

    int protocolError(string message)
    {
        channel.write(frameOf("error", ["message": JSONValue(message)]));
        return 4;
    }

    int exit(in JSONValue command)
    {
        if (auto merge = "coverageMerge" in command.object)
            if (merge.boolean)
                setCoverageMerge();
        return 0;
    }

    private bool testIndex(in JSONValue command, string member, out size_t index)
    {
        if (auto p = member in command.object)
        {
            index = fromJson!size_t(*p);
            return index < tests.length;
        }
        return false;
    }

    string run(in JSONValue command)
    {
        import core.stdc.stdio : fflush;
        import sparkles.test_runner.fallback : runPlaced;

        size_t id;
        if (!testIndex(command, "id", id))
            return "run: an id outside the listing";
        bool mainThread;
        if (auto p = "mainThread" in command.object)
            mainThread = fromJson!bool(*p);

        channel.write(frameOf("started", ["id": JSONValue(id)]));
        const result = runPlaced(tests[id], mainThread);
        fflush(null);
        writeOutput(sentinelText(id, token));
        channel.write(resultFrame(id, result));
        return null;
    }

    string register(in JSONValue command)
    {
        import sparkles.test_runner.bench : BenchConfig, provenanceLines, registerBenchmark;

        const config = fromJson!BenchConfig(command["config"]);
        foreach (ref idJson; command["ids"].array)
        {
            const id = fromJson!size_t(idJson);
            if (id >= tests.length)
                return "register: an id outside the listing";
            auto test = tests[id];
            auto reg = registerBenchmark(test, config);
            foreach (ref c; reg.cases)
            {
                channel.write(frameOf("case", [
                    "case": JSONValue(cases.length),
                    "test": JSONValue(id),
                    "name": JSONValue(c.name),
                    "labels": toJson(c.labels),
                    "metrics": toJson(c.metrics),
                ]));
                cases ~= c;
            }
            channel.write(resultFrame(id, reg.result));
        }
        foreach (line; provenanceLines[provenanceSent .. $])
            channel.write(frameOf("provenance", ["line": JSONValue(line)]));
        provenanceSent = provenanceLines.length;
        channel.write(frameOf("registered"));
        return null;
    }

    string measure(in JSONValue command)
    {
        import sparkles.test_runner.bench : BenchConfig, BenchStats, errorCell,
            errorRow, measureCase;
        import sparkles.test_runner.execution : toThrown;
        import sparkles.test_runner.model : Thrown;
        import sparkles.test_runner.skip : TestSkipped;

        const index = fromJson!size_t(command["case"]);
        if (index >= cases.length)
            return "measure: a case that was never registered";
        const config = fromJson!BenchConfig(command["config"]);
        ensureSession();
        auto c = cases[index];

        channel.write(frameOf("caseStarted", ["case": JSONValue(index)]));
        BenchStats row;
        immutable(Thrown)[] thrown;
        try
            row = measureCase(c, config, session.counters);
        catch (TestSkipped sk)
            // A measurement-time skipTest: a yellow skipped row; the run stays green.
            row = BenchStats(name: c.name, labels: c.labels,
                error: errorCell(sk.message.idup), skipped: true);
        catch (Throwable t)
        {
            // A hard throw: an error row in its group table, plus the trace.
            // `toThrown` re-throws OutOfMemoryError, which must end the worker.
            thrown = toThrown(t);
            row = errorRow(c.name, c.labels, thrown);
        }
        channel.write(frameOf("row", [
            "case": JSONValue(index),
            "stats": toJson(row),
            "thrown": toJson(thrown),
        ]));
        channel.write(frameOf("measured"));
        return null;
    }

    string workload(in JSONValue command)
    {
        import sparkles.test_runner.workload : runWorkload;

        size_t id;
        if (!testIndex(command, "id", id))
            return "workload: an id outside the listing";
        ensureSession();
        if (!workloadSourcesOpen)
        {
            wall = WallSource.tryOpen(true);
            psi = PsiSource.tryOpen(true);
            workloadSourcesOpen = true;
            // Disclosed once per run: on such hosts every window's runqueue
            // column is an em dash and its time lands in `other`.
            if (wall.available && !wall.schedOk)
                channel.write(frameOf("note", ["text": JSONValue(
                    "workload: runqueue wait unattributable (" ~ wall.schedReason
                    ~ ") — its time lands in `other`")]));
        }
        auto outcome = runWorkload(tests[id], session.counters, wall, psi);
        foreach (ref w; outcome.windows)
            channel.write(frameOf("window", ["window": toJson(w)]));
        channel.write(resultFrame(id, outcome.result));
        return null;
    }

    string probe(in JSONValue command)
    {
        import sparkles.test_runner.bench_session : BenchOptions, listMetrics,
            openBenchSession;

        if (sessionOpen)
            session.close();
        session = openBenchSession(fromJson!BenchOptions(command["options"]));
        sessionOpen = true;
        foreach (note; session.probe.notes)
            channel.write(frameOf("note", ["text": JSONValue(note)]));
        if (auto list = "list" in command.object)
            if (list.boolean)
            {
                const listing = listMetrics();
                channel.write(frameOf("catalog", [
                    "catalog": toJson(listing.catalog),
                    "blocks": toJson(listing.blocks),
                    "wallNote": JSONValue(listing.wallNote),
                ]));
            }
        channel.write(frameOf("probed", [
            "syscallNames": toJson(session.probe.syscallNames),
            "rawEvents": toJson(session.probe.rawEvents),
        ]));
        return null;
    }

    private void ensureSession()
    {
        import sparkles.test_runner.bench_session : BenchOptions, openBenchSession;

        if (!sessionOpen)
        {
            session = openBenchSession(BenchOptions.init);
            sessionOpen = true;
        }
    }
}

/// A `result` frame (TRP16).
JSONValue resultFrame(size_t id, in TestResult result)
{
    const status = result.skipped ? "skipped" : result.succeeded ? "passed" : "failed";
    return frameOf("result", [
        "id": JSONValue(id),
        "status": JSONValue(status),
        "durationNs": JSONValue(result.duration.total!"nsecs"),
        "failures": toJson(result.thrown),
        "skip": JSONValue(result.skipReason),
        "stackBudget": JSONValue(result.stackBudgetExceeded),
    ]);
}

/// The frames channel: a duplicate of the standard output the worker started
/// with, close-on-exec, while descriptor 1 joins descriptor 2 (TRP6).
private struct FrameChannel
{
    int fd = -1;

    static FrameChannel open()
    {
        FrameChannel channel;
        version (Posix)
        {
            import core.sys.posix.fcntl : fcntl, FD_CLOEXEC, F_SETFD;
            import core.sys.posix.unistd : dup, dup2;

            channel.fd = dup(1);
            fcntl(channel.fd, F_SETFD, FD_CLOEXEC);
            dup2(2, 1);
        }
        else version (Windows)
        {
            import core.sys.windows.winbase : GetStdHandle, SetHandleInformation,
                SetStdHandle, STD_ERROR_HANDLE, STD_OUTPUT_HANDLE;
            import core.sys.windows.winnt : HANDLE;

            enum HANDLE_FLAG_INHERIT = 1;
            channel.fd = _dup(1);
            SetHandleInformation(cast(HANDLE) _get_osfhandle(channel.fd),
                HANDLE_FLAG_INHERIT, 0);
            _dup2(2, 1);
            SetStdHandle(STD_OUTPUT_HANDLE, GetStdHandle(STD_ERROR_HANDLE));
        }
        return channel;
    }

    void write(JSONValue frame)
    {
        writeRaw(frameText(frame));
    }

    void writeRaw(scope const(char)[] text)
    {
        writeAll(fd, text);
    }
}

/// The commands channel: a duplicate of the standard input the worker started
/// with, close-on-exec, while descriptor 0 reads the null device (TRP6). A
/// test, or a child it starts, that reads its standard input then reads end
/// of file, never the runner's commands.
private imported!"std.stdio".File openCommandChannel()
{
    import std.stdio : File;

    version (Posix)
        enum nullDevice = "/dev/null";
    else version (Windows)
        enum nullDevice = "NUL";
    auto nul = File(nullDevice, "r");
    File commands;
    version (Posix)
    {
        import core.sys.posix.fcntl : fcntl, FD_CLOEXEC, F_SETFD;
        import core.sys.posix.unistd : dup, dup2;

        const fd = dup(0);
        fcntl(fd, F_SETFD, FD_CLOEXEC);
        dup2(nul.fileno, 0);
    }
    else version (Windows)
    {
        import core.sys.windows.winbase : SetHandleInformation, SetStdHandle,
            STD_INPUT_HANDLE;
        import core.sys.windows.winnt : HANDLE;

        enum HANDLE_FLAG_INHERIT = 1;
        const fd = _dup(0);
        SetHandleInformation(cast(HANDLE) _get_osfhandle(fd), HANDLE_FLAG_INHERIT, 0);
        _dup2(nul.fileno, 0);
        SetStdHandle(STD_INPUT_HANDLE, cast(HANDLE) _get_osfhandle(0));
    }
    commands.fdopen(fd, "r");
    return commands;
}

/// Writes `text` to the output channel, descriptor 2.
private void writeOutput(scope const(char)[] text)
{
    writeAll(2, text);
}

private void writeAll(int fd, scope const(char)[] text) @trusted
{
    while (text.length)
    {
        version (Posix)
        {
            import core.sys.posix.unistd : write;

            const n = write(fd, text.ptr, text.length);
        }
        else version (Windows)
            const n = _write(fd, text.ptr, cast(uint) text.length);
        if (n <= 0)
            return; // the runner is gone; nothing left to tell it
        text = text[n .. $];
    }
}

version (Windows)
{
    extern (C) nothrow @nogc
    {
        int _dup(int);
        int _dup2(int, int);
        int _write(int, const(void)*, uint);
        ptrdiff_t _get_osfhandle(int);
    }
}

/// C stdio's `stdout` and `stderr` unbuffered, so output a test wrote before
/// a crash has reached the pipe (TRP23).
private void makeStdioUnbuffered() @trusted
{
    import core.stdc.stdio : _IONBF, setvbuf, stderr, stdout;

    setvbuf(stdout, null, _IONBF, 0);
    setvbuf(stderr, null, _IONBF, 0);
}

/// Makes druntime add this process's coverage counts to the listing files
/// already written (TRS5).
private void setCoverageMerge()
{
    version (D_Coverage)
        dmd_coverSetMerge(true);
}

version (D_Coverage)
    private extern (C) void dmd_coverSetMerge(bool);

private template imported(string moduleName)
{
    mixin("import imported = ", moduleName, ";");
}
