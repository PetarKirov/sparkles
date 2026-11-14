/**
Library resolution (build-graph SPEC BGR5): a target's `libs`, through
`pkg-config`, to compiler and linker flags, with dub's rules.

A name `pkg-config` knows is resolved as itself, else as `lib<name>`; the
rest stay plain libraries, linked as `-l<name>`. The `--libs` output becomes
linker flags (`-L-L…` and `-L-l…` unwrapped, `-Wl,` split, `-pthread` as
`-lpthread`, `-defaultlib` as a compiler flag), and the preprocessor flags of
`--cflags` become `-P`-prefixed compiler flags.

dub resolves only executable and dynamic-library targets and drops a library
target's `libs`. A library target here also receives the `--cflags` of its
own `libs` for its compiles: the recorded divergence D17.

Every `pkg-config` query goes through a $(LREF PkgConfigDriver), so planning
does no other I/O.

Copied from dub (`dub.compilers.utils.resolveLibs` and
`applyPkgConfigCFlags`); see the build-graph decisions on behaviour copied
from dub's source.
*/
module sparkles.build_primitives.resolve.libraries;

import std.algorithm.searching : startsWith;
import std.array : split;

import sparkles.build_primitives.resolve.platform : BuildPlatform;
import sparkles.build_primitives.resolve.settings : BuildSettings, TargetType;

/// The `pkg-config` queries library resolution makes.
interface PkgConfigDriver
{
    /// Whether `pkg-config --exists <name>` succeeds.
    bool exists(string name) @safe;

    /// `pkg-config --libs <names…>`; false when it fails.
    bool libs(const string[] names, out string output) @safe;

    /// `pkg-config --cflags <names…>`; false when it fails.
    bool cflags(const string[] names, out string output) @safe;

    /// The `.pc` file `name` resolves to (`pkg-config --path`), or null.
    string pcFile(string name) @safe;
}

/// What a target's libraries resolve to.
struct LibraryResolution
{
    /// The libraries left for plain `-l` linking.
    string[] libs;
    /// Linker flags from `--libs`.
    string[] lflags;
    /// Compiler flags: `-P` preprocessor flags from `--cflags`, and any
    /// `-defaultlib` from `--libs`.
    string[] dflags;
    /// The `pkg-config` packages queried, as resolved (`foo` or `libfoo`).
    string[] packages;
    /// The `.pc` files those packages resolved to: inputs of every action
    /// that uses the flags.
    string[] pcFiles;
    /// Whether `pkg-config` failed, so that dub would fall back to plain `-l`.
    bool unavailable;
}

