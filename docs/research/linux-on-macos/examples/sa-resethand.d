#!/usr/bin/env dub
/+ dub.sdl:
    name "sa_resethand_probe"
+/
/**
Does this kernel honour `SA_RESETHAND`?

A child installs a `SIGSEGV` handler with `SA_RESETHAND`, faults, and the
handler writes one byte to a pipe and returns. Returning re-executes the
faulting instruction. With `SA_RESETHAND` honoured the disposition is now
`SIG_DFL`, so the second delivery kills the child: the parent counts
exactly one byte and a `SIGSEGV` death. Where the reset is ignored the
handler runs again, and again — the parent caps the count and kills the
child itself.

This is how druntime's `runModuleUnitTests` installs its own segfault
handler (`SA_SIGINFO | SA_RESETHAND`, prints a backtrace, returns), which
every forked test child inherits. `sparkles:event-horizon`'s
`forkserver.crashIsOneLostRequestNotTheHost` therefore loops for ever on a
kernel that ignores the flag — observed under Apple `container --rosetta`
(`linux/amd64` on Apple silicon), not on native aarch64-linux, not on CI.

See: docs/research/linux-on-macos/sparkles-baseline.md
*/
module sa_resethand_probe;

import core.sys.posix.signal : kill, SA_RESETHAND, SA_SIGINFO, sigaction, sigaction_t,
    sigemptyset, siginfo_t, SIGKILL, SIGSEGV;
import core.sys.posix.sys.wait : waitpid, WIFSIGNALED, WTERMSIG;
import core.sys.posix.unistd : _exit, close, fork, pipe, read, write;
import core.volatile : volatileStore;
import std.stdio : writeln;

__gshared int reportFd;

extern (C) void onSegv(int, siginfo_t*, void*) nothrow @nogc
{
    ubyte one = 1;
    write(reportFd, &one, 1);
}

int main()
{
    int[2] fds;
    if (pipe(fds) != 0)
        return 1;

    const pid = fork();
    if (pid < 0)
        return 1;
    if (pid == 0)
    {
        close(fds[0]);
        reportFd = fds[1];
        sigaction_t sa;
        sa.sa_sigaction = &onSegv;
        sa.sa_flags = SA_SIGINFO | SA_RESETHAND;
        sigemptyset(&sa.sa_mask);
        sigaction(SIGSEGV, &sa, null);
        volatileStore(cast(uint*) 8, 1u); // the fault
        _exit(0);
    }
    close(fds[1]);

    enum cap = 100;
    int deliveries;
    ubyte b;
    while (deliveries < cap && read(fds[0], &b, 1) == 1)
        ++deliveries;
    const capped = deliveries >= cap;
    if (capped)
        kill(pid, SIGKILL);

    int status;
    waitpid(pid, &status, 0);
    const signalled = WIFSIGNALED(status) ? WTERMSIG(status) : 0;

    if (!capped && deliveries == 1 && signalled == SIGSEGV)
        writeln("SA_RESETHAND honoured: 1 delivery, child died of SIGSEGV");
    else
        writeln("SA_RESETHAND IGNORED: ", deliveries, capped ? "+" : "",
            " deliveries, child ", capped ? "killed by the parent" : "exited otherwise",
            " (signal ", signalled, ")");
    return 0;
}
