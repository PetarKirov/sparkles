/**
The twoslash notation parser for D samples — pure text → markers, no compiler
dependency (spec `NTN1`; the marker grammar inventory is
`docs/specs/hue/twoslash.md` `NOT1`–`NOT8`).

An annotated sample contains ordinary D plus `//` notation lines:

$(LIST
    * `// ^?` — query the inferred type of the identifier the `^` points at
        on the $(B previous kept line) (caret-column aligned).
    * `// ---cut---` / `---cut-before---` / `---cut-after---` /
        `---cut-start---` + `---cut-end---` — code that is $(B compiled but
        not shown).
    * `// @errors: <patterns>` / `// @noErrors` — the sample's expected-
        diagnostics contract (verification metadata for `--verify`/ci;
        extraction always emits every diagnostic as a node).
    * `// @dflags: <flags>` / `// @import: <path>` — analysis configuration.
    * `// @annotate: …` / `@log:` / `@warn:` / `@error:` — custom tag lines
        rendered as below-line blocks.
)

Only that $(B closed set) of directive words is recognized: D comments
legitimately contain `@`-words (`// @safe pure nothrow` is a comment about
attributes, not a directive), so an unknown `@word` stays ordinary code.

Two coordinate spaces (spec `NTN2`): notation lines are stripped and cut
regions retained to form `fullSource` (what the compiler analyzes); applying
the `removals` then yields `displayCode` (what the reader sees). Nodes are
built in `fullSource` bytes and remapped via `mapToDisplay`; deferred markers
(`^|`, `^^^`, `@filename:`, `@dub:`) are listed in the spec's non-goals.
*/
module sparkles.twoslash_d.notation;

/// A `^?` query: the byte offset (into `fullSource`) of the queried
/// identifier — where the caret pointed on the line above.
struct QueryMarker
{
    size_t offset;
}

/// A `^^^` highlight: a caret-run span on the previous kept line, with an
/// optional trailing annotation.
struct HighlightMarker
{
    size_t offset; /// span start in `fullSource` bytes
    size_t length; /// caret-run length
    string text;   /// annotation after the run ("" when bare)
}

/// A custom tag line (`// @log: hello`), anchored to the start of the next
/// kept line in `fullSource` bytes.
struct TagDirective
{
    string name; /// `annotate` | `log` | `warn` | `error`
    string text;
    size_t offset;
}

/// A `fullSource` byte range removed from the display (`---cut---` family).
struct Removal
{
    size_t start; /// inclusive
    size_t end;   /// exclusive
}

/// The parse result: the analysis source, the display transform, and the
/// collected markers/directives.
struct ParsedNotation
{
    /// What the compiler analyzes: notation lines stripped, cut code kept.
    string fullSource;

    /// What the reader sees: `fullSource` minus `removals`.
    string displayCode;

    /// Sorted, disjoint cut ranges in `fullSource` bytes.
    Removal[] removals;

    QueryMarker[] queries;
    HighlightMarker[] highlights;
    TagDirective[] tags;

    /// `@errors:` patterns (whitespace-split), in declaration order.
    string[] expectedErrors;
    /// `// @noErrors` was present (asserts a clean sample).
    bool noErrors;

    string[] dflags;      /// accumulated `@dflags:` flags
    string[] importPaths; /// accumulated `@import:` paths

    /// Maps a `fullSource` byte offset to its `displayCode` offset, or -1 if
    /// the offset falls inside a removed range.
    ptrdiff_t mapToDisplay(size_t offset) const @safe pure nothrow @nogc
    {
        size_t shift = 0;
        foreach (r; removals)
        {
            if (offset < r.start)
                break;
            if (offset < r.end)
                return -1;
            shift += r.end - r.start;
        }
        return offset - shift;
    }
}

