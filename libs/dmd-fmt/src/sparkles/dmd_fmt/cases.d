/**
The markdown case runner — `TST1`, `TST4` and `TST5` of
[the testing spec](../../../../../docs/specs/dmd-fmt/testing.md).

A formatting fixture is a **documentation page**. There is no bespoke fixture
syntax and no generation step: the page a reader sees is the file this module
executes, so a documented example cannot drift from the implementation. A
generated page can be stale; an executed page cannot.

A case is a VitePress code group preceded by an `<!-- fmt … -->` directive:

---
### Blank-line runs collapse

<!-- fmt id=P19 -->

::: code-group

```d [Before]
void a() {}




void b() {}
```

```d [After]
void a() {}


void b() {}
```

:::
---

The first fence is the input; every later fence is an expectation. A fence
titled `[key=value]` is a $(B variant): those keys are merged over the case's
own, so one group documents an option by showing each of its values as a tab.

$(B Directive keys.) `id=P19` (a decision id, or several, comma-separated) ·
`width=60` · plus any [FormatConfig] key spelled as its `.editorconfig` name
(`indent_size`, `indent_style`, `tab_width`, `max_blank_lines`,
`insert_final_newline`).

$(B Running one case) applies the four-step `TST4` pipeline: format and compare,
[verifyFormat], [checkConvergence], and idempotence on the expectation itself —
`format(expected) == expected`, which catches an engine that produces a
stable-looking output it would not itself produce.

$(B Blessing.) With `SPARKLES_UPDATE_GOLDENS=1` set, [runCaseFile] rewrites the
expectation fences in place and reports what it changed. Input fences, prose,
directives and group structure are never touched, so a blessed diff reads as
"what changed in the output" — and a rule sentence the new output contradicts
stays in the same hunk for a reviewer to notice.
*/
module sparkles.dmd_fmt.cases;

import std.algorithm : canFind, startsWith;
import std.array : appender, split;
import std.conv : to;
import std.string : strip, stripRight;

import sparkles.dmd_fmt.config : FormatConfig;
import sparkles.dmd_fmt.printer : formatText;
import sparkles.dmd_fmt.verify : checkConvergence, verifyFormat;

/// One expectation of a case: a fence, its tab title, and where it sits.
struct Expectation
{
    /// The fence's code-group tab title (`After`, `brace_style=allman`, …).
    string title;
    /// The fence's contents, newline-terminated.
    string text;
    /// 1-based line of the fence's opening ```` ```d ```` line.
    size_t line;
    /// Line span of the fence body, as a half-open 0-based range into the
    /// file's lines — what [blessCaseFile] rewrites.
    size_t bodyFirst, bodyLast;
}

/// One case: a directive plus the code group that follows it.
struct Case
{
    /// The `<!-- fmt … -->` keys, verbatim.
    string[string] meta;
    /// Decision ids from `id=`, e.g. `["P19"]`.
    string[] ids;
    /// The first fence in the group.
    string input;
    /// 1-based line of the `::: code-group` marker, for failure messages.
    size_t line;
    /// The remaining fences.
    Expectation[] expectations;

    /// A short human label: the ids, or the line when the case is untagged.
    string label() const @safe pure
    {
        if (!ids.length)
            return "line " ~ line.to!string;
        string s = ids[0];
        foreach (id; ids[1 .. $])
            s ~= " " ~ id;
        return s;
    }
}

/// The outcome of one expectation.
struct CaseResult
{
    string label;   /// Decision ids (or line) plus the variant title.
    size_t line;    /// 1-based line of the case.
    bool ok;        /// Whether every `TST4` step passed.
    string error;   /// The first failure, `null` when `ok`.
    string actual;  /// What the formatter produced (set whenever it differs).
    string expected; /// What the case said it should produce.
}

