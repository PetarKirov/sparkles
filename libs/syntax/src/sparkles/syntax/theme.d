/**
The theme layer: label selectors → styles, resolved once per vocabulary.

A $(LREF Theme) is plain data — ordered $(LREF ThemeRule)s mapping dotted
selectors to $(LREF StyleSpec)s. $(LREF resolveTheme) folds it against a
`LabelSet` into a $(LREF ResolvedTheme): a flat `labelId → StyleSpec` table
indexed in O(1) on the render path. Resolution is longest-dot-prefix (the
same rule `LabelSet.resolve` applies to capture names), whole-spec-wins (no
attribute cascade), and last-rule-wins among equal selectors.

`ResolvedTheme` is public API for every backend — including future
non-markup consumers (a GPU text renderer indexes it with `StyledSpan.label`
directly). Theme files (TOML/JSON) are a future seam: only a parser
producing `ThemeRule[]` is missing.
*/
module sparkles.syntax.theme;

import sparkles.syntax.color : Color;
import sparkles.syntax.event : LabelId;
import sparkles.syntax.label : LabelSet;

@safe:

/// Font-style flags, backend-neutral (they select faces/decorations, not
/// escape codes).
enum FontStyle : ubyte
{
    none = 0,
    bold = 1 << 0,
    dim = 1 << 1,
    italic = 1 << 2,
    underline = 1 << 3,
    strikethrough = 1 << 4,
}

/// `true` iff `flags` contains every bit of `bit`.
bool hasFont(FontStyle flags, FontStyle bit) pure nothrow @nogc
    => (flags & bit) == bit && bit != FontStyle.none;

/// The style a theme assigns to one label: optional fore-/background colors
/// plus font flags. `Color.Kind.unset` means "not specified".
struct StyleSpec
{
    Color fg;       /// foreground; unset = unspecified
    Color bg;       /// background; unset = unspecified
    FontStyle font; /// font flags

    /// `true` iff the spec specifies nothing at all (renders unstyled).
    bool empty() const scope pure nothrow @nogc
        => !fg.isSet && !bg.isSet && font == FontStyle.none;
}

/// One theme rule: a dotted label selector and the style it assigns.
struct ThemeRule
{
    string selector; /// dotted label name, matched by longest-dot-prefix
    StyleSpec style; /// the whole spec assigned on match (no cascade)
}

/// A theme as plain data. See the module header for resolution semantics.
struct Theme
{
    string name;                             /// display name
    Color defaultFg = Color.defaultColor;    /// unlabeled-text foreground
    Color defaultBg = Color.defaultColor;    /// document background
    ThemeRule[] rules;                       /// ordered; later wins among equal selectors
}

/**
A theme resolved against a label vocabulary: `labelId → StyleSpec` in O(1).
The single style bundle every backend takes.
*/
struct ResolvedTheme
{
    LabelSet labels;                 /// the vocabulary this was resolved against
    immutable(StyleSpec)[] styles;   /// parallel to `labels`; `.init` if unmatched
    StyleSpec defaults;              /// style of unlabeled text (`LabelId.none`)

    /// The style for `id`; `defaults` for `LabelId.none`. Ids outside this
    /// vocabulary (a producer configured against a different `LabelSet`)
    /// render as defaults — renderers are total.
    StyleSpec opIndex(LabelId id) const scope pure nothrow @nogc
        => id && id.value < styles.length ? styles[id.value] : defaults;
}

/**
Writes the per-label resolved styles into the output range `w` — one
`StyleSpec` per vocabulary name, in `LabelId` order: for every name, the
longest rule selector that is a dot-prefix of the name wins (last rule wins
among equal selectors); unmatched names get `StyleSpec.init`. `defaults`
receives the normalized unlabeled-text style.

Allocation-free — the whole-table resolution logic without owning the buffer.
A `@nogc nothrow` caller (e.g. an interactive previewer re-resolving on each
theme switch into one reused `SmallBuffer`) drives this directly; `resolveTheme`
is the GC-allocating convenience wrapper. A `defaultFg`/`defaultBg` of
`Color.defaultColor` is normalized to unset — for a renderer, "the terminal
default" and "unspecified" both mean "emit nothing".
*/
void writeThemeStyles(Writer)(ref Writer w, in Theme theme, LabelSet labels,
    out StyleSpec defaults)
{
    import std.range.primitives : put;

    foreach (i; 0 .. labels.length)
    {
        const labelName = labels.name(LabelId(cast(ushort) i));
        size_t bestLen = 0;
        bool found = false;
        StyleSpec best;
        foreach (rule; theme.rules)
        {
            if (rule.selector.length >= bestLen && isDotPrefix(rule.selector, labelName))
            {
                bestLen = rule.selector.length;
                best = rule.style;
                found = true;
            }
        }
        put(w, found ? best : StyleSpec.init);
    }

    defaults = StyleSpec(
        fg: normalizeDefault(theme.defaultFg),
        bg: normalizeDefault(theme.defaultBg));
}

