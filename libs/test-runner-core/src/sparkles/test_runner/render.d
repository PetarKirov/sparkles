/**
 * The core's plain-text rendering of a session's events: the lines a client
 * without a terminal reporter shows, and the output `ci` gives a test action
 * (process-model TRM6). One test's lines stay together: its output, its
 * result line, then its failures.
 */
module sparkles.test_runner.render;

import sparkles.test_runner.model : TestResult;
import sparkles.test_runner.session : EventKind, noTest, RunnerEvent;

/// The lines of `event`; none for events that only drive a client.
string[] plainLines(const RunnerEvent event, bool verbose = false) @safe
{
    switch (event.kind)
    {
        case EventKind.testOutput:
            // A test's own output is rendered with its result; unattributed
            // output stands alone.
            return event.test == noTest ? [event.text] : null;
        case EventKind.testFinished:
            return resultLines(event.result, verbose);
        case EventKind.protocolError:
            return ["error: " ~ event.text];
        case EventKind.workerEnded:
            return event.expected ? null : ["the test binary " ~ event.text];
        default:
            return null;
    }
}

/// A test's output, its result line and its failures.
string[] resultLines(const TestResult result, bool verbose = false) @safe
{
    import std.algorithm.iteration : splitter;
    import std.conv : text;

    string[] lines;
    if (result.output.length)
    {
        const body = result.output[$ - 1] == '\n' ? result.output[0 .. $ - 1] : result.output;
        foreach (line; body.splitter('\n'))
            lines ~= line.idup;
    }
    if (result.skipped)
        return lines ~ text("⊘ ", result.test.name, " — ", result.skipReason);
    lines ~= text(result.succeeded ? "✓ " : "✗ ", result.test.name);
    foreach (ref thrown; result.thrown)
    {
        lines ~= text("    ", thrown.type, "@", thrown.file, "(", thrown.line, "): ",
            thrown.message);
        if (verbose)
            foreach (frame; thrown.info)
                lines ~= "        " ~ frame;
    }
    return lines;
}

/// The summary line of a run's counts.
string summaryLine(size_t passed, size_t failed, size_t skipped) @safe
{
    import std.conv : text;

    return text("Summary: ", passed, " passed, ", failed, " failed, ", skipped, " skipped");
}

@("render.resultLines.outputThenResultThenFailures")
@safe
unittest
{
    import sparkles.test_runner.model : Test, Thrown;

    auto failed = TestResult(test: Test(name: "parse"), output: "trace 1\ntrace 2\n");
    failed.thrown = [Thrown(type: "AssertError", message: "1 != 2", file: "a.d", line: 7,
        info: ["frame"])];
    assert(resultLines(failed) == ["trace 1", "trace 2", "✗ parse",
        "    AssertError@a.d(7): 1 != 2"]);
    assert(resultLines(failed, verbose: true)[$ - 1] == "        frame");

    const skipped = TestResult(test: Test(name: "perf"), skipped: true, skipReason: "no PMU");
    assert(resultLines(skipped) == ["⊘ perf — no PMU"]);
    assert(resultLines(TestResult(test: Test(name: "ok"), succeeded: true)) == ["✓ ok"]);
}

@("render.plainLines.events")
@system
unittest
{
    assert(plainLines(RunnerEvent(kind: EventKind.testOutput, text: "stray")) == ["stray"]);
    assert(plainLines(RunnerEvent(kind: EventKind.testOutput, test: 3, text: "mine")) is null);
    assert(plainLines(RunnerEvent(kind: EventKind.workerEnded, text: "exited with status 0",
        expected: true)) is null);
    assert(plainLines(RunnerEvent(kind: EventKind.workerEnded,
        text: "was killed by signal 9 (SIGKILL)")) == ["the test binary was killed by signal 9 (SIGKILL)"]);
    assert(summaryLine(3, 1, 2) == "Summary: 3 passed, 1 failed, 2 skipped");
}