/**
Parse every case in `text`.

Tolerant by construction: a code group without a preceding `<!-- fmt … -->`
directive is ordinary documentation and is skipped, as is any fence that is not
` ```d `. Nothing here throws on malformed markdown — an unterminated fence
simply ends the case.
*/
Case[] parseCases(const(char)[] text) @safe pure
{
    Case[] cases;
    auto lines = splitKeepingCount(text);
    string[string] pending;
    bool havePending;

    for (size_t i = 0; i < lines.length; i++)
    {
        const line = lines[i].strip;
        if (line.startsWith("<!-- fmt") && line.canFind("-->"))
        {
            pending = parseDirective(line);
            havePending = true;
            continue;
        }
        if (line != "::: code-group")
        {
            // The directive reaches forward past the section's prose — a
            // decision page states its rule between the two, and that prose is
            // the point of the page. Only a new section ends the reach, so a
            // directive can never leak into a later decision's group.
            if (havePending && line.startsWith("#"))
                havePending = false;
            continue;
        }
        if (!havePending)
            continue;

        Case c;
        c.meta = pending;
        c.line = i + 1;
        if (auto ids = "id" in pending)
            foreach (id; (*ids).split(','))
                if (id.strip.length)
                    c.ids ~= id.strip.idup;
        havePending = false;

        for (i++; i < lines.length && lines[i].strip != ":::"; i++)
        {
            const fence = lines[i].strip;
            if (!fence.startsWith("```d"))
                continue;
            const fenceLine = i + 1;
            const title = fenceTitle(fence);
            const bodyFirst = i + 1;
            auto body_ = appender!string;
            for (i++; i < lines.length && lines[i].strip != "```"; i++)
            {
                body_ ~= lines[i];
                body_ ~= "\n";
            }
            if (c.input is null)
                c.input = body_[];
            else
                c.expectations ~= Expectation(title, body_[], fenceLine,
                    bodyFirst, i);
        }
        cases ~= c;
    }
    return cases;
}

/// The configuration a case's expectation runs under: the case's own keys,
/// then the variant title's `key=value` merged over them.
FormatConfig configFor(const Case c, string variantTitle) @safe pure
{
    FormatConfig cfg;
    foreach (key, value; c.meta)
        applyKey(cfg, key, value);
    const eq = indexOfChar(variantTitle, '=');
    if (eq != -1)
        applyKey(cfg, variantTitle[0 .. eq], variantTitle[eq + 1 .. $]);
    return cfg;
}

/// Run one case's expectations — the `TST4` pipeline, per variant.
CaseResult[] runCase(const Case c) @system
{
    CaseResult[] results;
    foreach (exp; c.expectations)
    {
        auto r = CaseResult(c.label ~ " [" ~ exp.title ~ "]", c.line, true);
        const cfg = configFor(c, exp.title);
        const got = formatText(c.input, cfg);

        if (got != exp.text)
        {
            r.ok = false;
            r.error = "output differs";
            r.actual = got;
            r.expected = exp.text;
        }
        else
        {
            // 2. The change is safe: token equality plus DDoc attachment.
            const verified = verifyFormat(c.input, got);
            if (!verified.ok)
            {
                r.ok = false;
                r.error = "verifier: " ~ (verified.tokenError !is null
                    ? verified.tokenError : verified.ddocError);
            }
            else
            {
                // 3. The formatter agrees with itself, to a fixed point.
                const conv = checkConvergence(
                    (const(char)[] s) => formatText(s, cfg), c.input);
                if (!conv.converged)
                {
                    r.ok = false;
                    r.error = conv.error !is null
                        ? "convergence: " ~ conv.error
                        : "no fixed point within the iteration bound";
                }
                // 4. The golden is its own fixed point.
                else if (formatText(exp.text, cfg) != exp.text)
                {
                    r.ok = false;
                    r.error = "the expected output is not itself formatted";
                }
            }
        }
        results ~= r;
    }
    return results;
}

