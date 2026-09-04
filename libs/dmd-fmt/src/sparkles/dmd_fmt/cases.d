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
`width=60` · `fixedpoint` (see below) · plus any [FormatConfig] key spelled as
its `.editorconfig` name (`indent_size`, `indent_style`, `tab_width`,
`max_blank_lines`, `insert_final_newline`).

$(B The input must be misformatted) (`TST16`). A case whose Before block is
already its own After demonstrates nothing: a reader sees two identical blocks
and has to take the prose's word for what the rule does, which is exactly the
drift an executed page exists to prevent. Break the input on purpose — wrong
indentation, joined lines, doubled spaces — so the pair shows the rule working.

The exception is a case whose $(I subject) is that nothing changes: a verbatim
region, a suppression range, an already-canonical form the formatter must not
touch. Those say `fixedpoint` in the directive, which is a claim about the rule
rather than an excuse for the fixture.

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
import std.string : splitLines, strip, stripRight;

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
    string file;    /// The markdown page the case came from, when run through
                    /// [runCaseFile] — names the artifacts a failure writes.
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

        // `TST16`: a case whose input is already its own output demonstrates
        // nothing — a reader sees two identical blocks and learns what the
        // rule does from the prose alone, which is the drift the executed page
        // exists to prevent. Misformat the input, or say `fixedpoint` and mean
        // it.
        if (c.input == exp.text && !("fixedpoint" in c.meta))
        {
            r.ok = false;
            r.error = "the input is already formatted — misformat it so the"
                ~ " Before/After pair shows the rule, or mark the case"
                ~ " `fixedpoint` if not changing it IS the rule";
            results ~= r;
            continue;
        }

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
            // `sparkles.test_utils.goldens` states the same rule for the
            // file-based suites and took it from here. This module is not on
            // that helper: it is compiled into the `library` configuration, so
            // it cannot reach a unittest-only package, and its goldens are
            // fences inside a markdown page rather than files.
            if (r.error == "output differs" &&
                environment.get("SPARKLES_UPDATE_GOLDENS") == "1")
            {
                auto exp = c.expectations[i];
                exp.text = r.actual;
                toBless ~= exp;
                blessed ~= r.label;
                continue;
            }
            r.file = path;
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
// Decision coverage (`TST2`)

/// The two trees a case may live in, relative to the repository root: the
/// unpublished hostile cases, and the published decision pages (`TST3`).
immutable string[] caseRoots = [
    "libs/dmd-fmt/test/cases",
    "docs/libs/dmd-fmt/reference/decisions",
];

/// Where the ledger of decisions that have no case yet lives.
enum uncoveredLedger = "libs/dmd-fmt/test/cases/uncovered.txt";

/// One row of the decision inventory: the id, and the verdict scored for D.
struct Decision
{
    string id;
    string verdict;

    /// Does this verdict oblige a case? `Adopt`, `Adapt` and `Opt-in` are the
    /// decisions D means to make; `Have` is already decided elsewhere, and
    /// `N/A`, `Reject`, `Codemod` and `Oracle` are decisions not to.
    bool requiresCase() const @safe pure nothrow @nogc
        => verdict == "Adopt" || verdict == "Adapt" || verdict == "Opt-in";
}

/**
Parse the inventory's decision rows: `| P19 | … | source | **Adopt** |`.

Deliberately shallow — it reads the first cell and the bolded last cell, and
ignores everything in between, so prose edits to a row never break the gate.
*/
Decision[] parseInventory(const(char)[] markdown) @safe pure
{
    import std.string : splitLines;

    Decision[] rows;
    foreach (line; markdown.splitLines)
    {
        const t = line.strip;
        if (t.length < 4 || t[0] != '|' || t[1] != ' ' || t[2] != 'P')
            continue;
        auto cells = t.split('|');
        if (cells.length < 3)
            continue;
        const id = cells[1].strip;
        if (id.length < 2 || !isDigits(id[1 .. $]))
            continue;
        auto verdict = cells[$ - 2].strip;
        if (verdict.length > 4 && verdict[0 .. 2] == "**"
                && verdict[$ - 2 .. $] == "**")
            verdict = verdict[2 .. $ - 2];
        rows ~= Decision(id.idup, verdict.idup);
    }
    return rows;
}