/// Parses the notation out of an annotated sample. Pure text processing;
/// tolerates any line endings (`\n` assumed; `\r` treated as line content).
ParsedNotation parseNotation(string source) @safe pure
{
    import std.algorithm.searching : findSplit, startsWith;
    import std.string : indexOf, splitLines, strip, stripLeft;

    // --- Pass 1: classify lines; build fullSource from non-notation lines.
    static struct Line
    {
        string text;       // without terminator
        size_t fullStart;  // byte offset of this line in fullSource
        bool cut;          // inside a cut region (set in pass 2)
    }

    ParsedNotation result;
    Line[] kept;
    string fullSource;

    enum CutKind { none, before, after, start, end }
    static struct PendingCut { CutKind kind; size_t keptIndex; }
    PendingCut[] cuts;

    // Pending queries recorded as (caret column) waiting for resolution
    // against the previous kept line; tags waiting for the next kept line.
    size_t[] pendingTagIndexes;

    foreach (rawLine; source.splitLines)
    {
        const stripped = rawLine.strip;

        // --- cut directives
        CutKind cutKind = CutKind.none;
        switch (stripped)
        {
            case "// ---cut---", "// ---cut-before---":
                cutKind = CutKind.before;
                break;
            case "// ---cut-after---":
                cutKind = CutKind.after;
                break;
            case "// ---cut-start---":
                cutKind = CutKind.start;
                break;
            case "// ---cut-end---":
                cutKind = CutKind.end;
                break;
            default:
                break;
        }
        if (cutKind != CutKind.none)
        {
            cuts ~= PendingCut(cutKind, kept.length);
            continue;
        }

        // --- caret markers: `//` + spaces + `^?` (query) or `^^^…` run
        // (highlight, optional trailing annotation). Both point at the
        // previous kept line, caret-column aligned.
        {
            const commentAt = rawLine.indexOf("//");
            if (commentAt >= 0)
            {
                const afterSlashes = rawLine[commentAt + 2 .. $];
                const body = afterSlashes.stripLeft;
                const caretCol = commentAt + 2
                    + (afterSlashes.length - body.length);
                if (body == "^?" || body == "^?.")
                {
                    if (kept.length)
                        result.queries ~= QueryMarker(
                            kept[$ - 1].fullStart + caretCol);
                    continue;
                }
                if (body.length >= 2 && body[0] == '^' && body[1] == '^')
                {
                    size_t run = 0;
                    while (run < body.length && body[run] == '^')
                        run++;
                    if (kept.length)
                        result.highlights ~= HighlightMarker(
                            offset: kept[$ - 1].fullStart + caretCol,
                            length: run,
                            text: body[run .. $].strip.idup);
                    continue;
                }
            }
        }

        // --- `@word` directives (closed set only — see the module docs).
        if (auto directive = parseDirective(stripped))
        {
            final switch (directive.kind)
            {
                case DirectiveKind.errors:
                {
                    import std.algorithm.iteration : filter, splitter;

                    foreach (p; directive.value.splitter(' ').filter!(p => p.length))
                        result.expectedErrors ~= p;
                    break;
                }
                case DirectiveKind.noErrors:
                    result.noErrors = true;
                    break;
                case DirectiveKind.dflags:
                {
                    import std.algorithm.iteration : filter, splitter;

                    foreach (f; directive.value.splitter(' ').filter!(f => f.length))
                        result.dflags ~= f;
                    break;
                }
                case DirectiveKind.importPath:
                    if (directive.value.length)
                        result.importPaths ~= directive.value;
                    break;
                case DirectiveKind.tag:
                    result.tags ~= TagDirective(directive.name, directive.value, 0);
                    pendingTagIndexes ~= result.tags.length - 1;
                    break;
            }
            continue;
        }

        // --- ordinary code line: append to fullSource.
        const start = fullSource.length;
        fullSource ~= rawLine;
        fullSource ~= '\n';
        kept ~= Line(rawLine, start);
        foreach (ti; pendingTagIndexes)
            result.tags[ti].offset = start;
        pendingTagIndexes = null;
    }
    // Tags at EOF anchor to the end of the source.
    foreach (ti; pendingTagIndexes)
        result.tags[ti].offset = fullSource.length;

    result.fullSource = fullSource;

    // --- Pass 2: resolve cut directives to fullSource byte removals.
    size_t lineStart(size_t keptIndex) @safe pure nothrow @nogc
        => keptIndex < kept.length ? kept[keptIndex].fullStart : fullSource.length;

    size_t regionStart = size_t.max;
    foreach (c; cuts)
    {
        final switch (c.kind)
        {
            case CutKind.before:
                // Drop everything above the directive (restarts any earlier cut).
                result.removals = [Removal(0, lineStart(c.keptIndex))];
                break;
            case CutKind.after:
                result.removals ~= Removal(lineStart(c.keptIndex), fullSource.length);
                break;
            case CutKind.start:
                regionStart = lineStart(c.keptIndex);
                break;
            case CutKind.end:
                if (regionStart != size_t.max)
                {
                    result.removals ~= Removal(regionStart, lineStart(c.keptIndex));
                    regionStart = size_t.max;
                }
                break;
            case CutKind.none:
                assert(0);
        }
    }
    if (regionStart != size_t.max) // unterminated ---cut-start---
        result.removals ~= Removal(regionStart, fullSource.length);
    normalizeRemovals(result.removals);

    // --- displayCode = fullSource minus removals.
    {
        size_t at = 0;
        string display;
        foreach (r; result.removals)
        {
            display ~= fullSource[at .. r.start];
            at = r.end;
        }
        display ~= fullSource[at .. $];
        result.displayCode = display;
    }

    return result;
}

