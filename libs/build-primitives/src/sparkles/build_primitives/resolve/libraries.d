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

    /// The `.pc` file `name` resolves to, or null.
    string pcFile(string name) @safe;

    /// The directories `pkg-config` searches for `.pc` files, in order.
    string[] searchPath() @safe;

    /// The packages `name`'s `.pc` file requires, publicly and privately, by name.
    string[] requires(string name) @safe;
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
    /// BGK9: the search that answered for those packages, as key lines (see
    /// $(LREF pkgConfigSearch)): inputs of every action that uses the flags.
    string[] pcSearch;
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
    if (packages.length)
        result.pcSearch = pkgConfigSearch(packages, driver);

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

/**
BGK9: the inputs of `pkg-config`'s answer for `packages`, as key lines. The
directories it searched, in order (`pc-dirs <dir>:<dir>…`); each `.pc` file
the packages and the packages they require resolved to (`pc <file>`); and
each candidate it looked for first and did not find (`pc-absent <path>`):
`<name>-uninstalled.pc` in every directory, which `pkg-config` prefers
wherever it lies, then `<name>.pc` in each directory before the one used. A
directory beneath `/nix/store` never gains a file, so its candidates are left
out. An action keys on each file's digest and on each candidate's absence.
*/
string[] pkgConfigSearch(const string[] packages, PkgConfigDriver driver) @safe
{
    import std.algorithm.searching : startsWith;
    import std.array : join;

    const dirs = driver.searchPath();
    string[] lines = ["pc-dirs " ~ dirs.join(":")];
    bool[string] seen;
    string[] queue = packages.dup;
    while (queue.length)
    {
        const name = queue[0];
        queue = queue[1 .. $];
        if (name in seen)
            continue;
        seen[name] = true;
        size_t until = dirs.length;
        if (const file = driver.pcFile(name))
        {
            lines ~= "pc " ~ file;
            size_t slash = file.length;
            while (slash > 0 && file[slash - 1] != '/')
                --slash;
            foreach (i, d; dirs)
                if (slash > 1 && d == file[0 .. slash - 1])
                {
                    until = i;
                    break;
                }
        }
        foreach (i, d; dirs)
        {
            if (d.startsWith("/nix/store/"))
                continue;
            lines ~= "pc-absent " ~ d ~ "/" ~ name ~ "-uninstalled.pc";
            if (i < until)
                lines ~= "pc-absent " ~ d ~ "/" ~ name ~ ".pc";
        }
        queue ~= driver.requires(name);
    }
    return lines;
}