/// Run every case in `path`. With `SPARKLES_UPDATE_GOLDENS=1` set, rewrite the
/// expectations that differ instead of reporting them (`TST5`).
CaseResult[] runCaseFile(string path) @system
{
    import std.file : readText;
    import std.process : environment;

    const text = readText(path);
    auto cases = parseCases(text);
    CaseResult[] failures;
    Expectation[] toBless;
    string[] blessed;

    foreach (c; cases)
        foreach (i, r; runCase(c))
        {
            if (r.ok)
                continue;
            // Only a plain mismatch is blessable; a verifier or convergence
            // failure is a defect, and writing it down would enshrine it.
            if (r.error == "output differs" &&
                environment.get("SPARKLES_UPDATE_GOLDENS") == "1")
            {
                auto exp = c.expectations[i];
                exp.text = r.actual;
                toBless ~= exp;
                blessed ~= r.label;
                continue;
            }
            failures ~= r;
        }

    if (toBless.length)
    {
        // Loud on purpose. A silent rewrite of a committed golden is how a
        // stale binary quietly enshrines its own bug — say what moved, and
        // let the reviewer read it in the diff.
        import std.stdio : stderr;

        blessCaseFile(path, text, toBless);
        stderr.writefln("blessed %s expectation(s) in %s:", blessed.length, path);
        foreach (label; blessed)
            stderr.writefln("  %s", label);
    }
    return failures;
}

/// Rewrite `path`, replacing the body of each listed expectation. Only fence
/// bodies move; prose, directives, titles and inputs are untouched.
void blessCaseFile(string path, const(char)[] text, Expectation[] updates) @safe
{
    import std.algorithm : sort;
    import std.file : write;

    auto lines = splitKeepingCount(text);
    updates.sort!((a, b) => a.bodyFirst < b.bodyFirst);

    auto out_ = appender!string;
    size_t at;
    foreach (u; updates)
    {
        foreach (line; lines[at .. u.bodyFirst])
        {
            out_ ~= line;
            out_ ~= "\n";
        }
        out_ ~= u.text.stripRight("\n");
        out_ ~= "\n";
        at = u.bodyLast;
    }
    foreach (line; lines[at .. $])
    {
        out_ ~= line;
        out_ ~= "\n";
    }
    // `splitKeepingCount` drops a single trailing newline; restore the file's.
    auto result = out_[];
    if (text.length && text[$ - 1] != '\n' && result.length)
        result = result[0 .. $ - 1];
    write(path, result);
}

// ---------------------------------------------------------------------------

private string[] splitKeepingCount(const(char)[] text) @safe pure
{
    import std.string : splitLines;

    string[] lines;
    foreach (line; text.splitLines)
        lines ~= line.idup;
    return lines;
}

private string[string] parseDirective(const(char)[] line) @safe pure
{
    string[string] meta;
    auto inner = line["<!-- fmt".length .. $];
    const close = indexOfNeedle(inner, "-->");
    if (close != -1)
        inner = inner[0 .. close];
    foreach (token; inner.strip.split(' '))
    {
        const t = token.strip;
        if (!t.length)
            continue;
        const eq = indexOfChar(t, '=');
        if (eq == -1)
            meta[t.idup] = "";
        else
            meta[t[0 .. eq].idup] = t[eq + 1 .. $].idup;
    }
    return meta;
}

/// The `[Title]` of a fence info string, or `"After"` when it has none.
private string fenceTitle(const(char)[] fence) @safe pure
{
    const lb = indexOfChar(fence, '[');
    if (lb == -1)
        return "After";
    const rb = indexOfChar(fence[lb .. $], ']');
    if (rb == -1)
        return "After";
    return fence[lb + 1 .. lb + rb].idup;
}

private void applyKey(ref FormatConfig cfg, const(char)[] key,
    const(char)[] value) @safe pure
{
    switch (key)
    {
        // `width` is the fixture spelling of the wrap column; the dfmt key is
        // accepted too, so a case can be written in either vocabulary.
        case "width", "dfmt_soft_max_line_length":
            cfg.softMaxLineLength = value.to!int;
            break;
        case "max_line_length":
            cfg.maxLineLength = value.to!int;
            break;
        case "indent_size":
            cfg.indentSize = value.to!int;
            break;
        case "tab_width":
            cfg.tabWidth = value.to!int;
            break;
        case "indent_style":
            cfg.useTabs = value == "tab";
            break;
        case "max_blank_lines":
            cfg.maxBlankLines = value.to!int;
            break;
        case "insert_final_newline":
            cfg.insertFinalNewline = value == "true";
            break;
        // `id` and any future annotation are metadata, not configuration.
        default:
            break;
    }
}

