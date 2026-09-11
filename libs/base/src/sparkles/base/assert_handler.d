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

/// Druntime assert handler type.
alias AssertHandler = void function(string file, size_t line, string msg) nothrow;

/// Resolves the assertion handler function pointer for the requested kind.
AssertHandler resolveAssertHandler(AssertHandlerKind kind) pure nothrow @nogc @safe
{
    final switch (kind) with (AssertHandlerKind)
    {
        case default_:
            return null;
        case abort:
        case halt:
            return &abortAssertHandler;
    }
}

/// Installs the requested druntime assertion handler.
void installAssertHandler(AssertHandlerKind kind) @trusted
{
    import core.exception : assertHandler;

    assertHandler = resolveAssertHandler(kind);
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

/// Pre-scans an argv array for --assert-handler flags.
/// Returns true if a recognized flag was found and sets `kind`.
bool parseAssertHandlerArg(const(string)[] args, out AssertHandlerKind kind) pure nothrow @safe @nogc
{
    for (size_t i = 1; i < args.length; ++i)
    {
        const arg = args[i];
        if (arg == "--assert-handler=abort" || arg == "--assert-handler=halt")
        {
            kind = AssertHandlerKind.abort;
            return true;
        }
        else if (arg == "--assert-handler=default")
        {
            kind = AssertHandlerKind.default_;
            return true;
        }
        else if (arg == "--assert-handler" && i + 1 < args.length)
        {
            const next = args[i + 1];
            if (next == "abort" || next == "halt")
            {
                kind = AssertHandlerKind.abort;
                return true;
            }
            else if (next == "default")
            {
                kind = AssertHandlerKind.default_;
                return true;
            }
        }
    }
    return false;
}

/// Pre-scans an argv array for --assert-handler flags and installs the handler immediately.
void preScanAndInstallAssertHandler(const(string)[] args) @safe
{
    AssertHandlerKind kind;
    if (parseAssertHandlerArg(args, kind))
        installAssertHandler(kind);
}

@("base.assertHandler.resolveAssertHandler")
@safe pure nothrow @nogc unittest
{
    assert(resolveAssertHandler(AssertHandlerKind.abort) is &abortAssertHandler);
    assert(resolveAssertHandler(AssertHandlerKind.halt) is &abortAssertHandler);
    assert(resolveAssertHandler(AssertHandlerKind.default_) is null);
}

@("base.assertHandler.parseAssertHandlerArg")
@safe pure nothrow @nogc unittest
{
    AssertHandlerKind kind;
    assert(parseAssertHandlerArg(["app", "--assert-handler", "abort"], kind) && kind == AssertHandlerKind.abort);
    assert(parseAssertHandlerArg(["app", "--assert-handler=default"], kind) && kind == AssertHandlerKind.default_);
    assert(parseAssertHandlerArg(["app", "--assert-handler=halt"], kind) && kind == AssertHandlerKind.abort);
    assert(!parseAssertHandlerArg(["app", "--other"], kind));
}
