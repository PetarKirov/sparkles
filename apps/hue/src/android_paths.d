/**
Pure path helpers for the Android bootstrap. Kept free of version gates so
`dub test :hue` exercises them on any host; the platform-bound half lives in
`android_glue.d` (over `sparkles:android`) under `version (Android)`, and the
bundle checks and env-file parser are `sparkles.android.bundle`'s.

The extracted-asset layout under the app's internal data dir mirrors the APK
`assets/` tree the nix build assembles (see nix/packages/android/hue.nix):
`fonts/` (with `.charset` sidecars), `grammars/<lang>/queries/*.scm`, `docs/`
sample documents, plus the `assets-ready` marker holding the bundle hash of
the last completed extraction.
*/
module android_paths;

import std.path : buildPath;

/// The extracted font directory (`FontSet.FontSources` scans it first).
string fontsDir(string dataDir) @safe pure nothrow => buildPath(dataDir, "fonts");

/// The grammar-query root (`GrammarRegistry` reads `<root>/<lang>/queries/`).
string grammarQueriesRoot(string dataDir) @safe pure nothrow => buildPath(dataDir, "grammars");

/// The sample documents the explorer roots at.
string docsDir(string dataDir) @safe pure nothrow => buildPath(dataDir, "docs");

/// The extraction marker: holds the bundle hash of the last completed extraction.
string assetsReadyPath(string dataDir) @safe pure nothrow => buildPath(dataDir, "assets-ready");

/// The on-device debug-environment file (see `sparkles.android.bundle.parseEnvFile`).
string debugEnvPath(string dataDir) @safe pure nothrow => buildPath(dataDir, "hue-debug.env");

/// The configuration file (`CFG12`): Android has no command line, so this
/// path is the only route to every preference.
string configPath(string dataDir) @safe pure nothrow => buildPath(dataDir, "config.json");

@("android_paths.layout")
@safe pure unittest
{
    assert(fontsDir("/data/app") == "/data/app/fonts");
    assert(grammarQueriesRoot("/data/app") == "/data/app/grammars");
    assert(docsDir("/data/app") == "/data/app/docs");
    assert(assetsReadyPath("/data/app") == "/data/app/assets-ready");
    assert(debugEnvPath("/data/app") == "/data/app/hue-debug.env");
    assert(configPath("/data/app") == "/data/app/config.json");
}
