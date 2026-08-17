#!/usr/bin/env dub
/+ dub.sdl:
    name "gen-coverage-fixtures"
    dependency "sparkles:code-instrumentation" path="../../.."
    dependency "sparkles:core-cli" path="../../.."
    dependency "sparkles:test-utils" path="../../.."
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
// Coverage fixtures for every format `hue --cov` reads, all describing the same
// program, so a reviewer can flip between them and see the overlay agree.
//
// Hand-writing these is where the UAT loop stalls: each format has a shape that
// is easy to get subtly wrong (an LCOV `DA` third field is a checksum, not a
// count; gcov spells an untaken branch two ways; V8's ranges nest and are
// order-sensitive), and a fixture that is wrong in the same way as the parser
// proves nothing. So this generator owns one truth table and emits five
// encodings of it, then reads each back through `sparkles:code-instrumentation`
// and checks the parse against that same table.
//
// That makes it a differential test as well as a fixture generator: if two
// parsers disagree about the program they were both handed, the run says so and
// exits non-zero. `--no-verify` turns that off; it is on by default, because a
// fixture nobody checked is the thing this exists to avoid.
//
//   dub run --single apps/hue/tools/gen-coverage-fixtures.d -- --out /tmp/cov
//   dub run --single apps/hue/tools/gen-coverage-fixtures.d -- --formats lcov,v8
//   dub run --single apps/hue/tools/gen-coverage-fixtures.d -- --no-verify
module gen_coverage_fixtures;

import std.algorithm.iteration : map;
import std.algorithm.searching : canFind, countUntil;
import std.array : appender, array, join;
import std.conv : text;
import std.exception : enforce;
import std.file : mkdirRecurse, write;
import std.path : buildPath;
import std.stdio : stderr, writefln, writeln;
import std.string : split, splitLines, strip;

import sparkles.test_utils.string : outdent;

import sparkles.core_cli.args : HelpInfo, Option, parseCli, reportCliError;

import sparkles.code_instrumentation;

// ── The one truth every emitter encodes ─────────────────────────────────────

/// What a line is, independent of any wire format.
struct LineTruth
{
    size_t line;       /// 1-based
    ulong count;       /// times executed
    LineState state;   /// the verdict a format that can say `partial` should reach
}

/// The D program the four line-oriented formats describe, as a `q{}` token
/// string: the compiler lexes the contents, so an unbalanced brace or a stray
/// character is a build error rather than a fixture that quietly describes
/// something other than the file beside it. It also reads as the program it
/// is, instead of as a list of quoted fragments whose line numbers have to be
/// counted by eye — and the line numbers are the whole point of the table
/// below.
enum dSourceText = q{
module sample;

int add(int a, int b)
{
    return a + b;
}

int neverCalled(int a)
{
    return a * 2;
}

int guard(int c)
{
    if (c) { return add(c, 1); }
    return 0;
}

void main()
{
    assert(add(2, 3) == 5);
    assert(guard(0) == 0);
}
};

/// ditto
immutable string[] dSource = dSourceText.sourceLines;

/// Line 15 is the interesting one: it ran three times, and the block it guards
/// never did. A format with a branch or sub-line channel reports `partial`;
/// a DMD `.lst` and an llvm-cov export have nowhere to put that, so they
/// report `covered` and the count carries what they can say.
immutable LineTruth[] dTruth = [
    LineTruth(5, 5, LineState.covered),
    LineTruth(10, 0, LineState.uncovered),
    LineTruth(15, 3, LineState.partial),
    LineTruth(16, 3, LineState.covered),
    LineTruth(21, 1, LineState.covered),
    LineTruth(22, 1, LineState.covered),
];

