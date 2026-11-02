/**
 * One worker session as a protocol state machine (process-model TRM1): the
 * runner's end of the protocol with no I/O of its own. A client feeds it the
 * bytes it read from a worker's frames and output channels and the worker's
 * end, writes the command bytes it returns, and takes the events it
 * produces. The standalone runner drives sessions with threads and pipes;
 * `ci` drives them with supervised processes.
 */
module sparkles.test_runner.session;

import std.json : JSONValue;

import sparkles.test_runner.model : Test, TestResult, Thrown;
import sparkles.test_runner.protocol;

/// What a session produces (process-model TRM2).
enum EventKind
{
    /// The handshake and the listing are complete: `hello` and `listing`.
    workerReady,
    /// `test` started running.
    testStarted,
    /// One line of output, attributed to `test`, or to none (`noTest`).
    testOutput,
    /// `test` finished: `result`, its output included.
    testFinished,
    /// A frame of a bench or probe command, in `frame` (`case`, `result`,
    /// `provenance`, `caseStarted`, `row`, `window`, `note`, `catalog`,
    /// `probed`).
    commandFrame,
    /// The command in flight has finished; the session is idle again.
    commandFinished,
    /// The worker broke the protocol, or speaks no common version: `text`.
    protocolError,
    /// The worker's process ended: `text` says how, `expected` whether it was
    /// asked to.
    workerEnded,
}

/// `test` when an event belongs to no test.
enum size_t noTest = size_t.max;

/// One event of a session.
struct RunnerEvent
{
    EventKind kind;
    size_t test = noTest;
    string text;
    TestResult result;
    JSONValue frame;
    bool expected;
}

/// The facts a worker's `hello` carries (process-model TRP12).
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

/// The argument vector that starts `binary` as a worker of this protocol
/// version range, with `druntimeOptions` after it (TRL1, TRS5).
string[] workerArguments(string binary, in string[] druntimeOptions)
{
    import std.conv : text;

    return [binary, text(protocolFlag, protocolMin, "-", protocolMax)] ~ druntimeOptions.dup;
}

/// A worker session.
struct WorkerSession
{
    private enum State
    {
        hello,
        listing,
        idle,
        busy,
        exiting,
        ended,
        failed,
    }

    private enum Command
    {
        none,
        run,
        other,
    }

    private string binary;
    private State state;
    private size_t expectedTests;
    private string frameBuffer;
    private string outputBuffer;
    private string pending;          // output since the last sentinel
    private RunnerEvent[] events;

    private Command command;
    private string terminal;          // the frame type that ends `command`
    private size_t running = noTest;  // the test a `run` runs
    private TestResult runResult;
    private bool haveResult, haveSentinel;

    private bool processEnded;
    private string ending;
    private bool outputClosed;

    /// What `hello` said, once `workerReady` was produced.
    Hello hello;
    /// The listing, each test's `ptr` null.
    Test[] listing;

    /// A session with the worker started on `binary`; `binary` names it in
    /// errors.
    this(string binary) @safe pure nothrow
    {
        this.binary = binary;
    }

    /// Whether the session can take a command.
    bool idle() const @safe pure nothrow @nogc => state == State.idle;

    /// Whether the worker is gone, or the session gave up on it.
    bool over() const @safe pure nothrow @nogc
        => state == State.ended || state == State.failed;

    /// The events produced since the last call.
    RunnerEvent[] takeEvents() @safe pure nothrow
    {
        auto taken = events;
        events = null;
        return taken;
    }

    // ── Commands ────────────────────────────────────────────────────────────

    /// The bytes that run test `id` (TRP16); `mainThread` places it (TRP17).
    string run(size_t id, bool mainThread)
    in (idle, "a command is already in flight")
    in (id < listing.length, "an id outside the listing")
    {
        command = Command.run;
        terminal = "result";
        running = id;
        haveResult = haveSentinel = false;
        state = State.busy;
        return frameText(frameOf("run", [
            "id": JSONValue(id),
            "mainThread": JSONValue(mainThread),
        ]));
    }

    /// The bytes of a bench or probe command (TRP18–TRP21), which ends with a
    /// frame of type `last`; its frames arrive as `commandFrame` events.
    string request(JSONValue frame, string last)
    in (idle, "a command is already in flight")
    {
        command = Command.other;
        terminal = last;
        state = State.busy;
        return frameText(frame);
    }

    /// The bytes that end the worker (TRP22).
    string exit(bool coverageMerge)
    {
        state = processEnded ? state : State.exiting;
        return frameText(frameOf("exit", ["coverageMerge": JSONValue(coverageMerge)]));
    }