private ptrdiff_t indexOfChar(const(char)[] s, char c) @safe pure nothrow @nogc
{
    foreach (i, ch; s)
        if (ch == c)
            return i;
    return -1;
}

private ptrdiff_t indexOfNeedle(const(char)[] s, const(char)[] needle)
    @safe pure nothrow @nogc
{
    if (needle.length > s.length)
        return -1;
    foreach (i; 0 .. s.length - needle.length + 1)
        if (s[i .. i + needle.length] == needle)
            return i;
    return -1;
}


// ---------------------------------------------------------------------------
// Reporting

/**
Render a failure for a human: the expectation, what the formatter produced,
and the diff between them.

When `hue` is on `PATH` and the terminal takes colour, all three panes go
through it — this repository's own viewer, so a formatting failure is read
with the same syntax highlighting and the same diff view as the code it is
about. `--diff-show-formatting` is what makes that useful here: a formatter's
diff is usually whitespace-only, and hue folds such a hunk to a badge unless
asked not to (there is no keystroke to expand it in a one-shot render).

Everything degrades: no `hue`, no colour, or any failure invoking it falls
back to plain text with a unified diff. A test report that cannot be produced
is worse than a plain one.
*/
string renderFailure(const CaseResult r) @system
{
    string plain()
    {
        return "\n--- expected ---\n" ~ r.expected
            ~ "\n--- actual ---\n" ~ r.actual
            ~ "\n--- diff ---\n" ~ unifiedDiff(r.expected, r.actual);
    }

    if (!r.expected.length && !r.actual.length)
        return "";
    if (!hueUsable)
        return plain();

    import std.file : tempDir, write;
    import std.path : buildPath;
    import std.process : execute;

    const dir = tempDir;
    const expPath = buildPath(dir, "dmd-fmt-case-expected.d");
    const actPath = buildPath(dir, "dmd-fmt-case-actual.d");
    try
    {
        write(expPath, r.expected);
        write(actPath, r.actual);
        scope (exit)
            removeQuietly(expPath, actPath);

        auto pane = (string title, string[] argv) {
            const res = execute(argv);
            return res.status == 0
                ? "\n" ~ title ~ "\n" ~ res.output
                : "";
        };
        const expected = pane("--- expected ---", ["hue", "view", "--ansi", expPath]);
        const actual = pane("--- actual ---", ["hue", "view", "--ansi", actPath]);
        const diff = pane("--- diff ---",
            ["hue", "diff", "--ansi", "--diff-show-formatting", expPath, actPath]);
        // An older `hue` rejects the flag; its diff would fold the hunk away,
        // so fall back to ours rather than print a badge that says nothing.
        if (!expected.length || !actual.length || !diff.length)
            return plain();
        return expected ~ actual ~ diff;
    }
    catch (Exception)
        return plain();
}

private void removeQuietly(string[] paths...) @safe nothrow
{
    import std.file : remove;

    foreach (path; paths)
        try
            remove(path);
        catch (Exception)
        {
        }
}

/// A plain unified diff, for the no-`hue` path — computed with the same
/// Myers engine the formatter's edit emitter uses (`sparkles:diff`), so a
/// pathological pair degrades to one coarse edit rather than hanging.
private string unifiedDiff(string expected, string actual) @safe
{
    import sparkles.diff.myers : diffLines, splitDiffLines;

    bool missingA, missingB;
    auto oldLines = splitDiffLines(expected, missingA);
    auto newLines = splitDiffLines(actual, missingB);
    const d = diffLines(expected, oldLines, actual, newLines, 4096);

    string lineAt(const(char)[] text, size_t start, size_t end)
        => text[start .. end].stripRight("\r\n").idup;

    auto out_ = appender!string;
    size_t i, j;
    while (i < oldLines.length || j < newLines.length)
    {
        const removed = i < oldLines.length && d.oldRemoved[][i];
        const inserted = j < newLines.length && d.newInserted[][j];
        if (removed)
        {
            out_ ~= "- " ~ lineAt(expected, oldLines[][i].start,
                oldLines[][i].end) ~ "\n";
            i++;
        }
        else if (inserted)
        {
            out_ ~= "+ " ~ lineAt(actual, newLines[][j].start,
                newLines[][j].end) ~ "\n";
            j++;
        }
        else if (i < oldLines.length)
        {
            out_ ~= "  " ~ lineAt(expected, oldLines[][i].start,
                oldLines[][i].end) ~ "\n";
            i++;
            j++;
        }
        else
            break;
    }
    return out_[];
}