/// What `checkDecisionCoverage` found.
struct CoverageReport
{
    /// Decisions that oblige a case, have none, and are not in the ledger.
    string[] missing;
    /// Ledger entries that now have a case — the ratchet's one direction.
    string[] stale;
    /// Ids a case names that neither the inventory nor the spec defines.
    string[] dangling;
    size_t required;  /// Decisions obliging a case.
    size_t covered;   /// …of which have one.

    bool ok() const @safe pure nothrow @nogc
        => missing.length == 0 && stale.length == 0 && dangling.length == 0;
}

/**
`TST2`: every decision the inventory scores Adopt/Adapt/Opt-in has a case, and
every case names a decision that exists.

Coverage that does not exist yet is not a lie to be papered over — it is a
ledger. `uncovered.txt` lists the decisions still waiting for one, and the gate
fails in **both** directions: a decision that leaves the ledger without gaining
a case, and a ledger entry that has gained one and should be deleted. The count
in that file only goes down, and a reviewer can see it go down.

Ids the spec defines rather than the inventory (`M4`'s magic trailing comma,
`D5`'s escape hatch) are accepted when the decision record mentions them, which
also catches a typo'd id in a case directive.
*/
CoverageReport checkDecisionCoverage(string repoRoot) @system
{
    import std.algorithm : canFind, sort;
    import std.file : dirEntries, exists, readText, SpanMode;
    import std.path : buildPath;

    CoverageReport r;
    const inventory = parseInventory(
        readText(buildPath(repoRoot, "docs/research/code-formatting/prettier-decisions.md")));
    const specText = readText(buildPath(repoRoot, "docs/specs/dmd-fmt/index.md"));

    bool[string] known, needed;
    foreach (d; inventory)
    {
        known[d.id] = true;
        if (d.requiresCase)
            needed[d.id] = true;
    }
    r.required = needed.length;

    bool[string] cited;
    foreach (root; caseRoots)
    {
        const dir = buildPath(repoRoot, root);
        if (!dir.exists)
            continue;
        foreach (entry; dirEntries(dir, "*.md", SpanMode.depth))
            foreach (c; parseCases(readText(entry.name)))
                foreach (id; c.ids)
                    cited[id] = true;
    }

    foreach (id; cited.byKey)
    {
        if (id in known)
        {
            if (id in needed)
                r.covered++;
            continue;
        }
        // A spec-native id (`M4`, `D5`) counts when the decision record
        // actually mentions it; anything else is a typo.
        if (!specText.canFind(id))
            r.dangling ~= id;
    }

    bool[string] ledger;
    const ledgerPath = buildPath(repoRoot, uncoveredLedger);
    if (ledgerPath.exists)
        foreach (line; readText(ledgerPath).splitLines)
        {
            const t = line.strip;
            if (!t.length || t[0] == '#')
                continue;
            const id = t.split(' ')[0].strip;
            ledger[id.idup] = true;
            if (id in cited)
                r.stale ~= id.idup;
        }

    foreach (id; needed.byKey)
        if (!(id in cited) && !(id in ledger))
            r.missing ~= id;

    r.missing.sort();
    r.stale.sort();
    r.dangling.sort();
    return r;
}

private bool isDigits(const(char)[] s) @safe pure nothrow @nogc
{
    if (!s.length)
        return false;
    foreach (c; s)
        if (c < '0' || c > '9')
            return false;
    return true;
}

// ---------------------------------------------------------------------------
// Reporting

