/**
 * Reading a standalone example's embedded dub single-file manifest.
 *
 * `--example-files` runs each tracked example with `dub run --single`. Some
 * examples are platform-specific (e.g. the `io_uring` examples depend on the
 * Linux-only io_uring binding, `sparkles.event_horizon.sys.uring`). dub's
 * `platforms` directive is only advisory — it does not stop dub from
 * *building* a single-file package on an unlisted
 * platform — so the runner honors the declaration itself: an example whose
 * manifest declares `platforms` the host does not satisfy is skipped rather than
 * built. This keeps the runner generic (it understands the standard dub
 * `platforms` field) instead of hard-coding any particular example's needs.
 */
module example_manifest;

import sparkles.build_primitives.dub_manifest : hostPlatformTokens, parseEmbeddedDubManifest,
    platformsAllowHost;

/**
 * Platform specifiers declared by an example's embedded `/+ dub.sdl: … +/`
 * manifest (the top-level `platforms "…"` directive). Returns an empty slice
 * when the example declares no platform restriction, or has no readable
 * manifest: dub itself then reports the problem when it builds the example.
 */
string[] exampleDeclaredPlatforms(scope const(char)[] source) @safe pure
{
    auto manifest = parseEmbeddedDubManifest(source);
    return manifest.hasValue ? manifest.value.platforms : null;
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
