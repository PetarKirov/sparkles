/**
Fence audit: enumerate every fenced code block in the documentation, classify
its language label against the tree-sitter grammar bundle, and inventory the
VitePress-specific code-block features a highlighter swap has to preserve.

The audit exists because the docs site is about to swap Shiki for `hue`
(`sparkles:syntax` + the tree-sitter grammar bundle) behind VitePress's
`markdown.highlight` hook. Before that swap, three questions need answers that
are counted rather than guessed:

$(LIST
    $(ITEM Which fence labels are $(B grammar-backed) — a grammar exists in
        `$SPARKLES_TS_GRAMMAR_PATH` for the canonical language name?)
    $(ITEM Which are $(B plain text by design) — `text`, `ansi` and friends,
        where no highlighting is the correct output, not a regression?)
    $(ITEM Which are $(B uncovered) — a real language with no bundled grammar,
        which would silently lose the coloring Shiki gives it today?)
)

Label folding goes through `sparkles.syntax.ts.registry.canonicalLanguage` and
`isPlainTextLabel`, so the audit and the renderer agree by construction; the
alias table is never duplicated here.

The fourth question the audit answers is not about languages at all: a
`markdown.highlight` hook receives the code and the language, and everything
VitePress layers on top of the highlighted HTML — `[!code highlight]` markers,
`{1,3-5}` line ranges, `code-group` titles, `twoslash`, mermaid — regresses
silently if the new seam does not reimplement it. `scanFeatures` inventories
those with `file:line` provenance.
*/
module fence_audit;

import std.algorithm : canFind, filter, map, sort, startsWith, sum;
import std.array : appender, array, join;
import std.conv : to;
import std.string : lineSplitter, strip, stripRight;

import sparkles.syntax.ts.registry : canonicalLanguage, GrammarRegistry, isPlainTextLabel;

// === Fence scanning ===

/// One fenced code block, as found in a markdown file.
struct Fence
{
    /// Repo-relative path of the containing file.
    string file;
    /// 1-based line of the opening fence.
    size_t line;
    /// 1-based line of the closing fence; `0` when the block is never closed.
    size_t endLine;
    /// The info string, verbatim (trimmed of surrounding whitespace).
    string info;
    /// The language label: the info string's first token, minus attributes.
    string label;
    /// Whatever followed the label in the info string (`{1,3}`, `[title]`, …).
    string attrs;
    /// `0` for a fence the site highlights; `1`+ for one nested inside a
    /// wrapper fence (a ` ```` ` block quoting markdown), which is content of
    /// the wrapper, not a block VitePress highlights on its own.
    size_t depth;
    /// Leading spaces on the opening fence line.
    size_t indent;
    /// Number of marker characters on the opening fence (3, 4, …).
    size_t markerLen;
    /// The marker character: '`' or '~'.
    char marker;
    /// The fence sits inside a `::: code-group` container.
    bool inCodeGroup;
    /// The block's content lines (empty for an empty block).
    string[] bodyLines;
}

/// The two halves of an info string: `js {1,3-5} twoslash` is label `js`,
/// attrs `{1,3-5} twoslash`.
struct InfoString
{
    /// The language label.
    string label;
    /// The remainder, trimmed.
    string attrs;
}

/**
Splits an info string into its language label and the attributes VitePress
layers on top of it.

The label ends at whitespace, at `{` (a line-range attribute, written with no
separating space: `js{1,4}`) or at `:` (a per-block option such as
`:no-line-numbers`). A bracketed info string is kept whole as the label, so a
stray legacy `[Output]` fence surfaces as an odd label instead of quietly
folding into the unlabelled bucket.
*/
InfoString parseInfoString(scope const(char)[] info) @safe pure nothrow
{
    static bool isLabelEnd(char c) @safe pure nothrow @nogc
        => c == ' ' || c == '\t' || c == '{' || c == ':';

    const trimmed = stripAscii(info);
    if (trimmed.length == 0)
        return InfoString.init;

    size_t end;
    if (trimmed[0] == '[')
    {
        // A bracketed token is one unit: the legacy `[Output]` / `[Output:ansi]`
        // output-fence spelling, which must not be split on its inner colon.
        while (end < trimmed.length && trimmed[end] != ']')
            end++;
        if (end < trimmed.length)
            end++; // include the ']'
    }
    else
    {
        while (end < trimmed.length && !isLabelEnd(trimmed[end]))
            end++;
    }

    return InfoString(
        label: trimmed[0 .. end].idup,
        attrs: stripAscii(trimmed[end .. $]).idup,
    );
}

///
@("fence_audit.parseInfoString.cases")
@safe pure nothrow
unittest
{
    assert(parseInfoString("d") == InfoString("d", ""));
    assert(parseInfoString("") == InfoString("", ""));
    assert(parseInfoString("  ts  ") == InfoString("ts", ""));

    // VitePress attributes: line ranges glued to the label, titles, options.
    assert(parseInfoString("js{1,4}") == InfoString("js", "{1,4}"));
    assert(parseInfoString("ts {1,3-5} twoslash") == InfoString("ts", "{1,3-5} twoslash"));
    assert(parseInfoString("js [config.js]") == InfoString("js", "[config.js]"));
    assert(parseInfoString("bash:no-line-numbers") == InfoString("bash", ":no-line-numbers"));
    assert(parseInfoString("d twoslash") == InfoString("d", "twoslash"));

    // A bracketed info string stays whole (legacy output fences).
    assert(parseInfoString("[Output]") == InfoString("[Output]", ""));
    assert(parseInfoString("[Output:ansi]") == InfoString("[Output:ansi]", ""));
}

/// ASCII-only `strip`, so the scanner stays `nothrow` on invalid UTF-8.
private inout(char)[] stripAscii(scope return inout(char)[] s) @safe pure nothrow @nogc
{
    static bool isSpace(char c) @safe pure nothrow @nogc
        => c == ' ' || c == '\t' || c == '\r' || c == '\n';

    size_t b;
    while (b < s.length && isSpace(s[b]))
        b++;
    size_t e = s.length;
    while (e > b && isSpace(s[e - 1]))
        e--;
    return s[b .. e];
}

