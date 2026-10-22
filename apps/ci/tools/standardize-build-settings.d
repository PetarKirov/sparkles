#!/usr/bin/env dub
/+ dub.sdl:
    name "standardize_build_settings"
    targetPath "build"
    dependency "sparkles:build-primitives" path="../../.."
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
Canonical build types for every tracked dub.sdl, including standalone roots.
Run from the repository root with `dub run --single
apps/ci/tools/standardize-build-settings.d -- --check` (omit --check to update).
Package configurations own dependencies and source selection, not test/benchmark
link policy. Platform/compiler-specific flags never leak into other toolchains.
*/
module standardize_build_settings;

import std.algorithm : canFind, endsWith, startsWith;
import std.array : replace;
import std.file : readText, write;
import std.regex : regex, replaceAll;
import std.stdio : stderr, writeln;
import std.string : lineSplitter, strip;

import sparkles.build_primitives.git_env : runGit;

// Measured defaults; the companion report records the experiment and exceptions.
// Template linkage stays package-scoped: forcing it onto mir-ion crashes LDC.
enum managed = q"SDL
// BEGIN managed build types — apps/ci/tools/standardize-build-settings.d
buildType "unittest" {
    buildOptions "unittests" "debugMode" "debugInfo"
    dflags "--gline-tables-only" platform="ldc"
    dflags "-defaultlib=libphobos2.so" "-L-fuse-ld=gold" platform="linux-dmd"
    dflags "--link-defaultlib-shared" "--linker=gold" platform="linux-ldc"
    lflags "--export-dynamic" platform="linux-ldc"
}
buildType "unittest-debug" {
    buildOptions "unittests" "debugMode" "debugInfo"
    dflags "-defaultlib=libphobos2.so" "-L-fuse-ld=gold" platform="linux-dmd"
    dflags "--link-defaultlib-shared" "--linker=gold" platform="linux-ldc"
    lflags "--export-dynamic" platform="linux-ldc"
}
buildType "unittest-cov" {
    buildOptions "unittests" "coverage" "debugMode" "debugInfo"
    dflags "--gline-tables-only" platform="ldc"
    dflags "-defaultlib=libphobos2.so" "-L-fuse-ld=gold" platform="linux-dmd"
    dflags "--link-defaultlib-shared" "--linker=gold" platform="linux-ldc"
    lflags "--export-dynamic" platform="linux-ldc"
}
buildType "unittest-cov-ctfe" {
    buildOptions "unittests" "coverageCTFE" "debugMode" "debugInfo"
    dflags "--gline-tables-only" platform="ldc"
    dflags "-defaultlib=libphobos2.so" "-L-fuse-ld=gold" platform="linux-dmd"
    dflags "--link-defaultlib-shared" "--linker=gold" platform="linux-ldc"
    lflags "--export-dynamic" platform="linux-ldc"
}
buildType "checked" {
    buildOptions "optimize" "inline" "debugInfo"
}
buildType "bench" {
    buildOptions "unittests" "optimize" "inline"
    dflags "-mcpu=native" "-O3" "-allinst" platform="ldc"
    dflags "-defaultlib=libphobos2.so" "-L-fuse-ld=gold" platform="linux-dmd"
    dflags "--link-defaultlib-shared" "--linker=gold" platform="linux-ldc"
    lflags "--export-dynamic" platform="linux-ldc"
}
buildType "bench-unchecked" {
    buildOptions "unittests" "releaseMode" "optimize" "inline"
    dflags "-mcpu=native" "-O3" "-allinst" platform="ldc"
    dflags "-defaultlib=libphobos2.so" "-L-fuse-ld=gold" platform="linux-dmd"
    dflags "--link-defaultlib-shared" "--linker=gold" platform="linux-ldc"
    lflags "--export-dynamic" platform="linux-ldc"
}
buildType "bench-static" {
    buildOptions "unittests" "releaseMode" "optimize" "inline"
    dflags "-mcpu=native" "-O3" "-allinst" platform="ldc"
    dflags "--link-defaultlib-shared=false" "--linker=gold" platform="linux-ldc"
    dflags "-defaultlib=libphobos2.a" "-L-fuse-ld=gold" platform="linux-dmd"
    lflags "--export-dynamic" platform="linux-ldc"
}
// END managed build types
SDL";

