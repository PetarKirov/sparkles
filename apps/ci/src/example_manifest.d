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

import std.string : strip, startsWith, indexOf;
import std.algorithm : canFind;
import std.array : split;

/**
 * Platform specifiers declared by an example's embedded `/+ dub.sdl: … +/`
 * manifest (the top-level `platforms "…"` directive). Returns an empty slice
 * when the example declares no platform restriction.
 */
string[] exampleDeclaredPlatforms(const(char[])[] lines) @safe pure
{
    string[] platforms;
    bool inManifest = false;

    foreach (line; lines)
    {
        const s = line.strip;

        if (!inManifest)
        {
            if (s.startsWith("/+ dub.sdl:"))
                inManifest = true;
            continue;
        }

        if (s.startsWith("+/"))
            break;

        enum kw = "platforms";
        if (s.startsWith(kw) && (s.length == kw.length || s[kw.length] == ' ' || s[kw.length] == '"'))
        {
            // Collect every double-quoted token: `platforms "linux" "osx"`.
            const parts = s.split('"');
            for (size_t i = 1; i < parts.length; i += 2)
                if (parts[i].length)
                    platforms ~= parts[i].idup;
        }
    }

    return platforms;
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
bool exampleRunsOnHost(const(char[])[] lines) @safe pure
{
    return platformsAllowHost(exampleDeclaredPlatforms(lines), hostPlatformTokens());
}

@("example_manifest.declaredPlatforms.single")
@safe pure unittest
{
    const lines = [
        "#!/usr/bin/env dub",
        "/+ dub.sdl:",
        `    name "x"`,
        `    dependency "during" version="~>0.5.0"`,
        `    platforms "linux"`,
        `    targetPath "build"`,
        "+/",
        "void main() {}",
    ];
    assert(exampleDeclaredPlatforms(lines) == ["linux"]);
}

@("example_manifest.declaredPlatforms.none")
@safe pure unittest
{
    const lines = ["/+ dub.sdl:", `    name "x"`, "+/", "void main() {}"];
    assert(exampleDeclaredPlatforms(lines).length == 0);
}

@("example_manifest.declaredPlatforms.multiple")
@safe pure unittest
{
    const lines = ["/+ dub.sdl:", `    platforms "linux" "osx"`, "+/"];
    assert(exampleDeclaredPlatforms(lines) == ["linux", "osx"]);
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