/// The same program in JavaScript, for V8 — which is a JS engine's format, and
/// whose byte ranges only mean anything against the source they were taken
/// from. Kept line-for-line comparable to `dSource` so the two overlays read
/// the same way side by side.
///
/// A $(LINK2 https://dlang.org/spec/lex#delimited_strings, delimited string)
/// rather than a token string: `q{}` lexes its contents as D, and this is not
/// D. The identifier form takes the text verbatim, so what is written here is
/// byte-for-byte what lands on disk — which matters more than usual, because
/// V8 addresses this file by byte offset.
enum jsSourceText = q"JS
export function add(a, b) {
    return a + b;
}

export function neverCalled(a) {
    return a * 2;
}

export function guard(c) {
    if (c) { return add(c, 1); }
    return 0;
}

add(2, 3);
guard(0);
JS";

/// ditto
immutable string[] jsSource = jsSourceText.sourceLines;

/// `jsSource`'s truth, which is a different table rather than a copy: the two
/// programs say the same thing at different line numbers, and reusing `dTruth`
/// here would check V8's answers against the wrong file. Line 10 is the JS
/// twin of D's line 15. Everything outside a function still ran once, because
/// V8's module-level range covers the whole script.
immutable LineTruth[] jsTruth = [
    LineTruth(2, 5, LineState.covered),
    LineTruth(6, 0, LineState.uncovered),
    LineTruth(10, 3, LineState.partial),
    LineTruth(11, 3, LineState.covered),
    LineTruth(14, 1, LineState.covered),
    LineTruth(15, 1, LineState.covered),
];

/// Whether a format can express "ran, but not every way through".
bool expressesPartial(CoverageFormat f) @safe pure nothrow @nogc
    => f == CoverageFormat.gcov || f == CoverageFormat.lcov || f == CoverageFormat.v8Json;

/// The verdict `f` should reach for `t` — `partial` collapses to `covered`
/// wherever the format has no channel for it.
LineState expected(in LineTruth t, CoverageFormat f) @safe pure nothrow @nogc
    => t.state == LineState.partial && !expressesPartial(f) ? LineState.covered : t.state;

/// The truth for `line`, or `null` when the program says nothing about it.
/// Not `in`: that implies `scope` under `-preview=in`, and the result points
/// into the slice.
const(LineTruth)* truthAt(const(LineTruth)[] truth, size_t line) @safe pure nothrow @nogc
{
    foreach (ref t; truth)
        if (t.line == line)
            return &t;
    return null;
}

// ── Emitters ────────────────────────────────────────────────────────────────

/// DMD / LDC `-cov` (`.lst`): one row per source line, `<count>|<text>`, with a
/// blank counter for a line that emitted no code. The trailer is the only place
/// the source path appears, which is why it is not optional.
string emitDmdLst(in string[] src, in LineTruth[] truth, string sourcePath)
{
    auto w = appender!string;
    foreach (i, line; src)
    {
        if (auto t = truth.truthAt(i + 1))
            w ~= text(t.count).padLeft(7);
        else
            w ~= "       ";
        w ~= "|";
        w ~= line;
        w ~= "\n";
    }

    const cover = truth.length ? (100 * truth.count!(t => t.count > 0)) / truth.length : 100;
    w ~= text(sourcePath, " is ", cover, "% covered\n");
    return w[];
}

/// GCC / GDC `gcov`: a line-0 preamble, then `<count>:<line>:<text>`. Branch
/// annotations attach to the line above them by position, which is how line 15
/// becomes `partial` — and they are spelled as counts here (`gcov -b -c`), the
/// spelling a percentage-only reader gets wrong.
string emitGcov(in string[] src, in LineTruth[] truth, string sourcePath)
{
    auto w = appender!string;
    foreach (key, value; ["Source": sourcePath, "Graph": "sample.gcno",
        "Data": "sample.gcda", "Runs": "1"])
        w ~= text("        -:    0:", key, ":", value, "\n");

    foreach (i, line; src)
    {
        const no = i + 1;
        auto t = truth.truthAt(no);
        if (t is null)
            w ~= "        -:";
        else if (t.count == 0)
            w ~= "    #####:";
        else
            w ~= text(t.count).padLeft(9) ~ ":";
        w ~= text(no).padLeft(5) ~ ":" ~ line ~ "\n";

        if (t !is null && t.state == LineState.partial)
        {
            w ~= text("branch  0 taken ", t.count, "\n");
            w ~= "branch  1 never executed\n";
        }
    }
    return w[];
}

