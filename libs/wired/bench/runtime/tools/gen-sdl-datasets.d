#!/usr/bin/env dub
/+ dub.sdl:
    name "gen-sdl-datasets"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
Derives the two generated SDL benchmark datasets of the `wired_bench` runtime
harness. `nix/packages/wired-bench-data.nix` runs it at build time with
`ldc2 -run`, so it imports nothing but Phobos, and its output depends only on
its arguments: the same input tree gives the same bytes.

$(UL
$(LI `concat <recipes-dir> <out>` — every `dub.sdl` under `<recipes-dir>`, in
    byte order of its relative path, wrapped as an inline `subPackage { … }`
    block of one root recipe. Each block's top-level `name` is replaced by its
    directory path (`libs/base` → `libs-base`, the root → `root`), so the
    subpackage names are unique and the file is one valid DUB recipe.)
$(LI `deep-wide <out>` — a deep and wide SDL document over every scalar kind
    DUB's pinned SDLang parser shares with `sdlFull`: chains nested 200 levels
    deep, tags with 256 attributes and 64 values, and a balanced tree of
    4⁶ leaves, filled from a fixed xorshift sequence.)
)

Run by hand with `dub run --single tools/gen-sdl-datasets.d -- deep-wide /tmp/x.sdl`.
A change to either output changes the dataset: regenerate the fingerprints
in `src/sparkles/wired_bench/sdl.d` in the same commit.
*/
module gen_sdl_datasets;

import std.algorithm.iteration : map, splitter;
import std.algorithm.searching : startsWith;
import std.algorithm.sorting : sort;
import std.array : appender, array, replace;
import std.conv : to;
import std.file : dirEntries, readText, SpanMode, write;
import std.format : format;
import std.path : dirName, relativePath;
import std.stdio : stderr;

int main(string[] args)
{
    if (args.length == 4 && args[1] == "concat")
        write(args[3], concatRecipes(args[2]));
    else if (args.length == 3 && args[1] == "deep-wide")
        write(args[2], deepWide());
    else
    {
        stderr.writeln("usage: gen-sdl-datasets concat <recipes-dir> <out>\n"
            ~ "       gen-sdl-datasets deep-wide <out>");
        return 2;
    }
    return 0;
}

/// The recipes under `root` as one recipe of inline subpackages.
string concatRecipes(string root)
{
    auto paths = dirEntries(root, "dub.sdl", SpanMode.depth)
        .map!(e => e.name.relativePath(root))
        .array;
    paths.sort();

    auto o = appender!string;
    o ~= "name \"sparkles-recipes\"\n";
    o ~= "description \"Every dub.sdl of the snapshot, as inline subpackages\"\n";
    foreach (path; paths)
    {
        const dir = path.dirName;
        const slug = dir == "." ? "root" : dir.replace("/", "-");
        o ~= "subPackage {\n";
        bool renamed;
        foreach (line; readText(root ~ "/" ~ path).splitter('\n'))
        {
            if (!renamed && line.startsWith("name \""))
            {
                o ~= format!"name \"%s\"\n"(slug);
                renamed = true;
            }
            else
            {
                o ~= line;
                o ~= '\n';
            }
        }
        o ~= "}\n";
    }
    return o.data;
}

/// Fixed pseudo-random sequence (xorshift64), so the document never varies.
private struct Rng
{
    ulong s = 0x9E37_79B9_7F4A_7C15;

    ulong next()
    {
        s ^= s << 13;
        s ^= s >> 7;
        s ^= s << 17;
        return s;
    }

    uint below(uint n) => cast(uint) (next() % n);
}