private enum DirectiveKind { errors, noErrors, dflags, importPath, tag }

private struct Directive
{
    DirectiveKind kind;
    string name;  // the word after `@`
    string value; // text after the `:` (stripped), or ""

    bool opCast(T : bool)() const @safe pure nothrow @nogc => name.length != 0;
}

/// Recognizes `// @word: value` / `// @noErrors` for the closed directive
/// set; anything else — including D attribute chatter like `// @safe pure` —
/// is not a directive.
private Directive parseDirective(string stripped) @safe pure
{
    import std.algorithm.searching : startsWith;
    import std.string : indexOf, strip, stripLeft;

    if (!stripped.startsWith("//"))
        return Directive.init;
    const body = stripped[2 .. $].stripLeft;
    if (!body.startsWith("@"))
        return Directive.init;

    const colonAt = body.indexOf(':');
    const word = colonAt >= 0 ? body[1 .. colonAt] : body[1 .. $];
    const value = colonAt >= 0 ? body[colonAt + 1 .. $].strip : "";

    switch (word)
    {
        case "errors":
            return colonAt >= 0 ? Directive(DirectiveKind.errors, word, value)
                : Directive.init;
        case "noErrors":
            return colonAt < 0 ? Directive(DirectiveKind.noErrors, word)
                : Directive.init;
        case "dflags":
            return colonAt >= 0 ? Directive(DirectiveKind.dflags, word, value)
                : Directive.init;
        case "import":
            return colonAt >= 0 ? Directive(DirectiveKind.importPath, word, value)
                : Directive.init;
        case "annotate", "log", "warn", "error":
            return colonAt >= 0 ? Directive(DirectiveKind.tag, word, value)
                : Directive.init;
        default:
            return Directive.init;
    }
}

/// Sorts and merges overlapping/adjacent removals in place.
private void normalizeRemovals(ref Removal[] removals) @safe pure nothrow
{
    import std.algorithm.sorting : sort;

    if (removals.length < 2)
        return;
    removals.sort!((a, b) => a.start < b.start);
    Removal[] merged = [removals[0]];
    foreach (r; removals[1 .. $])
    {
        if (r.start <= merged[$ - 1].end)
        {
            if (r.end > merged[$ - 1].end)
                merged[$ - 1].end = r.end;
        }
        else
            merged ~= r;
    }
    removals = merged;
}

// -- tests -------------------------------------------------------------------

@("notation.parseNotation.plain")
@safe pure unittest
{
    const n = parseNotation("module m;\nint x;\n");
    assert(n.fullSource == "module m;\nint x;\n");
    assert(n.displayCode == n.fullSource);
    assert(!n.queries.length && !n.tags.length && !n.removals.length);
}

@("notation.parseNotation.query")
@safe pure unittest
{
    // The caret points at column 4 → `x` on the previous kept line.
    const n = parseNotation("auto x = 1;\n//   ^?\nint y;\n");
    assert(n.fullSource == "auto x = 1;\nint y;\n");
    assert(n.queries.length == 1);
    assert(n.queries[0].offset == 5); // byte of `x`
    assert(n.fullSource[n.queries[0].offset] == 'x');
}

