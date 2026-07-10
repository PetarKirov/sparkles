/**
 * Runtime execution of discovered tests.
 */
module sparkles.test_runner.execution;

import sparkles.test_runner.model : Test, TestResult, Thrown;
import sparkles.test_runner.skip : TestSkipped;

/// Runs one test, capturing anything it throws.
///
/// Almost everything a test throws — `Exception`s, `AssertError`s, and other
/// `Error`s such as `RangeError` (whose semantics are well-defined in D) — is
/// recorded (with its full chain and stack traces) as a failure, so one broken
/// test never aborts the rest of the parallel run. `TestSkipped` (from
/// `skipTest`) records the test as skipped, not failed. Only
/// `OutOfMemoryError` indicates a genuinely broken process state and is
/// re-thrown.
TestResult executeTest(Test test)
{
    import core.time : MonoTime;

    auto result = TestResult(test: test);
    const started = MonoTime.currTime;

    try
    {
        scope (exit)
            result.duration = MonoTime.currTime - started;
        test.ptr();
        result.succeeded = true;
    }
    catch (TestSkipped s)
    {
        result.skipped = true;
        // The recycled instance's message buffer is reused by the next
        // skipTest on this thread — copy now.
        result.skipReason = s.message.idup;
    }
    catch (Throwable t)
        result.thrown = toThrown(t); // re-throws OutOfMemoryError

    return result;
}

@("executeTest.skip")
@system
unittest
{
    import sparkles.test_runner.skip : skipTest;

    static void skipper()
    {
        skipTest("no perf counters");
    }

    auto result = executeTest(Test(fullName: "m.s", name: "s", ptr: &skipper));
    assert(result.skipped && !result.succeeded);
    assert(result.thrown.length == 0, "a skip is not a failure");
    assert(result.skipReason == "no perf counters");

    // A second skip on the same thread reuses the recycled message buffer;
    // the first result's reason must have been copied out of it.
    static void skipper2()
    {
        skipTest("different reason entirely");
    }

    cast(void) executeTest(Test(fullName: "m.s2", name: "s2", ptr: &skipper2));
    assert(result.skipReason == "no perf counters");
}

/// Converts a caught `Throwable` chain into `Thrown[]` (its full chain, each with
/// stack trace). `OutOfMemoryError` signals a genuinely broken process and is
/// re-thrown rather than recorded. Shared by `executeTest` and the benchmark
/// driver, whose measurement of a registered case runs outside `executeTest`.
package immutable(Thrown)[] toThrown(Throwable t)
{
    import core.exception : OutOfMemoryError;

    if (cast(OutOfMemoryError) t)
        throw t;

    immutable(Thrown)[] result;
    foreach (thrown; t)
    {
        immutable(string)[] trace;
        try
        {
            // `info` is null for exceptions that were chained but never thrown
            // (e.g. `new Exception("effect", new Exception("cause"))`).
            if (thrown.info !is null)
                foreach (frame; thrown.info)
                    trace ~= frame.idup;
        }
        catch (OutOfMemoryError)
        {
            trace ~= "<test-runner> failed to read the stack trace";
        }

        result ~= Thrown(
            type: typeid(thrown).name,
            message: thrown.message.idup,
            file: thrown.file,
            line: thrown.line,
            info: trace,
        );
    }
    return result;
}

@("executeTest.pass")
@system
unittest
{
    static void ok() {}
    auto result = executeTest(Test(fullName: "m.ok", name: "ok", ptr: &ok));
    assert(result.succeeded);
    assert(result.thrown.length == 0);
}

@("executeTest.failure")
@system
unittest
{
    static void boom()
    {
        int zero = 0;
        assert(zero == 1, "boom happened");
    }

    auto result = executeTest(Test(fullName: "m.boom", name: "boom", ptr: &boom));
    assert(!result.succeeded);
    assert(result.thrown.length == 1);
    assert(result.thrown[0].type == "core.exception.AssertError");
}

@("executeTest.exceptionChain")
@system
unittest
{
    static void chained()
    {
        auto cause = new Exception("cause");
        throw new Exception("effect", cause);
    }

    auto result = executeTest(Test(fullName: "m.chained", name: "chained", ptr: &chained));
    assert(!result.succeeded);
    assert(result.thrown.length == 2);
    assert(result.thrown[0].message == "effect");
    assert(result.thrown[1].message == "cause");
}

@("executeTest.recordsRangeError")
@system
unittest
{
    // A non-`Exception` `Error` (here `RangeError` from an out-of-bounds index)
    // is recorded as a failure, not re-thrown — one broken test must not abort
    // the whole parallel run.
    static void outOfBounds()
    {
        int[] empty;
        cast(void) empty[3]; // core.exception.RangeError
    }

    auto result = executeTest(Test(fullName: "m.oob", name: "oob", ptr: &outOfBounds));
    assert(!result.succeeded);
    assert(result.thrown.length == 1); // recorded, not re-thrown out of the run
    // `RangeError`, or its `ArrayIndexError` subclass on newer druntime.
    import std.algorithm.searching : endsWith;
    assert(result.thrown[0].type.endsWith("RangeError")
        || result.thrown[0].type.endsWith("IndexError"));
}