/// Standard LCOV (`.info`). `BRDA` is written before the `DA` block here, the
/// way `geninfo` does it — Istanbul writes it after, and a parser that joins by
/// adjacency rather than by line number only works for one of them.
string emitLcov(in LineTruth[] truth, string sourcePath)
{
    auto w = appender!string;
    w ~= text("SF:", sourcePath, "\n");
    w ~= "FN:3,add\n";
    w ~= "FN:8,neverCalled\n";
    w ~= "FN:13,guard\n";
    w ~= "FNDA:5,add\n";
    w ~= "FNDA:0,neverCalled\n";
    w ~= "FNDA:3,guard\n";
    w ~= "FNF:3\nFNH:2\n";

    foreach (ref t; truth)
        if (t.state == LineState.partial)
        {
            w ~= text("BRDA:", t.line, ",0,0,", t.count, "\n");
            w ~= text("BRDA:", t.line, ",0,1,0\n");
        }

    foreach (ref t; truth)
        w ~= text("DA:", t.line, ",", t.count, "\n");

    w ~= text("LF:", truth.length, "\n");
    w ~= text("LH:", truth.count!(t => t.count > 0), "\n");
    w ~= "end_of_record\n";
    return w[];
}

/// `llvm-cov export` JSON. A segment is
/// `[line, column, count, hasCount, isRegionEntry, isGapRegion]`; the two
/// trailing flags are the ones that matter, since a segment with `hasCount`
/// false is a region *exit* and states no count at all. One is emitted here so
/// a reader that treats it as a zero shows up immediately.
string emitLlvmJson(in string[] src, in LineTruth[] truth, string sourcePath)
{
    auto segs = appender!(string[]);
    foreach (ref t; truth)
        segs ~= text("[", t.line, ",5,", t.count, ",true,true,false]");
    // The closing brace of `main` ends a region and carries no count of its own.
    segs ~= text("[", src.length, ",1,0,false,false,false]");

    const covered = truth.count!(t => t.count > 0);
    return text(
        `{"version":"2.0.1","type":"llvm.coverage.json.export","data":[{"files":[{`,
        `"filename":`, sourcePath.jsonString, `,`,
        `"segments":[`, segs[].join(","), `],`,
        `"summary":{"lines":{"count":`, truth.length, `,"covered":`, covered,
        `,"percent":`, (100.0 * covered) / truth.length, `},`,
        `"branches":{"count":2,"covered":1,"percent":50.0}}`,
        `}]}]}`, "\n");
}

/// V8 block coverage (Vitest, `node:inspector`). Ranges nest: the module-level
/// range covers everything, each function narrows it, and a zero-count range
/// inside a function carves out the part that did not run.
///
/// Two orderings are in play, and only one of them is a parser's problem:
///
/// $(UL
/// $(LI Within a function, ranges may arrive in any order, and a reader that
///     applies them as they come gets the opposite verdict from one that
///     applies them widest-first. `guard`'s inner zero-count block is emitted
///     $(B before) the function range here, so a fixture rendering correctly
///     means the parser sorted rather than trusted.)
/// $(LI Across functions, order is the producer's own nesting, and V8 emits
///     the module-level wrapper first. That is not a parser freedom — a
///     whole-file range applied last would overwrite every verdict under it —
///     so it is emitted first, the way a real report has it.)
/// )
string emitV8Json(in string[] src, string sourcePath)
{
    const source = src.join("\n") ~ "\n";

    /// The byte range of `needle`, which must occur exactly once.
    string range(string needle, ulong count)
    {
        const at = source.countUntil(needle);
        enforce(at >= 0, "fixture text not found: " ~ needle);
        return text(`{"startOffset":`, at, `,"endOffset":`, at + needle.length,
            `,"count":`, count, `}`);
    }

    const whole = text(`{"startOffset":0,"endOffset":`, source.length, `,"count":1}`);

    return text(
        `{"result":[{"scriptId":"1","url":`, sourcePath.jsonString, `,"functions":[`,
        `{"functionName":"","isBlockCoverage":false,"ranges":[`, whole, `]},`,
        `{"functionName":"add","isBlockCoverage":true,"ranges":[`,
        range("function add(a, b) {\n    return a + b;\n}", 5), `]},`,
        `{"functionName":"neverCalled","isBlockCoverage":true,"ranges":[`,
        range("function neverCalled(a) {\n    return a * 2;\n}", 0), `]},`,
        // Inner block first, function range second — the per-function sort is
        // what has to put these right.
        `{"functionName":"guard","isBlockCoverage":true,"ranges":[`,
        range("{ return add(c, 1); }", 0), `,`,
        range("function guard(c) {\n    if (c) { return add(c, 1); }\n    return 0;\n}", 3),
        `]}`,
        `]}]}`, "\n");
}

