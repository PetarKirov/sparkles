/// `@nogc nothrow` POSIX process helpers returning `Expected`.
///
/// This is a deliberate first step toward a future `sparkles.core_cli.process`
/// module: small, allocation-free process primitives that report failure via
/// `Expected!(T, ProcessError, NoGcHook)` rather than throwing, so they can be
/// called from the terminal's `nothrow @nogc` core loop. For now it hosts only
/// what the loop needs (`spawnDetached`); grow it (e.g. a `captureCommand`)
/// before promoting it into `core-cli`.
module posix_util;

import expected : Expected, ok, err;
import sparkles.core_cli.text.errors : NoGcHook;

/// Which POSIX step failed.
enum ProcessErrorCode
{
    fork,
    exec,
    wait,
}

/// A structured, allocation-free process error: the failing step plus the
/// `errno` captured at the failure site (0 when not applicable).
struct ProcessError
{
    ProcessErrorCode code;
    int errnoValue;
}

/// Subsystem alias locking in `ProcessError` and the no-default-construct hook.
alias ProcessExpected(T) = Expected!(T, ProcessError, NoGcHook);

/// Success helpers (mirror the `parseOk`/`parseErr` idiom in `core-cli`).
@safe nothrow @nogc
ProcessExpected!T procOk(T)(T value)
    => ok!(ProcessError, NoGcHook)(value);

/// ditto
@safe nothrow @nogc
ProcessExpected!void procOk()
    => ok!(ProcessError, NoGcHook)();

/// Failure helper.
@safe nothrow @nogc
ProcessExpected!T procErr(T)(ProcessErrorCode code, int errnoValue)
    => err!(T, NoGcHook)(ProcessError(code, errnoValue));

/// Spawn a fully detached process via the classic double-fork, so the spawned
/// program is reparented to init and never becomes a zombie of this process.
///
/// `argv` must be NUL-terminated C strings with a trailing `null` sentinel
/// (`argv[$-1] is null`); `argv[0]` is resolved through `PATH` (`execvp`). The
/// caller owns the backing memory; it only needs to outlive this call. Used for
/// "open this URL" (`xdg-open`) from the core loop.
///
/// Both forked children touch only async-signal-safe calls (`fork`/`execvp`/
/// `_exit`), which matters because every fork in this app happens after raylib
/// has created GL/window threads.
@system nothrow @nogc
ProcessExpected!void spawnDetached(scope const(char)*[] argv)
{
    import core.sys.posix.unistd : fork, _exit, execvp;
    import core.sys.posix.sys.wait : waitpid;
    import core.sys.posix.sys.types : pid_t;
    import core.stdc.errno : errno;

    const pid_t middle = fork();
    if (middle < 0)
        return procErr!void(ProcessErrorCode.fork, errno);

    if (middle == 0)
    {
        // Middle child: fork the grandchild that actually execs, then exit
        // immediately so the grandchild is orphaned onto init.
        const pid_t grandchild = fork();
        if (grandchild == 0)
        {
            execvp(argv[0], cast(char**) argv.ptr);
            _exit(127); // exec failed
        }
        _exit(0);
    }

    // Parent: reap the middle child right away (it exits at once), leaving no
    // zombie. The grandchild is not ours to wait for.
    int status;
    if (waitpid(middle, &status, 0) < 0)
        return procErr!void(ProcessErrorCode.wait, errno);

    return procOk();
}