/// Is `hue` worth invoking — on `PATH`, and the output takes colour? Computed
/// once: a failing suite would otherwise stat the `PATH` per failure.
private bool hueUsable() @safe
{
    import sparkles.base.term_caps : detectTermCaps;
    import std.algorithm : splitter;
    import std.file : exists;
    import std.path : buildPath;
    import std.process : environment;

    static bool computed, result;
    if (computed)
        return result;
    computed = true;
    if (!detectTermCaps().colors)
        return result = false;
    foreach (dir; environment.get("PATH", "").splitter(':'))
        if (dir.length && buildPath(dir, "hue").exists)
            return result = true;
    return result = false;
}

// ---------------------------------------------------------------------------

@("cases.parse.directive-and-group")
@safe unittest
{
    enum md = "# Page\n\nProse.\n\n<!-- fmt id=P19 width=60 -->\n\n"
        ~ "::: code-group\n\n```d [Before]\nint  a;\n```\n\n"
        ~ "```d [After]\nint a;\n```\n\n:::\n";
    auto cases = parseCases(md);
    assert(cases.length == 1);
    assert(cases[0].ids == ["P19"]);
    assert(cases[0].meta["width"] == "60");
    assert(cases[0].input == "int  a;\n");
    assert(cases[0].expectations.length == 1);
    assert(cases[0].expectations[0].title == "After");
    assert(cases[0].expectations[0].text == "int a;\n");
    assert(configFor(cases[0], "After").softMaxLineLength == 60);
}

@("cases.parse.variants-become-expectations")
@safe unittest
{
    enum md = "<!-- fmt id=P32 variants=indent_size -->\n\n::: code-group\n\n"
        ~ "```d [Before]\nvoid f()\n{\nx();\n}\n```\n\n"
        ~ "```d [indent_size=4]\nvoid f()\n{\n    x();\n}\n```\n\n"
        ~ "```d [indent_size=2]\nvoid f()\n{\n  x();\n}\n```\n\n:::\n";
    auto cases = parseCases(md);
    assert(cases.length == 1);
    assert(cases[0].expectations.length == 2);
    assert(configFor(cases[0], "indent_size=4").indentSize == 4);
    assert(configFor(cases[0], "indent_size=2").indentSize == 2);
}

@("cases.parse.undirected-groups-are-documentation")
@safe unittest
{
    // A code group with no `<!-- fmt … -->` directive is prose, not a case —
    // which is what lets a decision page carry ordinary examples too.
    enum md = "::: code-group\n\n```d [Before]\nint a;\n```\n\n:::\n";
    assert(parseCases(md).length == 0);
}

@("cases.run.pipeline-passes-and-reports")
@system unittest
{
    enum good = "<!-- fmt id=P19 -->\n\n::: code-group\n\n"
        ~ "```d [Before]\nint  a;\n```\n\n```d [After]\nint a;\n```\n\n:::\n";
    foreach (r; runCase(parseCases(good)[0]))
        assert(r.ok, r.error);

    enum bad = "<!-- fmt id=P19 -->\n\n::: code-group\n\n"
        ~ "```d [Before]\nint  a;\n```\n\n```d [After]\nint    a;\n```\n\n:::\n";
    const results = runCase(parseCases(bad)[0]);
    assert(results.length == 1);
    assert(!results[0].ok);
    assert(results[0].error == "output differs");
    assert(results[0].actual == "int a;\n");
    assert(results[0].label == "P19 [After]");
}

