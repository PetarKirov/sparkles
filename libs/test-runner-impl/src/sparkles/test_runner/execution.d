/**
 * Runtime execution of discovered tests.
 */
module sparkles.test_runner.execution;

import sparkles.test_runner.model : Test, TestResult, Thrown;

/// Runs one test, capturing anything it throws.
///
/// `Exception`s and `AssertError`s are recorded (with their full chain and
/// stack traces) as a failure; other `Throwable`s — `RangeError`,
/// `OutOfMemoryError`, … — indicate a broken process state and are re-thrown.
TestResult executeTest(Test test)
{
    import core.exception : AssertError, OutOfMemoryError;
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
    catch (Throwable t)
    {
        if (!(cast(Exception) t || cast(AssertError) t))
            throw t;

        foreach (thrown; t)
        {
            immutable(string)[] trace;
            try
            {
                // `info` is null for exceptions that were chained but never
                // thrown (e.g. `new Exception("effect", new Exception("cause"))`).
                if (thrown.info !is null)
                    foreach (frame; thrown.info)
                        trace ~= frame.idup;
            }
            catch (OutOfMemoryError)
            {
                trace ~= "<test-runner> failed to read the stack trace";
            }

            result.thrown ~= Thrown(
                type: typeid(thrown).name,
                message: thrown.message.idup,
                file: thrown.file,
                line: thrown.line,
                info: trace,
            );
        }
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
