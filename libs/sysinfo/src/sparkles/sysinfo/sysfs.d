module sparkles.sysinfo.sysfs;

import expected : Expected, ok, err;

alias EStr = Expected!(string, string);
alias EUlong = Expected!(ulong, string);
alias EBytes = Expected!(ubyte[], string);

/// Read a sysfs/procfs file, stripping trailing whitespace.
EStr readSysfsFile(string path) @safe
{
    return (() @trusted {
        try
        {
            import std.file : readText;
            import std.string : strip;

            return ok(readText(path).strip);
        }
        catch (Exception e)
        {
            return err!string(e.msg.idup);
        }
    })();
}

/// Read a sysfs file and parse as `ulong`.
EUlong readSysfsFileAsUlong(string path) @safe
{
    auto text = readSysfsFile(path);
    if (text.hasError)
        return err!ulong(text.error);

    try
    {
        import std.conv : to;

        return ok(text.value.to!ulong);
    }
    catch (Exception e)
    {
        return err!ulong(e.msg.idup);
    }
}

/// Read a sysfs file as raw bytes.
EBytes readSysfsBinary(string path) @safe
{
    return (() @trusted {
        try
        {
            import std.file : read;

            return ok(cast(ubyte[]) read(path));
        }
        catch (Exception e)
        {
            return err!(ubyte[])(e.msg.idup);
        }
    })();
}

/// Return the first path from `candidates` that exists.
EStr findFile(string[] candidates) @safe
{
    return (() @trusted {
        import std.file : exists;

        foreach (c; candidates)
        {
            if (exists(c))
                return ok(c);
        }
        return err!string("none of the candidate paths exist");
    })();
}

// ─── Unit Tests ──────────────────────────────────────────────────────────────

@("sysfs.readSysfsFile.existing")
@safe unittest
{
    auto result = readSysfsFile("/proc/sys/kernel/ostype");
    if (result.hasValue)
        assert(result.value.length > 0);
}

@("sysfs.readSysfsFile.missing")
@safe unittest
{
    auto result = readSysfsFile("/nonexistent/path/that/does/not/exist");
    assert(result.hasError);
}

@("sysfs.readSysfsFileAsUlong.valid")
@safe unittest
{
    auto result = readSysfsFileAsUlong("/proc/sys/kernel/pid_max");
    if (result.hasValue)
        assert(result.value > 0);
}

@("sysfs.findFile.firstMatch")
@safe unittest
{
    auto result = findFile(["/nonexistent", "/proc/version", "/also/nonexistent"]);
    if (result.hasValue)
        assert(result.value == "/proc/version");
}

@("sysfs.findFile.noMatch")
@safe unittest
{
    auto result = findFile(["/nonexistent1", "/nonexistent2"]);
    assert(result.hasError);
}
