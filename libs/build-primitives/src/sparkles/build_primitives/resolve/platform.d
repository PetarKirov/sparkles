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