// ── Small helpers ───────────────────────────────────────────────────────────

/// The lines of a delimited string literal, through
/// $(REF outdent, sparkles,test_utils,string) — which drops the newline that
/// follows a token string's opening brace, the one difference between the two
/// forms here.
///
/// Zero levels, deliberately: these literals sit at column 0, so outdenting a
/// level would strip the sample program's *own* indentation along with it and
/// silently change the fixture.
string[] sourceLines(string literal)
    => literal.outdent(0).splitLines;

/// Right-aligns `s` in `width` columns (the counter columns are fixed-width).
string padLeft(string s, size_t width)
{
    if (s.length >= width)
        return s;
    auto w = appender!string;
    foreach (_; 0 .. width - s.length)
        w ~= ' ';
    w ~= s;
    return w[];
}

/// A JSON string literal — paths are the only untrusted text here, and a
/// Windows path would otherwise emit stray escapes.
string jsonString(const(char)[] s)
{
    auto w = appender!string;
    w ~= '"';
    foreach (c; s)
        switch (c)
        {
            case '"':  w ~= `\"`;   break;
            case '\\': w ~= `\\`;   break;
            case '\n': w ~= `\n`;   break;
            default:   w ~= c;      break;
        }
    w ~= '"';
    return w[];
}

/// `count!pred` over a slice, without pulling in the whole algorithm module
/// for one predicate.
size_t count(alias pred, T)(in T[] items)
{
    size_t n;
    foreach (ref it; items)
        if (pred(it))
            n++;
    return n;
}

// ── Driver ──────────────────────────────────────────────────────────────────

/// One emitted artifact and what it should parse back to.
struct Fixture
{
    string name;             /// the `--formats` key
    string path;             /// the artifact on disk
    string sourcePath;       /// the source it describes
    CoverageFormat format;   /// what detection should call it
    const(LineTruth)[] truth;
}

struct Params
{
    @(Option("out|o", description: "Directory to write the fixtures into"))
    string outDir = "coverage-fixtures";

    @(Option("formats|f", description: "Comma list: dmd, gcov, lcov, llvm, v8 (default all)"))
    string formats = "dmd,gcov,lcov,llvm,v8";

    @(Option("no-verify", description: "Skip reading each artifact back through the library"))
    bool noVerify;
}

