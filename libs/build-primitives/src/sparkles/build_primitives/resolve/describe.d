/**
A resolution as `dub describe` reports it, for the tools that read that
report: the shader compiler reads a package's device configuration from it
(shader build SHP1), whether the build graph resolved it or the tool did.
*/
module sparkles.build_primitives.resolve.describe;

import std.algorithm.searching : startsWith;

import sparkles.build_primitives.resolve.configure : Resolution;

/**
The JSON document `dub describe` prints for `r`, cut to what the shader
compiler reads: the root package, each target's package and directory, and
each target's import paths, versions, dflags and source files. Paths beneath
`root` are written `$ROOT/…`, so the description is the same in every
worktree; with `root` null they stay as they are.
*/
string describeDevice(ref const Resolution r, string root = null) @safe
{
    import std.json : JSONValue;

    string place(string path)
    {
        if (root.length && path == root)
            return "$ROOT";
        if (root.length && path.startsWith(root ~ "/"))
            return "$ROOT/" ~ path[root.length + 1 .. $];
        return path;
    }
    JSONValue[] places(const string[] paths)
    {
        JSONValue[] values;
        foreach (p; paths)
            values ~= JSONValue(place(p));
        return values;
    }
    JSONValue[] strings(const string[] values)
    {
        JSONValue[] result;
        foreach (s; values)
            result ~= JSONValue(s);
        return result;
    }

    JSONValue[] packages, targets;
    foreach (ref t; r.targets)
    {
        packages ~= JSONValue(["name": JSONValue(t.package_), "path": JSONValue(place(t.directory))]);
        targets ~= JSONValue([
            "rootPackage": JSONValue(t.package_),
            "buildSettings": JSONValue([
                "importPaths": JSONValue(places(t.settings.importPaths)),
                "versions": JSONValue(strings(t.settings.versions)),
                "dflags": JSONValue(strings(t.settings.dflags)),
                "sourceFiles": JSONValue(places(t.settings.sourceFiles)),
            ]),
        ]);
    }
    return JSONValue([
        "rootPackage": JSONValue(r.rootPackage),
        "packages": JSONValue(packages),
        "targets": JSONValue(targets),
    ]).toString;
}

///
@("build_primitives.resolve.describe.describeDevice.rootedPaths")
@safe unittest
{
    import std.json : parseJSON;
    import sparkles.build_primitives.resolve.configure : ResolvedTarget;

    Resolution r;
    r.rootPackage = "ui";
    ResolvedTarget t;
    t.package_ = "ui";
    t.directory = "/r/libs/ui";
    t.settings.importPaths = ["/r/libs/ui/src", "/elsewhere/src"];
    t.settings.versions = ["Have_ui"];
    t.settings.dflags = ["-mdcompute-targets=vulkan-130"];
    t.settings.sourceFiles = ["/r/libs/ui/shaders/effects.d"];
    r.targets = [t];

    const rooted = parseJSON(describeDevice(r, "/r"));
    assert(rooted["rootPackage"].str == "ui");
    assert(rooted["packages"][0]["path"].str == "$ROOT/libs/ui");
    const settings = rooted["targets"][0]["buildSettings"];
    assert(settings["importPaths"][0].str == "$ROOT/libs/ui/src");
    assert(settings["importPaths"][1].str == "/elsewhere/src");
    assert(settings["dflags"][0].str == "-mdcompute-targets=vulkan-130");

    // Without a root, every path is as resolved.
    const plain = parseJSON(describeDevice(r));
    assert(plain["targets"][0]["buildSettings"]["sourceFiles"][0].str == "/r/libs/ui/shaders/effects.d");
}
