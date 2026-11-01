module sparkles.core_cli.args.error;

import expected = sparkles.base.expected;

public import sparkles.base.expected : Expected;

struct CliError
{
    enum Kind
    {
        parse,
        help,
        /// `-V` / `--version`. Exit 0 when the section is missing or valid.
        /// `version` is a D keyword, so the member is `version_`.
        version_,
    }

    Kind kind;
    string message;
    string help;
    int exitCode = 1;

    bool isHelp() const @safe pure nothrow @nogc => kind == Kind.help;

    /// `-V` / `--version`.
    bool isVersion() const @safe pure nothrow @nogc => kind == Kind.version_;
}

alias CliExpected(T) = Expected!(T, CliError);

/// `Expected`-success constructors with the error type fixed to `CliError`.
/// Mirrors `expected.ok` but removes the need to repeat `!CliError` at every
/// call site.
auto ok(T)(T value) => expected.ok!CliError(value);

/// ditto
auto ok() => expected.ok!CliError();

/// `Expected`-failure constructor with the error type fixed to `CliError`.
/// `T` is the value type of the resulting `Expected!(T, CliError)`; defaults
/// to `void`. Mirrors `expected.err` but skips the `CliError` boilerplate.
auto error(T = void)(CliError e)
{
    static if (is(T == void))
        return expected.err(e);
    else
        return expected.err!T(e);
}

/**
How a command's `run()` reports what is not success: a failure, or a skip —
the environment lacks what the program needs (no display, no GPU driver),
which is not the program's fault. `runCli` writes a skip as `SKIP: …` on
standard output and exits 0, and a failure as `Error: …` on standard error,
exiting 1.
*/
struct RunError
{
    string message;   ///
    bool skipped;     /// a degraded environment, not a failure
    int exitCode = 1; /// a failure's exit status (a skip exits 0)
}

/// A `run()` result: a value, or a $(LREF RunError).
alias RunExpected(T = void) = Expected!(T, RunError);

/// A skip: `what` the program could not do, and the environment's `detail`.
RunExpected!T skipRun(T = void)(string what, string detail = null)
{
    const message = detail.length ? what ~ " — " ~ detail : what;
    static if (is(T == void))
        return expected.err(RunError(message, skipped: true));
    else
        return expected.err!T(RunError(message, skipped: true));
}

/// A failure, described by `message`, exiting with `exitCode`.
RunExpected!T failRun(T = void)(string message, int exitCode = 1)
{
    static if (is(T == void))
        return expected.err(RunError(message, exitCode: exitCode));
    else
        return expected.err!T(RunError(message, exitCode: exitCode));
}

/// The success of a `RunExpected!void` `run()`.
RunExpected!void ranOk() @safe pure nothrow @nogc => expected.ok!RunError();

///
@("args.error.runError")
@safe unittest
{
    const skipped = skipRun("no display", "WAYLAND_DISPLAY unset");
    assert(skipped.hasError && skipped.error.skipped);
    assert(skipped.error.message == "no display — WAYLAND_DISPLAY unset");
    assert(skipRun!int("no GPU").error.message == "no GPU");
    const failed = failRun("createWindow failed");
    assert(failed.hasError && !failed.error.skipped && failed.error.exitCode == 1);
    assert(failRun("bad theme", 2).error.exitCode == 2);
    assert(!ranOk().hasError);
}