/**
Resolves `settings.libs` for a target of `settings.targetType`, as dub's
`resolveLibs` does on POSIX, and applies the result to `settings`. A library
target keeps its `libs` dropped, as dub does, but receives its `--cflags`.
*/
LibraryResolution resolveLibraries(ref BuildSettings settings, const BuildPlatform platform,
    PkgConfigDriver driver) @safe
{
    import std.algorithm.iteration : map;
    import std.algorithm.sorting : partition;
    import std.array : array;

    LibraryResolution result;
    if (settings.libs.length == 0)
        return result;

    const isLibrary = settings.targetType == TargetType.library
        || settings.targetType == TargetType.staticLibrary;
    string[] libs = settings.libs.dup;
    if (isLibrary)
    {
        settings.libs = null;
        if (platform.isWindows)
            return result;
    }
    if (platform.isWindows)
    {
        result.libs = libs;
        return result;
    }

    // dub's own partitions (unstable, as dub's), so the order agrees.
    auto viaPkgConfig = libs.partition!(l => !driver.exists(l));
    string[] packages = viaPkgConfig.dup;
    auto remaining = libs[0 .. $ - viaPkgConfig.length];
    auto prefixed = remaining.partition!(l => !driver.exists("lib" ~ l));
    packages ~= prefixed.map!(l => "lib" ~ l).array;
    const plain = remaining[0 .. $ - prefixed.length];
    result.packages = packages;
    foreach (p; packages)
        if (auto file = driver.pcFile(p))
            result.pcFiles ~= file;

    if (!isLibrary)
        result.libs = plain.dup;

    if (packages.length == 0)
    {
        if (!isLibrary)
            settings.libs = result.libs;
        return result;
    }

    string output;
    if (!isLibrary)
    {
        if (!driver.libs(packages, output))
        {
            // dub warns, having already taken the `pkg-config` names out.
            result.unavailable = true;
            settings.libs = result.libs;
            return result;
        }
        foreach (flag; output.split)
        {
            if (flag.startsWith("-L-L"))
                result.lflags ~= flag[2 .. $];
            else if (flag.startsWith("-defaultlib"))
                result.dflags ~= flag;
            else if (flag.startsWith("-L-defaultlib"))
                result.dflags ~= flag[2 .. $];
            else if (flag.startsWith("-pthread"))
                result.lflags ~= "-lpthread";
            else if (flag.startsWith("-L-l"))
                result.lflags ~= flag[2 .. $].split(",");
            else if (flag.startsWith("-Wl,"))
                result.lflags ~= flag[4 .. $].split(",");
            else
                result.lflags ~= flag;
        }
    }
    if (driver.cflags(packages, output))
        result.dflags ~= preprocessorFlags(output);

    if (!isLibrary)
        settings.libs = result.libs;
    settings.addLFlags(result.lflags);
    settings.addDFlags(result.dflags);
    return result;
}

// The preprocessor options dub keeps from `--cflags`. Each takes an operand,
// joined (`-I/x`) or as the next word (`-I /x`).
private immutable preprocessorOptions = ["-I", "-D", "-U", "-include", "-isystem", "-idirafter"];

/*
The preprocessor flags of a `--cflags` output, `-P`-prefixed, as dub's
`applyPkgConfigCFlags`, except that an option written apart from its operand
(`-isystem /x`) keeps it: the two are joined into one flag (`-P-isystem/x`),
which GCC and Clang read as the separated form. dub keeps the option alone
and drops the operand (decision D45).
*/
private string[] preprocessorFlags(string output) @safe pure
{
    import std.algorithm.searching : any, canFind;

    string[] result;
    auto words = output.split;
    for (size_t i = 0; i < words.length; ++i)
    {
        const flag = words[i];
        if (!preprocessorOptions.any!(o => flag.startsWith(o)))
            continue;
        // A bare option takes the next word as its operand.
        if (preprocessorOptions.canFind(flag) && i + 1 < words.length)
            result ~= "-P" ~ flag ~ words[++i];
        else
            result ~= "-P" ~ flag;
    }
    return result;
}

/// A driver that runs `pkg-config` (`$PKG_CONFIG`, else `pkg-config`).
final class SystemPkgConfig : PkgConfigDriver
{
    private string executable;

    ///
    this(string executable = null) @safe
    {
        import std.process : environment;

        this.executable = executable.length ? executable : environment.get("PKG_CONFIG", "pkg-config");
    }

    bool exists(string name) @safe => run(["--exists", name]).status == 0;

    bool libs(const string[] names, out string output) @safe => query("--libs", names, output);

    bool cflags(const string[] names, out string output) @safe => query("--cflags", names, output);

    string pcFile(string name) @safe
    {
        import std.string : strip;

        const r = run(["--path", name]);
        return r.status == 0 ? r.output.strip : null;
    }

    private bool query(string what, const string[] names, out string output) @safe
    {
        const r = run([what] ~ names);
        output = r.output;
        return r.status == 0;
    }

    private auto run(const string[] arguments) @safe
    {
        import std.process : execute;
        import std.typecons : Tuple;

        try
            return execute([executable] ~ arguments);
        catch (Exception e)
            return Tuple!(int, "status", string, "output")(-1, e.msg);
    }
}

/// A driver over fixed answers: `.pc` names to their `--libs` and `--cflags`.
final class MemoryPkgConfig : PkgConfigDriver
{
    string[string] libsOf;   /// name → `--libs` output
    string[string] cflagsOf; /// name → `--cflags` output