/// The marker run at the start of `line` (after up to `indent` spaces): the
/// marker character and its length, or `('\0', 0)` when the line does not open
/// or close a fence.
private struct FenceMarker
{
    char marker;
    size_t length;
    size_t indent;
    /// Everything after the marker run, trimmed — the info string on an opener.
    const(char)[] rest;
}

private FenceMarker fenceMarkerOf(return scope const(char)[] line) @safe pure nothrow @nogc
{
    size_t indent;
    while (indent < line.length && (line[indent] == ' ' || line[indent] == '\t'))
        indent++;

    if (indent >= line.length)
        return FenceMarker.init;

    const marker = line[indent];
    if (marker != '`' && marker != '~')
        return FenceMarker.init;

    size_t run = indent;
    while (run < line.length && line[run] == marker)
        run++;

    const length = run - indent;
    if (length < 3)
        return FenceMarker.init;

    return FenceMarker(marker, length, indent, stripAscii(line[run .. $]));
}

/**
The line index just past the closing fence of the wrapper block opened at
`openIdx`, or `0` when that line opens no wrapper or the wrapper is never
closed.

A $(I wrapper) is a fence of four or more markers — the corpus convention for
quoting markdown that itself contains fences. Its interior is content, so a
scanner walking for real code blocks must jump over it wholesale; this is the
shared primitive behind both that skip (`extractExamples` in `app.d`) and the
nesting-aware enumeration below.
*/
size_t wrapperFenceEnd(in string[] lines, size_t openIdx) @safe pure nothrow
{
    if (openIdx >= lines.length)
        return 0;

    const open = fenceMarkerOf(lines[openIdx]);
    if (open.length < 4)
        return 0;

    const close = closingFenceIndex(lines, openIdx, open);
    return close == size_t.max ? 0 : close + 1;
}

///
@("fence_audit.wrapperFenceEnd.skipsQuotedMarkdown")
@safe pure nothrow
unittest
{
    static immutable string[] lines = [
        "````markdown",
        "```d",
        "void main() {}",
        "```",
        "````",
        "after",
    ];

    assert(wrapperFenceEnd(lines, 0) == 5);
    // Not a wrapper: a plain three-marker fence is skipped by the caller's
    // ordinary block handling, not by this helper.
    assert(wrapperFenceEnd(lines, 1) == 0);
    assert(wrapperFenceEnd(lines, 5) == 0);
}

/// Index of the fence line closing the block opened at `openIdx`, or
/// `size_t.max` when the file ends first.
private size_t closingFenceIndex(in string[] lines, size_t openIdx, in FenceMarker open)
    @safe pure nothrow
{
    foreach (i; openIdx + 1 .. lines.length)
    {
        const m = fenceMarkerOf(lines[i]);
        if (m.marker == open.marker && m.length >= open.length && m.rest.length == 0)
            return i;
    }
    return size_t.max;
}

/**
Enumerates every fenced code block in `content`.

Top-level blocks (`depth == 0`) are the ones VitePress highlights. A wrapper
fence's interior is re-scanned at `depth + 1`, so the fences a doc quotes as
$(I examples of markdown) are visible to the audit without polluting the census
of blocks the site actually highlights.

`::: code-group` containers are tracked so a fence can report whether its title
attribute is a code-group tab.
*/
Fence[] scanFences(string file, string content) @safe pure
{
    auto lines = content.lineSplitter.array;
    Fence[] fences;
    scanFenceRange(file, lines, 0, 0, fences);
    return fences;
}

private void scanFenceRange(
    string file,
    in string[] lines,
    size_t lineOffset,
    size_t depth,
    ref Fence[] fences,
) @safe pure
{
    // The container stack: `::: code-group` … `:::`. VitePress containers nest
    // (`::: details` inside a code-group), and a bare `:::` closes the
    // innermost, so a stack — not a flag — is what tracks membership.
    string[] containers;

    size_t idx;
    while (idx < lines.length)
    {
        const marker = fenceMarkerOf(lines[idx]);

        if (marker.length == 0)
        {
            if (depth == 0)
                trackContainer(lines[idx], containers);
            idx++;
            continue;
        }

        // A backtick fence's info string may not contain a backtick
        // (CommonMark §4.5) — such a line is prose, not a fence opener.
        if (marker.marker == '`' && marker.rest.canFind('`'))
        {
            idx++;
            continue;
        }

        const close = closingFenceIndex(lines, idx, marker);
        const bodyEnd = close == size_t.max ? lines.length : close;
        const info = parseInfoString(marker.rest);

        fences ~= Fence(
            file: file,
            line: lineOffset + idx + 1,
            endLine: close == size_t.max ? 0 : lineOffset + close + 1,
            info: stripAscii(marker.rest).idup,
            label: info.label,
            attrs: info.attrs,
            depth: depth,
            indent: marker.indent,
            markerLen: marker.length,
            marker: marker.marker,
            inCodeGroup: containers.canFind("code-group"),
            bodyLines: lines[idx + 1 .. bodyEnd].dup,
        );

        // Only a wrapper can hold fences: inside a three-marker block the next
        // ``` line *is* the closer, so there is nothing nested to find.
        if (marker.length > 3 && close != size_t.max)
            scanFenceRange(file, lines[idx + 1 .. close], lineOffset + idx + 1, depth + 1, fences);

        idx = (close == size_t.max ? lines.length : close) + 1;
    }
}

/// Applies a `:::`-container line to the container stack.
private void trackContainer(scope const(char)[] line, ref string[] containers) @safe pure nothrow
{
    const trimmed = stripAscii(line);
    if (trimmed.length < 3 || trimmed[0] != ':')
        return;

    size_t run;
    while (run < trimmed.length && trimmed[run] == ':')
        run++;
    if (run < 3)
        return;

    const name = stripAscii(trimmed[run .. $]);
    if (name.length == 0)
    {
        if (containers.length)
            containers = containers[0 .. $ - 1];
        return;
    }

    // `::: warning Custom title` — the container type is the first word.
    size_t end;
    while (end < name.length && name[end] != ' ' && name[end] != '\t')
        end++;
    containers ~= name[0 .. end].idup;
}