///
@("build_primitives.resolve.libraries.pkgConfigSearch")
@safe unittest
{
    auto driver = new MemoryPkgConfig(["a": "-la", "b": "-lb"], null);
    driver.dirs = ["/etc/pc", "/pc", "/opt/pc"];
    driver.requiresOf = ["a": ["b"]];
    assert(pkgConfigSearch(["a"], driver) == [
        "pc-dirs /etc/pc:/pc:/opt/pc",
        // `a` lies in /pc: /etc/pc is searched before it, and any directory
        // could hold the uninstalled variant `pkg-config` prefers.
        "pc /pc/a.pc",
        "pc-absent /etc/pc/a-uninstalled.pc", "pc-absent /etc/pc/a.pc",
        "pc-absent /pc/a-uninstalled.pc", "pc-absent /opt/pc/a-uninstalled.pc",
        // `b`, which `a` requires, the same way.
        "pc /pc/b.pc",
        "pc-absent /etc/pc/b-uninstalled.pc", "pc-absent /etc/pc/b.pc",
        "pc-absent /pc/b-uninstalled.pc", "pc-absent /opt/pc/b-uninstalled.pc",
    ]);
    driver.dirs = ["/nix/store/x-pc/lib/pkgconfig", "/pc"];
    assert(pkgConfigSearch(["b"], driver) == ["pc-dirs /nix/store/x-pc/lib/pkgconfig:/pc", "pc /pc/b.pc",
        "pc-absent /pc/b-uninstalled.pc"]);
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

    // The directory `pkg-config` found the package in (`pcfiledir`, which
    // pkg-config 0.29 and pkgconf both define), and the file there that
    // it read: the uninstalled variant, which it prefers, or the package's.
    string pcFile(string name) @safe
    {
        import std.file : exists;
        import std.string : strip;

        const r = run(["--variable=pcfiledir", name]);
        if (r.status != 0)
            return null;
        const dir = r.output.strip;
        foreach (candidate; [dir ~ "/" ~ name ~ "-uninstalled.pc", dir ~ "/" ~ name ~ ".pc"])
            if (exists(candidate))
                return candidate;
        return null;
    }

    // pkg-config 0.29 names each directory it adds to its search path, in
    // order, under `PKG_CONFIG_DEBUG_SPEW`, wherever a wrapper took it from
    // (Nix's takes a target-specific variable). Otherwise the path is
    // `PKG_CONFIG_PATH`'s, then `PKG_CONFIG_LIBDIR`'s or the default's.
    string[] searchPath() @safe
    {
        import std.algorithm.iteration : filter, splitter;
        import std.algorithm.searching : startsWith;
        import std.array : array;
        import std.process : environment;
        import std.string : indexOf, lineSplitter, strip;

        string[] dirs;
        enum prefix = "Adding directory '";
        foreach (line; run(["--exists", "sparkles-search-path-probe"], ["PKG_CONFIG_DEBUG_SPEW": "1"]).output
                .lineSplitter)
            if (line.startsWith(prefix))
            {
                const rest = line[prefix.length .. $];
                const close = rest.indexOf('\'');
                if (close > 0)
                    dirs ~= rest[0 .. close].idup;
            }
        if (dirs.length)
            return dirs;
        dirs = environment.get("PKG_CONFIG_PATH", "").splitter(':').filter!(d => d.length).array;
        const libdir = environment.get("PKG_CONFIG_LIBDIR");
        const defaults = libdir !is null ? libdir : run(["--variable", "pc_path", "pkg-config"]).output.strip;
        return dirs ~ defaults.splitter(':').filter!(d => d.length).array;
    }

    string[] requires(string name) @safe
    {
        import std.array : split;
        import std.string : lineSplitter;

        string[] names;
        foreach (what; ["--print-requires", "--print-requires-private"])
        {
            const r = run([what, name]);
            if (r.status == 0)
                foreach (line; r.output.lineSplitter)
                    if (auto words = line.split)
                        names ~= words[0].idup;
        }
        return names;
    }

    private bool query(string what, const string[] names, out string output) @safe
    {
        const r = run([what] ~ names);
        output = r.output;
        return r.status == 0;
    }

    private auto run(const string[] arguments, const string[string] env = null) @safe
    {
        import std.process : execute;
        import std.typecons : Tuple;

        try
            return execute([executable] ~ arguments, env);
        catch (Exception e)
            return Tuple!(int, "status", string, "output")(-1, e.msg);
    }
}

/**
A driver that answers each query of `inner` once and records it, with its
status and output, in a tree's read set (BGP1), with the environment
variables `pkg-config` reads. Planning queries through it, so its plan
records what the libraries resolved from.
*/
final class RecordingPkgConfig : PkgConfigDriver
{
    import sparkles.build_primitives.resolve.tree : ResolveTree;

    private PkgConfigDriver inner;
    private ResolveTree tree;
    private string[string] environment;
    private Answer[string] answers;

    private static struct Answer
    {
        bool ok;
        string output;
    }

    /// The variables `pkg-config` reads, besides its executable's.
    static immutable string[] variables = ["PKG_CONFIG", "PKG_CONFIG_PATH", "PKG_CONFIG_LIBDIR",
        "PKG_CONFIG_SYSROOT_DIR", "PKG_CONFIG_ALLOW_SYSTEM_CFLAGS", "PKG_CONFIG_ALLOW_SYSTEM_LIBS"];

