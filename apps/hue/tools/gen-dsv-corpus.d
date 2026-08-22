#!/usr/bin/env dub
/+ dub.sdl:
    name "gen-dsv-corpus"
    dependency "sparkles:dsv" path="../../.."
    dependency "sparkles:base" path="../../.."
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
// The DSV sample corpus — real numbers about THIS repository, encoded so the
// set covers everything the DSV preview / data browser does
// (`docs/specs/hue/dsv-preview.md`).
//
// Hand-writing demo CSVs is where a UAT loop stalls: a file that is
// interesting to browse (real names, real spreads, enough rows to scroll) is
// tedious to fake, and a fake never exercises the messy corners — quoted
// commas inside real commit subjects, unicode authors, a decimal-comma
// column that is WHY semicolon CSV exists. So this generator harvests the
// repository itself (git history, the source tree, the sub-package table)
// and emits one file per feature axis:
//
//   subpackages.csv   comma + quoted lists   sorting, typed integer columns
//   commits.tsv       tab, ISO dates         the date type, unicode subjects
//   contributors.csv  SEMICOLON dialect      decimal-comma share (`DSD1`)
//   deps.psv          PIPE dialect           the fourth candidate delimiter
//   modules-wide.csv  16 columns             h-scroll + freeze panes (DSG4)
//   files.csv         every tracked file     scale: viewport + filter + sort
//   todos.csv         harvested TODO text    RFC 4180 quoting, embedded "",
//   matrix.tsv        no header              synthetic A/B/C headers (DSD3)
//   releases.csv      BOM + CRLF + defects   ragged rows, unterminated quote,
//                                            no trailing newline (DSM3/DSC4)
//
// Like `gen-coverage-fixtures.d`, it is a differential test as well as a
// generator: every emitted file is read straight back through `sparkles:dsv`
// — sniff, parse, type inference — and checked against what the writer
// intended (dialect, header verdict, shape, ragged count, column types). A
// corpus nobody verified proves nothing; `--no-verify` turns it off.
//
//   dub run --single apps/hue/tools/gen-dsv-corpus.d
//   dub run --single apps/hue/tools/gen-dsv-corpus.d -- --out /tmp/dsv
//   dub run --single apps/hue/tools/gen-dsv-corpus.d -- --commits 500
module gen_dsv_corpus;

import std.algorithm.iteration : filter, map, splitter, sum;
import std.algorithm.searching : canFind, startsWith;
import std.algorithm.sorting : sort;
import std.array : array, join, replace, split;
import std.conv : text, to;
import std.exception : enforce;
import std.file : dirEntries, exists, isFile, mkdirRecurse, read, readText,
    SpanMode, write;
import std.path : baseName, buildPath, dirName, extension;
import std.process : execute;
import std.stdio : stderr, writefln, writeln;
import std.string : indexOf, lineSplitter, strip;

import sparkles.dsv : ColumnType, decodeCell, detectHeader, Dialect, DsvDoc,
    inferColumnTypes, parseDsv, seedForExtension, sniff;
import sparkles.base.smallbuffer : SmallBuffer;

