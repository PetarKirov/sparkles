/**
 * Reading a standalone example's embedded dub single-file manifest.
 *
 * `--example-files` runs each tracked example with `dub run --single`. Some
 * examples are platform-specific (e.g. the `io_uring` examples depend on the
 * Linux-only `during` binding). dub's `platforms` directive is only advisory —
 * it does not stop dub from *building* a single-file package on an unlisted
 * platform — so the runner honors the declaration itself: an example whose
 * manifest declares `platforms` the host does not satisfy is skipped rather than
 * built. This keeps the runner generic (it understands the standard dub
 * `platforms` field) instead of hard-coding any particular example's needs.
 */
module example_manifest;

import std.string : indexOf;
import std.algorithm : canFind;

import sparkles.build_primitives.dub_manifest : embeddedDubRecipe, parseEmbeddedDubManifest;

/**
 * Platform specifiers declared by an example's embedded `/+ dub.sdl: … +/`
 * manifest (the top-level `platforms "…"` directive). Returns an empty slice
 * when the example declares no platform restriction, or has no readable
 * manifest: dub itself then reports the problem when it builds the example.
 */
string[] exampleDeclaredPlatforms(scope const(char)[] source) @safe pure
{
    const embedded = embeddedDubRecipe(source);
    if (!embedded.found || embedded.isJson)
        return null;
    auto manifest = parseEmbeddedDubManifest(embedded);
    return manifest.hasValue ? manifest.value.platforms : null;
}

/// dub platform OS tokens describing the host this binary was built for.
string[] hostPlatformTokens() @safe pure nothrow
{
    version (Windows)
        return ["windows"];
    else version (OSX)
        return ["osx", "darwin", "posix"];
    else version (linux)
        return ["linux", "posix"];
    else version (FreeBSD)
        return ["freebsd", "posix"];
    else version (Posix)
        return ["posix"];
    else
        return [];
}

/**
 * Whether an example declaring `declared` platforms is buildable on a host
 * described by `hostTokens`. No declaration means no restriction (always true).
 * A dub platform spec may be `os`, `os-arch`, or `os-arch-compiler`; only the
 * leading OS component is matched.
 */
bool platformsAllowHost(const(string)[] declared, const(string)[] hostTokens) @safe pure nothrow
{
    if (declared.length == 0)
        return true;

    foreach (spec; declared)
    {
        const dash = spec.indexOf('-');
        const os = dash < 0 ? spec : spec[0 .. cast(size_t) dash];
        if (hostTokens.canFind(os))
            return true;
    }
    return false;
}

/// Whether a single-file example's manifest permits building on this host.
bool exampleRunsOnHost(scope const(char)[] source) @safe pure
    => platformsAllowHost(exampleDeclaredPlatforms(source), hostPlatformTokens());

@("example_manifest.declaredPlatforms.single")
@safe pure unittest
{
    const source = "#!/usr/bin/env dub\n"
        ~ "/+ dub.sdl:\n"
        ~ "    name \"x\"\n"
        ~ "    dependency \"during\" version=\"~>0.5.0\"\n"
        ~ "    platforms \"linux\"\n"
        ~ "    targetPath \"build\"\n"
        ~ "+/\n"
        ~ "void main() {}\n";
    assert(exampleDeclaredPlatforms(source) == ["linux"]);
}

@("example_manifest.declaredPlatforms.none")
@safe pure unittest
{
    assert(exampleDeclaredPlatforms("/+ dub.sdl:\n    name \"x\"\n+/\nvoid main() {}\n").length == 0);
    // A configuration's restriction is not the package's.
    assert(exampleDeclaredPlatforms("/+ dub.sdl:\n    configuration \"w\" {\n"
        ~ "        platforms \"windows\"\n    }\n+/\n").length == 0);
    assert(exampleDeclaredPlatforms("module m;\n").length == 0);
}

@("example_manifest.declaredPlatforms.multiple")
@safe pure unittest
{
    assert(exampleDeclaredPlatforms("/+ dub.sdl:\n    platforms \"linux\" \"osx\"\n+/\n")
        == ["linux", "osx"]);
}

@("example_manifest.platformsAllowHost.matching")
@safe pure nothrow unittest
{
    // No declaration => runs anywhere.
    assert(platformsAllowHost([], ["osx", "darwin", "posix"]));
    // Linux-only example: runs on Linux, skipped on macOS.
    assert(platformsAllowHost(["linux"], ["linux", "posix"]));
    assert(!platformsAllowHost(["linux"], ["osx", "darwin", "posix"]));
    // `posix` matches any POSIX host; OS component of a compound spec is matched.
    assert(platformsAllowHost(["posix"], ["linux", "posix"]));
    assert(platformsAllowHost(["linux-x86_64"], ["linux", "posix"]));
    assert(!platformsAllowHost(["windows"], ["linux", "posix"]));
}