@("fence_audit.scanFences.nestedAndIndented")
@safe pure
unittest
{
    enum content = "# Doc\n"
        ~ "\n"
        ~ "```d\n"
        ~ "void main() {}\n"
        ~ "```\n"
        ~ "\n"
        ~ "````markdown\n"
        ~ "```rust\n"
        ~ "fn main() {}\n"
        ~ "```\n"
        ~ "````\n"
        ~ "\n"
        ~ "- item:\n"
        ~ "\n"
        ~ "    ```toml\n"
        ~ "    key = 1\n"
        ~ "    ```\n";

    auto fences = scanFences("doc.md", content);
    assert(fences.length == 4, fences.length.to!string);

    assert(fences[0].label == "d" && fences[0].line == 3 && fences[0].endLine == 5);
    assert(fences[0].depth == 0);
    assert(fences[0].bodyLines == ["void main() {}"]);

    // The wrapper itself is a fence (label `markdown`) …
    assert(fences[1].label == "markdown" && fences[1].markerLen == 4);
    assert(fences[1].depth == 0);
    // … and its interior is re-scanned one level down, with absolute line
    // numbers preserved.
    assert(fences[2].label == "rust" && fences[2].depth == 1 && fences[2].line == 8);

    // An indented fence inside a list item is a fence, and knows its indent.
    assert(fences[3].label == "toml" && fences[3].indent == 4 && fences[3].line == 15);
}

@("fence_audit.scanFences.codeGroupAndAttrs")
@safe pure
unittest
{
    enum content = "::: code-group\n"
        ~ "```js [config.js]\n"
        ~ "export default {}\n"
        ~ "```\n"
        ~ "```ts{1,3-5} twoslash\n"
        ~ "const a = 1\n"
        ~ "```\n"
        ~ ":::\n"
        ~ "```text\n"
        ~ "plain\n"
        ~ "```\n";

    auto fences = scanFences("doc.md", content);
    assert(fences.length == 3);

    assert(fences[0].label == "js" && fences[0].attrs == "[config.js]");
    assert(fences[0].inCodeGroup);
    assert(fences[1].label == "ts" && fences[1].attrs == "{1,3-5} twoslash");
    assert(fences[1].inCodeGroup);
    // The bare `:::` closed the container.
    assert(fences[2].label == "text" && !fences[2].inCodeGroup);
}

@("fence_audit.scanFences.tildeAndUnclosed")
@safe pure
unittest
{
    enum content = "~~~python\n"
        ~ "print(1)\n"
        ~ "~~~\n"
        ~ "```yaml\n"
        ~ "a: 1\n";

    auto fences = scanFences("doc.md", content);
    assert(fences.length == 2);
    assert(fences[0].label == "python" && fences[0].marker == '~');
    // A block the file never closes still counts, with `endLine == 0`.
    assert(fences[1].label == "yaml" && fences[1].endLine == 0);
    assert(fences[1].bodyLines == ["a: 1"]);
}

// === Classification ===

/// How a fence label fares under a tree-sitter-backed highlighter.
enum FenceClass
{
    /// A grammar for the canonical language is present in the bundle.
    grammarBacked,
    /// The label asks for no highlighting (`text`, `ansi`, unlabelled …), so
    /// plain output is correct rather than a regression.
    plainText,
    /// A real language label with no bundled grammar: it renders plain, which
    /// is a regression wherever Shiki colors it today.
    uncovered,
}

/// Human-facing name of a classification (also the JSON spelling).
string name(FenceClass cls) @safe pure nothrow @nogc
{
    final switch (cls)
    {
        case FenceClass.grammarBacked: return "grammar-backed";
        case FenceClass.plainText: return "plain-text-by-design";
        case FenceClass.uncovered: return "uncovered";
    }
}

/// Classifies a raw fence label against the set of bundled grammar names.
FenceClass classifyLabel(scope const(char)[] label, in bool[string] bundled) @safe pure nothrow
{
    const canonical = canonicalLanguage(label);
    if (isPlainTextLabel(canonical))
        return FenceClass.plainText;
    return (canonical in bundled) ? FenceClass.grammarBacked : FenceClass.uncovered;
}

///
@("fence_audit.classifyLabel.foldsAliases")
@safe pure nothrow
unittest
{
    bool[string] bundled = ["d": true, "typescript": true, "cpp": true, "sdl": true];

    // Aliases fold through `canonicalLanguage`, so the bundle is consulted
    // under the canonical name only.
    assert(classifyLabel("ts", bundled) == FenceClass.grammarBacked);
    assert(classifyLabel("C++", bundled) == FenceClass.grammarBacked);
    // `sdlang` folds onto the in-house `sdl` grammar; `sdl` itself is already
    // canonical and must NOT fold onto `d`, which would shadow that grammar.
    assert(classifyLabel("sdlang", bundled) == FenceClass.grammarBacked);
    assert(classifyLabel("sdl", bundled) == FenceClass.grammarBacked);

    // No highlighting requested is not a gap.
    assert(classifyLabel("", bundled) == FenceClass.plainText);
    assert(classifyLabel("text", bundled) == FenceClass.plainText);
    assert(classifyLabel("ansi", bundled) == FenceClass.plainText);

    assert(classifyLabel("wat", bundled) == FenceClass.uncovered);
    assert(classifyLabel("haskell", bundled) == FenceClass.uncovered);
}

/// The canonical language names the grammar bundle provides — a directory per
/// language, each holding the compiled `parser`.
bool[string] bundledLanguages(GrammarRegistry registry) @safe
{
    import std.file : dirEntries, exists, isDir, SpanMode;
    import std.path : baseName, buildPath;

    bool[string] langs;
    foreach (dir; registry.dirs)
    {
        if (!dir.exists || !dir.isDir)
            continue;
        foreach (entry; dirEntries(dir, SpanMode.shallow))
        {
            if (!entry.isDir)
                continue;
            if (buildPath(entry.name, "parser").exists)
                langs[entry.name.baseName] = true;
        }
    }
    return langs;
}

// === VitePress feature inventory ===

/// One occurrence of a VitePress code-block feature, with provenance.
struct FeatureHit
{
    /// Feature kind — see `FeatureKind`.
    string kind;
    /// The matched text (the marker, the attribute, the container line …).
    string detail;
    /// Repo-relative path.
    string file;
    /// 1-based line.
    size_t line;
}