int main(string[] args)
{
    string outDir = buildPath("apps", "hue", "samples", "dsv");
    size_t commitLimit = 200;
    bool verify = true;
    for (size_t i = 1; i < args.length; i++)
    {
        switch (args[i])
        {
            case "--out": outDir = args[++i]; break;
            case "--commits": commitLimit = args[++i].to!size_t; break;
            case "--no-verify": verify = false; break;
            default:
                stderr.writeln("unknown option: ", args[i]);
                return 2;
        }
    }
    enforce("dub.sdl".exists && buildPath("apps", "hue").exists,
        "run from the repository root");
    mkdirRecurse(outDir);

    bool ok = true;
    void emit(string name, string bytes, in Expect ex)
    {
        const path = buildPath(outDir, name);
        write(path, bytes);
        if (!verify)
        {
            writefln("  %-18s %6d bytes", name, bytes.length);
            return;
        }
        const err = check(bytes, name, ex);
        if (err.length)
        {
            ok = false;
            writefln("✗ %-18s %s", name, err);
        }
        else
            writefln("✓ %-18s %6d bytes, %s", name, bytes.length, ex.describe);
    }

    emit("subpackages.csv", genSubpackages(),
        Expect(',', '"', header: true, columns: 7,
            types: [3: ColumnType.integer, 4: ColumnType.integer,
                5: ColumnType.integer]));
    emit("commits.tsv", genCommits(commitLimit),
        Expect('\t', '"', header: true, columns: 7,
            types: [1: ColumnType.date, 4: ColumnType.integer]));
    emit("contributors.csv", genContributors(),
        Expect(';', '"', header: true, columns: 5,
            types: [1: ColumnType.integer, 2: ColumnType.date]));
    emit("deps.psv", genDeps(),
        Expect('|', '"', header: true, columns: 3));
    emit("modules-wide.csv", genModulesWide(),
        Expect(',', '"', header: true, columns: 16,
            types: [2: ColumnType.integer, 15: ColumnType.integer]));
    emit("files.csv", genFiles(),
        Expect(',', '"', header: true, columns: 6,
            types: [4: ColumnType.integer, 5: ColumnType.integer]));
    emit("todos.csv", genTodos(),
        Expect(',', '"', header: true, columns: 4,
            types: [1: ColumnType.integer]));
    emit("matrix.tsv", genMatrix(),
        Expect('\t', '"', header: false, columns: 3,
            types: [0: ColumnType.integer, 2: ColumnType.integer]));
    emit("releases.csv", genReleases(),
        // columns = 5, not 4: the grid is as wide as the WIDEST record
        // (`DSM3`), and the long defect row carries an overflow cell.
        Expect(',', '"', header: true, columns: 5, minRagged: 3,
            noTrailingNewline: true, looksDsv: false));

    if (!ok)
    {
        stderr.writeln("corpus verification FAILED");
        return 1;
    }
    writeln("corpus written to ", outDir);
    return 0;
}

// ── the writer ──────────────────────────────────────────────────────────────

/// RFC 4180 serialization under a dialect: a cell is quoted when it contains
/// the delimiter, the quote (doubled inside), or a newline.
string serialize(in string[][] rows, in Dialect d, string eol = "\n",
    bool trailingNewline = true) @safe pure
{
    string s;
    foreach (ri, row; rows)
    {
        foreach (ci, cell; row)
        {
            if (ci)
                s ~= d.delimiter;
            const needsQuote = cell.canFind(d.delimiter)
                || cell.canFind(d.quote) || cell.canFind('\n')
                || cell.canFind('\r');
            if (needsQuote)
            {
                s ~= d.quote;
                foreach (ch; cell)
                {
                    s ~= ch;
                    if (ch == d.quote)
                        s ~= d.quote;
                }
                s ~= d.quote;
            }
            else
                s ~= cell;
        }
        if (ri + 1 < rows.length || trailingNewline)
            s ~= eol;
    }
    return s;
}

// ── the harvesters ──────────────────────────────────────────────────────────

string git(string[] cmd...)
{
    auto r = execute(["git"] ~ cmd);
    enforce(r.status == 0, "git " ~ cmd.join(" ") ~ " failed: " ~ r.output);
    return r.output;
}

struct SourceStats
{
    size_t files, lines, bytes;
}

SourceStats statsUnder(string dir)
{
    SourceStats s;
    if (!dir.exists)
        return s;
    foreach (e; dirEntries(dir, "*.d", SpanMode.depth).filter!(e => e.isFile))
    {
        const src = readText(e.name);
        s.files++;
        s.bytes += src.length;
        foreach (_; src.lineSplitter)
            s.lines++;
    }
    return s;
}

/// `subpackages.csv`: one row per sub-package — kind, source stats, and a
/// quoted comma-joined module list (the quoting exercise).
string genSubpackages()
{
    string[][] rows = [["name", "kind", "path", "d files", "source lines",
        "source bytes", "top modules"]];
    string[][] data;
    foreach (kind, parent; ["app": "apps", "lib": "libs"])
        foreach (e; dirEntries(parent, SpanMode.shallow))
        {
            if (!buildPath(e.name, "dub.sdl").exists)
                continue;
            const st = statsUnder(buildPath(e.name, "src"));
            string[] tops;
            foreach (f; dirEntries(buildPath(e.name, "src"), "*.d",
                    SpanMode.depth).filter!(f => f.isFile))
                tops ~= baseName(f.name);
            tops.sort!((a, b) => a < b);
            if (tops.length > 3)
                tops = tops[0 .. 3];
            data ~= [baseName(e.name), kind, e.name, text(st.files),
                text(st.lines), text(st.bytes), tops.join(", ")];
        }
    data.sort!((a, b) => a[0] < b[0]);
    return serialize(rows ~ data, Dialect(','));
}