    // ── Input ───────────────────────────────────────────────────────────────

    /// Bytes read from the worker's frames channel.
    void feedFrames(scope const(char)[] bytes)
    {
        import std.string : indexOf;

        frameBuffer ~= bytes;
        for (;;)
        {
            const nl = frameBuffer.indexOf('\n');
            if (nl < 0)
                break;
            const line = withoutCarriageReturn(frameBuffer[0 .. nl]);
            frameBuffer = frameBuffer[nl + 1 .. $];
            takeFrameLine(line);
        }
    }

    /// Bytes read from the worker's output channel.
    void feedOutput(scope const(char)[] bytes)
    {
        import std.string : indexOf;

        outputBuffer ~= bytes;
        for (;;)
        {
            const nl = outputBuffer.indexOf('\n');
            if (nl < 0)
                break;
            const line = withoutCarriageReturn(outputBuffer[0 .. nl]);
            outputBuffer = outputBuffer[nl + 1 .. $];
            takeOutputLine(line);
        }
    }

    /// The output channel ended, or the client stopped waiting for it after
    /// the worker died (TRP28).
    void feedOutputClosed()
    {
        if (outputClosed)
            return;
        outputClosed = true;
        if (outputBuffer.length)
        {
            pending ~= outputBuffer;
            outputBuffer = null;
        }
        settleDeath();
    }

    /// The worker's process ended; `how` says how (see $(LREF describeEnding)).
    void feedEnd(string how)
    {
        if (processEnded)
            return;
        processEnded = true;
        ending = how;
        // A frame cut off by the end is not a frame.
        frameBuffer = null;
        settleDeath();
    }

    // ── Frames ──────────────────────────────────────────────────────────────

    private void takeFrameLine(string line)
    {
        string stray;
        JSONValue frame;
        bool isFrame;
        try
            isFrame = splitFrame(line, stray, frame);
        catch (Exception e)
            return fail("protocol error from " ~ binary ~ ": " ~ e.msg);
        if (stray.length)
            emitOutput(noTest, stray);
        if (isFrame)
            takeFrame(frame);
    }

    private void takeFrame(JSONValue frame)
    {
        import std.conv : text;
        import std.json : JSONType;

        if (state == State.failed || state == State.ended)
            return;
        const type = frame["t"].str;
        if (type == "error")
            return fail("protocol error reported by " ~ binary ~ ": "
                ~ fromJson!string(frame["message"]));
        final switch (state)
        {
            case State.hello:
                if (type != "hello")
                    return fail(text("the test binary ", binary,
                        " does not speak the runner protocol: its first frame is ",
                        frame.toString));
                const supported = VersionRange(fromJson!uint(frame["supported"][0]),
                    fromJson!uint(frame["supported"][1]));
                if (frame["version"].type == JSONType.null_)
                    return fail(text("the test binary ", binary,
                        " speaks runner protocol ", supported.min, "–", supported.max,
                        "; this runner speaks ", protocolMin, "–", protocolMax,
                        ". Rebuild the binary against a matching sparkles:test-harness,",
                        " or move the runner's pin (nix/test-runner-pin.json)"));
                hello = Hello(
                    version_: fromJson!uint(frame["version"]),
                    supported: supported,
                    harness: fromJson!string(frame["harness"]),
                    compilerVendor: fromJson!string(frame["compiler"]["vendor"]),
                    compilerVersion: frame["compiler"]["version"].toString,
                    asserts: fromJson!bool(frame["build"]["asserts"]),
                    coverage: fromJson!bool(frame["build"]["coverage"]),
                    roots: fromJson!(string[])(frame["roots"]),
                    token: fromJson!string(frame["token"]),
                );
                expectedTests = fromJson!size_t(frame["tests"]);
                state = State.listing;
                return;
            case State.listing:
                if (type == "test" && listing.length < expectedTests)
                {
                    listing ~= fromJson!Test(frame);
                    return;
                }
                if (type == "listed" && listing.length == expectedTests)
                    return finishListing();
                return fail(text("protocol error from ", binary,
                    ": the listing holds an unexpected ", type, " frame"));
            case State.idle:
            case State.exiting:
                return fail(text("protocol error from ", binary,
                    ": a ", type, " frame with no command in flight"));
            case State.busy:
                return takeCommandFrame(type, frame);
            case State.ended:
            case State.failed:
                return;
        }
    }


    private void finishListing()
    {
        state = State.idle;
        events ~= RunnerEvent(kind: EventKind.workerReady);
    }