/// The feature kinds `scanFeatures` reports.
enum FeatureKind : string
{
    /// A `[!code …]` marker inside a block's body.
    codeMarker = "code-marker",
    /// A `{1,3-5}` line-range attribute on the info string.
    lineRange = "line-range",
    /// A `::: code-group` container opener.
    codeGroup = "code-group",
    /// A `[title]` attribute — a code-group tab title or a block caption.
    blockTitle = "block-title",
    /// A `twoslash` info-string attribute.
    twoslash = "twoslash",
    /// A `mermaid` fence: rendered as a diagram, never highlighted.
    mermaid = "mermaid",
    /// A `:line-numbers` / `:no-line-numbers` per-block option.
    lineNumbers = "line-numbers",
}

/**
Inventories the VitePress-specific features carried by `fences` plus the
`::: code-group` containers in `content`.

Every hit carries `file:line`, because the point of the inventory is a
checklist: each of these is layered on top of the highlighted HTML today, and a
`markdown.highlight` seam that ignores them regresses the page silently.
*/
FeatureHit[] scanFeatures(string file, string content, in Fence[] fences) @safe pure
{
    auto hits = appender!(FeatureHit[]);

    foreach (const ref f; fences)
    {
        // Nested fences are quoted content — the wrapper block is what the site
        // renders, so its interior carries no live VitePress attributes.
        if (f.depth != 0)
            continue;

        if (f.attrs.canFind("twoslash"))
            hits ~= FeatureHit(FeatureKind.twoslash, f.info, file, f.line);
        if (canonicalLanguage(f.label) == "mermaid")
            hits ~= FeatureHit(FeatureKind.mermaid, f.info, file, f.line);
        if (const range = lineRangeAttr(f.attrs))
            hits ~= FeatureHit(FeatureKind.lineRange, range, file, f.line);
        if (const title = bracketAttr(f.attrs))
            hits ~= FeatureHit(FeatureKind.blockTitle, title, file, f.line);
        if (f.attrs.canFind(":line-numbers") || f.attrs.canFind(":no-line-numbers"))
            hits ~= FeatureHit(FeatureKind.lineNumbers, f.attrs, file, f.line);

        foreach (i, bodyLine; f.bodyLines)
        {
            if (const marker = codeMarkerOf(bodyLine))
                hits ~= FeatureHit(FeatureKind.codeMarker, marker, file, f.line + i + 1);
        }
    }

    // Containers live between fences, so they are found on the raw text — with
    // fence bodies masked out, so a `::: code-group` quoted inside a block is
    // not counted as a live container.
    foreach (i, line; content.lineSplitter.array)
    {
        const lineNo = i + 1;
        if (fences.canFind!(f => f.depth == 0 && f.line < lineNo
                && (f.endLine == 0 || lineNo <= f.endLine)))
            continue;
        const trimmed = stripAscii(line);
        if (trimmed.startsWith(":::") && trimmed.canFind("code-group"))
            hits ~= FeatureHit(FeatureKind.codeGroup, trimmed.idup, file, lineNo);
    }

    return hits[];
}

/// The `{…}` line-range attribute in an info string, or `null`.
private string lineRangeAttr(scope const(char)[] attrs) @safe pure nothrow
{
    size_t open;
    while (open < attrs.length && attrs[open] != '{')
        open++;
    if (open == attrs.length)
        return null;

    size_t close = open + 1;
    while (close < attrs.length && attrs[close] != '}')
        close++;
    if (close == attrs.length)
        return null;

    return attrs[open .. close + 1].idup;
}

/// The `[…]` title attribute in an info string, or `null`.
private string bracketAttr(scope const(char)[] attrs) @safe pure nothrow
{
    size_t open;
    while (open < attrs.length && attrs[open] != '[')
        open++;
    if (open == attrs.length)
        return null;

    size_t close = open + 1;
    while (close < attrs.length && attrs[close] != ']')
        close++;
    if (close == attrs.length)
        return null;

    return attrs[open .. close + 1].idup;
}

/// The `[!code …]` marker on a body line, or `null`.
private string codeMarkerOf(scope const(char)[] line) @safe pure nothrow
{
    enum needle = "[!code ";
    if (line.length < needle.length)
        return null;

    foreach (start; 0 .. line.length - needle.length + 1)
    {
        if (line[start .. start + needle.length] != needle)
            continue;
        size_t close = start + needle.length;
        while (close < line.length && line[close] != ']')
            close++;
        if (close == line.length)
            return null;
        return line[start .. close + 1].idup;
    }
    return null;
}

@("fence_audit.scanFeatures.inventory")
@safe pure
unittest
{
    enum content = "::: code-group\n"
        ~ "```js [config.js] {2}\n"
        ~ "const a = 1\n"
        ~ "const b = 2 // [!code highlight]\n"
        ~ "const c = 3 // [!code ++]\n"
        ~ "```\n"
        ~ ":::\n"
        ~ "```d twoslash\n"
        ~ "void main() {}\n"
        ~ "```\n"
        ~ "```mermaid\n"
        ~ "graph TD;\n"
        ~ "```\n"
        ~ "```bash:no-line-numbers\n"
        ~ "ls\n"
        ~ "```\n";

    auto fences = scanFences("doc.md", content);
    auto hits = scanFeatures("doc.md", content, fences);

    string[] kinds = hits.map!(h => h.kind).array;
    assert(kinds.canFind(cast(string) FeatureKind.codeGroup), kinds.join(","));
    assert(kinds.canFind(cast(string) FeatureKind.blockTitle));
    assert(kinds.canFind(cast(string) FeatureKind.lineRange));
    assert(kinds.canFind(cast(string) FeatureKind.twoslash));
    assert(kinds.canFind(cast(string) FeatureKind.mermaid));
    assert(kinds.canFind(cast(string) FeatureKind.lineNumbers));

    auto markers = hits.filter!(h => h.kind == FeatureKind.codeMarker).array;
    assert(markers.length == 2, markers.length.to!string);
    assert(markers[0].detail == "[!code highlight]" && markers[0].line == 4);
    assert(markers[1].detail == "[!code ++]" && markers[1].line == 5);
}