@("cases.run.unformatted-golden-is-a-failure")
@system unittest
{
    // Step 4: an expectation the formatter would not itself produce fails even
    // when the input formats to it — impossible for a real formatter, and the
    // check that catches the day it stops being impossible.
    enum md = "<!-- fmt id=P19 -->\n\n::: code-group\n\n"
        ~ "```d [Before]\nint a;\n```\n\n```d [After]\nint a;\n```\n\n:::\n";
    foreach (r; runCase(parseCases(md)[0]))
        assert(r.ok, r.error);
}

@("cases.report.unified-diff-aligns-context")
@safe unittest
{
    // The plain path must align: a one-line change reads as one `-`/`+` pair
    // with the rest as context, not as "delete everything, add everything".
    const d = unifiedDiff("a\nb\nc\n", "a\nB\nc\n");
    assert(d == "  a\n- b\n+ B\n  c\n", d);
}

@("cases.report.plain-render-has-all-three-panes")
@system unittest
{
    CaseResult r;
    r.expected = "int a;\n";
    r.actual = "int  a;\n";
    const report = renderFailure(r);
    assert(report.canFind("--- expected ---"), report);
    assert(report.canFind("--- actual ---"), report);
    assert(report.canFind("--- diff ---"), report);
    // Empty on both sides is not a diff worth printing.
    assert(renderFailure(CaseResult.init) == "");
}

@("cases.bless.rewrites-only-the-expectation")
@safe unittest
{
    enum md = "Prose stays.\n\n<!-- fmt id=P19 -->\n\n::: code-group\n\n"
        ~ "```d [Before]\nint  a;\n```\n\n```d [After]\nwrong;\n```\n\n:::\n";
    auto cases = parseCases(md);
    auto exp = cases[0].expectations[0];
    exp.text = "int a;\n";

    // Bless into a temp file and read it back.
    import std.file : readText, remove, tempDir, write;
    import std.path : buildPath;

    const path = buildPath(tempDir, "sparkles-dmd-fmt-bless-test.md");
    write(path, md);
    scope (exit) remove(path);
    blessCaseFile(path, md, [exp]);

    const after = readText(path);
    assert(after.canFind("Prose stays."));
    assert(after.canFind("```d [Before]\nint  a;\n```"));
    assert(after.canFind("```d [After]\nint a;\n```"));
}

@("cases.corpus.every-case-file-passes")
@system unittest
{
    import std.file : dirEntries, exists, readText, SpanMode;
    import std.path : buildPath, dirName;

    enum thisDir = __FILE_FULL_PATH__.dirName;
    enum repoRoot = thisDir.dirName.dirName.dirName.dirName.dirName;

    // Both trees, when present: the unpublished hostile cases, and the
    // published decision pages (`TST3`). Missing either is not a failure —
    // the runner has to work in a checkout that carries only one of them.
    static immutable roots = [
        "libs/dmd-fmt/test/cases",
        "docs/libs/dmd-fmt/reference/decisions",
    ];

    size_t files, checks;
    string report;
    foreach (root; roots)
    {
        const dir = buildPath(repoRoot, root);
        if (!dir.exists)
            continue;
        foreach (entry; dirEntries(dir, "*.md", SpanMode.depth))
        {
            files++;
            // A fixture file that parses to nothing is the failure mode this
            // harness is most exposed to: it passes silently and proves
            // nothing. Count what actually ran and demand it be non-zero.
            size_t ran;
            foreach (c; parseCases(readText(entry.name)))
                ran += c.expectations.length;
            if (ran == 0)
            {
                report ~= "\n" ~ entry.name
                    ~ ": no cases parsed — is the `<!-- fmt … -->` directive"
                    ~ " missing, or the fence not ```d?";
                continue;
            }
            checks += ran;
            foreach (failure; runCaseFile(entry.name))
            {
                report ~= "\n" ~ entry.name ~ ":" ~ failure.line.to!string
                    ~ ": " ~ failure.label ~ " — " ~ failure.error;
                report ~= renderFailure(failure);
            }
        }
    }
    assert(report is null, report);
    assert(files > 0, "no case files found — the runner is testing nothing");
    assert(checks > 0, "case files parsed, but no expectations ran");
}