@("notation.parseNotation.cutBefore")
@safe pure unittest
{
    const n = parseNotation("import std.stdio;\n// ---cut---\nvoid f() {}\n");
    assert(n.fullSource == "import std.stdio;\nvoid f() {}\n");
    assert(n.displayCode == "void f() {}\n");
    assert(n.removals == [Removal(0, 18)]);
    // Offsets in the hidden prelude are unmapped; visible ones shift.
    assert(n.mapToDisplay(0) == -1);
    assert(n.mapToDisplay(18) == 0);
    assert(n.mapToDisplay(23) == 5);
}

@("notation.parseNotation.cutStartEnd")
@safe pure unittest
{
    const n = parseNotation(
        "int a;\n// ---cut-start---\nint hidden;\n// ---cut-end---\nint b;\n");
    assert(n.fullSource == "int a;\nint hidden;\nint b;\n");
    assert(n.displayCode == "int a;\nint b;\n");
    assert(n.removals == [Removal(7, 19)]);
}

@("notation.parseNotation.cutAfter")
@safe pure unittest
{
    const n = parseNotation("int a;\n// ---cut-after---\nint hidden;\n");
    assert(n.displayCode == "int a;\n");
    assert(n.fullSource == "int a;\nint hidden;\n");
}

@("notation.parseNotation.directives")
@safe pure unittest
{
    const n = parseNotation(
        "// @errors: cannot{{_}}convert undefined\n" ~
        "// @dflags: -preview=in -betterC\n" ~
        "// @import: /some/path\n" ~
        "int x;\n");
    assert(n.expectedErrors == ["cannot{{_}}convert", "undefined"]);
    assert(n.dflags == ["-preview=in", "-betterC"]);
    assert(n.importPaths == ["/some/path"]);
    assert(n.fullSource == "int x;\n");
    assert(!n.noErrors);

    assert(parseNotation("// @noErrors\nint x;\n").noErrors);
}

@("notation.parseNotation.tags")
@safe pure unittest
{
    const n = parseNotation("int a;\n// @log: computed eagerly\nint b;\n");
    assert(n.fullSource == "int a;\nint b;\n");
    assert(n.tags.length == 1);
    assert(n.tags[0].name == "log");
    assert(n.tags[0].text == "computed eagerly");
    assert(n.tags[0].offset == 7); // start of `int b;`
}

@("notation.parseNotation.attributeCommentIsNotADirective")
@safe pure unittest
{
    // `// @safe pure` is a comment about attributes, not a directive: the
    // closed-set rule keeps it in the code verbatim (the false-positive trap
    // called out in the module docs).
    const src = "// @safe pure nothrow is inferred here\nint f() => 1;\n";
    const n = parseNotation(src);
    assert(n.fullSource == src);
    assert(!n.tags.length && !n.expectedErrors.length);
}

@("notation.parseNotation.queryAfterCut")
@safe pure unittest
{
    // A query below the cut queries visible code; its fullSource offset maps
    // through to the display.
    const n = parseNotation(
        "int hidden;\n// ---cut---\nauto answer = 42;\n//   ^?\n");
    assert(n.queries.length == 1);
    const q = n.queries[0].offset;
    assert(n.fullSource[q] == 'a'); // `answer`
    assert(n.displayCode[n.mapToDisplay(q)] == 'a');
}

@("notation.parseNotation.mergedRemovals")
@safe pure unittest
{
    const n = parseNotation(
        "// ---cut-start---\nint h1;\n// ---cut-end---\n// ---cut-start---\nint h2;\n// ---cut-end---\nint v;\n");
    assert(n.displayCode == "int v;\n");
    assert(n.removals.length == 1); // adjacent regions merged
}

@("notation.parseNotation.highlights")
@safe pure unittest
{
    // A caret run marks the aligned span above; trailing text annotates.
    const n = parseNotation(
        "auto value = compute();\n" ~
        "//   ^^^^^ the interesting part\n" ~
        "int plain;\n" ~
        "//  ^^\n");
    assert(n.fullSource == "auto value = compute();\nint plain;\n");
    assert(n.highlights.length == 2);
    assert(n.highlights[0].offset == 5 && n.highlights[0].length == 5);
    assert(n.fullSource[n.highlights[0].offset .. n.highlights[0].offset + 5]
        == "value");
    assert(n.highlights[0].text == "the interesting part");
    assert(n.highlights[1].offset == 24 + 4 && n.highlights[1].length == 2);
    assert(n.highlights[1].text == "");
}
