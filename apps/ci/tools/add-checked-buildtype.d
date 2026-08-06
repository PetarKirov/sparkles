#!/usr/bin/env dub
/+ dub.sdl:
    name "add_checked_buildtype"
    dependency "sparkles:build-primitives" path="../../.."
    targetPath "build"
+/
/**
 * One-shot migration: give every in-repo dub recipe the shared `checked`
 * build type (`optimize` + `inline` + `debugInfo` — optimised, assertions
 * live, `debug {}` blocks out).
 *
 * A custom build type must be declared by the *root* package of a build:
 * `dub.settings.json` has no equivalent, and `Package.getBuildSettings`
 * resolves `--build=<name>` against the root recipe's `buildTypes` alone. For
 * `dub --single` examples the root package *is* the file, so the declaration
 * has to live in each inline `/+ dub.sdl: … +/` block.
 *
 * Idempotent: a recipe that already declares `checked` is left alone, so this
 * can be re-run after new examples land.
 *
 * Run with: `dub run --single add-checked-buildtype.d -- <repo-root>`
 */
module add_checked_buildtype;

import std.algorithm : canFind, endsWith, sort;
import std.array : array, replace;
import std.file : dirEntries, exists, isDir, readText, write, SpanMode;
import std.path : buildPath;
import std.stdio : writefln, writeln;
import std.string : indexOf, lastIndexOf, lineSplitter;

/// The declaration inserted into every recipe, and the marker that makes the
/// insertion idempotent.
enum marker = `buildType "checked"`;

// A delimited string: the SDL comment quotes `debug` in backticks, so a
// backtick-delimited literal would terminate early.
enum blockSdl = q"SDL
// Optimised, assertions live, `debug {}` blocks out — the build every nix
// artifact uses. Neither `debug` (which compiles those blocks in) nor
// `release` (which deletes assert *expressions*, side effects included).
buildType "checked" {
    buildOptions "optimize" "inline" "debugInfo"
}
SDL";

/// Insert the block into a single-file example's inline recipe, immediately
/// before its closing `+/`. Returns the new text, or null when the file
/// already declares `checked` or carries no inline recipe.
string withCheckedInSingleFile(string text)
{
    if (text.canFind(marker))
        return null;

    const start = text.indexOf("/+ dub.sdl:");
    if (start < 0)
        return null;

    const close = text.indexOf("+/", start);
    if (close < 0)
        return null;

    // The inline block is indented by four spaces throughout; match it so the
    // inserted lines do not stand out (and so editorconfig stays happy). Each
    // line is indented individually rather than by replacing every newline —
    // the latter also indents the closing `+/` that follows the insertion.
    string indented;
    foreach (line; blockSdl.lineSplitter)
        indented ~= line.length ? "    " ~ line ~ "\n" : "\n";

    return text[0 .. close] ~ indented ~ text[close .. $];
}

/// Append the block to a normal `dub.sdl`, which needs no re-indentation.
string withCheckedInManifest(string text)
{
    if (text.canFind(marker))
        return null;
    return text ~ blockSdl;
}

int main(string[] args)
{
    const root = args.length > 1 ? args[1] : ".";

    string[] targets;
    foreach (group; ["libs", "apps"])
    {
        const groupDir = buildPath(root, group);
        if (!groupDir.exists || !groupDir.isDir)
            continue;

        foreach (pkg; dirEntries(groupDir, SpanMode.shallow))
        {
            if (!pkg.isDir)
                continue;

            // The package's own manifest, so `dub build :<pkg> -b checked`
            // works for a developer, not only for the nix builder.
            const manifest = buildPath(pkg.name, "dub.sdl");
            if (manifest.exists)
                targets ~= manifest;

            // Its standalone examples — the *direct* children only. A nested
            // tree under `examples/` is input data, not a program to build
            // (`libs/twoslash-d/examples/src/*.d` are analyzer samples), the
            // same rule `nix/packages/examples.nix` applies.
            const examples = buildPath(pkg.name, "examples");
            if (!examples.exists || !examples.isDir)
                continue;
            foreach (entry; dirEntries(examples, SpanMode.shallow))
                if (entry.name.endsWith(".d"))
                    targets ~= entry.name;
        }
    }
    targets.sort();

    size_t changed;
    foreach (path; targets)
    {
        const text = path.readText;
        const updated = path.endsWith("dub.sdl")
            ? withCheckedInManifest(text)
            : withCheckedInSingleFile(text);

        if (updated is null)
            continue;

        path.write(updated);
        writefln("+ %s", path);
        ++changed;
    }

    writefln("\n%d of %d recipes updated", changed, targets.length);
    return 0;
}