/**
Render a failure for a human: the expectation, what the formatter produced,
and the diff between them — each in its own titled box, and side by side when
the terminal is wide enough to hold them.

Both sides are also **written to disk**, under `.result/dmd-fmt-cases/` at the
repository root, and each box's footer names its file relative to the working
directory. A report is a snapshot; the artifacts are the thing itself, and a
whitespace defect is often easier to settle with `diff`, `cmp`, `xxd` or an
editor than by reading two columns of near-identical D. The files outlive the
run on purpose — [clearArtifacts] is what removes them, so a passing sweep
starts clean and whatever is left afterwards belongs to a failure that just
happened.

When `hue` is on `PATH` and the terminal takes colour, all three panes go
through it — this repository's own viewer, so a formatting failure is read
with the same syntax highlighting and the same diff view as the code it is
about. Five flags make it usable as a *pane* rather than a page:
`--diff-show-formatting` (a formatter's diff is nearly always whitespace-only,
and hue folds such a hunk to a badge unless asked not to — with no keystroke
to expand it in a one-shot render), `--no-diff-chrome` and `--no-line-numbers`
(the file header, the `@@` bands and the gutter say what the box's own title
and footer already say), `--diff-context` (passed the file's own line count:
with the bands suppressed, an elided region would be invisible), and `--width`
(a pipe has no size to ask for, so hue would otherwise lay out at its
80-column fallback regardless of the pane it is going into).

All three panes render at [paneBackground]. Mind that mode: a diff's row tints
and its intra-line emphasis are *backgrounds*, so `no-background`
(`BgEmit.none`, foreground only) erases the very signal the diff pane carries.

Everything degrades: no `hue`, no colour, or any failure invoking it falls
back to plain text with a unified diff. A test report that cannot be produced
is worse than a plain one — and the artifacts are written either way.
*/
string renderFailure(const CaseResult r, string artifacts = artifactDir)
    @system
{
    if (!r.expected.length && !r.actual.length)
        return "";

    const width = reportWidth();
    Artifacts art = writeArtifacts(r, artifacts);
    Pane[3] panes = [
        Pane("expected", r.expected, art.expectedLabel),
        Pane("actual", r.actual, art.actualLabel),
        Pane("diff", unifiedDiff(r.expected, r.actual), null),
    ];

    // Plan on the plain text first. hue shrink-wraps to the same content, so
    // the boxes come out the same width either way — which means the layout
    // decision holds, and planning first is what lets each pane be told the
    // width it has to fill.
    const plan = planLayout(panes[], width);
    Pane[3] styled;
    if (art.written && huePanes(art, plan, styled))
    {
        foreach (i, ref p; styled)
            p.footer = panes[i].footer;
        panes = styled;
    }
    return "\n" ~ render(panes[], plan);
}

/**
Delete the artifact directory.

Called once at the top of a sweep, so that what is in `.result/dmd-fmt-cases/`
afterwards is exactly what this run produced. Without it a case that has since
been fixed leaves its old expected/actual pair sitting next to a live one, and
the two are indistinguishable — a stale artifact is worse than none, because
it looks current.
*/
void clearArtifacts() @system
{
    import std.file : exists, rmdirRecurse;

    const dir = artifactDir;
    try
        if (dir.length && dir.exists)
            rmdirRecurse(dir);
    catch (Exception)
    {
    }
}

/// Where a failure's two sides landed, and how to name them to a reader.
private struct Artifacts
{
    bool written;
    /// Absolute — what `hue` is handed.
    string expectedPath, actualPath;
    /// Relative to `getcwd` — what the footer shows and a person types.
    string expectedLabel, actualLabel;
}

/// `<repo>/.result/dmd-fmt-cases`, or empty when the root cannot be found.
private string artifactDir() @safe
{
    import std.file : exists;
    import std.path : buildPath, dirName;

    // The source tree's own location: five directories up from
    // `libs/dmd-fmt/src/sparkles/dmd_fmt/cases.d`. Checked rather than
    // trusted, since a binary can outlive the checkout it was built from.
    enum compiled = __FILE_FULL_PATH__
        .dirName.dirName.dirName.dirName.dirName;
    const root = buildPath(compiled, "dub.sdl").exists ? compiled : cwdOrEmpty;
    return root.length ? buildPath(root, ".result", "dmd-fmt-cases") : null;
}

private string cwdOrEmpty() @trusted nothrow
{
    import std.file : getcwd;

    try
        return getcwd();
    catch (Exception)
        return null;
}

/// Write both sides next to each other under [artifactDir], named after the
/// case that produced them, and report where they went. A failure to write is
/// not a test failure: the report still renders, only without the footers.
private Artifacts writeArtifacts(const CaseResult r, string dir = artifactDir)
    @system
{
    import std.file : mkdirRecurse, write;
    import std.path : baseName, buildPath, relativePath, stripExtension;

    Artifacts art;
    if (!dir.length)
        return art;

    const stem = (r.file.length ? r.file.baseName.stripExtension : "case")
        ~ "-" ~ r.line.to!string ~ "-" ~ slug(r.label);
    try
    {
        mkdirRecurse(dir);
        art.expectedPath = buildPath(dir, stem ~ ".expected.d");
        art.actualPath = buildPath(dir, stem ~ ".actual.d");
        write(art.expectedPath, r.expected);
        write(art.actualPath, r.actual);
        art.written = true;
        art.expectedLabel = shortestPath(art.expectedPath);
        art.actualLabel = shortestPath(art.actualPath);
    }
    catch (Exception)
        art.written = false;
    return art;
}

