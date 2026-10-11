/**
POSIX shutdown signals become pipe completions on the pin scheduler. Caught
signal dispositions reset on exec, so children retain ordinary TERM behavior;
the application does not block and accidentally pass a blocked signal mask.
*/
module derivation_pin_signals;

version (Posix):

import core.atomic : atomicLoad, atomicStore;
import core.stdc.errno : errno;
import core.sys.posix.fcntl : fcntl, F_SETFL, F_SETFD, FD_CLOEXEC, O_NONBLOCK;
import core.sys.posix.signal : sigaction, sigaction_t, sigemptyset, SIGINT, SIGTERM;
import core.sys.posix.unistd : pipe, close, write;

import sparkles.event_horizon.errors : IoResult, IoErrorStage, OpKind, ioErr, ioOk;

private shared int signalWriter = -1;

private extern (C) void shutdownSignal(int signal) @system nothrow @nogc
{
    const saved = errno;
    const fd = atomicLoad(signalWriter);
    if (fd >= 0)
    {
        ubyte value = 1;
        cast(void) write(fd, &value, 1); // non-blocking; a full pipe already carries a request
    }
    errno = saved;
}

/// One process-level signal subscription; address-pinned until close.
struct ShutdownSignals
{
    @disable this(this);
    int reader = -1;
    private int writer = -1;
    private sigaction_t[2] previous;
    private size_t installed;

    /// Installs the subscription before workers start. Restores on every failed setup.
    static IoResult!void create(out ShutdownSignals signals) @system nothrow @nogc
    {
        int[2] descriptors;
        if (pipe(descriptors) != 0)
            return ioErr!void(errno, OpKind.none, IoErrorStage.setup, "shutdown pipe");
        signals.reader = descriptors[0];
        signals.writer = descriptors[1];
        foreach (fd; descriptors)
            if (fcntl(fd, F_SETFL, O_NONBLOCK) != 0 || fcntl(fd, F_SETFD, FD_CLOEXEC) != 0)
            {
                const error = errno;
                signals.close();
                return ioErr!void(error, OpKind.none, IoErrorStage.setup, "shutdown pipe flags");
            }
        atomicStore(signalWriter, signals.writer);
        sigaction_t action;
        sigemptyset(&action.sa_mask);
        action.sa_handler = &shutdownSignal;
        const int[2] numbers = [SIGINT, SIGTERM];
        foreach (i, number; numbers)
        {
            if (sigaction(number, &action, &signals.previous[i]) != 0)
            {
                const error = errno;
                signals.close();
                return ioErr!void(error, OpKind.none, IoErrorStage.setup, "shutdown signal handler");
            }
            ++signals.installed;
        }
        return ioOk();
    }

    /// Restores original signal dispositions; descriptors live through scope join.
    void close() @system nothrow @nogc
    {
        const int[2] numbers = [SIGINT, SIGTERM];
        foreach (i; 0 .. installed)
            cast(void) sigaction(numbers[i], &previous[i], null);
        installed = 0;
        atomicStore(signalWriter, -1);
        if (reader >= 0)
            cast(void) .close(reader);
        if (writer >= 0)
            cast(void) .close(writer);
        reader = writer = -1;
    }
}
