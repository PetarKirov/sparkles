#!/usr/bin/env dub
/+ dub.sdl:
    name "ec_spawn"
    dependency "eventcore" version="0.9.39"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
    platforms "linux"
+/
import core.sys.posix.signal : SIGTERM;
import core.time : Duration, msecs;
import eventcore.core;
import std.stdio : writeln;

void main()
{
    ubyte[128] readBuf;
    char[128] lineBuf;
    size_t lineLen = 0;
    int linesSeen = 0;
    bool timedOut = false;
    bool procExited = false;
    bool stdoutClosed = false;
    int termSig = 0;

    auto p = eventDriver.processes.spawn(
        ["sh", "-c", "echo one; echo two; exec sleep 30"],
        ProcessStdinFile(ProcessRedirect.pipe),
        ProcessStdoutFile(ProcessRedirect.pipe),
        ProcessStderrFile(ProcessRedirect.pipe),
        null, ProcessConfig.none, null
    );
    assert(p.pid != ProcessID.invalid);

    eventDriver.pipes.close(p.stdin, (PipeFD pfd, CloseStatus) nothrow @safe {
        eventDriver.pipes.releaseRef(pfd);
    });
    eventDriver.pipes.close(p.stderr, (PipeFD pfd, CloseStatus) nothrow @safe {
        eventDriver.pipes.releaseRef(pfd);
    });

    // Schedule 100ms timeout timer
    auto timer = eventDriver.timers.create();
    // Arm only after the second complete line proves the child is ready.
    eventDriver.timers.wait(timer, (TimerID tm) nothrow @safe {
        timedOut = true;
        eventDriver.processes.kill(p.pid, SIGTERM);
        eventDriver.timers.releaseRef(tm);
    });

    // Manual line framing callback
    void readStdout(PipeFD pipe, IOStatus status, size_t bytesRead) nothrow @safe
    {
        if (status == IOStatus.ok && bytesRead > 0)
        {
            foreach (b; readBuf[0 .. bytesRead])
            {
                if (b == '\n')
                {
                    try writeln("line: ", lineBuf[0 .. lineLen]);
                    catch (Exception error) { assert(false, error.msg); }
                    linesSeen++;
                    if (linesSeen == 2) eventDriver.timers.set(timer, 100.msecs, 0.msecs);
                    lineLen = 0;
                }
                else if (lineLen < lineBuf.length)
                {
                    lineBuf[lineLen++] = cast(char) b;
                }
            }
            eventDriver.pipes.read(pipe, readBuf[], IOMode.once, &readStdout);
        }
        else
        {
            stdoutClosed = true;
            eventDriver.pipes.close(pipe, (PipeFD pfd, CloseStatus) nothrow @safe {
                eventDriver.pipes.releaseRef(pfd);
            });
        }
    }
    eventDriver.pipes.read(p.stdout, readBuf[], IOMode.once, &readStdout);

    eventDriver.processes.wait(p.pid, (ProcessID pid, int status) nothrow @safe {
        procExited = true;
        if (status < 0) termSig = -status;
        else termSig = status;
        eventDriver.processes.releaseRef(pid);
    });

    while ((!procExited || !stdoutClosed) && eventDriver.core.waiterCount > 0)
        eventDriver.core.processEvents(Duration.max);

    assert(linesSeen == 2);
    assert(procExited && stdoutClosed && lineLen == 0);
    assert(timedOut);
    assert(termSig == SIGTERM);

    writeln("exited: timedOut, signaled by ", termSig);
    writeln("end: timedOut, reap: reaped");
}
