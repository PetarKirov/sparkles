/**
 * The scenario tests' fixture: what the runner must report about each test
 * is decided by the environment the scenario starts it in.
 */
module fixture;

@("fixture.writes")
unittest
{
    import core.stdc.stdio : printf;
    import std.stdio : stderr, stdout;

    stdout.writeln("one");
    stderr.writeln("two");
    printf("three\n");
    version (Posix)
    {
        import core.sys.posix.unistd : write;

        write(2, "four\n".ptr, 5);
    }
}

@("fixture.crashes")
unittest
{
    import core.stdc.stdlib : abort;
    import std.process : environment;
    import std.stdio : stdout;

    if (environment.get("FIXTURE_CRASH"))
    {
        stdout.writeln("about to abort");
        abort();
    }
}

@("fixture.after")
unittest
{
}

// A frame well framed but missing every member of its type, written to the
// frames channel as if the worker had: a protocol error (TRP9).
@("fixture.badFrame")
unittest
{
    import std.process : environment;

    version (Posix)
        if (environment.get("FIXTURE_BAD_FRAME"))
        {
            import core.sys.posix.unistd : write;

            // The frames channel is the first descriptor the worker opens
            // (TRP6): 3.
            enum frame = "\x1e{\"t\":\"result\"}\n";
            write(3, frame.ptr, frame.length);
        }
}

// A test that forks a child holding every channel open, then crashes: the
// runner must see the crash when it happens (TRP28).
@("fixture.forksAndCrashes")
unittest
{
    import std.process : environment;

    version (Posix)
        if (environment.get("FIXTURE_FORK_AND_CRASH"))
        {
            import core.stdc.stdlib : abort;
            import core.sys.posix.unistd : _exit, fork, sleep;

            if (fork() == 0)
            {
                sleep(20);
                _exit(0);
            }
            abort();
        }
}

// A worker that is asked to exit and aborts on the way out: its tests pass,
// and the run must fail all the same (TRP22).
// With `late`, it first takes longer than a runner might wait.
shared static ~this()
{
    import core.stdc.stdlib : abort;
    import core.thread : Thread;
    import core.time : seconds;
    import std.process : environment;

    if (const how = environment.get("FIXTURE_ABORT_AT_EXIT"))
    {
        if (how == "late")
            Thread.sleep(6.seconds);
        abort();
    }
}