@("fence_audit.scanFeatures.ignoresQuotedContainers")
@safe pure
unittest
{
    // A code-group container quoted inside a fence is documentation about the
    // syntax, not a live container.
    enum content = "````markdown\n"
        ~ "::: code-group\n"
        ~ "```js [a.js]\n"
        ~ "```\n"
        ~ ":::\n"
        ~ "````\n";

    auto fences = scanFences("doc.md", content);
    auto hits = scanFeatures("doc.md", content, fences);
    assert(!hits.canFind!(h => h.kind == FeatureKind.codeGroup));
    // Nor do the nested fence's own attributes count.
    assert(!hits.canFind!(h => h.kind == FeatureKind.blockTitle));
}

// === srcExclude mirror ===

/**
A verbatim copy of the `srcExclude` list in `docs/.vitepress/config.mts` — the
files the docs site does not build into pages.

> [!IMPORTANT]
> This is a $(B mirror), and mirrors drift. The site's list is JavaScript this
> tool cannot evaluate, and parsing `config.mts` from D would be worse than
> duplicating nine globs. The audit therefore never hides the difference: it
> reports the excluded set as its own census alongside the site-visible one,
> and prints the patterns it used, so a mismatch shows up as a file count that
> disagrees with the site rather than as a silently wrong percentage.
*/
immutable string[] srcExcludeMirror = [
    "**/research/parsing/grounding/**",
    "**/research/units-of-measure/grounding/**",
    "**/research/cpu-pmu/grounding/**",
    "**/research/sanitizers/grounding/**",
    "**/research/manim/grounding/**",
    "**/research/application-packaging/PLAN.md",
    "**/research/application-packaging/grounding/**",
    "**/research/sql/grounding/**",
    "**/research/iroh/prompt.md",
];

/**
Glob match with the semantics VitePress's `srcExclude` uses: `**` spans any
number of path segments, `*` matches within one segment, `?` matches a single
non-separator character.
*/
bool matchesGlob(scope const(char)[] path, scope const(char)[] pattern) @safe pure nothrow
{
    if (pattern.length == 0)
        return path.length == 0;

    if (pattern.length >= 2 && pattern[0 .. 2] == "**")
    {
        auto rest = pattern[2 .. $];
        // `**/` also matches zero segments, so `**/a/**` matches `a/b`.
        if (rest.length && rest[0] == '/' && matchesGlob(path, rest[1 .. $]))
            return true;
        foreach (i; 0 .. path.length + 1)
            if (matchesGlob(path[i .. $], rest))
                return true;
        return false;
    }

    if (pattern[0] == '*')
    {
        foreach (i; 0 .. path.length + 1)
        {
            if (i > 0 && path[i - 1] == '/')
                break;
            if (matchesGlob(path[i .. $], pattern[1 .. $]))
                return true;
        }
        return false;
    }

    if (pattern[0] == '?')
        return path.length > 0 && path[0] != '/' && matchesGlob(path[1 .. $], pattern[1 .. $]);

    return path.length > 0 && path[0] == pattern[0]
        && matchesGlob(path[1 .. $], pattern[1 .. $]);
}

///
@("fence_audit.matchesGlob.doubleStar")
@safe pure nothrow
unittest
{
    assert(matchesGlob("docs/research/sql/grounding/notes.md", "**/research/sql/grounding/**"));
    assert(matchesGlob("docs/research/sql/grounding/a/b.md", "**/research/sql/grounding/**"));
    assert(!matchesGlob("docs/research/sql/index.md", "**/research/sql/grounding/**"));
    assert(matchesGlob("docs/research/iroh/prompt.md", "**/research/iroh/prompt.md"));
    assert(!matchesGlob("docs/research/iroh/prompts.md", "**/research/iroh/prompt.md"));

    // `*` stays within a segment.
    assert(matchesGlob("docs/a.md", "docs/*.md"));
    assert(!matchesGlob("docs/sub/a.md", "docs/*.md"));
}

/// `true` when the docs site excludes `path` from the built site.
bool isSrcExcluded(scope const(char)[] path) @safe pure nothrow
    => srcExcludeMirror.canFind!(p => matchesGlob(path, p));

///
@("fence_audit.isSrcExcluded.mirror")
@safe pure nothrow
unittest
{
    assert(isSrcExcluded("docs/research/parsing/grounding/claims.md"));
    assert(isSrcExcluded("docs/research/application-packaging/PLAN.md"));
    assert(!isSrcExcluded("docs/research/parsing/index.md"));
    assert(!isSrcExcluded("README.md"));
}

// === Aggregation ===

/// Which files the primary census covers.
enum AuditScope
{
    /// Only files the docs site builds into pages (the default: these are the
    /// blocks the highlighter swap actually affects).
    site,
    /// Every scanned file, `srcExclude`d ones included.
    all,
    /// Only the `srcExclude`d files.
    excluded,
}

/// Per-label census row.
struct LabelStat
{
    /// The label as written in the info string.
    string label;
    /// Its canonical grammar name.
    string canonical;
    /// Classification of `canonical` against the bundle.
    FenceClass cls;
    /// Number of top-level fences carrying this label.
    size_t count;
    /// Number of distinct files carrying it.
    size_t files;
    /// `file:line` of the first occurrence.
    string firstSeen;
}

/// The full audit result.
struct AuditResult
{
    /// Files scanned into the primary census.
    size_t filesScanned;
    /// Files skipped because the site excludes them (only when scoped `site`).
    size_t filesExcluded;
    /// Top-level fences (what VitePress highlights).
    size_t fences;
    /// Fences nested inside wrapper blocks (quoted markdown; not highlighted).
    size_t nestedFences;
    /// Blocks whose closing fence is missing.
    size_t unclosedFences;
    /// Per-label rows, most frequent first.
    LabelStat[] labels;
    /// VitePress feature occurrences.
    FeatureHit[] features;
    /// Grammar names present in the bundle.
    size_t bundledGrammars;
}

/// Fence count for one classification.
size_t fenceCount(in AuditResult r, FenceClass cls) @safe pure nothrow
    => r.labels.filter!(l => l.cls == cls).map!(l => l.count).sum;

/// Distinct-label count for one classification.
size_t labelCount(in AuditResult r, FenceClass cls) @safe pure nothrow
    => r.labels.filter!(l => l.cls == cls).map!(l => size_t(1)).sum;