    private void takeCommandFrame(string type, JSONValue frame)
    {
        if (command == Command.run)
        {
            if (type == "started")
            {
                events ~= RunnerEvent(kind: EventKind.testStarted, test: running);
                return;
            }
            if (type == "result")
            {
                runResult = decodeResult(listing[running], frame);
                haveResult = true;
                return finishRunIfDone();
            }
            import std.conv : text;

            return fail(text("protocol error from ", binary,
                ": a ", type, " frame while a test runs"));
        }
        events ~= RunnerEvent(kind: EventKind.commandFrame, frame: frame);
        if (type == terminal)
            finishCommand();
    }

    private void finishRunIfDone()
    {
        if (!haveResult || !haveSentinel)
            return;
        runResult.output = takePending();
        events ~= RunnerEvent(kind: EventKind.testFinished, test: running, result: runResult);
        running = noTest;
        finishCommand();
    }

    private void finishCommand()
    {
        command = Command.none;
        state = State.idle;
        events ~= RunnerEvent(kind: EventKind.commandFinished);
    }

    // ── Output ──────────────────────────────────────────────────────────────

    private void takeOutputLine(string line)
    {
        import std.conv : ConvException, to;
        import std.string : indexOf;

        enum marker = frameMark ~ sentinelWord ~ " ";
        const at = line.indexOf(marker);
        if (at >= 0 && hello.token.length)
        {
            import std.algorithm.iteration : splitter;
            import std.array : array;

            auto words = line[at + marker.length .. $].splitter(' ').array;
            if (words.length == 2 && words[1] == hello.token)
            {
                if (at)
                    emitOutput(running, line[0 .. at]);
                size_t id = noTest;
                try
                    id = words[0].to!size_t;
                catch (ConvException)
                {
                }
                if (command == Command.run && id == running)
                {
                    haveSentinel = true;
                    finishRunIfDone();
                }
                return;
            }
        }
        emitOutput(command == Command.run ? running : noTest, line);
    }

    private void emitOutput(size_t test, string line)
    {
        if (test != noTest)
            pending ~= line ~ "\n";
        events ~= RunnerEvent(kind: EventKind.testOutput, test: test, text: line);
    }

    private string takePending()
    {
        auto text = pending;
        pending = null;
        return text;
    }

    // ── Ends ────────────────────────────────────────────────────────────────

    private void settleDeath()
    {
        if (!processEnded || !outputClosed || over)
            return;
        final switch (state)
        {
            case State.exiting:
                state = State.ended;
                events ~= RunnerEvent(kind: EventKind.workerEnded, text: ending, expected: true);
                return;
            case State.busy:
                if (command == Command.run)
                {
                    // A crash during a test fails that test, with its output
                    // (TRP25, TRP26).
                    auto result = TestResult(test: listing[running]);
                    result.thrown = [Thrown(type: "worker crashed",
                        message: "the test binary " ~ ending ~ " while running this test")];
                    result.output = takePending();
                    events ~= RunnerEvent(kind: EventKind.testFinished, test: running,
                        result: result);
                    running = noTest;
                }
                break;
            case State.hello:
            case State.listing:
                import std.conv : text;

                fail(text("the test binary ", binary,
                    " does not speak the runner protocol: it ", ending,
                    " before its listing", pending.length ? ":\n" ~ pending : ""));
                return;
            case State.idle:
            case State.ended:
            case State.failed:
                break;
        }
        state = State.ended;
        events ~= RunnerEvent(kind: EventKind.workerEnded, text: ending, expected: false);
    }