/// `commits.tsv`: the last N commits — short sha, ISO date (the date type),
/// author (unicode), churn totals, and the raw subject.
string genCommits(size_t limit)
{
    // %x1f as the field separator: subjects may contain anything printable.
    const log = git("log", text("-", limit),
        "--pretty=format:%h\x1f%as\x1f%an\x1f%s", "--numstat");
    string[][] rows = [["sha", "date", "author", "files", "insertions",
        "deletions", "subject"]];
    string[] cur;
    size_t files, ins, dels;
    void flush()
    {
        if (cur.length)
            rows ~= [cur[0], cur[1], cur[2], text(files), text(ins),
                text(dels), cur[3]];
        cur = null;
        files = ins = dels = 0;
    }

    foreach (line; log.lineSplitter)
    {
        if (line.canFind('\x1f'))
        {
            flush();
            auto f = line.split('\x1f');
            enforce(f.length == 4, "unexpected log line: " ~ line);
            cur = [f[0], f[1], f[2],
                f[3].replace("\t", " ").replace("\r", " ")];
            continue;
        }
        auto parts = line.split('\t');
        if (parts.length == 3)
        {
            files++;
            if (parts[0] != "-")
                ins += parts[0].to!size_t;
            if (parts[1] != "-")
                dels += parts[1].to!size_t;
        }
    }
    flush();
    return serialize(rows, Dialect('\t'));
}

/// `contributors.csv`: the semicolon dialect's reason to exist — a
/// decimal-COMMA share column, unquoted, beside the author names.
string genContributors()
{
    size_t[string] commits;
    string[string] first, last;
    foreach (line; git("log", "--pretty=format:%an\x1f%as").lineSplitter)
    {
        auto f = line.split('\x1f');
        if (f.length != 2)
            continue;
        commits[f[0]]++;
        if (f[0] !in first || f[1] < first[f[0]])
            first[f[0]] = f[1];
        if (f[0] !in last || f[1] > last[f[0]])
            last[f[0]] = f[1];
    }
    const total = commits.byValue.sum;
    string[][] rows = [["author", "commits", "first", "last", "share %"]];
    string[][] data;
    foreach (name, n; commits)
    {
        // one decimal, comma-separated: "97,3" — the European-CSV cell that
        // forces the semicolon delimiter (`DSD1`'s semicolon-CSV case).
        const tenths = (n * 1000 + total / 2) / total;
        data ~= [name, text(n), first[name], last[name],
            text(tenths / 10, ",", tenths % 10)];
    }
    data.sort!((a, b) => a[1].to!size_t > b[1].to!size_t
        || (a[1] == b[1] && a[0] < b[0]));
    return serialize(rows ~ data, Dialect(';'));
}

/// `deps.psv`: the in-tree dependency edges under the pipe dialect.
string genDeps()
{
    string[][] rows = [["package", "depends on", "declared in"]];
    string[][] data;
    foreach (parent; ["apps", "libs"])
        foreach (e; dirEntries(parent, SpanMode.shallow))
        {
            const sdl = buildPath(e.name, "dub.sdl");
            if (!sdl.exists)
                continue;
            foreach (line; readText(sdl).lineSplitter)
            {
                const t = line.strip;
                if (!t.startsWith("dependency \""))
                    continue;
                const rest = t["dependency \"".length .. $];
                const q = rest.indexOf('"');
                if (q < 0)
                    continue;
                data ~= [baseName(e.name), rest[0 .. q], sdl];
            }
        }
    data.sort!((a, b) => a[0] < b[0] || (a[0] == b[0] && a[1] < b[1]));
    return serialize(rows ~ data, Dialect('|'));
}