    ///
    this(string[string] libsOf, string[string] cflagsOf) @safe pure nothrow
    {
        this.libsOf = libsOf;
        this.cflagsOf = cflagsOf;
    }

    bool exists(string name) @safe => (name in libsOf) !is null;

    bool libs(const string[] names, out string output) @safe => join(libsOf, names, output);

    bool cflags(const string[] names, out string output) @safe => join(cflagsOf, names, output);

    string pcFile(string name) @safe => name in libsOf ? "/pc/" ~ name ~ ".pc" : null;

    private static bool join(const string[string] of, const string[] names, out string output) @safe
    {
        foreach (n; names)
        {
            auto found = n in of;
            if (found is null)
                return false;
            output ~= (output.length ? " " : "") ~ *found;
        }
        return true;
    }
}

@("build_primitives.resolve.libraries.resolveLibraries.executable")
@safe unittest
{
    auto pc = new MemoryPkgConfig(["raylib": "-L/r/lib -lraylib -pthread", "libfoo": "-Wl,-rpath,/f -lfoo"],
        ["raylib": "-I/r/include -DRAY -O2", "libfoo": "-isystem /f/i"]);
    BuildSettings s;
    s.targetType = TargetType.executable;
    s.libs = ["raylib", "m", "foo"];
    const platform = BuildPlatform(["linux", "posix"], ["x86_64"], "ldc");
    const r = resolveLibraries(s, platform, pc);
    assert(r.libs == ["m"] && s.libs == ["m"]);
    assert(r.packages.length == 2 && r.pcFiles.length == 2);
    assert(r.lflags == ["-L/r/lib", "-lraylib", "-lpthread", "-rpath", "/f", "-lfoo"]
        || r.lflags == ["-rpath", "/f", "-lfoo", "-L/r/lib", "-lraylib", "-lpthread"]);
    assert(r.dflags == ["-P-I/r/include", "-P-DRAY", "-P-isystem/f/i"]
        || r.dflags == ["-P-isystem/f/i", "-P-I/r/include", "-P-DRAY"]);
}

@("build_primitives.resolve.libraries.resolveLibraries.libraryTargetsGetTheirCFlags")
@safe unittest
{
    auto pc = new MemoryPkgConfig(["raylib": "-lraylib"], ["raylib": "-I/r/include"]);
    BuildSettings s;
    s.targetType = TargetType.staticLibrary;
    s.libs = ["raylib"];
    const r = resolveLibraries(s, BuildPlatform(["linux", "posix"], ["x86_64"], "ldc"), pc);
    // dub drops the libraries; D17 keeps the headers.
    assert(s.libs.length == 0 && s.lflags.length == 0);
    assert(r.dflags == ["-P-I/r/include"] && s.dflags == ["-P-I/r/include"]);
}

@("build_primitives.resolve.libraries.resolveLibraries.separatedOperands")
@safe unittest
{
    import std.conv : to;

    // An option written apart from its operand keeps it.
    auto pc = new MemoryPkgConfig(["sdk": "-lsdk"],
        ["sdk": "-isystem /sdk/include -include config.h -I /sdk/a -D FOO=1 -U BAR "
            ~ "-idirafter /sdk/late -I/sdk/b -O2 -iquote /sdk/q"]);
    BuildSettings s;
    s.targetType = TargetType.executable;
    s.libs = ["sdk"];
    const r = resolveLibraries(s, BuildPlatform(["linux", "posix"], ["x86_64"], "ldc"), pc);
    // `-iquote` is not a flag dub keeps; neither is its operand.
    const expected = ["-P-isystem/sdk/include", "-P-includeconfig.h", "-P-I/sdk/a", "-P-DFOO=1",
        "-P-UBAR", "-P-idirafter/sdk/late", "-P-I/sdk/b"];
    assert(r.dflags == expected && s.dflags == expected, r.dflags.to!string);
}
