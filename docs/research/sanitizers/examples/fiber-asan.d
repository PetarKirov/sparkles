#!/usr/bin/env dub
/+ dub.sdl:
    name "fiber_asan"
    platforms "linux"
    dflags "-g"
    dflags "-fsanitize=address" platform="ldc"
    targetPath "build"
+/
/**
 * AddressSanitizer catches a fiber stack-use-after-return: a `scope` delegate
 * whose closure lives in a stack frame is stored for deferred `Fiber` start,
 * and the frame dies before the fiber runs — the bug shape ASan found for
 * real in this repo (`feat/event-horizon` commit `c9537f96`, "storing scope
 * delegates for deferred fiber start is stack-use-after-return").
 *
 * Two child-process demonstrations (the parent re-execs itself and asserts on
 * each child's exit code and stderr report):
 *
 *   1. With `ASAN_OPTIONS=detect_stack_use_after_return=1` the instrumented
 *      frame lives on ASan's *fake stack* and is poisoned when the frame
 *      returns; the fiber's later call through the dead closure dies with
 *      `stack-use-after-return`, symbolized to the closure body's
 *      `file:line`, exit 1. The catch works with the stock (uninstrumented,
 *      no-`SupportSanitizers`) nixpkgs druntime — no fiber annotations are
 *      required for this particular defect because the faulting read
 *      happens in instrumented user code.
 *   2. With `detect_stack_use_after_return=0` the same child reads garbage
 *      from the reused frame and exits 0 — the bug silently corrupts. The
 *      option gate (LDC default `-fsanitize-address-use-after-return=
 *      runtime`) is what makes leg 1 switchable at run time.
 *
 * Companion to docs/research/sanitizers/d-toolchain.md
 *   § "Fibers under ASan: fake stacks and stack-use-after-return".
 *
 * Run with: dub run --single fiber-asan.d
 *
 * Environment recorded: Linux 6.18.26, AMD Ryzen 9 7940HX (Zen 4), LDC 1.41.0
 * (LLVM 18.1.8). ASan runtime = GCC 15.2.0 `libasan.so.8` via LDC's
 * `linker-gcc.cpp` fallback (nixpkgs LDC ships no compiler-rt); druntime
 * fiber stacks are `mmap`'d with a guard page
 * (`core/thread/fiber/package.d`, `allocStack`).
 *
 * Portability: builds without instrumentation (DMD has no `-fsanitize`; the
 * flag is gated `platform="ldc"`), in which case — detected at compile time
 * via the `LDC_AddressSanitizer` predefined version — the probe prints a
 * `SKIP:` line and exits 0 so CI stays green on any host.
 */
module fiber_asan;

import std.stdio : writefln, writeln;

version (LDC_AddressSanitizer)
    private enum instrumented = true;
else
    private enum instrumented = false;

/// Name of the env var that arms the faulty child leg.
private enum childVar = "FIBER_ASAN_CHILD";

private Fiber[] pending;

import core.thread.fiber : Fiber;

/// Stores a `scope` delegate for *deferred* start — the escape the compiler
/// trusted us not to make. With `scope`, the closure may stay in the caller's
/// stack frame instead of being GC-heap-allocated; keeping it past the
/// frame's death is the bug.
private void spawnDeferred(scope void delegate() dg) @system
{
    pending ~= new Fiber(dg);
}

/// The frame that dies: `local` (captured by the nested function's closure)
/// lives here, and `spawnDeferred` keeps a delegate to it.
private void scopeBody() @system
{
    int local = 41;
    void child()
    {
        ++local; // read+write through the dead frame once the fiber runs
        writefln("fiber sees local = %s", local);
    }

    spawnDeferred(&child);
} // scopeBody's frame is gone; pending[0] still points into it

/// Child: run the deferred fiber after the owning frame returned.
private int runChildLeg()
{
    scopeBody();
    foreach (f; pending)
        f.call(); // stack-use-after-return happens inside the fiber
    writeln("child leg: fiber ran to completion (bug undetected)");
    return 0;
}

/// Re-execs this binary with the leg armed and `detect_stack_use_after_return`
/// set as given; returns (exitCode, combined output).
private auto runChild(bool detectUar)
{
    import std.file : thisExePath;
    import std.process : escapeShellCommand, executeShell;

    const env = [
        childVar: "1",
        // detect_leaks=0 keeps the asserted exit codes purely about the
        // demonstrated defect; the UAR toggle is the experiment's variable.
        "ASAN_OPTIONS": "detect_stack_use_after_return="
            ~ (detectUar ? "1" : "0") ~ ":detect_leaks=0",
    ];
    return executeShell(escapeShellCommand(thisExePath) ~ " 2>&1", env);
}

version (linux) private int run()
{
    import std.algorithm.searching : canFind;
    import std.process : environment;

    if (environment.get(childVar) !is null)
        return runChildLeg();

    static if (!instrumented)
    {
        writeln("SKIP: built without AddressSanitizer instrumentation ",
            "(DMD has no -fsanitize; LDC-only dflags are platform-gated)");
        return 0;
    }
    else
    {
        const caught = runChild(true);
        assert(caught.status != 0,
            "expected ASan to abort the deferred-fiber child");
        assert(caught.output.canFind("stack-use-after-return"),
            "expected a stack-use-after-return report; got:\n" ~ caught.output);
        writefln("proved: deferred fiber start through a scope delegate is " ~
            "stack-use-after-return (child exit %s)", caught.status);

        const silent = runChild(false);
        assert(silent.status == 0,
            "expected the bug to go undetected with the fake stack disabled");
        assert(!silent.output.canFind("AddressSanitizer"),
            "expected no ASan report with detect_stack_use_after_return=0");
        writeln("proved: detect_stack_use_after_return=0 turns the same run " ~
            "into silent corruption");

        writeln("OK: ASan's fake stack catches the fiber " ~
            "stack-use-after-return that killed event-horizon's M5 gate");
        return 0;
    }
}

int main()
{
    version (linux)
        return run();
    else
    {
        writeln("SKIP: this probe records Linux behavior (platforms \"linux\")");
        return 0;
    }
}