/**
Resolves `theme` against `labels` into a freshly allocated `ResolvedTheme`.

Configure-time only (allocates the table once); see $(LREF writeThemeStyles)
for the `@nogc` output-range variant this delegates to.
*/
ResolvedTheme resolveTheme(in Theme theme, LabelSet labels) pure nothrow
{
    import std.array : appender;
    import std.exception : assumeUnique;

    auto styles = appender!(StyleSpec[]);
    styles.reserve(labels.length); // final size is known: one StyleSpec per label
    StyleSpec defaults;
    styles.writeThemeStyles(theme, labels, defaults);
    // Transfer the fresh, uniquely-owned array to the immutable table with no
    // second copy (vs `.idup`); the immutable cast is the only unsafe step.
    auto immStyles = (() @trusted => assumeUnique(styles[]))();
    return ResolvedTheme(labels, immStyles, defaults);
}

///
@("theme.resolveTheme.longestPrefixLastWins")
unittest
{
    const theme = Theme(
        name: "test",
        rules: [
            ThemeRule("string", StyleSpec(fg: Color.fromPalette(2))),
            ThemeRule("string.special", StyleSpec(fg: Color.fromPalette(5))),
            ThemeRule("string", StyleSpec(fg: Color.fromPalette(3))), // last wins
        ]);
    const labels = LabelSet.standard();
    const resolved = resolveTheme(theme, labels);

    // longest prefix beats rule order
    assert(resolved[labels.find("string.special.key")].fg == Color.fromPalette(5));
    // last rule wins among equal selectors
    assert(resolved[labels.find("string")].fg == Color.fromPalette(3));
    assert(resolved[labels.find("string.escape")].fg == Color.fromPalette(3));
    // unmatched label → empty spec
    assert(resolved[labels.find("keyword")].empty);
    // no-label text → defaults (normalized to unset here)
    assert(resolved[LabelId.none].empty);
}

@("theme.resolveTheme.noPartialSegmentMatch")
unittest
{
    // "str" must not match "string" — prefixes are whole dotted segments.
    const theme = Theme(name: "test", rules: [
        ThemeRule("str", StyleSpec(fg: Color.fromPalette(1))),
    ]);
    const labels = LabelSet.standard();
    const resolved = resolveTheme(theme, labels);
    assert(resolved[labels.find("string")].empty);
}

@("theme.writeThemeStyles.nogc")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.smallbuffer : SmallBuffer;

    // Resolves into a reused SmallBuffer with no GC — the interactive-previewer
    // path. `put` appends each StyleSpec, so no pre-sizing/fill is needed.
    ThemeRule[1] rules = [ThemeRule("string", StyleSpec(fg: Color.fromPalette(2)))];
    const theme = Theme(name: "t", defaultFg: Color.fromPalette(7), rules: rules[]);
    const labels = LabelSet.standard();

    SmallBuffer!(StyleSpec, 128) styles;
    StyleSpec defaults;
    writeThemeStyles(styles, theme, labels, defaults);

    auto s = styles[];
    assert(s[labels.find("string").value] == StyleSpec(fg: Color.fromPalette(2)));
    assert(s[labels.find("keyword").value] == StyleSpec.init);
    assert(defaults.fg == Color.fromPalette(7));
}

@("theme.writeThemeStyles.matchesWrapper")
@safe pure nothrow
unittest
{
    // The output-range path is identical to the GC wrapper, entry for entry.
    const theme = Theme(name: "t", defaultBg: Color.fromPalette(235), rules: [
        ThemeRule("string", StyleSpec(fg: Color.fromPalette(2))),
        ThemeRule("string.special", StyleSpec(fg: Color.fromPalette(5))),
        ThemeRule("comment", StyleSpec(fg: Color.fromPalette(8))),
    ]);
    const labels = LabelSet.standard();
    const wrapped = resolveTheme(theme, labels);

    import std.array : appender;

    auto buf = appender!(StyleSpec[]);
    StyleSpec defaults;
    buf.writeThemeStyles(theme, labels, defaults);

    assert(buf[] == wrapped.styles[]);
    assert(defaults == wrapped.defaults);
}

@("theme.StyleSpec.empty")
pure nothrow @nogc
unittest
{
    assert(StyleSpec.init.empty);
    assert(!StyleSpec(fg: Color.fromPalette(1)).empty);
    assert(!StyleSpec(font: FontStyle.bold).empty);
    assert(!StyleSpec(fg: Color.defaultColor).empty); // default_ counts as set
}

@("theme.hasFont")
pure nothrow @nogc
unittest
{
    const flags = cast(FontStyle)(FontStyle.bold | FontStyle.italic);
    assert(hasFont(flags, FontStyle.bold));
    assert(hasFont(flags, FontStyle.italic));
    assert(!hasFont(flags, FontStyle.underline));
    assert(!hasFont(flags, FontStyle.none));
}

/// `prefix` matches `full` iff equal, or `full` continues with `.` right
/// after `prefix` (whole-segment prefix matching).
private bool isDotPrefix(scope const(char)[] prefix, scope const(char)[] full) pure nothrow @nogc
{
    import std.algorithm.searching : startsWith;

    return full.startsWith(prefix)
        && (full.length == prefix.length || full[prefix.length] == '.');
}

private Color normalizeDefault(Color c) pure nothrow @nogc
    => c.kind == Color.Kind.default_ ? Color.init : c;