/// `modules-wide.csv`: 16 metric columns per library module — enough width
/// that the grid h-scrolls and the frozen name column earns its keep.
string genModulesWide()
{
    static size_t count(in char[] hay, string needle) @safe pure
    {
        size_t n, from;
        while (from < hay.length)
        {
            const at = hay[from .. $].indexOf(needle);
            if (at < 0)
                break;
            n++;
            from += at + needle.length;
        }
        return n;
    }

    string[][] rows = [["package", "module", "bytes", "lines", "blank",
        "comment", "imports", "unittests", "structs", "classes", "enums",
        "templates", "@safe", "@nogc", "asserts", "todos"]];
    string[][] data;
    foreach (e; dirEntries("libs", "*.d", SpanMode.depth)
        .filter!(e => e.isFile && e.name.canFind("/src/")))
    {
        const src = readText(e.name);
        size_t lines, blank, comment;
        foreach (line; src.lineSplitter)
        {
            lines++;
            const t = line.strip;
            if (t.length == 0)
                blank++;
            else if (t.startsWith("//") || t.startsWith("*")
                || t.startsWith("/*") || t.startsWith("+"))
                comment++;
        }
        const pkg = e.name.split("/")[1];
        data ~= [pkg, baseName(e.name), text(src.length), text(lines),
            text(blank), text(comment),
            text(count(src, "import ")), text(count(src, "unittest")),
            text(count(src, "struct ")), text(count(src, "class ")),
            text(count(src, "enum ")), text(count(src, "template ")),
            text(count(src, "@safe")), text(count(src, "@nogc")),
            text(count(src, "assert(")), text(count(src, "TODO"))];
    }
    data.sort!((a, b) => a[0] < b[0] || (a[0] == b[0] && a[1] < b[1]));
    return serialize(rows ~ data, Dialect(','));
}

/// `files.csv`: every tracked file — the tall one (thousands of rows), for
/// scrolling, filtering (`ext:d`), and multi-key sorts at a real size.
string genFiles()
{
    string[][] rows = [["path", "directory", "name", "ext", "bytes",
        "lines"]];
    string[][] data;
    foreach (path; git("ls-files").lineSplitter)
    {
        if (!path.exists || !path.isFile)
            continue;
        const raw = cast(const(ubyte)[]) read(path);
        size_t lines;
        if (!raw.canFind(0)) // binary files report 0 lines
            foreach (_; (cast(const(char)[]) raw).lineSplitter)
                lines++;
        data ~= [path.idup, dirName(path), baseName(path),
            extension(path).length ? extension(path)[1 .. $] : "",
            text(raw.length), text(lines)];
    }
    data.sort!((a, b) => a[0] < b[0]);
    return serialize(rows ~ data, Dialect(','));
}

/// `todos.csv`: harvested TODO/FIXME/HACK/XXX lines — real prose with
/// commas, quotes and unicode, so the RFC 4180 quoting corner is genuine.
string genTodos()
{
    static immutable markers = ["TODO", "FIXME", "HACK", "XXX"];
    string[][] rows = [["file", "line", "marker", "text"]];
    string[][] data;
    outer: foreach (path; git("ls-files", "*.d", "*.md").lineSplitter)
    {
        if (!path.exists || !path.isFile)
            continue;
        size_t ln;
        foreach (line; readText(path).lineSplitter)
        {
            ln++;
            foreach (m; markers)
            {
                const at = line.indexOf(m);
                if (at < 0)
                    continue;
                // require a plausible marker: start-of-comment-ish context
                const after = line[at + m.length .. $];
                if (after.startsWith(":") || after.startsWith(" —")
                    || after.startsWith("("))
                {
                    data ~= [path.idup, text(ln), m,
                        line[at .. $].strip.idup];
                    if (data.length >= 400)
                        break outer;
                    break;
                }
            }
        }
    }
    data.sort!((a, b) => a[0] < b[0]
        || (a[0] == b[0] && a[1].to!size_t < b[1].to!size_t));
    return serialize(rows ~ data, Dialect(','));
}

/// `matrix.tsv`: monthly commit counts with NO header row — every cell
/// numeric, so the header heuristic says no and the grid shows synthetic
/// `A`/`B`/`C` column letters (`DSD3`).
string genMatrix()
{
    size_t[string] perMonth;
    foreach (line; git("log", "--pretty=format:%as").lineSplitter)
        if (line.length >= 7)
            perMonth[line[0 .. 7].idup]++;
    string[][] rows;
    foreach (month, n; perMonth)
        rows ~= [month[0 .. 4], month[5 .. 7], text(n)];
    rows.sort!((a, b) => a[0] < b[0] || (a[0] == b[0] && a[1] < b[1]));
    return serialize(rows, Dialect('\t'));
}