/// The path as a reader would type it: relative to the working directory when
/// that is shorter (the common case — a sweep is run from the repo root), and
/// absolute when it is not (a run from elsewhere, where `../../..` helps
/// nobody).
private string shortestPath(string path) @safe
{
    import std.path : relativePath;

    const here = cwdOrEmpty;
    if (!here.length)
        return path;
    try
    {
        const rel = relativePath(path, here);
        return rel.length && rel.length < path.length ? rel : path;
    }
    catch (Exception)
        return path;
}

/// A case label (`P22 [After]`, `P32 [indent_size=2]`) as one filename-safe
/// token, so two failures in one page cannot overwrite each other.
private string slug(string label) @safe
{
    import std.ascii : isAlphaNum;

    auto out_ = appender!string;
    bool lastDash;
    foreach (char c; label)
    {
        if (c.isAlphaNum)
        {
            out_ ~= c;
            lastDash = false;
        }
        else if (!lastDash)
        {
            out_ ~= '-';
            lastDash = true;
        }
    }
    const s = out_[].stripRight("-");
    return s.length ? s : "case";
}

/// One report pane: what it is, the block of text that shows it, and the file
/// it was written to (empty when the artifact could not be written).
private struct Pane
{
    string title;
    string body_;
    string footer;
}

/// What the panes will look like, decided before any of them is rendered for
/// real: whether the two code panes share a row, whether the paths go in the
/// borders, and the width every box is drawn at.
private struct Layout
{
    size_t columns;   /// 2 panes on the first row, or 1 (everything stacked).
    bool footers;     /// Paths in the bottom borders, or on their own lines.
    size_t boxWidth;  /// Total width of every box, frame included.
    size_t pairRows;  /// Content rows in each of the two side-by-side boxes.

    /// What a pane has to fill for `--background=full` to reach the frame
    /// instead of stopping where the text happens to end. `drawBox` frames a
    /// row as `│ ` + content + ` │`, so four cells.
    size_t inner() const @safe pure nothrow @nogc
        => boxWidth > 4 ? boxWidth - 4 : 0;
}

/**
Choose the layout for a terminal `width` columns wide.

**Every box is the same width** — the widest any of the three needs, whether
that comes from a line of code, a title or a footer path. Three panes at three
widths is three left edges and three right edges for the eye to track, and the
whole point of the report is comparing two near-identical texts: a difference
of two columns of indentation has to be the most obvious thing on screen, not
the second-most after a ragged frame. Equal widths also mean expectation and
actual line up character-for-character, so a change of *length* shows as one
box's text running past where the other's stopped.

**Two columns, never three.** Expectation and actual go side by side, because
they are the pair being compared; the diff goes underneath at the same width.
The diff is a different kind of thing — it is *about* the pair rather than a
member of it — and reading it wants the eye moving down a column of `-`/`+`
markers, not across a third pane whose rows do not correspond to the two
beside it.

Below `2 × boxWidth + gap` there is no room for even that, and all three
stack.

A footer is as wide as the path it names, which is usually wider than the D it
sits under, so drawing the paths in the borders can widen every box past what
the terminal holds. When it would, the panes are drawn bare and the paths go
on their own lines underneath: the same information, and the columns kept.

The boxes are measured rather than predicted — `drawBox` decides a width from
content, title *and* footer, and re-deriving that rule here would be a second
copy of it, free to drift.
*/
private Layout planLayout(const Pane[] panes, size_t width) @system
{
    Layout best;
    // Footers first, so an equal outcome keeps them: the paths are worth more
    // in the borders, next to the pane they name, than in a list underneath.
    foreach (footers; [true, false])
    {
        Layout plan;
        plan.footers = footers;
        plan.boxWidth = uniformWidth(boxesFor(panes, footers, 0));
        plan.pairRows = pairHeight(panes);
        plan.columns = 2 * plan.boxWidth + paneGap <= width ? 2 : 1;
        if (best.boxWidth == 0 || plan.columns > best.columns)
            best = plan;
    }
    return best;
}

