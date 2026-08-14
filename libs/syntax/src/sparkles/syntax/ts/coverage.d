/**
Theme coverage over a grammar bundle: which capture names a theme can actually
style.

The projection from grammar capture names onto $(REF standardLabels,
sparkles,syntax,label) and from theme selectors onto the same vocabulary are
written independently — one in the grammar queries upstream ships, the other in
the theme importer. Nothing forces them to meet, and when they miss, tokens
render in the default foreground with no error anywhere: numbers were uncolored
in every built-in theme across 20 grammars before this module existed.

$(LREF auditBundle) closes that loop by measuring it. See
$(LINK2 ../../../../../docs/specs/syntax/label-vocabulary-dialects.md, the
label-vocabulary spec) for how the two dialects drifted apart.

Note the check is `ResolvedTheme`-based, not selector-based: a label with no
rule of its own is still styled when an ancestor has one — `string.special`
inherits `string`. Only a label whose whole dotted chain is unstyled is a gap.
*/
module sparkles.syntax.ts.coverage;

import sparkles.syntax.event : LabelId;
import sparkles.syntax.label : LabelSet;
import sparkles.syntax.theme : ResolvedTheme;

/// One capture name a bundle's grammars emit, and what a theme does with it.
struct CaptureCoverage
{
    string capture;      /// the capture name, as the query writes it (no `@`)
    string[] languages;  /// bundle languages emitting it, sorted
    LabelId label;       /// what `LabelSet.resolve` makes of it
    bool styled;         /// the resolved label carries a non-empty style

    /// `true` when the capture reaches no label at all — it emits no span.
    bool unresolved() const @safe pure nothrow @nogc => !label;
}

/**
Scans every `<lang>/queries/highlights.scm` under `bundleDir` and reports what
`labels` and `theme` jointly make of each capture name found, sorted by capture
name.

Capture names beginning with `_` are omitted: the query convention is that they
exist only to be referenced by a predicate and are never highlighted.
*/
CaptureCoverage[] auditBundle(string bundleDir, in LabelSet labels, in ResolvedTheme theme) @safe
{
    import std.algorithm.iteration : map;
    import std.algorithm.sorting : sort;
    import std.array : array;
    import std.file : DirEntry, SpanMode, dirEntries, exists, readText;
    import std.path : baseName, buildPath;

    string[][string] byCapture;
    if (!bundleDir.exists)
        return null;

    foreach (DirEntry lang; dirEntries(bundleDir, SpanMode.shallow))
    {
        const query = buildPath(lang.name, "queries", "highlights.scm");
        if (!query.exists)
            continue;
        foreach (capture; captureNames(readText(query)))
            byCapture[capture] ~= lang.name.baseName;
    }

    auto out_ = byCapture.keys.sort().map!((capture) {
        const id = labels.resolve(capture);
        return CaptureCoverage(
            capture: capture,
            languages: byCapture[capture].sort().array,
            label: id,
            styled: id && !theme[id].empty);
    }).array;
    return out_;
}

/**
The `@capture` names in one query file's source.

Comments (`;` to end of line) and string literals are skipped first: a `#match?`
pattern or an author's email in a header comment would otherwise read as a
capture. `_`-prefixed names are dropped as predicate-only.
*/
private string[] captureNames(scope const(char)[] source) @safe pure
{
    import std.array : appender;

    auto found = appender!(string[]);
    bool inString, inComment;
    size_t i;
    while (i < source.length)
    {
        const c = source[i];
        if (inComment)
        {
            if (c == '\n')
                inComment = false;
            ++i;
        }
        else if (inString)
        {
            if (c == '\\' && i + 1 < source.length)
                ++i; // an escaped quote does not close the literal
            else if (c == '"')
                inString = false;
            ++i;
        }
        else if (c == ';')
            inComment = true;
        else if (c == '"')
        {
            inString = true;
            ++i;
        }
        else if (c == '@')
        {
            const start = ++i;
            while (i < source.length && isCaptureChar(source[i]))
                ++i;
            if (i > start && source[start] != '_')
                found ~= source[start .. i].idup;
        }
        else
            ++i;
    }
    return found[];
}

private bool isCaptureChar(char c) @safe pure nothrow @nogc
    => (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
        || (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-';

@("ts.coverage.captureNames.skipsCommentsAndStrings")
@safe pure
unittest
{
    // A predicate string and a comment both contain an `@`; neither is a capture.
    const query = `; contact stumash@gmail.com
((number) @number (#match? @number "^@4"))
(x) @_predicate_only
(y) @variable.member`;
    assert(captureNames(query) == ["number", "number", "variable.member"]);
}

///
@("ts.coverage.auditBundle.everyCaptureIsStyled")
@safe
unittest
{
    import std.algorithm.iteration : filter, map;
    import std.algorithm.searching : canFind;
    import std.array : array, join;
    import std.conv : text;
    import std.process : environment;
    import sparkles.syntax.theme : resolveTheme;
    import sparkles.syntax.themes : builtinDark;
    import sparkles.test_runner.skip : skipTest;

    const bundle = environment.get("SPARKLES_TS_GRAMMAR_PATH", "");
    if (bundle.length == 0)
        skipTest("SPARKLES_TS_GRAMMAR_PATH not set (enter `nix develop`)");

    const labels = LabelSet.standard();
    const coverage = auditBundle(bundle, labels, resolveTheme(builtinDark, labels));
    assert(coverage.length, "no highlights.scm found under the bundle");

    // Captures that are *supposed* to render as plain text, so an absent style
    // is the correct outcome rather than a hole. Keep this list short and
    // justified — every entry is a capture this audit can no longer protect.
    static immutable string[] plainText = [
        "none",     // upstream's explicit "do not highlight this"
        "spell",    // a spellchecker hint, not a highlight
        "text",     // literal trailing text (D's `__EOF__` region)
        "markup",   // XML CharData — document body text, not a highlight
        "embedded", // marks an injected region; the injected grammar colors it
        "label",    // goto labels read as ordinary identifiers in TextMate themes
    ];
    auto gaps = coverage
        .filter!(c => !c.styled && !plainText.canFind(c.capture))
        .map!(c => text(c.capture, c.unresolved ? " (unresolved)" : " (no style)",
            " [", c.languages.join(", "), "]"))
        .array;

    assert(gaps.length == 0,
        text(gaps.length, " capture name(s) the bundle emits that ", builtinDark.name,
            " cannot style:\n  ", gaps.join("\n  ")));
}
