#!/usr/bin/env dub
/+ dub.sdl:
    name "gen-wired-inline"
+/
/**
Generates the `wired-inline` bench engine's single-translation-unit copy of
the native JSON reader.

The wired-native hot path is built from templates (`parseJsonDocument` →
`parseInto` → `scanNumber`), so it is code-generated in whichever package
*instantiates* it — here the benchmark package, which cannot enable
`-enable-cross-module-inlining` (it would propagate to mir-ion and cull a
template-nested symbol). The consequence is visible in the disassembly: even
`doubleToBits`, a single `movq`, is emitted as a `call` into `sparkles:base`.

This tool splices the six modules that make up that path into one module, so
every seam is intra-module and LDC's inliner sees the whole kernel at once.
That isolates the value of inlining from the build-system variables
(cross-module inlining, ThinLTO, PGO) that could not be evaluated cleanly.

Nothing under `libs/base` or `libs/wired` is modified — this is a copy, and
the copy is what the `wired-inline` engine measures. Re-run after changing any
source module so the two engines stay comparable:

    dub run --single tools/gen-wired-inline.d
*/
module gen_wired_inline;

import std.algorithm.searching : canFind, startsWith;
import std.array : appender, join;
import std.file : readText, write;
import std.path : buildPath, dirName;
import std.stdio : writefln;
import std.string : strip, stripRight;

/// One source module folded into the generated unit. Order is cosmetic —
/// D module-scope declarations are order-independent — but it keeps the
/// generated file readable bottom-up: primitives first, grammar last.
private struct Source
{
    string path; /// repo-relative
    string moduleName; /// the module being absorbed (its imports drop out)
}

private immutable Source[] sources = [
    Source("libs/base/src/sparkles/base/text/errors.d", "sparkles.base.text.errors"),
    Source("libs/base/src/sparkles/base/text/float_conv.d", "sparkles.base.text.float_conv"),
    Source("libs/base/src/sparkles/base/text/utf8.d", "sparkles.base.text.utf8"),
    Source("libs/wired/src/sparkles/wired/json/document.d", "sparkles.wired.json.document"),
    Source("libs/wired/src/sparkles/wired/json/scan.d", "sparkles.wired.json.scan"),
    Source("libs/wired/src/sparkles/wired/json/reader.d", "sparkles.wired.json.reader"),
];

private enum outRelative = "libs/wired/bench/runtime/src/sparkles/wired_bench/engines/"
    ~ "wired_inline_impl.d";

void main(string[] args)
{
    // The tool lives at <repo>/libs/wired/bench/runtime/tools/.
    const repo = args[0].dirName.buildPath("..", "..", "..", "..", "..");

    auto body_ = appender!string;
    string[] carriedImports;

    foreach (src; sources)
    {
        auto r = absorb(readText(repo.buildPath(src.path)), src.moduleName);
        foreach (imp; r.imports)
            if (!carriedImports.canFind(imp))
                carriedImports ~= imp;

        body_ ~= "// ═══════════════════════════════════════════════════════"
            ~ "══════════════════\n";
        body_ ~= "// From " ~ src.path ~ "\n";
        body_ ~= "// ═══════════════════════════════════════════════════════"
            ~ "══════════════════\n\n";
        body_ ~= r.code;
        body_ ~= "\n";
    }

    const outPath = repo.buildPath(outRelative);
    // Exactly one trailing newline — the end-of-file-fixer hook rewrites the
    // file otherwise, and a hook-edited generated file no longer matches what
    // the generator produces.
    write(outPath, (header(carriedImports) ~ body_[]).stripRight ~ "\n");
    writefln("wrote %s (%s lines, %s carried imports)", outRelative,
        body_[].countLines, carriedImports.length);
}

private size_t countLines(string s)
{
    size_t n = 1;
    foreach (c; s)
        if (c == '\n')
            n++;
    return n;
}