/**
Content rows in each of the two boxes that share a row.

Equal *height*, for the same reason as equal width: the pair is read as one
picture, and a short expectation next to a long actual leaves the eye
resolving which of two bottom borders it just crossed. The taller one sets it;
the shorter is padded (by hue, so the padding is painted like the rest, or
with blank lines on the plain path).

The diff box is excluded — it is under them, not beside them, and stretching
it to match would only add empty rows to the pane that already says the most.
*/
private size_t pairHeight(const Pane[] panes) @safe
{
    import std.algorithm : max;
    import std.string : lineSplitter;

    size_t rows;
    foreach (p; panes[0 .. panes.length < 2 ? panes.length : 2])
    {
        size_t n;
        foreach (_; p.body_.lineSplitter)
            ++n;
        rows = max(rows, n);
    }
    return rows;
}

/// The width every box is drawn at: the widest one's, so none is padded to a
/// size that hides how long its lines actually are.
private size_t uniformWidth(const string[] boxes) @safe
{
    import std.algorithm : max;

    size_t w;
    foreach (box; boxes)
        w = max(w, blockWidth(box));
    return w;
}

/// Plan and render in one step — what the tests use, and what a caller with
/// no hue in the picture needs.
private string composePanes(const Pane[] panes, size_t width) @system
    => render(panes, planLayout(panes, width));

private string render(const Pane[] panes, in Layout plan) @system
{
    auto padded = panes.dup;
    if (plan.columns >= 2)
        foreach (i; 0 .. padded.length < 2 ? padded.length : 2)
            padded[i].body_ = padTo(padded[i].body_, plan.pairRows);
    const boxes = boxesFor(padded, plan.footers, plan.boxWidth);
    return assemble(boxes, plan.columns)
        ~ (plan.footers ? "" : pathLines(panes));
}

/// `body_` with blank lines appended until it has `rows` of them. The
/// hue-rendered panes come back already padded (`--height`), so this is the
/// plain path's half of the same rule.
private string padTo(string body_, size_t rows) @safe
{
    import std.string : lineSplitter;

    size_t have;
    foreach (_; body_.lineSplitter)
        ++have;
    if (have >= rows)
        return body_;
    auto out_ = appender!string;
    out_ ~= body_;
    if (body_.length && body_[$ - 1] != '\n')
        out_ ~= '\n';
    foreach (_; have .. rows)
        out_ ~= '\n';
    return out_[];
}

/// The panes as boxes, every one `minWidth` wide (0 = each its own natural
/// width, which is how [planLayout] discovers what that common width is).
private string[] boxesFor(const Pane[] panes, bool footers, size_t minWidth)
    @system
{
    import sparkles.ui.components.box : BoxProps, drawBox;
    import std.algorithm : map;
    import std.array : array;

    return panes
        .map!(p => drawBox(p.body_, p.title,
            BoxProps(footer: footers ? p.footer : null, minWidth: minWidth)))
        .array;
}

private enum size_t paneGap = 2;

private string assemble(const string[] boxes, size_t columns) @safe
{
    import sparkles.ui.components.layout : hjoin;
    import std.array : join;

    if (columns >= 2 && boxes.length >= 2)
        return hjoin(boxes[0 .. 2], paneGap) ~ "\n" ~ boxes[2 .. $].join("\n");
    return boxes.join("\n");
}

/// The artifact paths as their own lines, for the layout that could not
/// afford them in the borders.
private string pathLines(const Pane[] panes) @safe
{
    string out_;
    foreach (p; panes)
        if (p.footer.length)
            out_ ~= "\n" ~ p.title ~ ": " ~ p.footer;
    return out_;
}

/// The widest visible line of a rendered block — the column count it occupies
/// once ANSI styling is discounted.
private size_t blockWidth(string block) @safe
{
    import sparkles.base.text.grapheme : visibleWidth;
    import std.algorithm : max;
    import std.string : lineSplitter;

    size_t w;
    foreach (line; block.lineSplitter)
        w = max(w, visibleWidth(line));
    return w;
}

