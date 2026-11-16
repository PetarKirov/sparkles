/**
The platform a resolution targets, and dub's platform specifiers
(`linux-x86_64-ldc`) matched against it (build-graph SPEC BGR2).

The platform is an input of resolution, never probed here: the planner
supplies it from the toolchain's identity.

Copied from dub (`dub.platform.matchesSpecification`); see the build-graph
decisions on behaviour copied from dub's source.
*/
module sparkles.build_primitives.resolve.platform;

/// The platform a package is resolved for, as dub describes one.
struct BuildPlatform
{
    /// Platform identifiers, such as `["linux", "posix"]`.
    string[] platform;
    /// Architecture identifiers, such as `["x86_64"]`.
    string[] architecture;
    /// The canonical compiler name: `dmd`, `ldc` or `gdc`.
    string compiler;
    /// The compiler binary, such as `ldc2`.
    string compilerBinary;
    /// The frontend version, `2111` for 2.111.
    int frontendVersion;
    /// The compiler's own version, such as `1.41.0`.
    string compilerVersion;

    /// A copy that shares no array with this one.
    BuildPlatform dup() const @safe pure nothrow
        => BuildPlatform(platform.dup, architecture.dup, compiler, compilerBinary, frontendVersion,
            compilerVersion);

    /// Whether the platform is Windows.
    bool isWindows() const scope @safe pure nothrow @nogc
    {
        foreach (p; platform)
            if (p == "windows")
                return true;
        return false;
    }
}

/**
Whether `platform` matches a dub platform specifier: empty, or
`[os][-arch][-compiler]`, each component optional, matched in that order,
with a leading `-` allowed. There is no list form: dub reads `linux,freebsd`
as one platform name, which matches no platform.
*/
bool matchesSpecification(const BuildPlatform platform, const(char)[] specification)
    @safe pure nothrow @nogc
{
    if (specification.length == 0)
        return true;
    if (specification[0] == '-')
        specification = specification[1 .. $];

    // The specifier's `-`-separated parts, consumed from the front.
    const(char)[] rest = specification;
    bool done;
    const(char)[] next()
    {
        foreach (i, c; rest)
            if (c == '-')
            {
                auto part = rest[0 .. i];
                rest = rest[i + 1 .. $];
                return part;
            }
        done = true;
        return rest;
    }

    static bool among(const string[] names, const(char)[] part)
    {
        foreach (name; names)
            if (name == part)
                return true;
        return false;
    }

    auto part = next();
    if (among(platform.platform, part))
    {
        if (done)
            return true;
        part = next();
    }
    if (among(platform.architecture, part))
    {
        if (done)
            return true;
        part = next();
    }
    // dub rejects a specifier with anything after the compiler.
    return platform.compiler == part && done;
}

///
@("build_primitives.resolve.platform.matchesSpecification.dubCases")
@safe pure nothrow unittest
{
    const platform = BuildPlatform(["posix", "linux"], ["x86_64"], "dmd");
    assert(platform.matchesSpecification(""));
    assert(platform.matchesSpecification("posix"));
    assert(platform.matchesSpecification("linux"));
    assert(platform.matchesSpecification("linux-dmd"));
    assert(platform.matchesSpecification("linux-x86_64-dmd"));
    assert(platform.matchesSpecification("x86_64"));
    assert(platform.matchesSpecification("-x86_64"));
    assert(!platform.matchesSpecification("windows"));
    assert(!platform.matchesSpecification("ldc"));
    assert(!platform.matchesSpecification("windows-dmd"));
    assert(!platform.matchesSpecification("linux,freebsd"));
    assert(!platform.matchesSpecification("linux-dmd-extra"));
}

/**
Reads a compiler's identity from what `binary --version` printed into
`platform`'s compiler fields: `compiler`, `compilerBinary`,
`frontendVersion` and `compilerVersion`. LDC names its frontend on the
line after its own version (`based on DMD v2.113.0`); DMD's own version is
the frontend's. `false`, leaving `platform` as it was, for any other
compiler, GDC among them, and for output in neither shape.
*/
bool readCompilerIdentity(string binary, scope const(char)[] output, ref BuildPlatform platform)
    @safe pure nothrow
{
    import std.algorithm.searching : findSplitAfter;

    // The `M.mmm.p` at the front of `s`, and the frontend number dub
    // derives from it (`2.113.0` → 2113).
    static bool versionAt(scope const(char)[] s, out string text, out int frontend)
    {
        size_t i;
        int major, minor, dots;
        while (i < s.length && (s[i] == '.' || (s[i] >= '0' && s[i] <= '9')))
        {
            if (s[i] == '.')
                ++dots;
            else if (dots == 0)
                major = major * 10 + (s[i] - '0');
            else if (dots == 1)
                minor = minor * 10 + (s[i] - '0');
            ++i;
        }
        if (dots < 2)
            return false;
        text = s[0 .. i].idup;
        frontend = major * 1000 + minor;
        return true;
    }

    string own, frontendText;
    int frontend, ownFrontend;
    string compiler;
    if (auto ldc = output.findSplitAfter("LDC - the LLVM D compiler ("))
    {
        if (!versionAt(ldc[1], own, ownFrontend))
            return false;
        auto dmd = ldc[1].findSplitAfter("based on DMD v");
        if (!dmd || !versionAt(dmd[1], frontendText, frontend))
            return false;
        compiler = "ldc";
    }
    else if (auto dmd = output.findSplitAfter("D Compiler v"))
    {
        if (!versionAt(dmd[1], own, frontend))
            return false;
        compiler = "dmd";
    }
    else
        return false;
    platform.compiler = compiler;
    platform.compilerBinary = binary;
    platform.frontendVersion = frontend;
    platform.compilerVersion = own;
    return true;
}

///
@("build_primitives.resolve.platform.readCompilerIdentity")
@safe pure nothrow unittest
{
    BuildPlatform p;
    assert(readCompilerIdentity("ldc2", "LDC - the LLVM D compiler (1.43.0):\n"
        ~ "  based on DMD v2.113.0 and LLVM 24.0.0git\n"
        ~ "  built with LDC - the LLVM D compiler (1.42.0)\n", p));
    assert(p.compiler == "ldc" && p.compilerBinary == "ldc2");
    assert(p.frontendVersion == 2113 && p.compilerVersion == "1.43.0");

    assert(readCompilerIdentity("dmd", "DMD64 D Compiler v2.112.1\nCopyright (C) 1999-2025\n", p));
    assert(p.compiler == "dmd" && p.frontendVersion == 2112 && p.compilerVersion == "2.112.1");

    const before = p;
    assert(!readCompilerIdentity("gdc", "gdc (GCC) 14.2.0\n", p));
    assert(!readCompilerIdentity("ldc2", "LDC - the LLVM D compiler (1.43.0):\n", p));
    assert(p == before);
}