/// One scalar literal, cycling through the kinds both parsers accept. A
/// positional value is never a date-time: one followed by a value starting
/// with a digit does not lex as two values, so the slot is a duration.
private string scalar(ref Rng rng, bool positional)
{
    const kind = rng.below(12);
    switch (kind == 9 && positional ? 10 : kind)
    {
    case 0:
        return format!"\"s%d \\\"q\\\" \\t\\n\"" (rng.below(100_000));
    case 1:
        return format!"`raw %d\\no-escape`" (rng.below(100_000));
    case 2:
        return (cast(int) rng.below(2_000_000) - 1_000_000).to!string;
    case 3:
        return format!"%dL" (rng.next() >> 2);
    case 4:
        return format!"%d.%02dF" (rng.below(10_000), rng.below(100));
    case 5:
        return format!"%d.%04d" (rng.below(1_000_000), rng.below(10_000));
    case 6:
        return format!"%d.%03dBD" (rng.below(1_000_000), rng.below(1000));
    case 7:
        return rng.below(2) ? "true" : "false";
    case 8:
        return "null";
    case 9:
        // A zoned date-time: a bare date followed by a numeric value would
        // lex as one date-time.
        return format!"%04d/%02d/%02d %02d:%02d:%02d-GMT+%02d:00" (1970 + rng.below(80),
            1 + rng.below(12), 1 + rng.below(28), rng.below(24), rng.below(60),
            rng.below(60), rng.below(13));
    case 10:
        return format!"%02d:%02d:%02d" (rng.below(24), rng.below(60), rng.below(60));
    default:
        return "[" ~ ["c3BhcmtsZXM=", "d2lyZWQ=", "U0RM"][rng.below(3)] ~ "]";
    }
}

private void attrs(ref Rng rng, ref typeof(appender!string()) o, uint n)
{
    foreach (i; 0 .. n)
        o ~= format!" %sa%d=%s"(i % 5 == 0 ? "ns:" : "", i, scalar(rng, positional: false));
}

private void values(ref Rng rng, ref typeof(appender!string()) o, uint n)
{
    foreach (_; 0 .. n)
    {
        o ~= ' ';
        o ~= scalar(rng, positional: true);
    }
}

private void indent(ref typeof(appender!string()) o, size_t depth)
{
    foreach (_; 0 .. depth)
        o ~= "    ";
}

/// A balanced tree: `fanout` children per node down to `depth`.
private void tree(ref Rng rng, ref typeof(appender!string()) o, size_t level,
    uint depth, uint fanout)
{
    foreach (i; 0 .. fanout)
    {
        indent(o, level);
        o ~= format!"n%d"(i);
        values(rng, o, 1 + rng.below(3));
        attrs(rng, o, rng.below(3));
        if (depth > 1)
        {
            o ~= " {\n";
            tree(rng, o, level + 1, depth - 1, fanout);
            indent(o, level);
            o ~= "}\n";
        }
        else
            o ~= '\n';
    }
}

/// The generated deep-and-wide document.
string deepWide()
{
    Rng rng;
    auto o = appender!string;
    o ~= "// Generated by libs/wired/bench/runtime/tools/gen-sdl-datasets.d\n";

    // Deep: 4 chains, each nested 200 levels.
    foreach (c; 0 .. 4)
    {
        foreach (level; 0 .. 200)
        {
            indent(o, level);
            o ~= format!"deep:d%d"(level);
            values(rng, o, 2);
            attrs(rng, o, 2);
            o ~= " {\n";
        }
        indent(o, 200);
        o ~= format!"leaf %d\n"(c);
        foreach_reverse (level; 0 .. 200)
        {
            indent(o, level);
            o ~= "}\n";
        }
    }

    // Wide: 64 tags, each with 64 values and 256 attributes.
    foreach (w; 0 .. 64)
    {
        o ~= format!"wide%d"(w);
        values(rng, o, 64);
        attrs(rng, o, 256);
        o ~= '\n';
    }

    // Broad: a balanced tree, fan-out 4, depth 6.
    o ~= "tree {\n";
    tree(rng, o, 1, 6, 4);
    o ~= "}\n";
    return o.data;
}