/// One scanned file: its path and contents.
struct MarkdownFile
{
    /// Repo-relative path.
    string path;
    /// The file's full text.
    string content;
}

/**
Runs the census over already-read files.

Kept separate from I/O so the aggregation is unit-testable: `runFenceAudit`
reads the files, this decides what the numbers are.
*/
AuditResult auditFiles(in MarkdownFile[] files, in bool[string] bundled, AuditScope scope_)
    @safe pure
{
    AuditResult result;
    result.bundledGrammars = bundled.length;

    LabelStat[string] byLabel;
    bool[string][string] filesByLabel;

    foreach (const ref file; files)
    {
        const excluded = isSrcExcluded(file.path);
        final switch (scope_)
        {
            case AuditScope.site:
                if (excluded)
                {
                    result.filesExcluded++;
                    continue;
                }
                break;
            case AuditScope.excluded:
                if (!excluded)
                    continue;
                break;
            case AuditScope.all:
                break;
        }

        result.filesScanned++;

        auto fences = scanFences(file.path, file.content);
        result.features ~= scanFeatures(file.path, file.content, fences);

        foreach (const ref f; fences)
        {
            if (f.depth != 0)
            {
                result.nestedFences++;
                continue;
            }

            result.fences++;
            if (f.endLine == 0)
                result.unclosedFences++;

            auto stat = f.label in byLabel;
            if (stat is null)
            {
                byLabel[f.label] = LabelStat(
                    label: f.label,
                    canonical: canonicalLanguage(f.label),
                    cls: classifyLabel(f.label, bundled),
                    count: 0,
                    files: 0,
                    firstSeen: f.file ~ ":" ~ f.line.to!string,
                );
                stat = f.label in byLabel;
            }
            stat.count++;
            filesByLabel[f.label][f.file] = true;
        }
    }

    foreach (label, ref stat; byLabel)
        stat.files = filesByLabel[label].length;

    result.labels = byLabel.values
        .sort!((a, b) => a.count != b.count ? a.count > b.count : a.label < b.label)
        .array;

    return result;
}

@("fence_audit.auditFiles.censusAndScope")
@safe pure
unittest
{
    bool[string] bundled = ["d": true, "rust": true];

    const files = [
        MarkdownFile("docs/a.md", "```d\nx\n```\n```text\ny\n```\n```wat\nz\n```\n"),
        MarkdownFile("docs/research/sql/grounding/g.md", "```d\nq\n```\n"),
        MarkdownFile("docs/b.md", "````markdown\n```rust\nq\n```\n````\n"),
    ];

    auto site = auditFiles(files, bundled, AuditScope.site);
    assert(site.filesScanned == 2 && site.filesExcluded == 1);
    // 3 in a.md + the wrapper in b.md; the nested `rust` block is not one.
    assert(site.fences == 4, site.fences.to!string);
    assert(site.nestedFences == 1);
    assert(site.fenceCount(FenceClass.grammarBacked) == 1); // the `d` block
    assert(site.fenceCount(FenceClass.plainText) == 1);     // `text`
    assert(site.fenceCount(FenceClass.uncovered) == 2);     // `wat`, `markdown`

    auto all = auditFiles(files, bundled, AuditScope.all);
    assert(all.filesScanned == 3 && all.fences == 5);

    auto excluded = auditFiles(files, bundled, AuditScope.excluded);
    assert(excluded.filesScanned == 1 && excluded.fences == 1);

    // Per-label rows are ordered by frequency, then alphabetically.
    assert(all.labels[0].label == "d" && all.labels[0].count == 2);
    assert(all.labels[0].files == 2);
    assert(all.labels[0].firstSeen == "docs/a.md:1");
}

// === Reporting ===

/// A percentage of `total`, rendered with one decimal.
private string fmtPercent(size_t part, size_t total) @safe
{
    import sparkles.base.smallbuffer : SmallBuffer;
    import sparkles.base.text.writers : writeFixedPoint;

    if (total == 0)
        return "0.0%";

    // Scaled fixed-point (tenths of a percent) so the rendering never goes
    // through a float formatter.
    const scaled = (part * 1000 + total / 2) / total;
    SmallBuffer!(char, 16) buf;
    writeFixedPoint(buf, scaled, 1);
    return buf[].idup ~ "%";
}

@("fence_audit.fmtPercent.rounding")
@safe
unittest
{
    assert(fmtPercent(1, 4) == "25.0%");
    assert(fmtPercent(1, 3) == "33.3%");
    assert(fmtPercent(0, 0) == "0.0%");
    assert(fmtPercent(7, 7) == "100.0%");
}

/// Rows of the per-classification summary table (header row included).
string[][] classificationRows(in AuditResult r) @safe
{
    string[][] rows = [["Classification", "Labels", "Fences", "Share"]];
    foreach (cls; [FenceClass.grammarBacked, FenceClass.plainText, FenceClass.uncovered])
    {
        const fences = r.fenceCount(cls);
        rows ~= [
            cls.name,
            r.labelCount(cls).to!string,
            fences.to!string,
            fmtPercent(fences, r.fences),
        ];
    }
    rows ~= ["total", r.labels.length.to!string, r.fences.to!string, fmtPercent(r.fences, r.fences)];
    return rows;
}

/// Rows of the per-label census table (header row included).
string[][] labelRows(in AuditResult r) @safe
{
    string[][] rows = [["Label", "Canonical", "Classification", "Fences", "Share", "Files"]];
    foreach (const ref l; r.labels)
    {
        rows ~= [
            l.label.length ? l.label : "(none)",
            l.canonical.length ? l.canonical : "(none)",
            l.cls.name,
            l.count.to!string,
            fmtPercent(l.count, r.fences),
            l.files.to!string,
        ];
    }
    return rows;
}

/// Rows of the VitePress-feature inventory table (header row included).
string[][] featureRows(in AuditResult r) @safe
{
    size_t[string] counts;
    size_t[string] fileCounts;
    bool[string][string] filesByKind;
    string[string] firstSeen;

    foreach (const ref h; r.features)
    {
        counts[h.kind]++;
        filesByKind[h.kind][h.file] = true;
        if (h.kind !in firstSeen)
            firstSeen[h.kind] = h.file ~ ":" ~ h.line.to!string;
    }

    string[][] rows = [["Feature", "Occurrences", "Files", "First occurrence"]];
    foreach (kind; counts.keys.sort)
    {
        rows ~= [
            kind,
            counts[kind].to!string,
            filesByKind[kind].length.to!string,
            firstSeen[kind],
        ];
    }
    return rows;
}

