/**
Check that an APK's hand-kept D version list covers what dub would set.

The Android builders (`nix/packages/android/*.nix`) compile an application
without dub, so they list its version identifiers by hand: the
`Have_sparkles_*` names of its libraries and every `versions` a selected
configuration declares. A configuration that gains a version (terminal-view's
`TerminalViewRaylib`, which gates its whole raylib painter) and a list that
does not follow compile cleanly into an application that cannot draw. This
walks the application's selected configuration through its `sparkles:*`
closure — each library under the configuration a manifest selects for it,
else its first, as dub picks — and reports what the list lacks. The list may
name more (Android-only libraries, versions a third-party package sets).

Pure over a file reader, like `credits`, so it is unit-tested without a tree.
*/
module android_versions;

import std.algorithm : canFind, sort, uniq;
import std.array : array, join, replace;
import std.regex : ctRegex, matchAll;
import std.string : indexOf, lineSplitter;

import credits : FileReader, shippedSettings, sparklesEdges, sparklesSubConfigurations;
import sparkles.build_primitives.dub_manifest : parseDubManifest;

/// An application whose APK builder lists its versions by hand.
struct AndroidBuild
{
    string appDir;        /// its dub package directory
    string configuration; /// the configuration the APK mirrors
    string builder;       /// the Nix file with its `versions = [ … ]`
}

/// The builds the check covers.
immutable AndroidBuild[] androidBuilds = [
    AndroidBuild("apps/terminal", "application", "nix/packages/android/terminal.nix"),
    AndroidBuild("apps/hue", "android", "nix/packages/android/hue.nix"),
];

/// The identifiers a dub build of `appDir` in `configuration` sets: each
/// `versions` its selected configurations declare, and `Have_sparkles_*`
/// for each library it depends on in its closure.
string[] dubVersions(scope FileReader read, string appDir, string configuration) @safe
{
    string[string] selected; // library → configuration, the first selection wins
    string[] versions;
    // The closure under the selections made so far, until a pass adds none:
    // a selection may come from a library visited later.
    for (size_t known = size_t.max; known != selected.length;)
    {
        known = selected.length;
        versions = null;
        bool[string] seen;
        void visit(string dir, string config)
        {
            const text = read(dir ~ "/dub.sdl");
            if (text is null)
                return;
            const parsed = parseDubManifest(text, dir ~ "/dub.sdl");
            if (parsed.hasError)
                return;
            const manifest = parsed.value;
            // dub's default: the first configuration declared.
            if (!config.length && manifest.configurations.length)
                config = manifest.configurations[0].name;
            const settings = shippedSettings(manifest, config.length ? [config] : null);
            foreach (ref s; settings)
                foreach (ref entry; s.versions)
                    if (!entry.platform.length) // a platform-qualified one is that platform's
                        versions ~= entry.values;
            // A dependency sets `Have_`; a sibling source path does not.
            foreach (ref s; settings)
                foreach (ref d; s.dependencies)
                    if (d.rootName == "sparkles" && d.subPackageName.length)
                        versions ~= "Have_sparkles_" ~ d.subPackageName.replace("-", "_");
            // A configuration's selection overrides the manifest's top-level
            // one, as in dub; a selection made nearer the application wins.
            const top = sparklesSubConfigurations([manifest.buildSettings]);
            foreach (pair; sparklesSubConfigurations(settings))
                if (!top.canFind(pair) && pair[0] !in selected)
                    selected[pair[0]] = pair[1];
            foreach (pair; top)
                if (pair[0] !in selected)
                    selected[pair[0]] = pair[1];
            foreach (name; sparklesEdges(settings))
            {
                if (name in seen)
                    continue;
                seen[name] = true;
                const lib = read("libs/" ~ name ~ "/dub.sdl") !is null ? "libs/" ~ name
                    : "apps/" ~ name;
                visit(lib, selected.get(name, null));
            }
        }
        visit(appDir, configuration);
    }
    return versions.sort.uniq.array;
}

/// The quoted identifiers of a Nix file's `versions = [ … ];` list.
string[] nixVersions(string nix) @safe
{
    const at = nix.indexOf("versions = [");
    if (at < 0)
        return null;
    const end = nix[at .. $].indexOf("];");
    string[] names;
    foreach (line; nix[at .. at + (end < 0 ? nix.length - at : end)].lineSplitter)
    {
        const c = line.indexOf("#");
        foreach (m; (c < 0 ? line : line[0 .. c]).matchAll(ctRegex!`"([^"]+)"`))
            names ~= m[1];
    }
    return names;
}

/**
What `builder`'s list lacks of what dub sets for its application, among
the identifiers some source tests (`tested`): a `Have_` name nothing tests
changes no build, so its absence is not drift.
*/
string[] missingVersions(scope FileReader read, AndroidBuild b, in bool[string] tested) @safe
{
    const listed = nixVersions(read(b.builder));
    string[] missing;
    foreach (v; dubVersions(read, b.appDir, b.configuration))
        if (v in tested && !listed.canFind(v))
            missing ~= v;
    return missing;
}

/// The identifiers D source tests with `version (X)`.
string[] testedVersions(string source) @safe
{
    string[] names;
    foreach (m; source.matchAll(ctRegex!`\bversion\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)`))
        names ~= m[1];
    return names;
}

version (unittest)
{
    private FileReader tree(string[string] files) @safe
        => (string path) => path in files ? files[path] : null;
}

@("android_versions.missingVersions.followsTheSelectedConfigurations")
@safe unittest
{
    auto read = tree([
        "apps/app/dub.sdl": `dependency "sparkles:view" path="../.."
configuration "application" {
    subConfiguration "sparkles:host" "gui"
    dependency "sparkles:host" path="../.."
    versions "AppGui"
}
configuration "unittest" {
    versions "OnlyInTests"
}`,
        "libs/view/dub.sdl": `configuration "library" {
    versions "ViewRaylib" // the painter
}
configuration "core" {
    versions "ViewCore"
}`,
        "libs/host/dub.sdl": `configuration "tui" {
    versions "HostTui"
}
configuration "gui" {
    versions "HostGui"
}`,
        "nix/app.nix": `versions = [
    "AppGui"
    "HostGui" # the selected one
    "Have_sparkles_host"
    "Have_sparkles_view"
    "Extra"
];`,
    ]);
    const b = AndroidBuild("apps/app", "application", "nix/app.nix");
    assert(dubVersions(read, b.appDir, b.configuration) == ["AppGui", "Have_sparkles_host",
        "Have_sparkles_view", "HostGui", "ViewRaylib"],
        "the default configuration when none is selected; never the unittest one");
    assert(missingVersions(read, b, ["ViewRaylib": true, "Have_sparkles_view": true])
        == ["ViewRaylib"], "what the list lacks and a source tests, and only that");
    assert(missingVersions(read, b, null).length == 0, "an untested identifier is no drift");
    assert(testedVersions("version (ViewRaylib) {}\nversion(Have_x)\nversion = Y;")
        == ["ViewRaylib", "Have_x"]);
}
