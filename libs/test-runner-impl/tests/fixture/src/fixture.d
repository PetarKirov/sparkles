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
