/**
Druntime assertion handling utilities.

Provides handlers and installation helpers to configure assertion failure
behavior (such as calling abort() to generate core dumps with intact backtraces
for coredumpctl/gdb).
*/
module sparkles.base.assert_handler;

/// How assertion failures should be handled by druntime.
enum AssertHandlerKind
{
    /// Default druntime assert handler (throws AssertError).
    default_,

    /// Writes failure details to stderr and calls abort() to produce a core dump
    /// with the backtrace and stack frames intact for coredumpctl/gdb.
    abort,

    /// Alias for abort.
    halt,
}

/// Installs the requested druntime assertion handler.
void installAssertHandler(AssertHandlerKind kind) @trusted
{
    import core.exception : assertHandler;

    final switch (kind) with (AssertHandlerKind)
    {
        case default_:
            assertHandler = null;
            break;
        case abort:
        case halt:
            assertHandler = &abortAssertHandler;
            break;
    }
}

/// Druntime assert handler that prints failure details to stderr and calls
/// abort() to generate a core dump with the stack and backtrace preserved.
void abortAssertHandler(string file, size_t line, string msg) nothrow @nogc
{
    import core.stdc.stdio : fflush, fprintf, stderr;
    import core.stdc.stdlib : abort;

    const filePtr = file.length > 0 && file.ptr ? file.ptr : "".ptr;
    const msgPtr = msg.length > 0 && msg.ptr ? msg.ptr : "".ptr;

    if (msg.length > 0)
    {
        fprintf(stderr, "Assertion failure: %.*s at %.*s:%zu\n",
            cast(int) msg.length, msgPtr,
            cast(int) file.length, filePtr,
            line);
    }
    else
    {
        fprintf(stderr, "Assertion failure at %.*s:%zu\n",
            cast(int) file.length, filePtr,
            line);
    }
    fflush(stderr);
    abort();
}

/// Pre-scans an argv array for --assert-handler flags and installs the handler immediately.
void preScanAndInstallAssertHandler(const(string)[] args) @safe
{
    for (size_t i = 1; i < args.length; ++i)
    {
        const arg = args[i];
        if (arg == "--assert-handler=abort" || arg == "--assert-handler=halt")
            installAssertHandler(AssertHandlerKind.abort);
        else if (arg == "--assert-handler=default")
            installAssertHandler(AssertHandlerKind.default_);
        else if (arg == "--assert-handler" && i + 1 < args.length)
        {
            const next = args[i + 1];
            if (next == "abort" || next == "halt")
                installAssertHandler(AssertHandlerKind.abort);
            else if (next == "default")
                installAssertHandler(AssertHandlerKind.default_);
        }
    }
}

@("base.assertHandler.installAndRestore")
@system unittest
{
    import core.exception : assertHandler;

    const prev = assertHandler;
    scope (exit) assertHandler = prev;

    installAssertHandler(AssertHandlerKind.abort);
    assert(assertHandler is &abortAssertHandler);

    installAssertHandler(AssertHandlerKind.halt);
    assert(assertHandler is &abortAssertHandler);

    installAssertHandler(AssertHandlerKind.default_);
    assert(assertHandler is null);
}

@("base.assertHandler.preScan")
@safe unittest
{
    import core.exception : assertHandler;

    const prev = assertHandler;
    scope (exit) assertHandler = prev;

    preScanAndInstallAssertHandler(["app", "--assert-handler", "abort"]);
    assert(assertHandler is &abortAssertHandler);

    preScanAndInstallAssertHandler(["app", "--assert-handler=default"]);
    assert(assertHandler is null);

    preScanAndInstallAssertHandler(["app", "--assert-handler=halt"]);
    assert(assertHandler is &abortAssertHandler);
}