// === JSON report ===

/// One `labels` entry in the JSON report.
struct JsonLabel
{
    string label;
    string canonical;
    string classification;
    size_t fences;
    size_t files;
    string firstSeen;
}

/// One `features` entry in the JSON report.
struct JsonFeature
{
    string kind;
    string detail;
    string file;
    size_t line;
}

/// Aggregate counts in the JSON report.
struct JsonTotals
{
    size_t filesScanned;
    size_t filesExcluded;
    size_t fences;
    size_t nestedFences;
    size_t unclosedFences;
    size_t grammarBackedFences;
    size_t plainTextFences;
    size_t uncoveredFences;
    size_t distinctLabels;
    size_t bundledGrammars;
}

/**
The machine-readable audit report — the file `--json` writes, destined for
`docs/.vitepress/hue-langs.json`, where the future `markdown.highlight` hook
reads `hueLanguages` to decide hue-vs-Shiki per fence.
*/
struct JsonReport
{
    /// How the report was produced.
    string tool = "ci --audit-fences";
    /// `site`, `all` or `excluded`.
    string auditScope;
    /// The grammar search path the classification was made against.
    string[] grammarPath;
    /// The `srcExclude` patterns the site-visibility split used.
    string[] srcExclude;
    /// Canonical languages the bundle provides *and* the docs use — the
    /// allow-list. `diagramLanguages` are held out of it.
    string[] hueLanguages;
    /// Languages a plugin renders instead of the highlighter: the site runs
    /// `vitepress-plugin-mermaid`, so a `mermaid` fence becomes a diagram. A
    /// highlight hook that claims it replaces the diagram with colored text,
    /// which is why these are excluded from `hueLanguages` even though the
    /// bundle has a grammar for them.
    string[] diagramLanguages;
    /// Labels that ask for no highlighting.
    string[] plainTextLabels;
    /// Labels with no bundled grammar.
    string[] uncoveredLabels;
    /// Aggregate counts.
    JsonTotals totals;
    /// Per-label census.
    JsonLabel[] labels;
    /// VitePress feature occurrences, with `file:line` provenance.
    JsonFeature[] features;
}

/**
`true` for a canonical language a VitePress plugin renders instead of the
highlighter — today just `mermaid`, via `vitepress-plugin-mermaid` (see
`docs/.vitepress/config.mts`). The bundle *has* a mermaid grammar, so nothing
but this rule keeps a highlight hook from turning a diagram into colored text.
*/
bool isDiagramLanguage(scope const(char)[] canonical) @safe pure nothrow @nogc
    => canonical == "mermaid";

/// Builds the JSON report from an audit result.
JsonReport toJsonReport(in AuditResult r, AuditScope scope_, in string[] grammarPath) @safe
{
    JsonReport j;
    j.auditScope = scope_.to!string;
    j.grammarPath = grammarPath.dup;
    j.srcExclude = srcExcludeMirror.dup;

    bool[string] hue;
    bool[string] diagrams;
    foreach (const ref l; r.labels)
    {
        final switch (l.cls)
        {
            case FenceClass.grammarBacked:
                if (isDiagramLanguage(l.canonical))
                    diagrams[l.canonical] = true;
                else
                    hue[l.canonical] = true;
                break;
            case FenceClass.plainText:
                j.plainTextLabels ~= l.label;
                break;
            case FenceClass.uncovered:
                j.uncoveredLabels ~= l.label;
                break;
        }

        j.labels ~= JsonLabel(
            label: l.label,
            canonical: l.canonical,
            classification: l.cls.name,
            fences: l.count,
            files: l.files,
            firstSeen: l.firstSeen,
        );
    }

    j.hueLanguages = hue.keys.sort.array;
    j.diagramLanguages = diagrams.keys.sort.array;
    j.plainTextLabels.sort;
    j.uncoveredLabels.sort;

    j.totals = JsonTotals(
        filesScanned: r.filesScanned,
        filesExcluded: r.filesExcluded,
        fences: r.fences,
        nestedFences: r.nestedFences,
        unclosedFences: r.unclosedFences,
        grammarBackedFences: r.fenceCount(FenceClass.grammarBacked),
        plainTextFences: r.fenceCount(FenceClass.plainText),
        uncoveredFences: r.fenceCount(FenceClass.uncovered),
        distinctLabels: r.labels.length,
        bundledGrammars: r.bundledGrammars,
    );

    foreach (const ref h; r.features)
        j.features ~= JsonFeature(kind: h.kind, detail: h.detail, file: h.file, line: h.line);

    return j;
}

@("fence_audit.toJsonReport.allowList")
@safe
unittest
{
    bool[string] bundled = ["d": true, "typescript": true];
    const files = [MarkdownFile("docs/a.md", "```ts\nx\n```\n```text\ny\n```\n```wat\nz\n```\n")];

    auto j = auditFiles(files, bundled, AuditScope.all).toJsonReport(AuditScope.all, ["/grammars"]);

    // The allow-list is canonical names, not the labels as written.
    assert(j.hueLanguages == ["typescript"]);
    assert(j.plainTextLabels == ["text"]);
    assert(j.uncoveredLabels == ["wat"]);
    assert(j.totals.fences == 3 && j.totals.distinctLabels == 3);
    assert(j.auditScope == "all");
    assert(j.srcExclude == srcExcludeMirror);
}

@("fence_audit.toJsonReport.mermaidHeldOutOfAllowList")
@safe
unittest
{
    bool[string] bundled = ["mermaid": true, "d": true];
    const files = [MarkdownFile("docs/a.md", "```mermaid\ngraph TD;\n```\n```d\nx\n```\n")];

    auto j = auditFiles(files, bundled, AuditScope.all).toJsonReport(AuditScope.all, null);

    // A plugin renders mermaid; handing it to the highlighter would replace a
    // diagram with colored text.
    assert(j.hueLanguages == ["d"]);
    assert(j.diagramLanguages == ["mermaid"]);
}

