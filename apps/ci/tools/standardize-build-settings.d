#!/usr/bin/env dub
/+ dub.sdl:
    name "standardize_build_settings"
    targetPath "build"
    dependency "sparkles:build-primitives" path="../../.."
    dependency "sparkles:wired" path="../../.."
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
import std.experimental.allocator.mallocator : Mallocator;
import std.file : readText, write;
import std.stdio : stderr, writeln;
import std.string : lineSplitter, strip;

import sparkles.base.buffer : UniqueBuffer;
import sparkles.base.text.span : TextSpan;
import sparkles.build_primitives.git_env : runGit;
import sparkles.wired.sdl : parseSdlDocument, sdlDubRecipe, sdlEditor, SdlNode, SdlSpan;

// Linux uses lld; Nix must supply wrapped-lld.nix, not the raw ELF linker.
// Template linkage stays package-scoped: forcing it onto mir-ion crashes LDC.
enum managed = q"SDL
// BEGIN managed build types — apps/ci/tools/standardize-build-settings.d
dflags "--linker=lld" platform="linux-ldc"
dflags "-L-fuse-ld=lld" platform="linux-dmd"

buildType "unittest" {
    buildOptions "unittests" "debugMode" "debugInfo"
    dflags "--gline-tables-only" platform="ldc"
    dflags "-defaultlib=libphobos2.so" platform="linux-dmd"
    dflags "--link-defaultlib-shared" platform="linux-ldc"
    lflags "--export-dynamic" platform="linux-ldc"
}
buildType "unittest-debug" {
    buildOptions "unittests" "debugMode" "debugInfo"
    dflags "-defaultlib=libphobos2.so" platform="linux-dmd"
    dflags "--link-defaultlib-shared" platform="linux-ldc"
    lflags "--export-dynamic" platform="linux-ldc"
}
buildType "unittest-cov" {
    buildOptions "unittests" "coverage" "debugMode" "debugInfo"
    dflags "--gline-tables-only" platform="ldc"
    dflags "-defaultlib=libphobos2.so" platform="linux-dmd"
    dflags "--link-defaultlib-shared" platform="linux-ldc"
    lflags "--export-dynamic" platform="linux-ldc"
}
buildType "unittest-cov-ctfe" {
    buildOptions "unittests" "coverageCTFE" "debugMode" "debugInfo"
    dflags "--gline-tables-only" platform="ldc"
    dflags "-defaultlib=libphobos2.so" platform="linux-dmd"
    dflags "--link-defaultlib-shared" platform="linux-ldc"
    lflags "--export-dynamic" platform="linux-ldc"
}
buildType "checked" {
    buildOptions "optimize" "inline" "debugInfo"
}
buildType "bench" {
    buildOptions "unittests" "optimize" "inline"
    dflags "-mcpu=native" "-O3" "-allinst" platform="ldc"
    dflags "-defaultlib=libphobos2.so" platform="linux-dmd"
    dflags "--link-defaultlib-shared" platform="linux-ldc"
    lflags "--export-dynamic" platform="linux-ldc"
}
buildType "bench-unchecked" {
    buildOptions "unittests" "releaseMode" "optimize" "inline"
    dflags "-mcpu=native" "-O3" "-allinst" platform="ldc"
    dflags "-defaultlib=libphobos2.so" platform="linux-dmd"
    dflags "--link-defaultlib-shared" platform="linux-ldc"
    lflags "--export-dynamic" platform="linux-ldc"
}
buildType "bench-static" {
    buildOptions "unittests" "releaseMode" "optimize" "inline"
    dflags "-mcpu=native" "-O3" "-allinst" platform="ldc"
    dflags "--link-defaultlib-shared=false" platform="linux-ldc"
    dflags "-defaultlib=libphobos2.a" platform="linux-dmd"
    lflags "--export-dynamic" platform="linux-ldc"
}
// END managed build types
SDL";

/// Managed build types; outside the managed region a block of one of these
/// names is a stale copy.
private immutable string[] managedBuildTypes = ["unittest", "unittest-debug",
    "unittest-cov", "unittest-cov-ctfe", "checked", "bench", "bench-unchecked", "bench-static"];

/// Link settings an earlier policy put in configurations, now in build types.
private immutable string[] legacySettings = [
    `dflags "--link-defaultlib-shared" "-linkonce-templates" platform="ldc"`,
    `dflags "-defaultlib=libphobos2.so" "-L-fuse-ld=gold" platform="linux-dmd"`,
    `dflags "--link-defaultlib-shared" "--linker=gold" platform="linux-ldc"`,
    `lflags "--export-dynamic" platform="linux-ldc"`,
];

/// The comment an earlier generator wrote above its `checked` build type;
/// only this exact text is its, so a reworded copy is the author's.
private enum legacyComment = "// Optimised, assertions live, `debug {}` blocks out — the build every nix\n"
    ~ "// artifact uses. Neither `debug` (which compiles those blocks in) nor\n"
    ~ "// `release` (which deletes assert *expressions*, side effects included).\n";