/// Columns to lay the report out in: the terminal's, or a readable default
/// when there is none (a redirected run still produces a sensible report).
private size_t reportWidth() @system
{
    import sparkles.base.term_caps : StdStream, terminalSize;

    const w = terminalSize(StdStream.stdout).width;
    return w > 0 ? cast(size_t) w : 100;
}

/**
How a pane's background paints (hue's `--background`).

`full` — every cell, the theme's page colour behind the rest — because the
panes are now *framed*. A box gives the block an edge, so a filled interior
reads as an editor pane rather than as colour spilled across the terminal;
unframed, the same fill had nothing to stop it and no shape to be.

The other two modes stay one word away, and the choice is not free:

$(LIST
    * `spans` paints only what a span asked for. The diff's four tints
        (added/removed row, added/removed emphasis) survive any of the three
        — they are span backgrounds — but on a code pane `spans` paints the
        page colour onto each line's indentation and nothing else, which
        reads as stray blocks.
    * `no-background` is `BgEmit.none`: foreground only. It erases the diff's
        tints outright, which is how the diff pane first shipped monochrome.
)
*/
private enum paneBackground = "full";

/// Fill `out_` with hue-rendered pane bodies, or return false and leave the
/// caller's plain ones alone. False covers every reason at once: no `hue`, no
/// colour, an older `hue` that rejects one of the flags, a process that failed.
/// The files are the ones [writeArtifacts] already wrote — hue reads the same
/// bytes the reader can open afterwards, so the panes and the artifacts cannot
/// disagree.
private bool huePanes(in Artifacts art, in Layout plan, out Pane[3] out_)
    @system
{
    import std.algorithm : count, max;
    import std.process : execute;

    if (!hueUsable)
        return false;

    try
    {
        string run(size_t rows, string[] argv)
        {
            auto cmd = ["hue", "--background=" ~ paneBackground,
                "--width=" ~ plan.inner.to!string];
            // `--height` only for the pair that shares a row: hue pads to it,
            // so the added rows are painted like the rest instead of the
            // blank strip padding the box ourselves would leave.
            if (rows)
                cmd ~= "--height=" ~ rows.to!string;
            const res = execute(cmd ~ argv);
            return res.status == 0 ? res.output.stripRight("\n") : null;
        }

        const pairRows = plan.columns >= 2 ? plan.pairRows : 0;
        const expected = run(pairRows, ["view", "--ansi",
            "--no-line-numbers", art.expectedPath]);
        const actual = run(pairRows, ["view", "--ansi",
            "--no-line-numbers", art.actualPath]);
        // Enough context to reach both ends of the file. hue's default window
        // is three lines, and with the elision bands suppressed a truncated
        // pane would be indistinguishable from a complete one — the diff must
        // show the same region the other two panes do.
        const lines = max(expected.count('\n'), actual.count('\n')) + 2;
        const diff = run(0, ["diff", "--ansi",
            "--diff-show-formatting",
            "--no-diff-chrome", "--no-line-numbers",
            "--diff-context=" ~ lines.to!string,
            art.expectedPath, art.actualPath]);
        if (!expected.length || !actual.length || !diff.length)
            return false;

        out_ = [
            Pane("expected", expected),
            Pane("actual", actual),
            Pane("diff", diff),
        ];
        return true;
    }
    catch (Exception)
        return false;
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
    // check that catches the day it stops being impossible. `fixedpoint`
    // because not changing the input is this case's whole subject.
    enum md = "<!-- fmt id=P19 fixedpoint -->\n\n::: code-group\n\n"
        ~ "```d [Before]\nint a;\n```\n\n```d [After]\nint a;\n```\n\n:::\n";
    foreach (r; runCase(parseCases(md)[0]))
        assert(r.ok, r.error);
}