/// Normalize only policy lines; package-specific compiler flags remain intact.
string normalize(string source) @safe
{
    auto text = source.replaceAll(regex(
        `(?ms)^// BEGIN managed build types[^\n]*\n.*?^// END managed build types\n?`), "");
    text = text.replace("// Optimised, assertions live, `debug {}` blocks out — the build every nix\n"
        ~ "// artifact uses. Neither `debug` (which compiles those blocks in) nor\n"
        ~ "// `release` (which deletes assert *expressions*, side effects included).\n", "");
    // Build-type blocks in SDL contain flat settings, not nested configurations.
    text = text.replaceAll(regex(`(?ms)^buildType "(?:unittest|unittest-debug|unittest-cov|`
        ~ `unittest-cov-ctfe|checked|bench|bench-unchecked|bench-static)" \{\n.*?^\}\n?`), "");
    string result;
    bool preserveBlock;
    foreach (line; text.lineSplitter)
    {
        // Unmanaged calibration types and the conformance application's offline
        // configuration retain their explicitly scoped link settings.
        if (line.startsWith("buildType ") || line.startsWith(`configuration "offline"`))
            preserveBlock = true;
        const setting = line.strip;
        if (!preserveBlock && (setting == `dflags "--link-defaultlib-shared" "-linkonce-templates" platform="ldc"`
            || setting == `dflags "-defaultlib=libphobos2.so" "-L-fuse-ld=gold" platform="linux-dmd"`
            || setting == `dflags "--link-defaultlib-shared" "--linker=gold" platform="linux-ldc"`
            || setting == `lflags "--export-dynamic" platform="linux-ldc"`))
            continue;
        result ~= line ~ "\n";
        if (line == "}") preserveBlock = false;
    }
    return result.strip ~ "\n\n" ~ managed;
}

/// Regeneration is idempotent and preserves special codegen configurations.
@("buildSettings.normalize.idempotent")
@safe unittest
{
    const source = "name \"sample\"\nconfiguration \"library-inline\" {\n"
        ~ "    dflags \"-enable-cross-module-inlining\" \"-linkonce-templates\" platform=\"ldc\"\n}\n";
    const normalized = normalize(source);
    assert(normalize(normalized) == normalized);
    assert(normalized.canFind(`"-enable-cross-module-inlining" "-linkonce-templates"`));
}

/// Old test-link settings move out of configuration scope into the build type.
@("buildSettings.normalize.scopesLinkPolicy")
@safe unittest
{
    const source = "name \"sample\"\nconfiguration \"unittest\" {\n"
        ~ "    dflags \"--link-defaultlib-shared\" \"--linker=gold\" platform=\"linux-ldc\"\n}\n";
    const normalized = normalize(source);
    assert(!normalized[0 .. $ - managed.length].canFind("--linker=gold"));
    assert(normalized.canFind("configuration \"unittest\" {\n}"));
    assert(normalized.canFind(`buildOptions "unittests" "debugMode" "debugInfo"`));
}

/// Package-specific calibration types are outside the managed policy.
@("buildSettings.normalize.preservesCalibration")
@safe unittest
{
    const source = "buildType \"bench-plain\" {\n"
        ~ "    dflags \"--link-defaultlib-shared\" \"--linker=gold\" platform=\"linux-ldc\"\n}\n";
    assert(normalize(source).canFind(source));
}

version (unittest) {} else
int main(string[] args) @system
{
    const check = args.canFind("--check");
    const files = runGit(["ls-files", "*dub.sdl"]);
    assert(files.status == 0, files.output);
    size_t changed, count;
    foreach (path; files.output.lineSplitter)
    {
        if (!path.endsWith("dub.sdl")) continue;
        ++count;
        const before = path.readText;
        const after = normalize(before);
        if (before == after) continue;
        ++changed;
        if (check) stderr.writeln("Noncanonical build settings: ", path);
        else { path.write(after); writeln("Updated ", path); }
    }
    writeln(changed, " of ", count, " manifests ", check ? "need updating" : "updated");
    return check && changed ? 1 : 0;
}