int main(string[] args)
{
    auto parsed = parseCli!Params(args, HelpInfo("gen-coverage-fixtures",
        "Write one coverage artifact per format, all describing the same program, " ~
        "and check each parses back to it.", null));
    if (!parsed)
        return reportCliError(parsed.error);
    const p = parsed.value;

    const want = p.formats.split(",").map!strip.array;
    foreach (name; want)
        if (!["dmd", "gcov", "lcov", "llvm", "v8"].canFind(name))
        {
            stderr.writeln("gen-coverage-fixtures: unknown format '", name,
                "' (want dmd, gcov, lcov, llvm or v8)");
            return 1;
        }

    mkdirRecurse(p.outDir);
    const dPath = buildPath(p.outDir, "sample.d");
    const jsPath = buildPath(p.outDir, "sample.js");
    write(dPath, dSource.join("\n") ~ "\n");
    write(jsPath, jsSource.join("\n") ~ "\n");

    Fixture[] written;
    void emit(string name, string file, string body_, string src, CoverageFormat fmt,
        const(LineTruth)[] truth)
    {
        if (!want.canFind(name))
            return;
        const path = buildPath(p.outDir, file);
        write(path, body_);
        written ~= Fixture(name, path, src, fmt, truth);
    }

    emit("dmd", "sample.lst", emitDmdLst(dSource, dTruth, dPath), dPath,
        CoverageFormat.dmdLst, dTruth);
    emit("gcov", "sample.d.gcov", emitGcov(dSource, dTruth, dPath), dPath,
        CoverageFormat.gcov, dTruth);
    emit("lcov", "coverage.info", emitLcov(dTruth, dPath), dPath,
        CoverageFormat.lcov, dTruth);
    emit("llvm", "llvm-cov.json", emitLlvmJson(dSource, dTruth, dPath), dPath,
        CoverageFormat.llvmJson, dTruth);
    emit("v8", "v8-coverage.json", emitV8Json(jsSource, jsPath), jsPath,
        CoverageFormat.v8Json, jsTruth);

    writefln("Wrote %s artifact(s) to %s", written.length, p.outDir);
    writeln("  ", dPath, "   (sample.lst, sample.d.gcov, coverage.info, llvm-cov.json)");
    writeln("  ", jsPath, "  (v8-coverage.json)");
    writeln();

    const failures = p.noVerify ? 0 : verifyAll(written);

    writeln("Render each one:");
    foreach (ref f; written)
        writefln("  hue --cov=%s view %s", f.path, f.sourcePath);
    writeln();
    writeln("Line 15 (`if (c) { ... }`) is the one to watch: it ran, and the block");
    writeln("it guards did not. gcov, LCOV and V8 report that as `partial`; a DMD");
    writeln("listing and an llvm-cov export have no channel for it and say `covered`.");

    return failures == 0 ? 0 : 1;
}

/// Reads every artifact back through `loadCoverage` and checks it against the
/// table it was generated from. Returns the number of failures.
size_t verifyAll(in Fixture[] fixtures)
{
    import std.file : readText;

    size_t failures;
    foreach (ref f; fixtures)
    {
        const source = readText(f.sourcePath);
        const artifact = readText(f.path);

        const detected = detectFormat(f.path, artifact);
        if (detected != f.format)
        {
            writefln("  ✗ %-5s detected as %s, expected %s", f.name, detected, f.format);
            failures++;
            continue;
        }

        auto report = loadCoverage(f.path, artifact, source);
        if (!report)
        {
            writefln("  ✗ %-5s parse failed at byte %s: %s", f.name,
                report.error.offset, report.error.context);
            failures++;
            continue;
        }

        const file = report.value.findFile(f.sourcePath);
        if (file is null)
        {
            writefln("  ✗ %-5s parsed, but describes no entry for %s", f.name, f.sourcePath);
            failures++;
            continue;
        }

        size_t mismatches;
        foreach (ref t; f.truth)
        {
            const got = file.lineAt(t.line);
            const wanted = t.expected(f.format);
            if (got is null)
            {
                writefln("  ✗ %-5s line %s: not described (expected %s)",
                    f.name, t.line, wanted);
                mismatches++;
            }
            else if (got.state != wanted)
            {
                writefln("  ✗ %-5s line %s: %s, expected %s",
                    f.name, t.line, got.state, wanted);
                mismatches++;
            }
        }

        if (mismatches == 0)
        {
            const plan = planCoverage(*file);
            writefln("  ✓ %-5s %-16s %s", f.name, detected, plan.summaryBanner);
        }
        failures += mismatches;
    }

    writeln();
    return failures;
}