private string header(string[] imports)
{
    return "// GENERATED FILE — DO NOT EDIT.\n"
        ~ "// Regenerate with: dub run --single tools/gen-wired-inline.d\n"
        ~ "//\n"
        ~ "// A single-translation-unit copy of the `sparkles:wired` native JSON\n"
        ~ "// reader and the `sparkles:base` primitives it calls, spliced together\n"
        ~ "// so every seam is intra-module and LDC's inliner sees the whole kernel\n"
        ~ "// at once. Backs the `wired-inline` bench engine, whose only difference\n"
        ~ "// from `wired-native` is that this code is all in one module — the A/B\n"
        ~ "// that isolates inlining from cross-module-inlining, LTO and PGO.\n"
        ~ "//\n"
        ~ "// Sources are copied verbatim (module headers, imports of the absorbed\n"
        ~ "// modules, and unittest blocks removed). Edit the originals, not this.\n"
        ~ "module sparkles.wired_bench.engines.wired_inline_impl;\n\n"
        ~ imports.join("\n") ~ "\n\n";
}

private struct Absorbed
{
    string code;
    string[] imports; /// top-level imports of modules NOT being absorbed
}

/**
Strips `text` down to the declarations worth copying: drops the module
header, the top-level imports of modules that are themselves being absorbed
(they would be self-imports), the test section, and any stray named
unittest block. Top-level imports of *outside* modules are lifted out and
returned so the generated file can carry them once.
*/
private Absorbed absorb(string text, string moduleName)
{
    import std.string : splitLines;

    auto lines = text.splitLines;
    auto code = appender!string;
    string[] imports;

    size_t i = 0;

    // 1. Skip the module's DDoc banner and `module x.y.z;` line.
    foreach (j, line; lines)
        if (line.strip.startsWith("module "))
        {
            i = j + 1;
            break;
        }

    // The absorbed set — an import of any of these becomes a self-import.
    static immutable absorbedModules = [
        "sparkles.base.text.errors", "sparkles.base.text.float_conv",
        "sparkles.base.text.utf8", "sparkles.wired.json.document",
        "sparkles.wired.json.scan", "sparkles.wired.json.reader",
    ];

    for (; i < lines.length; i++)
    {
        const line = lines[i];

        // 2. The test section — every module in this repo separates it with a
        //    box-drawing banner whose next line reads `// Tests…`.
        if (line.startsWith("// ─────") && i + 1 < lines.length
            && lines[i + 1].strip.startsWith("// Tests"))
            break;

        // 3. A named unittest block (`@("name")` … through the closing brace
        //    in column 0). Covers modules whose tests sit between
        //    declarations rather than in a trailing section.
        if (line.startsWith("@(\""))
        {
            while (i < lines.length && lines[i] != "}")
                i++;
            continue;
        }

        // 4. A top-level import: drop it if self-referential, otherwise carry
        //    it up to the generated file's header. Selective imports wrap, so
        //    consume through the terminating semicolon.
        if (line.startsWith("import "))
        {
            string stmt = line;
            while (!stmt.stripRight.endsWith(";") && i + 1 < lines.length)
                stmt ~= "\n" ~ lines[++i];
            if (!absorbedModules.canFind(importedModule(stmt)))
                imports ~= stmt;
            continue;
        }

        // 5. A module-scope attribute *block* (`@safe … package:`) would leak
        //    its attributes across every later splice, so brace it instead.
        if (line.length && line[0] == '@' && line.stripRight.endsWith(":"))
        {
            const attrs = line.stripRight[0 .. $ - 1];
            code ~= attrs ~ "\n{\n";
            for (i++; i < lines.length; i++)
            {
                if (lines[i].startsWith("// ─────") && i + 1 < lines.length
                    && lines[i + 1].strip.startsWith("// Tests"))
                    break;
                if (lines[i].startsWith("@(\""))
                {
                    while (i < lines.length && lines[i] != "}")
                        i++;
                    continue;
                }
                code ~= lines[i] ~ "\n";
            }
            code ~= "}\n";
            break;
        }

        code ~= line ~ "\n";
    }

    return Absorbed(code[], imports);
}

private bool endsWith(string s, string suffix)
    => s.length >= suffix.length && s[$ - suffix.length .. $] == suffix;

/// `import a.b.c : x, y;` → `a.b.c`
private string importedModule(string stmt)
{
    auto rest = stmt["import ".length .. $].strip;
    foreach (k, c; rest)
        if (c == ':' || c == ';' || c == ' ' || c == ',')
            return rest[0 .. k].strip;
    return rest;
}