    /// Queries `inner`, recording in `tree`; `environment` holds the
    /// values of `variables` that are set.
    this(PkgConfigDriver inner, ResolveTree tree, string[string] environment) @safe
    {
        this.inner = inner;
        this.tree = tree;
        this.environment = environment;
    }

    bool exists(string name) @safe
    {
        string output;
        return ask(["--exists", name], (out string o) => inner.exists(name), output);
    }

    bool libs(const string[] names, out string output) @safe
        => ask(["--libs"] ~ names, (out string o) => inner.libs(names, o), output);

    bool cflags(const string[] names, out string output) @safe
        => ask(["--cflags"] ~ names, (out string o) => inner.cflags(names, o), output);

    string pcFile(string name) @safe
    {
        string output;
        return ask(["--path", name], (out string o) { o = inner.pcFile(name); return o !is null; }, output)
            ? output : null;
    }

    // Recorded as queries of their own, beside the ones `pkg-config` answers.
    string[] searchPath() @safe
    {
        import std.array : join, split;

        string output;
        cast(void) ask(["--search-path"], (out string o) { o = inner.searchPath().join("\n"); return true; }, output);
        return output.length ? output.split("\n") : null;
    }

    string[] requires(string name) @safe
    {
        import std.array : join, split;

        string output;
        cast(void) ask(["--requires", name], (out string o) { o = inner.requires(name).join("\n"); return true; },
            output);
        return output.length ? output.split("\n") : null;
    }

    private bool ask(const string[] arguments, scope bool delegate(out string) @safe query,
        out string output) @safe
    {
        string key;
        foreach (a; arguments)
            key ~= a ~ "\0";
        auto answer = key in answers;
        if (answer is null)
        {
            if (answers.length == 0)
                foreach (v; variables)
                {
                    auto value = v in environment;
                    tree.noteEnvironment(v, value ? *value : null, value !is null);
                }
            Answer a;
            a.ok = query(a.output);
            answers[key] = a;
            answer = key in answers;
        }
        tree.noteQuery(arguments, answer.ok ? 0 : 1, answer.output);
        output = answer.output;
        return answer.ok;
    }
}

/// The recording driver answers each query once and records each in the
/// tree's read set, with the variables `pkg-config` reads.
@("build_primitives.resolve.libraries.RecordingPkgConfig")
@safe
unittest
{
    import std.algorithm.searching : canFind;
    import sparkles.build_primitives.resolve.tree : memoryTree;
    import sparkles.build_primitives.workspace.discovery : ReadKind;

    auto tree = memoryTree(null);
    auto driver = new RecordingPkgConfig(new MemoryPkgConfig(["z": "-lz"], ["z": "-I/z"]), tree,
        ["PKG_CONFIG_PATH": "/pc"]);
    string output;
    assert(driver.libs(["z"], output) && output == "-lz");
    assert(!driver.exists("absent"));
    const reads = tree.reads.entries;
    assert(reads.canFind!(e => e.kind == ReadKind.query && e.names == "--libs z" && e.found));
    assert(reads.canFind!(e => e.kind == ReadKind.query && e.names == "--exists absent" && !e.found));
    assert(reads.canFind!(e => e.kind == ReadKind.environment && e.path == "PKG_CONFIG_PATH" && e.found));
    assert(reads.canFind!(e => e.kind == ReadKind.environment && e.path == "PKG_CONFIG_LIBDIR" && !e.found));
}

/// A driver over fixed answers: `.pc` names to their `--libs` and `--cflags`.
final class MemoryPkgConfig : PkgConfigDriver
{
    string[string] libsOf;   /// name → `--libs` output
    string[string] cflagsOf; /// name → `--cflags` output
    string[] dirs = ["/pc"];       /// the search path
    string[][string] requiresOf; /// name → the packages it requires

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

    string[] searchPath() @safe => dirs.dup;

    string[] requires(string name) @safe => requiresOf.get(name, null).dup;

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