/// `releases.csv`: the tag list wrapped in every tolerated defect at once —
/// UTF-8 BOM, CRLF terminators, two deliberately ragged rows, an
/// unterminated quote, and no trailing newline. The parser degrades, never
/// errors (`DSM3`), and a pristine whole-grid `source` copy reproduces the
/// file byte-for-byte, defects included (`DSC4`).
string genReleases()
{
    string[][] rows = [["tag", "date", "commits since previous", "notes"]];
    string[] tags;
    foreach (line; git("tag", "--sort=creatordate").lineSplitter)
        if (line.length)
            tags ~= line.idup;
    string prev = "";
    foreach (tag; tags)
    {
        const date = git("log", "-1", "--pretty=format:%as", tag).strip;
        const range = prev.length ? prev ~ ".." ~ tag : tag;
        size_t n;
        foreach (_; git("rev-list", range).lineSplitter)
            n++;
        rows ~= [tag, date.idup, text(n), "tagged release"];
        prev = tag;
    }
    if (rows.length == 1) // an untagged clone still gets the defect shapes
        rows ~= [["v0.0.0", "2024-01-01", "0", "synthetic"]];
    auto body_ = serialize(rows, Dialect(','), "\r\n", trailingNewline: true);
    // The defects, appended raw: a short row, a long row, and a final row
    // whose quote never closes AND whose line never ends.
    body_ ~= "next,\r\n";
    body_ ~= "someday,2199-01-01,0,wishful,extra-cell\r\n";
    body_ ~= "\"unterminated,2199-12-31,0,the parser tolerates this";
    return "\xEF\xBB\xBF" ~ body_;
}

// ── the verifier (the differential half) ────────────────────────────────────

struct Expect
{
    char delimiter = ',';
    char quote = '"';
    bool header = true;
    uint columns;
    ColumnType[size_t] types; /// column index → expected inferred type
    uint minRagged = 0;
    bool noTrailingNewline = false;
    /// The `DSD5` content signal. The defect file legitimately fails the
    /// 90% consistency floor — its `.csv` extension is what renders it.
    bool looksDsv = true;
}

/// ditto
string describe(in Expect ex) @safe pure
{
    const d = ex.delimiter == '\t' ? "tab"
        : ex.delimiter == ';' ? "semicolon"
        : ex.delimiter == '|' ? "pipe" : "comma";
    return text(d, ", ", ex.columns, " cols, ",
        ex.header ? "header" : "no header",
        ex.minRagged ? ", ragged + defects" : "");
}

/// Reads `bytes` back through the library and reports the first mismatch
/// ("" = the file is what the writer intended).
string check(string bytes, string name, in Expect ex)
{
    const seed = seedForExtension(extension(name));
    const sr = sniff(bytes, seed);
    if (sr.dialect.delimiter != ex.delimiter)
        return text("sniffed delimiter ", sr.dialect.delimiter,
            ", wanted ", ex.delimiter);
    if (sr.dialect.quote != ex.quote)
        return text("sniffed quote ", sr.dialect.quote, ", wanted ", ex.quote);
    if (sr.looksDsv != ex.looksDsv)
        return text("looksDsv ", sr.looksDsv, ", wanted ", ex.looksDsv);
    if (sr.hasHeader != ex.header)
        return text("header verdict ", sr.hasHeader, ", wanted ", ex.header);

    auto parsed = parseDsv(bytes, sr.dialect);
    if (parsed.hasError)
        return "parse error";
    auto doc = parsed.value;
    doc.hasHeader = sr.hasHeader;
    if (doc.columnCount != ex.columns)
        return text(doc.columnCount, " columns, wanted ", ex.columns);
    if (doc.dataRecordCount == 0)
        return "no data records";
    if (doc.raggedCount < ex.minRagged)
        return text(doc.raggedCount, " ragged records, wanted ≥ ",
            ex.minRagged);
    if (ex.noTrailingNewline && (bytes.length == 0 || bytes[$ - 1] == '\n'))
        return "expected no trailing newline";

    SmallBuffer!(ColumnType, 64) types;
    inferColumnTypes(doc, 200, types);
    foreach (col, want; ex.types)
    {
        if (col >= types.length)
            return text("no inferred type for column ", col);
        if (types[col] != want)
            return text("column ", col, " inferred ", types[col],
                ", wanted ", want);
    }
    return "";
}