    private void fail(string message)
    {
        if (over)
            return;
        state = State.failed;
        events ~= RunnerEvent(kind: EventKind.protocolError, text: message);
    }
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

/// How a process ended, from `std.process.wait`'s status convention: a
/// negative status is a POSIX signal.
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

version (unittest)
{
    /// A worker's opening, as `serveWorker` writes it: a line feed, `hello`,
    /// the listing, `listed`.
    private string opening(string token, string[] names...)
    {
        import std.conv : to;

        string bytes = "\n" ~ frameText(frameOf("hello", [
            "version": JSONValue(1),
            "supported": JSONValue([JSONValue(1), JSONValue(1)]),
            "harness": JSONValue("test"),
            "compiler": JSONValue(["vendor": JSONValue("LDC"), "version": JSONValue(2113)]),
            "build": JSONValue(["asserts": JSONValue(true), "coverage": JSONValue(false)]),
            "roots": JSONValue(["src"]),
            "token": JSONValue(token),
            "tests": JSONValue(names.length),
        ]));
        foreach (i, name; names)
        {
            auto test = toJson(Test(fullName: "m." ~ name, name: name, id: i));
            test["t"] = "test";
            bytes ~= frameText(test);
        }
        return bytes ~ frameText(frameOf("listed"));
    }

    private string resultBytes(size_t id, string status)
    {
        return frameText(frameOf("result", [
            "id": JSONValue(id),
            "status": JSONValue(status),
            "durationNs": JSONValue(10),
            "failures": JSONValue(JSONValue[].init),
            "skip": JSONValue(""),
            "stackBudget": JSONValue(false),
        ]));
    }

    private EventKind[] kinds(in RunnerEvent[] events)
    {
        EventKind[] k;
        foreach (ref e; events)
            k ~= e.kind;
        return k;
    }
}

@("session.handshake.byteByByte")
@system
unittest
{
    // A module constructor's unterminated print glued onto the frames
    // channel, then the opening fed one byte at a time.
    auto s = WorkerSession("bin");
    foreach (c; "ctor says hi" ~ opening("T", "a", "b"))
        s.feedFrames([c]);
    auto events = s.takeEvents();
    assert(kinds(events) == [EventKind.testOutput, EventKind.workerReady]);
    assert(events[0].text == "ctor says hi" && events[0].test == noTest);
    assert(s.idle && s.listing.length == 2 && s.listing[1].name == "b");
    assert(s.hello.token == "T" && s.hello.roots == ["src"]);
}

@("session.handshake.versionMismatch")
@system
unittest
{
    auto s = WorkerSession("bin");
    s.feedFrames("\n" ~ frameText(frameOf("hello", [
        "version": JSONValue(null),
        "supported": JSONValue([JSONValue(99), JSONValue(99)]),
    ])));
    auto events = s.takeEvents();
    assert(kinds(events) == [EventKind.protocolError]);
    import std.algorithm.searching : canFind;

    assert(events[0].text.canFind("speaks runner protocol 99–99"), events[0].text);
    assert(events[0].text.canFind("this runner speaks 1–1"), events[0].text);
    assert(s.over);
}

@("session.handshake.notTheProtocol")
@system
unittest
{
    // A binary that prints and exits: no hello at all.
    auto s = WorkerSession("bin");
    s.feedFrames("plain druntime runner output\n");
    s.feedOutput("1 modules passed unittests\n");
    s.feedEnd(describeEnding(0));
    s.feedOutputClosed();
    auto events = s.takeEvents();
    assert(events[$ - 1].kind == EventKind.protocolError);
    import std.algorithm.searching : canFind;

    assert(events[$ - 1].text.canFind("does not speak the runner protocol"));
}

@("session.run.outputBeforeResult")
@system
unittest
{
    auto s = WorkerSession("bin");
    s.feedFrames(opening("T", "a"));
    cast(void) s.takeEvents();

    const command = s.run(0, mainThread: false);
    assert(command[0] == frameMark);
    // The result frame overtakes the output on the other pipe.
    s.feedFrames(frameText(frameOf("started", ["id": JSONValue(0)])) ~ resultBytes(0, "passed"));
    assert(kinds(s.takeEvents()) == [EventKind.testStarted], "the result waits for the sentinel");
    s.feedOutput("one\ntw");
    s.feedOutput("o\n" ~ sentinelText(0, "T"));
    auto events = s.takeEvents();
    assert(kinds(events) == [EventKind.testOutput, EventKind.testOutput,
        EventKind.testFinished, EventKind.commandFinished]);
    assert(events[2].result.succeeded && events[2].result.output == "one\ntwo\n");
    assert(s.idle);
}

@("session.run.crashMidFrame")
@system
unittest
{
    auto s = WorkerSession("bin");
    s.feedFrames(opening("T", "a", "b"));
    cast(void) s.takeEvents();

    cast(void) s.run(1, mainThread: false);
    s.feedFrames(frameText(frameOf("started", ["id": JSONValue(1)])));
    s.feedOutput("about to abort\n");
    // The worker dies halfway through writing its result.
    s.feedFrames("\x1e{\"id\":1,\"stat");
    s.feedEnd(describeEnding(-6));
    assert(kinds(s.takeEvents()) == [EventKind.testStarted, EventKind.testOutput],
        "nothing settles until the output channel is closed");
    s.feedOutputClosed();
    auto events = s.takeEvents();
    assert(kinds(events) == [EventKind.testFinished, EventKind.workerEnded]);
    const result = events[0].result;
    assert(!result.succeeded && result.test.name == "b");
    assert(result.output == "about to abort\n");
    version (Posix)
    {
        import std.algorithm.searching : canFind;

        assert(result.thrown[0].message.canFind("signal 6 (SIGABRT)"), result.thrown[0].message);
    }
    assert(!events[1].expected && s.over);
}

@("session.run.unattributedBetweenTests")
@system
unittest
{
    auto s = WorkerSession("bin");
    s.feedFrames(opening("T", "a"));
    cast(void) s.takeEvents();
    s.feedOutput("a thread that outlived its test\n");
    auto events = s.takeEvents();
    assert(events.length == 1 && events[0].test == noTest);
}

@("session.protocol.frameWithNoCommand")
@system
unittest
{
    auto s = WorkerSession("bin");
    s.feedFrames(opening("T", "a"));
    cast(void) s.takeEvents();
    s.feedFrames(resultBytes(0, "passed"));
    auto events = s.takeEvents();
    assert(kinds(events) == [EventKind.protocolError] && s.over);
}

@("session.exit.expected")
@system
unittest
{
    auto s = WorkerSession("bin");
    s.feedFrames(opening("T"));
    cast(void) s.takeEvents();
    import std.algorithm.searching : canFind;

    assert(s.exit(coverageMerge: true).canFind(`"coverageMerge":true`));
    s.feedEnd(describeEnding(0));
    s.feedOutputClosed();
    auto events = s.takeEvents();
    assert(kinds(events) == [EventKind.workerEnded] && events[0].expected);
}

@("session.bench.reRegistrationKeepsCaseIds")
@system
unittest
{
    // A worker registers a test's cases, then dies measuring one; a new
    // worker registering the same test in the same order yields the same
    // case ids (TRP26).
    string registration(size_t test)
    {
        string bytes;
        foreach (i, name; ["fast", "slow"])
            bytes ~= frameText(frameOf("case", [
                "case": JSONValue(i), "test": JSONValue(test), "name": JSONValue(name),
                "labels": JSONValue(string[string].init), "metrics": JSONValue(JSONValue[].init),
            ]));
        return bytes ~ resultBytes(test, "passed") ~ frameText(frameOf("registered"));
    }

    string[] caseIds(ref WorkerSession s)
    {
        import std.conv : to;

        string[] ids;
        foreach (ref e; s.takeEvents())
            if (e.kind == EventKind.commandFrame && e.frame["t"].str == "case")
                ids ~= e.frame["case"].integer.to!string ~ ":" ~ e.frame["name"].str;
        return ids;
    }

    auto first = WorkerSession("bin");
    first.feedFrames(opening("T", "bench"));
    cast(void) first.takeEvents();
    cast(void) first.request(frameOf("register", ["ids": JSONValue([JSONValue(0)])]), "registered");
    first.feedFrames(registration(0));
    const before = caseIds(first);
    cast(void) first.request(frameOf("measure", ["case": JSONValue(1)]), "measured");
    first.feedFrames(frameText(frameOf("caseStarted", ["case": JSONValue(1)])));
    first.feedEnd(describeEnding(-11));
    first.feedOutputClosed();
    auto ends = first.takeEvents();
    assert(ends[$ - 1].kind == EventKind.workerEnded && !ends[$ - 1].expected);

    auto second = WorkerSession("bin");
    second.feedFrames(opening("U", "bench"));
    cast(void) second.takeEvents();
    cast(void) second.request(frameOf("register", ["ids": JSONValue([JSONValue(0)])]), "registered");
    second.feedFrames(registration(0));
    assert(caseIds(second) == before && before == ["0:fast", "1:slow"]);
}

/// `line` without the carriage return a Windows text-mode stream ends it
/// with: a CRLF worker's sentinel must still match (TRW1).
private string withoutCarriageReturn(string line) @safe pure nothrow @nogc
    => line.length && line[$ - 1] == '\r' ? line[0 .. $ - 1] : line;

@("session.run.crlfLines")
@system
unittest
{
    auto s = WorkerSession("bin");
    import std.array : replace;

    s.feedFrames(opening("T", "a").replace("\n", "\r\n"));
    cast(void) s.takeEvents();
    cast(void) s.run(0, mainThread: false);
    s.feedFrames((frameText(frameOf("started", ["id": JSONValue(0)]))
        ~ resultBytes(0, "passed")).replace("\n", "\r\n"));
    s.feedOutput(("line\n" ~ sentinelText(0, "T")).replace("\n", "\r\n"));
    auto events = s.takeEvents();
    assert(events[$ - 2].kind == EventKind.testFinished && events[$ - 2].result.output == "line\n");
}