@("cases.run.an-already-formatted-input-is-a-failure")
@system unittest
{
    // `TST16`: a Before that is already its own After shows the reader
    // nothing. The opt-out is a claim about the rule, so it has to be written
    // down — the version without it fails.
    enum inert = "<!-- fmt id=P19 -->\n\n::: code-group\n\n"
        ~ "```d [Before]\nint a;\n```\n\n```d [After]\nint a;\n```\n\n:::\n";
    const results = runCase(parseCases(inert)[0]);
    assert(results.length == 1 && !results[0].ok);
    assert(results[0].error.canFind("already formatted"), results[0].error);

    // A case that really does change something is unaffected.
    enum live = "<!-- fmt id=P19 -->\n\n::: code-group\n\n"
        ~ "```d [Before]\nint  a;\n```\n\n```d [After]\nint a;\n```\n\n:::\n";
    foreach (r; runCase(parseCases(live)[0]))
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
    import std.file : exists, rmdirRecurse, tempDir;
    import std.path : buildPath;

    // Its own directory: a passing test must not leave anything in the one a
    // real sweep clears, nor race that sweep for it.
    const dir = buildPath(tempDir, "sparkles-dmd-fmt-report-test");
    scope (exit)
        if (dir.exists)
            rmdirRecurse(dir);

    CaseResult r;
    r.expected = "int a;\n";
    r.actual = "int  a;\n";
    const report = renderFailure(r, dir);
    // The pane names live in the box borders, not in band above them.
    assert(report.canFind("expected"), report);
    assert(report.canFind("actual"), report);
    assert(report.canFind("diff"), report);
    assert(report.canFind("int  a;"), report);
    // Empty on both sides is not a diff worth printing — and writes nothing.
    assert(renderFailure(CaseResult.init, dir) == "");
}

@("cases.report.two-columns-of-equal-width")
@system unittest
{
    import std.string : lineSplitter;

    // Three panes of deliberately different natural widths.
    const panes = [
        Pane("expected", "int a;\n", null),
        Pane("actual", "int  a;    // a much longer line\n", null),
        Pane("diff", "- int a;\n+ int  a;    // a much longer line\n", null),
    ];

    size_t[] widths(string s)
    {
        import sparkles.base.text.grapheme : visibleWidth;

        size_t[] out_;
        foreach (line; s.lineSplitter)
            if (line.length)
                out_ ~= visibleWidth(line);
        return out_;
    }

    // Wide: expected and actual share a row, the diff sits under them. Every
    // box is the same width, so a two-box row is exactly twice a one-box row
    // plus the gap — which is the check that they really are equal.
    const wide = composePanes(panes, 200);
    auto ws = widths(wide);
    size_t pair, single;
    foreach (w; ws)
    {
        if (w > pair)
            pair = w;
        if (single == 0 || (w < single && w > 0))
            single = w;
    }
    assert(pair == 2 * single + paneGap,
        pair.to!string ~ " vs " ~ single.to!string);

    // Narrow: no room for two, so all three stack — and stay equal.
    const narrow = composePanes(panes, 20);
    foreach (w; widths(narrow))
        assert(w == widths(narrow)[0], narrow);

    // A pane is never dropped, whatever the width.
    foreach (report; [wide, narrow])
        foreach (p; panes)
            assert(report.canFind(p.title), report);
}

@("cases.report.paired-boxes-are-the-same-height")
@system unittest
{
    import std.algorithm : count;
    import std.string : lineSplitter;

    // Actual is four lines, expected one.
    const panes = [
        Pane("expected", "int a;\n", null),
        Pane("actual", "int  a;\nint b;\nint c;\nint d;\n", null),
        Pane("diff", "- int a;\n+ int  a;\n", null),
    ];

    const report = composePanes(panes, 200);
    // Two side by side and one below: three top borders, three bottom ones,
    // and the pair's bottoms share a line, so five lines carry a corner.
    size_t tops, bottoms;
    foreach (line; report.lineSplitter)
    {
        tops += line.canFind("╭") ? 1 : 0;
        bottoms += line.canFind("╰") ? 1 : 0;
    }
    assert(tops == 2, report);       // pair on one line, diff on its own
    assert(bottoms == 2, report);    // the pair closes together
    assert(report.canFind("╰") && report.count("╰") == 3, report);
}