/// Rows of the per-occurrence feature table (header row included), capped at
/// `limit` rows — the full list always goes to the JSON report.
string[][] featureDetailRows(in AuditResult r, size_t limit) @safe
{
    string[][] rows = [["Feature", "Detail", "Location"]];
    foreach (const ref h; r.features)
    {
        if (rows.length > limit)
            break;
        rows ~= [h.kind, h.detail, h.file ~ ":" ~ h.line.to!string];
    }
    return rows;
}

/// Rows of the uncovered-label table (header row included): the labels that
/// would lose their coloring, each with a place to look at.
string[][] uncoveredRows(in AuditResult r) @safe
{
    string[][] rows = [["Label", "Canonical", "Fences", "Files", "First occurrence"]];
    foreach (const ref l; r.labels.filter!(l => l.cls == FenceClass.uncovered))
        rows ~= [l.label, l.canonical, l.count.to!string, l.files.to!string, l.firstSeen];
    return rows;
}

// === Orchestration ===

/// Inputs of `runFenceAudit`.
struct FenceAuditOptions
{
    /// Repository root to audit; empty means the current directory.
    string root;
    /// Explicit file list; empty means `docs/**/*.md` plus `README.md`.
    string[] files;
    /// Where to write the JSON report; empty means no JSON.
    string jsonPath;
    /// Which files the primary census covers.
    AuditScope auditScope;
}

/**
Runs the fence audit end to end: enumerate the tracked markdown, scan it,
classify it against the grammar bundle, print the report, and (optionally)
write the JSON.

Returns `0` on success, `1` when the grammar bundle is missing (every label
would classify as uncovered, which is a wrong answer rather than a finding) or
no markdown was found.
*/
int runFenceAudit(in FenceAuditOptions opts)
{
    import std.file : readText;
    import std.stdio : writeln;
    import sparkles.base.logger : error, info, warning;
    import sparkles.ui.components.table : drawTable, TableProps;

    auto registry = GrammarRegistry.fromEnvironment();
    auto bundled = bundledLanguages(registry);
    if (bundled.length == 0)
    {
        error(i"No tree-sitter grammars found. Set $SPARKLES_TS_GRAMMAR_PATH to the grammar bundle (nix build .#ts-grammars).");
        return 1;
    }

    auto paths = opts.files.length ? opts.files.dup : trackedDocMarkdown(opts.root);
    if (paths.length == 0)
    {
        error(i"No markdown files to audit.");
        return 1;
    }

    MarkdownFile[] files;
    foreach (path; paths)
    {
        import std.path : buildPath;

        const full = opts.root.length ? buildPath(opts.root, path) : path;
        try
            files ~= MarkdownFile(path, readText(full));
        catch (Exception e)
            warning(i"Skipping $(path): $(e.msg)");
    }

    auto result = auditFiles(files, bundled, opts.auditScope);

    const distinct = result.labels.length;
    const scopeName = opts.auditScope.to!string;
    info(i"Fence audit: {bold $(result.fences)} top-level fences across {bold $(result.filesScanned)} files");
    info(i"$(distinct) distinct labels; $(bundled.length) grammars in the bundle; scope: $(scopeName)");
    if (result.nestedFences)
        info(i"$(result.nestedFences) further fences are nested inside wrapper blocks (quoted markdown; the site never highlights them on their own).");
    if (result.unclosedFences)
        warning(i"$(result.unclosedFences) fenced block(s) are never closed.");
    if (opts.auditScope == AuditScope.site && result.filesExcluded)
    {
        info(i"$(result.filesExcluded) file(s) skipped as srcExclude'd; see the note below and rerun with --audit-scope excluded to census them.");
    }

    writeln();
    writeln(drawTable(classificationRows(result), TableProps(headerRows: 1, title: "Classification")));
    writeln();
    writeln(drawTable(labelRows(result), TableProps(headerRows: 1, title: "Fence Labels")));

    auto uncovered = uncoveredRows(result);
    if (uncovered.length > 1)
    {
        writeln();
        writeln(drawTable(uncovered, TableProps(headerRows: 1,
            title: "Uncovered Labels (would render plain under hue)")));
    }

    auto features = featureRows(result);
    if (features.length > 1)
    {
        writeln();
        writeln(drawTable(features, TableProps(headerRows: 1,
            title: "VitePress Code-Block Features (a highlighter swap must preserve these)")));

        // The point of the inventory is a checklist, so every occurrence gets a
        // `file:line` — capped here, complete in the JSON report.
        enum detailLimit = 200;
        writeln();
        writeln(drawTable(featureDetailRows(result, detailLimit), TableProps(headerRows: 1,
            title: "Feature Occurrences")));
        if (result.features.length > detailLimit)
            info(i"$(result.features.length - detailLimit) further occurrence(s) omitted; pass --json for the complete list.");
    }

    writeln();
    const searchPath = registry.dirs.join(":");
    info(i"Grammar search path: $(searchPath)");
    info(i"srcExclude is mirrored from docs/.vitepress/config.mts ($(srcExcludeMirror.length) patterns) — see fence_audit.srcExcludeMirror.");

    if (opts.jsonPath.length)
    {
        import sparkles.wired.json : writeJSONFile;

        auto report = toJsonReport(result, opts.auditScope, registry.dirs.dup);
        auto written = writeJSONFile(report, opts.jsonPath);
        if (written.hasError)
        {
            error(i"Failed to write $(opts.jsonPath): $(written.error)");
            return 1;
        }
        info(i"Wrote $(opts.jsonPath)");
    }

    return 0;
}

/// The tracked markdown the audit covers by default: everything under `docs/`
/// plus the repository `README.md`.
private string[] trackedDocMarkdown(string root)
{
    import std.process : execute;
    import sparkles.base.logger : error;
    import std.string : endsWith;

    auto cmd = ["git"];
    if (root.length)
        cmd ~= ["-C", root];
    cmd ~= ["ls-files", "--", "docs", "README.md"];

    const result = execute(cmd);
    if (result.status != 0)
    {
        error(i"Failed to enumerate markdown files with git ls-files");
        return [];
    }

    return result.output
        .lineSplitter
        .filter!(line => line.endsWith(".md"))
        .map!(line => line.idup)
        .array;
}
