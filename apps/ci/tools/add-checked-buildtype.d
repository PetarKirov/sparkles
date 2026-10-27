#!/usr/bin/env dub
/+ dub.sdl:
    name "add_checked_buildtype"
    dependency "sparkles:build-primitives" path="../../.."
    dependency "sparkles:wired" path="../../.."
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

import std.algorithm : any, endsWith, sort;
import std.experimental.allocator.mallocator : Mallocator;
import std.file : dirEntries, exists, isDir, readText, write, SpanMode;
import std.path : buildPath;
import std.stdio : writefln;

import sparkles.base.buffer : UniqueBuffer;
import sparkles.build_primitives.dub_manifest : DubManifest;
import sparkles.wired.sdl : fromSDL, parseEmbeddedSdlDocument, parseSdlDocument, sdlDubRecipe,
    sdlEditor;

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

/**
Appends the block to a recipe — a `dub.sdl` (`embedded` false) or the recipe a
single-file example embeds — through the lossless SDL editor, indented like
the recipe's other top-level settings. Returns the new text, or null when the
recipe already declares `checked` (read through the `dub.sdl` schema, so a
commented-out declaration does not count), carries no SDL recipe, or does not
parse.
*/
string withChecked(string text, bool embedded) @safe
{
    import core.lifetime : move;

    auto parsed = embedded
        ? move(parseEmbeddedSdlDocument!sdlDubRecipe(text).parsed)
        : parseSdlDocument!sdlDubRecipe(text);
    if (parsed.hasError)
        return null;
    const manifest = fromSDL!DubManifest(parsed.document.root);
    if (manifest.hasError || manifest.value.buildTypes.any!(b => b.name == "checked"))
        return null;

    auto editor = sdlEditor!sdlDubRecipe(parsed.document, text);
    editor.append(parsed.document.root, blockSdl);
    UniqueBuffer!char output;
    Mallocator allocator;
    if (editor.write(output, allocator).hasError)
        return null;
    return output[].idup;
}

@("addChecked.withChecked")
@safe unittest
{
    enum single = "#!/usr/bin/env dub\n/+ dub.sdl:\n    name \"x\"\n+/\nvoid main() {}\n";
    const updated = withChecked(single, true);
    assert(updated == "#!/usr/bin/env dub\n/+ dub.sdl:\n    name \"x\"\n"
        ~ "    // Optimised, assertions live, `debug {}` blocks out — the build every nix\n"
        ~ "    // artifact uses. Neither `debug` (which compiles those blocks in) nor\n"
        ~ "    // `release` (which deletes assert *expressions*, side effects included).\n"
        ~ "    buildType \"checked\" {\n        buildOptions \"optimize\" \"inline\" \"debugInfo\"\n    }\n"
        ~ "+/\nvoid main() {}\n", updated);
    assert(withChecked(updated, true) is null);

    // A manifest without a final newline gains the block on lines of its own.
    assert(withChecked("name \"m\"", false) == "name \"m\"\n" ~ blockSdl[0 .. $ - 1]);
    // A commented-out declaration is no declaration.
    assert(withChecked("name \"m\"\n// buildType \"checked\" {\n", false) !is null);
    assert(withChecked("module m;\n", true) is null);
}

version (unittest) {} else
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
        const updated = withChecked(text, !path.endsWith("dub.sdl"));

        if (updated is null)
            continue;

        path.write(updated);
        writefln("+ %s", path);
        ++changed;
    }

    writefln("\n%d of %d recipes updated", changed, targets.length);
    return 0;
}
