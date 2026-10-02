/**
Which build is running: the version and commit an application was built from.

The facts come from the build, never from the source tree at run time. A
packaging build (the Nix derivation) writes a `sparkles-build-stamp` file and
puts its directory on the compiler's string-import path (`-J`); a plain
`dub build` has no such file and reports `dev`:

---
enum stamp = buildStampOf!();   // in the application's own compilation
info(i"myapp $(stamp.version_) $(stamp.commitLabel)");
---

The stamp is `key=value` lines:

$(UL
    $(LI `version=0.1.0`)
    $(LI `commit=4f2c1aa` — or `4f2c1aa-dirty` for a tree with uncommitted
        changes, which is then never reported as that commit)
    $(LI `component.libghostty-vt=0.1.0-dev+4749c4e` — the version of a
        component the build linked in, one line each)
)
*/
module sparkles.base.build_stamp;

/// The file a packaging build provides on the string-import path.
enum buildStampFile = "sparkles-build-stamp";

/// The version and commit a binary was built from.
struct BuildStamp
{
    /// The version the build was given; `dev` for an unstamped build.
    string version_ = "dev";

    /// The short commit hash, or `null` when the build did not say.
    string commit;

    /// Whether the tree had uncommitted changes on top of `commit`.
    bool dirty;

    /// The versions of the components the build linked in, as it named them
    /// (`component.<name>=<version>` lines): what an about page lists.
    Component[] components;

    /// One linked component and its version.
    static struct Component
    {
        string name;
        string version_;
    }

    /// The version the build gave for component `name`; `null` when it gave
    /// none (a plain `dub build`).
    string componentVersion(scope const(char)[] name) const @safe pure nothrow @nogc
    {
        foreach (ref c; components)
            if (c.name == name)
                return c.version_;
        return null;
    }

    /// `true` when a packaging build stamped this binary.
    bool stamped() const @safe pure nothrow @nogc => commit.length != 0 || version_ != "dev";

    /**
    The commit as a reader should see it: `4f2c1aa`, `4f2c1aa + uncommitted
    changes`, or `unknown commit`.
    */
    string commitLabel() const @safe pure nothrow
        => commit.length == 0 ? "unknown commit"
            : dirty ? commit ~ " + uncommitted changes"
            : commit;
}

/**
Parses a stamp file's text. Unknown keys and malformed lines are ignored, so
an older reader accepts a newer stamp.
*/
BuildStamp parseBuildStamp(string text) @safe pure
{
    import std.algorithm.iteration : splitter;
    import std.algorithm.searching : endsWith, findSplit, startsWith;
    import std.string : strip;

    enum dirtySuffix = "-dirty";
    enum componentPrefix = "component.";

    BuildStamp s;
    foreach (line; text.splitter('\n'))
    {
        auto kv = line.findSplit("=");
        if (!kv[1].length)
            continue;
        const key = kv[0].strip;
        const value = kv[2].strip;
        if (key == "version" && value.length)
            s.version_ = value;
        else if (key == "commit" && value.length)
        {
            s.dirty = value.endsWith(dirtySuffix);
            s.commit = s.dirty ? value[0 .. $ - dirtySuffix.length] : value;
        }
        else if (key.startsWith(componentPrefix) && key.length > componentPrefix.length
            && value.length)
            s.components ~= BuildStamp.Component(key[componentPrefix.length .. $], value);
    }
    return s;
}

///
@("build_stamp.parseBuildStamp.cleanAndDirty")
@safe pure unittest
{
    const clean = parseBuildStamp("version=0.1.0\ncommit=4f2c1aa\n");
    assert(clean.version_ == "0.1.0");
    assert(clean.commit == "4f2c1aa" && !clean.dirty);
    assert(clean.commitLabel == "4f2c1aa");

    // Nix's `dirtyShortRev`: the last commit, marked — never reported as it.
    const dirty = parseBuildStamp("version=0.1.0\ncommit=4f2c1aa-dirty\n");
    assert(dirty.commit == "4f2c1aa" && dirty.dirty);
    assert(dirty.commitLabel == "4f2c1aa + uncommitted changes");
}

///
@("build_stamp.parseBuildStamp.components")
@safe pure unittest
{
    const s = parseBuildStamp("version=0.1.0\ncomponent.libghostty-vt=0.1.0-dev+4749c4e\n"
        ~ "component.=nameless\ncomponent.raylib=\n");
    assert(s.componentVersion("libghostty-vt") == "0.1.0-dev+4749c4e");
    assert(s.components.length == 1, "a nameless or versionless line is ignored");
    assert(s.componentVersion("raylib") is null);
}

@("build_stamp.parseBuildStamp.unstampedIsDev")
@safe pure unittest
{
    const none = parseBuildStamp("");
    assert(none.version_ == "dev" && !none.stamped);
    assert(none.commitLabel == "unknown commit");

    const odd = parseBuildStamp("garbage\nfuture=1\r\nversion = 2.0 \n");
    assert(odd.version_ == "2.0" && odd.commit is null);
}

/**
The stamp of the compilation that instantiates this template: the parsed
`sparkles-build-stamp` when the build put one on the string-import path, else
an unstamped `dev` [BuildStamp].

A template on purpose — `import(…)` resolves against the $(I instantiating)
compilation's `-J` paths, so a library compiled once still reports the
application's build.
*/
template buildStampOf(string file = buildStampFile)
{
    static if (__traits(compiles, import(file)))
        enum BuildStamp buildStampOf = parseBuildStamp(import(file));
    else
        enum BuildStamp buildStampOf = BuildStamp.init;
}

@("build_stamp.buildStampOf.noStampIsDev")
@safe pure nothrow @nogc unittest
{
    // This test binary is built without a stamp on its import path.
    static assert(buildStampOf!("no-such-stamp-file").version_ == "dev");
    static assert(!buildStampOf!("no-such-stamp-file").stamped);
}
