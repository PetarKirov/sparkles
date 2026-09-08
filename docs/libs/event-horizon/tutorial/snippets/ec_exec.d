#!/usr/bin/env dub
/+ dub.sdl:
    name "ec_exec"
    dependency "eventcore" version="0.9.39"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
    platforms "linux"
+/
import core.time : Duration;
import eventcore.core;
import std.stdio : writeln;

void main()
{
    ubyte[64] stdoutBuf;
    ubyte[64] stderrBuf;
    size_t stdoutLen = 0;
    size_t stderrLen = 0;
    int exitCode = -1;
    bool procDone = false;
    bool stdoutDone = false;
    bool stderrDone = false;

    auto p = eventDriver.processes.spawn(
        ["sh", "-c", "echo out; echo err >&2; exit 3"],
        ProcessStdinFile(ProcessRedirect.pipe),
        ProcessStdoutFile(ProcessRedirect.pipe),
        ProcessStderrFile(ProcessRedirect.pipe),
        null, ProcessConfig.none, null
    );
    assert(p.pid != ProcessID.invalid);

    // Close unused stdin pipe
    eventDriver.pipes.close(p.stdin, (PipeFD pfd, CloseStatus) nothrow @safe {
        eventDriver.pipes.releaseRef(pfd);
    });

    // Manually drain stdout pipe
    void readStdout(PipeFD pipe, IOStatus status, size_t bytesRead) nothrow @safe
    {
        if (status == IOStatus.ok && bytesRead > 0)
        {
            stdoutLen += bytesRead;
            eventDriver.pipes.read(pipe, stdoutBuf[stdoutLen .. $], IOMode.once, &readStdout);
        }
        else
        {
            stdoutDone = true;
            eventDriver.pipes.close(pipe, (PipeFD pfd, CloseStatus) nothrow @safe {
                eventDriver.pipes.releaseRef(pfd);
            });
        }
    }
    eventDriver.pipes.read(p.stdout, stdoutBuf[0 .. $], IOMode.once, &readStdout);

    // Manually drain stderr pipe
    void readStderr(PipeFD pipe, IOStatus status, size_t bytesRead) nothrow @safe
    {
        if (status == IOStatus.ok && bytesRead > 0)
        {
            stderrLen += bytesRead;
            eventDriver.pipes.read(pipe, stderrBuf[stderrLen .. $], IOMode.once, &readStderr);
        }
        else
        {
            stderrDone = true;
            eventDriver.pipes.close(pipe, (PipeFD pfd, CloseStatus) nothrow @safe {
                eventDriver.pipes.releaseRef(pfd);
            });
        }
    }
    eventDriver.pipes.read(p.stderr, stderrBuf[0 .. $], IOMode.once, &readStderr);

    // Wait for process termination
    eventDriver.processes.wait(p.pid, (ProcessID pid, int status) nothrow @safe {
        exitCode = status;
        procDone = true;
        eventDriver.processes.releaseRef(pid);
    });

    while ((!procDone || !stdoutDone || !stderrDone) && eventDriver.core.waiterCount > 0)
        eventDriver.core.processEvents(Duration.max);

    assert(procDone && stdoutDone && stderrDone);
    assert(exitCode == 3);
    assert(cast(const(char)[]) stdoutBuf[0 .. stdoutLen] == "out\n");
    assert(cast(const(char)[]) stderrBuf[0 .. stderrLen] == "err\n");

    writeln("stdout: ", cast(const(char)[]) stdoutBuf[0 .. stdoutLen]);
    writeln("stderr: ", cast(const(char)[]) stderrBuf[0 .. stderrLen]);
    writeln("exit code: ", exitCode);
}