@("cases.artifacts.both-sides-land-on-disk")
@system unittest
{
    import std.file : exists, mkdirRecurse, readText, rmdirRecurse, tempDir;
    import std.path : baseName, buildPath;

    const dir = buildPath(tempDir, "sparkles-dmd-fmt-artifact-test");
    scope (exit)
        if (dir.exists)
            rmdirRecurse(dir);

    CaseResult r;
    r.file = "/somewhere/declarations.md";
    r.line = 9;
    r.label = "P22 [After]";
    r.expected = "int a;\n";
    r.actual = "int  a;\n";

    const art = writeArtifacts(r, dir);
    assert(art.written);
    // Named after the case, so two failures in one page cannot collide.
    assert(art.expectedPath.baseName == "declarations-9-P22-After.expected.d",
        art.expectedPath);
    assert(art.actualPath.baseName == "declarations-9-P22-After.actual.d",
        art.actualPath);
    // The bytes on disk are the case's, verbatim — this is what a person
    // opens in an editor or feeds to `diff`.
    assert(art.expectedPath.readText == r.expected);
    assert(art.actualPath.readText == r.actual);
    assert(art.expectedLabel.length && art.actualLabel.length);

    // An unwritable directory is not a test failure: the report degrades to
    // no footers rather than throwing over a diagnostic.
    const nowhere = writeArtifacts(r, "/proc/nonexistent/dir");
    assert(!nowhere.written);
}

@("cases.artifacts.footers-yield-to-a-column")
@system unittest
{
    import std.algorithm : canFind;
    import std.string : lineSplitter;

    const long_ = ".result/dmd-fmt-cases/declarations-9-P22-After.expected.d";
    const panes = [
        Pane("expected", "int a;\n", long_),
        Pane("actual", "int  a;\n", long_[0 .. $ - 10] ~ ".actual.d"),
        Pane("diff", "- int a;\n+ int  a;\n", null),
    ];

    // Wide enough for three footered boxes: the path is drawn in the border.
    const wide = composePanes(panes, 300);
    assert(wide.canFind("╭──╼ expected ╾"), wide);
    foreach (line; wide.lineSplitter)
        if (line.canFind(long_))
            assert(line.canFind("╰"), "the path sits in the bottom border");

    // Too narrow for that, but wide enough for three bare ones: the paths
    // move out of the borders rather than costing a column.
    const tight = composePanes(panes, 70);
    assert(tight.canFind("\nexpected: " ~ long_), tight);
    foreach (line; tight.lineSplitter)
        if (line.canFind(long_))
            assert(!line.canFind("╰"), "the border no longer carries it");
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

@("cases.inventory.reads-id-and-verdict")
@safe unittest
{
    enum md = "| #   | Decision | Source | Verdict |\n"
        ~ "| --- | -------- | ------ | ------- |\n"
        ~ "| P19 | Blank lines collapse | [seq][seq] | **Have** |\n"
        ~ "| P90 | Fluid assignment | [asg][asg] | **Adopt** |\n"
        ~ "| P155 | An IES rewrite | this survey | **Codemod** |\n"
        ~ "not a row, and | this | is not one either |\n";
    const rows = parseInventory(md);
    assert(rows.length == 3, "prose containing pipes is not a row");
    assert(rows[0] == Decision("P19", "Have"));
    assert(rows[1] == Decision("P90", "Adopt"));
    assert(!rows[0].requiresCase, "an already-made decision owes no case");
    assert(rows[1].requiresCase);
    assert(!rows[2].requiresCase, "a codemod is not the formatter's to make");
}

@("cases.coverage.every-decision-has-a-case-or-a-ledger-entry")
@system unittest
{
    import std.path : dirName;

    enum thisDir = __FILE_FULL_PATH__.dirName;
    enum repoRoot = thisDir.dirName.dirName.dirName.dirName.dirName;

    const r = checkDecisionCoverage(repoRoot);
    string report;
    foreach (id; r.missing)
        report ~= "\n  " ~ id ~ " — scored for D, has no case, and is not in "
            ~ uncoveredLedger;
    foreach (id; r.stale)
        report ~= "\n  " ~ id ~ " — now has a case; delete its line from "
            ~ uncoveredLedger;
    foreach (id; r.dangling)
        report ~= "\n  " ~ id ~ " — named by a case, but neither the"
            ~ " inventory nor the decision record defines it";
    assert(r.ok, "decision coverage:" ~ report);
    assert(r.required > 0, "the inventory parsed to nothing — wrong path?");
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

    // One sweep, one clean directory: whatever survives belongs to a failure
    // this run produced.
    clearArtifacts();

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