/**
Normalizes only policy, through the lossless SDL editor: the managed region
(between its marker comments) is replaced in place or appended, stale managed
build types and legacy link settings outside it are removed, and every other
byte — comments, layout, package-specific flags — is kept.
*/
string normalize(string source) @safe
{
    auto parsed = parseSdlDocument!sdlDubRecipe(source);
    if (parsed.hasError)
        return source; // not ours to repair; `dub` reports it
    auto root = parsed.document.root;
    auto editor = sdlEditor!sdlDubRecipe(parsed.document, source);

    // The lines of `[start, end)`: from the start of `start`'s line through
    // the newline that ends `end`'s line.
    TextSpan wholeLines(size_t start, size_t end)
    {
        while (start > 0 && source[start - 1] != '\n')
            start--;
        while (end < source.length && source[end] != '\n')
            end++;
        return TextSpan(cast(uint) start, cast(uint)(end < source.length ? end + 1 : end));
    }

    SdlSpan begin, end, legacy;
    foreach (comment; parsed.document.comments)
    {
        const text = comment.span.sliceOf(source);
        if (text.startsWith("// BEGIN managed build types"))
            begin = comment.span;
        else if (text.startsWith("// END managed build types"))
            end = comment.span;
        else if (comment.span.startOffset + legacyComment.length <= source.length
            && source[comment.span.startOffset .. comment.span.startOffset + legacyComment.length]
                == legacyComment)
            legacy = comment.span;
    }
    const hasRegion = begin.isValid && end.isValid && begin.startOffset < end.startOffset;
    const region = hasRegion ? wholeLines(begin.startOffset, end.startOffset) : TextSpan.init;
    bool inRegion(scope SdlNode node)
        => hasRegion && node.span.startOffset >= region.startOffset
            && node.span.startOffset < region.endOffset;

    if (legacy.isValid)
    {
        const start = wholeLines(legacy.startOffset, legacy.startOffset).startOffset;
        editor.replaceRegion(TextSpan(start, cast(uint)(legacy.startOffset + legacyComment.length)), "");
    }

    // The node's own text, without its terminator or trailing comment.
    const(char)[] statement(scope SdlNode node)
        => source[node.span.startOffset .. node.extent.endOffset].strip;

    void removeLegacySettings(scope SdlNode parent)
    {
        foreach (node; parent.byChild)
            if (!inRegion(node) && legacySettings.canFind(statement(node)))
                editor.remove(node);
    }

    removeLegacySettings(root);
    foreach (node; root.byChild)
    {
        if (inRegion(node) || node.valueCount != 1)
            continue;
        const name = node.qualifiedName.localName;
        const value = node.byValue.front;
        if (name == "buildType" && managedBuildTypes.canFind(value.stringValue))
            editor.remove(node);
        else if (name == "configuration" && value.stringValue != "offline")
            removeLegacySettings(node);
    }

    if (hasRegion)
    {
        if (region.sliceOf(source) != managed)
            editor.replaceRegion(region, managed);
    }
    else
        editor.append(root, (source.endsWith("\n\n") || source.length == 0 ? "" : "\n") ~ managed);

    UniqueBuffer!char output;
    Mallocator allocator;
    const written = editor.write(output, allocator);
    assert(!written.hasError, written.hasError ? written.error.toString : "");
    return output[].idup;
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
    assert(normalized.canFind(`dflags "--linker=lld" platform="linux-ldc"`));
    assert(normalized.canFind(`dflags "-L-fuse-ld=lld" platform="linux-dmd"`));
}

/// Only policy changes: CRLF, a `}` out of column zero, trailing spaces and
/// comments elsewhere all survive, and the region takes the host's newline.
@("buildSettings.normalize.lossless")
@safe unittest
{
    import std.array : replace;

    const crlf = "name \"x\"   \r\n// keep me\r\nbuildType \"checked\" {\r\n"
        ~ "    buildOptions \"optimize\"\r\n  }\r\n";
    assert(normalize(crlf) == "name \"x\"   \r\n// keep me\r\n\r\n" ~ managed.replace("\n", "\r\n"));

    const legacy = "name \"y\"\n" ~ legacyComment
        ~ "buildType \"checked\" {\n    buildOptions \"optimize\"\n}\n";
    assert(normalize(legacy) == "name \"y\"\n\n" ~ managed);
    // A reworded copy is the author's comment, and stays.
    const reworded = "name \"y\"\n// Optimised, assertions live, `debug {}` blocks out — the build every nix\n"
        ~ "// artifact uses.\n\n" ~ managed;
    assert(normalize(reworded) == reworded);

    // An up-to-date file is left byte for byte, wherever its region sits.
    const current = "name \"z\" // note\n\n" ~ managed ~ "\nconfiguration \"c\" {\n}\n";
    assert(normalize(current) == current);
    // A stale region is replaced in place.
    const stale = "name \"z\"\n\n// BEGIN managed build types — old\nbuildType \"checked\" {\n}\n"
        ~ "// END managed build types\nconfiguration \"c\" {\n}\n";
    assert(normalize(stale) == "name \"z\"\n\n" ~ managed ~ "configuration \"c\" {\n}\n");
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
