/**
 * First-class test skipping: `skipTest("reason")` aborts the current test and
 * the runner records it as SKIPPED — a yellow `⊘` result line with the reason
 * and an `N skipped` summary segment — instead of the early-`return` pattern
 * that silently counts a degraded environment as a pass.
 *
 * Runtime-only: not usable in `@ctfe` bodies (the probe compile evaluates
 * them, and a skip there is a compile error) nor in the extracted
 * `--better-c`/`--wasm` programs (no druntime classes there). Inside a
 * `@benchmark` body, prefer skipping at registration time (the top of the
 * body) — a `skipTest` inside a deferred `benchIter`/`benchCase` closure
 * skips only that case's row.
 */
module sparkles.test_runner.skip;

/// Thrown by `skipTest`; the runner records the test as skipped, not failed.
/// NB: instances come from a recycled thread-local buffer — catchers must
/// `.idup` the message before the next `skipTest` on the same thread.
class TestSkipped : Error
{
    @nogc @safe pure nothrow this(string msg, Throwable next = null)
    {
        super(msg, next);
    }
}

/// Aborts the current test, recording it as skipped with `reason` — for
/// environment capabilities a test needs but this machine/run lacks (perf
/// counters, a root-only tracefs, a missing toolchain binary). Callable from
/// the strictest test bodies: throwing an `Error` is `nothrow`-legal, and the
/// recycled instance keeps it `@nogc` (the minimal `@trusted` covers only the
/// deliberately-`@system` `recycledSkip`).
noreturn skipTest(string reason) @safe pure nothrow @nogc
{
    throw (() @trusted => (cast(TestSkipped function(in char[]) @system pure nothrow @nogc)
        &recycledSkip)(reason))();
}

/// The thread's one `TestSkipped`, re-initialized with a copy of `reason` in
/// a thread-local buffer, so the message survives the caller's frame.
private TestSkipped recycledSkip(in char[] reason) @system nothrow @nogc
{
    import core.lifetime : emplace;

    static char[16 * 1024] message;
    align(16) static ubyte[__traits(classInstanceSize, TestSkipped)] slot;
    const n = reason.length < message.length ? reason.length : message.length;
    message[0 .. n] = reason[0 .. n];
    return emplace!TestSkipped(cast(void[]) slot[], cast(string) message[0 .. n]);
}

@("skip.skipTest.throwsTestSkipped")
@system
unittest
{
    bool caught;
    try
        skipTest("no perf counters");
    catch (TestSkipped e)
    {
        caught = true;
        assert(e.message == "no perf counters");
    }
    assert(caught);

    // The attribute set is part of the contract: callable from the strictest
    // test bodies without relaxing them.
    static assert(is(typeof(() @safe pure nothrow @nogc { skipTest("x"); })));
}
