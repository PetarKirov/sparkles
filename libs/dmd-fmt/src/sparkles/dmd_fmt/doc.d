/**
The `Doc` IR and the greedy layout engine — M2 of the dmd-fmt proposal,
implemented per decision D6 (`docs/specs/dmd-fmt/`): $(B Lindig's strict
form) of Wadler's algebra (an explicit `Flat`/`Break` mode tag on a
worklist — never the lazy formulation, which is exponential in a strict
language), with `fits` taking the $(B rest of the worklist) (Lindig's `z`),
`propagateBreaks` as a pre-pass (prettier), and prettier's three genuine
additions: `fill`, `ifBreak`/`lineSuffix`, and `conditionalGroup` — the
N-way primitive is in the IR from day one so M9's cost search is an
interpreter swap, not an IR rewrite.

Deviations from the papers, all decided in M0:

$(LIST
    * The width measurer is an $(B injected parameter) with a
        display-column default (East-Asian wide = 2) — graphemes undercount
        CJK, bytes are simply wrong.
    * The engine can start $(B mid-document) at an inherited (column,
        indent) — D2's range-model requirement, a constructor parameter
        rather than an M6 retrofit.
    * A `verbatim` node carries text that may contain newlines and is
        emitted untouched (no indentation applied) — the do-no-harm valve's
        representation in the IR: `// dfmt off` regions, directives and the
        `__EOF__` tail flow through it.
)
*/
module sparkles.dmd_fmt.doc;

import std.array : appender;

/// The node kinds of the layout IR. See the module doc for provenance.
enum DocKind : ubyte
{
    text,       /// literal text, no newline
    verbatim,   /// literal that may contain newlines; emitted untouched
    line,       /// a space when flat, a newline+indent when broken
    softline,   /// nothing when flat, a newline+indent when broken
    hardline,   /// always a newline+indent; forces enclosing groups to break
    group,      /// flat if it fits, else broken; subgroups re-decide (Lindig §2)
    fill,       /// break only the separators that fall at line ends (Oppen's inconsistent)
    indentBlock, /// one more indentation level around the children
    alignBlock, /// `alignCols` more columns around the children
    ifBreak,    /// `text_` when the enclosing group broke, `altText` when flat
    lineSuffix, /// deferred text, flushed just before the next newline
    conditional, /// ordered alternatives; first that fits flat, else the last, broken
    sequence,   /// plain concatenation
}

/// One IR node. Build with the factory functions below.
struct Doc
{
    DocKind kind;
    string text_;
    string altText;
    int alignCols;
    Doc[] children;
    /// Set by `propagateBreaks`: this group/conditional contains a hard
    /// break and can never be flat.
    bool forcedBreak;
}

/// Literal text (must not contain a newline; use [verbatim] for that).
Doc text(string s) @safe pure nothrow => Doc(DocKind.text, s);
/// Raw text emitted untouched; may contain newlines.
Doc verbatim(string s) @safe pure nothrow => Doc(DocKind.verbatim, s);
/// A break point: space when flat.
Doc line() @safe pure nothrow => Doc(DocKind.line);
/// A break point: nothing when flat.
Doc softline() @safe pure nothrow => Doc(DocKind.softline);
/// An unconditional newline.
Doc hardline() @safe pure nothrow => Doc(DocKind.hardline);
/// Flat-if-it-fits over the children.
Doc group(Doc[] children...) @safe pure nothrow
    => Doc(DocKind.group, null, null, 0, children.dup);
/// Oppen's inconsistent breaking over the children.
Doc fill(Doc[] children...) @safe pure nothrow
    => Doc(DocKind.fill, null, null, 0, children.dup);
/// One extra indentation level around the children.
Doc indented(Doc[] children...) @safe pure nothrow
    => Doc(DocKind.indentBlock, null, null, 0, children.dup);
/// `cols` extra columns around the children.
Doc aligned(int cols, Doc[] children...) @safe pure nothrow
    => Doc(DocKind.alignBlock, null, null, cols, children.dup);
/// `broken` when the enclosing group broke, `flat` otherwise.
Doc ifBreak(string broken, string flat = null) @safe pure nothrow
    => Doc(DocKind.ifBreak, broken, flat);
/// Deferred text (a trailing comment), flushed before the next newline.
Doc lineSuffix(string s) @safe pure nothrow => Doc(DocKind.lineSuffix, s);
/// Ordered alternatives: the first that fits flat wins, else the last.
Doc conditional(Doc[] alternatives...) @safe pure nothrow
    => Doc(DocKind.conditional, null, null, 0, alternatives.dup);
/// Plain concatenation.
Doc sequence(Doc[] children...) @safe pure nothrow
    => Doc(DocKind.sequence, null, null, 0, children.dup);

/// Rendering parameters. `measure` is the injected width model (D6).
struct RenderOptions
{
    /// The line width `fits` tests against.
    int width = 100;
    /// Columns per indentation level.
    int indentSize = 4;
    /// Emit tabs for indentation (one tab per `tabWidth` columns).
    bool useTabs = false;
    /// Columns one tab advances (only used when `useTabs`).
    int tabWidth = 4;
    /// Mid-document start: the column the first character lands on.
    int startColumn = 0;
    /// Mid-document start: the indentation (in columns) of new lines.
    int startIndent = 0;
    /// The width model; defaults to display columns.
    size_t function(const(char)[]) @safe pure nothrow @nogc measure = &displayWidth;
}

/**
Display-column width: East-Asian wide characters count 2, combining marks 0,
everything else 1. A compact approximation of `wcwidth` — the ranges cover
CJK, Hangul, full-width forms and the common combining blocks; callers with
stricter needs inject their own measure.
*/
size_t displayWidth(const(char)[] s) @safe pure nothrow @nogc
{
    size_t cols;
    for (size_t i = 0; i < s.length;)
    {
        dchar c;
        const b = s[i];
        if (b < 0x80)
        {
            c = b;
            i += 1;
        }
        else if ((b & 0xE0) == 0xC0 && i + 1 < s.length)
        {
            c = ((b & 0x1F) << 6) | (s[i + 1] & 0x3F);
            i += 2;
        }
        else if ((b & 0xF0) == 0xE0 && i + 2 < s.length)
        {
            c = ((b & 0x0F) << 12) | ((s[i + 1] & 0x3F) << 6) | (s[i + 2] & 0x3F);
            i += 3;
        }
        else if ((b & 0xF8) == 0xF0 && i + 3 < s.length)
        {
            c = ((b & 0x07) << 18) | ((s[i + 1] & 0x3F) << 12)
                | ((s[i + 2] & 0x3F) << 6) | (s[i + 3] & 0x3F);
            i += 4;
        }
        else
        {
            i += 1; // invalid byte: count 1, resync
            cols += 1;
            continue;
        }
        cols += columnWidth(c);
    }
    return cols;
}

private size_t columnWidth(dchar c) @safe pure nothrow @nogc
{
    // Combining marks: zero columns.
    if ((c >= 0x0300 && c <= 0x036F) || (c >= 0x1AB0 && c <= 0x1AFF)
        || (c >= 0x20D0 && c <= 0x20FF) || (c >= 0xFE00 && c <= 0xFE0F))
        return 0;
    // East-Asian wide / full-width: two columns.
    if ((c >= 0x1100 && c <= 0x115F) || (c >= 0x2E80 && c <= 0xA4CF)
        || (c >= 0xAC00 && c <= 0xD7A3) || (c >= 0xF900 && c <= 0xFAFF)
        || (c >= 0xFE30 && c <= 0xFE4F) || (c >= 0xFF00 && c <= 0xFF60)
        || (c >= 0xFFE0 && c <= 0xFFE6) || (c >= 0x1F300 && c <= 0x1F64F)
        || (c >= 0x20000 && c <= 0x3FFFD))
        return 2;
    return 1;
}

private enum Mode : ubyte
{
    flat,
    brk,
}

private struct Cmd
{
    int indent; // columns
    Mode mode;
    Doc* doc;
}

/**
Mark every `group`/`conditional` that transitively contains a hard break
(`hardline`, or a `verbatim` with a newline) as `forcedBreak`, so `fits` is
never consulted for a group that cannot be flat (prettier's
`propagateBreaks`). Width-independent, hence safe to run once per tree.
*/
void propagateBreaks(ref Doc doc) @safe pure nothrow
{
    forcesBreak(doc);
}

private bool forcesBreak(ref Doc doc) @safe pure nothrow
{
    final switch (doc.kind)
    {
        case DocKind.hardline:
            return true;
        case DocKind.verbatim:
            foreach (ch; doc.text_)
                if (ch == '\n')
                    return true;
            return false;
        case DocKind.group:
        {
            bool forced;
            foreach (ref child; doc.children)
                forced |= forcesBreak(child);
            doc.forcedBreak = forced;
            return forced;
        }
        case DocKind.conditional:
        {
            // Alternatives are alternatives: a hard break inside ONE of
            // them must not force the conditional — the engine simply won't
            // pick that alternative flat. Only when EVERY alternative
            // forces does the break propagate to the enclosing group.
            bool all = doc.children.length != 0;
            foreach (ref child; doc.children)
                all = forcesBreak(child) && all;
            return all;
        }
        case DocKind.text, DocKind.line, DocKind.softline, DocKind.ifBreak,
            DocKind.lineSuffix:
            return false;
        case DocKind.fill, DocKind.indentBlock, DocKind.alignBlock,
            DocKind.sequence:
        {
            bool forced;
            foreach (ref child; doc.children)
                forced |= forcesBreak(child);
            return forced;
        }
    }
}

/**
Propagate breaks and render. The root is heap-boxed: the engine holds
pointers into the tree for its whole run, which a stack local's address may
not do under `dip1000` (inherited by the unittest build).
*/
string layout(Doc doc, RenderOptions opt = RenderOptions()) @safe
{
    auto root = new Doc;
    *root = doc;
    propagateBreaks(*root);
    auto engine = new Engine(opt);
    engine.run(root);
    return engine.sink[];
}

private struct Engine
{
    import std.array : Appender;

    const RenderOptions opt;
    Appender!string sink;
    int column;
    Doc*[] suffixes; // pending lineSuffix nodes, in emission order

    this(RenderOptions opt) @safe
    {
        this.opt = opt;
        this.sink = appender!string;
    }

    void run(Doc* root) @safe
    {
        column = opt.startColumn;
        Cmd[] stack = [Cmd(opt.startIndent, Mode.brk, root)];
        while (stack.length)
        {
            auto cmd = stack[$ - 1];
            stack.length--;
            step(cmd, stack);
        }
        flushSuffixes();
    }

    private void step(Cmd cmd, ref Cmd[] stack) @safe
    {
        auto doc = cmd.doc;
        final switch (doc.kind)
        {
            case DocKind.text:
                sink.put(doc.text_);
                column += cast(int) opt.measure(doc.text_);
                break;

            case DocKind.verbatim:
                emitVerbatim(doc.text_);
                break;

            case DocKind.line, DocKind.softline, DocKind.hardline:
                if (doc.kind != DocKind.hardline && cmd.mode == Mode.flat)
                {
                    if (doc.kind == DocKind.line)
                    {
                        sink.put(' ');
                        column += 1;
                    }
                    break;
                }
                newline(cmd.indent);
                break;

            case DocKind.group:
                const mode = doc.forcedBreak ? Mode.brk
                    : fits(opt.width - column, doc, stack) ? Mode.flat : Mode.brk;
                pushChildren(stack, doc.children, cmd.indent, mode);
                break;

            case DocKind.conditional:
                if (doc.children.length == 0)
                    break;
                size_t chosen = doc.children.length - 1;
                Mode mode = Mode.brk;
                if (!doc.forcedBreak)
                    foreach (i, ref alt; doc.children)
                        if (fits(opt.width - column, &alt, stack))
                        {
                            chosen = i;
                            mode = Mode.flat;
                            break;
                        }
                stack ~= Cmd(cmd.indent, mode, &doc.children[chosen]);
                break;

            case DocKind.fill:
                // Oppen's inconsistent breaking: each child is decided on
                // its own — flat when it fits in the remaining width, on a
                // fresh line otherwise. Children are processed in order via
                // a re-entrant marker scheme kept simple: decide the first
                // child now, requeue the rest as another fill.
                if (doc.children.length == 0)
                    break;
                if (doc.children.length > 1)
                {
                    auto rest = new Doc(DocKind.fill, null, null, 0,
                        doc.children[1 .. $]);
                    stack ~= Cmd(cmd.indent, cmd.mode, rest);
                }
                auto first = &doc.children[0];
                const flat = fits(opt.width - column, first, stack);
                stack ~= Cmd(cmd.indent, flat ? Mode.flat : Mode.brk, first);
                break;

            case DocKind.indentBlock:
                pushChildren(stack, doc.children,
                    cmd.indent + opt.indentSize, cmd.mode);
                break;

            case DocKind.alignBlock:
                pushChildren(stack, doc.children,
                    cmd.indent + doc.alignCols, cmd.mode);
                break;

            case DocKind.ifBreak:
                const t = cmd.mode == Mode.brk ? doc.text_ : doc.altText;
                if (t.length)
                {
                    sink.put(t);
                    column += cast(int) opt.measure(t);
                }
                break;

            case DocKind.lineSuffix:
                suffixes ~= doc;
                break;

            case DocKind.sequence:
                pushChildren(stack, doc.children, cmd.indent, cmd.mode);
                break;
        }
    }

    private void pushChildren(ref Cmd[] stack, Doc[] children,
        int indent, Mode mode) @safe
    {
        foreach_reverse (ref child; children)
            stack ~= Cmd(indent, mode, &child);
    }

    private void newline(int indent) @safe
    {
        flushSuffixes();
        sink.put('\n');
        emitIndent(indent);
    }

    private void flushSuffixes() @safe
    {
        foreach (s; suffixes)
        {
            sink.put(s.text_);
            column += cast(int) opt.measure(s.text_);
        }
        suffixes.length = 0;
    }

    private void emitIndent(int cols) @safe
    {
        if (opt.useTabs)
        {
            foreach (_; 0 .. cols / opt.tabWidth)
                sink.put('\t');
            foreach (_; 0 .. cols % opt.tabWidth)
                sink.put(' ');
        }
        else
            foreach (_; 0 .. cols)
                sink.put(' ');
        column = cols;
    }

    private void emitVerbatim(const(char)[] raw) @safe
    {
        // Untouched bytes; recompute the column from the last newline.
        size_t lastNl = size_t.max;
        foreach_reverse (i, ch; raw)
            if (ch == '\n')
            {
                lastNl = i;
                break;
            }
        if (lastNl != size_t.max)
        {
            flushSuffixes();
            column = cast(int) opt.measure(raw[lastNl + 1 .. $]);
        }
        else
            column += cast(int) opt.measure(raw);
        sink.put(raw);
    }

    /// Lindig's `fits`: measure `candidate` flat, followed by the rest of
    /// the worklist (`z`), stopping at the first newline reached in break
    /// mode or when the budget is exhausted.
    private bool fits(int remaining, Doc* candidate, Cmd[] rest) @safe
    {
        Cmd[] stack = [Cmd(0, Mode.flat, candidate)];
        size_t restIndex = rest.length; // consumed top-down (it is a stack)
        while (remaining >= 0)
        {
            if (!stack.length)
            {
                if (restIndex == 0)
                    return true;
                restIndex--;
                stack ~= rest[restIndex];
                continue;
            }
            auto cmd = stack[$ - 1];
            stack.length--;
            auto doc = cmd.doc;
            final switch (doc.kind)
            {
                case DocKind.text:
                    remaining -= cast(int) opt.measure(doc.text_);
                    break;
                case DocKind.verbatim:
                    foreach (ch; doc.text_)
                        if (ch == '\n')
                            return true;
                    remaining -= cast(int) opt.measure(doc.text_);
                    break;
                case DocKind.line, DocKind.softline:
                    if (cmd.mode == Mode.brk)
                        return true;
                    if (doc.kind == DocKind.line)
                        remaining -= 1;
                    break;
                case DocKind.hardline:
                    // In flat context a hard break is unrepresentable.
                    return cmd.mode == Mode.brk;
                case DocKind.group:
                    if (doc.forcedBreak && cmd.mode == Mode.flat)
                        return false;
                    pushFlat(stack, doc.children,
                        doc.forcedBreak ? Mode.brk : Mode.flat);
                    break;
                case DocKind.conditional:
                    if (doc.forcedBreak && cmd.mode == Mode.flat)
                        return false;
                    if (doc.children.length)
                        stack ~= Cmd(0, cmd.mode, &doc.children[0]);
                    break;
                case DocKind.fill, DocKind.sequence, DocKind.indentBlock,
                    DocKind.alignBlock:
                    pushFlat(stack, doc.children, cmd.mode);
                    break;
                case DocKind.ifBreak:
                    const t = cmd.mode == Mode.brk ? doc.text_ : doc.altText;
                    remaining -= cast(int) opt.measure(t);
                    break;
                case DocKind.lineSuffix:
                    break;
            }
        }
        return false;
    }

    private static void pushFlat(ref Cmd[] stack, Doc[] children,
        Mode mode) @safe
    {
        foreach_reverse (ref child; children)
            stack ~= Cmd(0, mode, &child);
    }
}

// ---------------------------------------------------------------------------

@("doc.group.flat-when-it-fits-broken-when-not")
@safe unittest
{
    auto d = group(text("aaa"), line, text("bbb"));
    RenderOptions wide = {width: 20};
    assert(layout(d, wide) == "aaa bbb");
    RenderOptions narrow = {width: 5};
    assert(layout(d, narrow) == "aaa\nbbb");
}

@("doc.fits.accounts-for-the-rest-of-the-worklist")
@safe unittest
{
    // The group alone fits in 10 columns; with the trailing text it does
    // not — Lindig's `z` is what makes the group break anyway.
    auto d = sequence(group(text("aaa"), line, text("bbb")), text("_cccc"));
    RenderOptions opt = {width: 10};
    assert(layout(d, opt) == "aaa\nbbb_cccc");
}

@("doc.group.subgroups-re-decide-independently")
@safe unittest
{
    // Lindig §2: the outer group breaks, the inner one still fits flat.
    auto d = group(text("aaaa"), line,
        group(text("b"), line, text("c")), line, text("dddd"));
    RenderOptions opt = {width: 6};
    assert(layout(d, opt) == "aaaa\nb c\ndddd");
}

@("doc.hardline.forces-enclosing-groups")
@safe unittest
{
    auto d = group(text("a"), hardline, text("b"));
    RenderOptions opt = {width: 80};
    assert(layout(d, opt) == "a\nb");

    // ...and ifBreak sees the forced break.
    auto e = group(text("["), text("x"), ifBreak(",", ""), hardline, text("]"));
    assert(layout(e, opt) == "[x,\n]");
}

@("doc.list.trailing-comma-pattern")
@safe unittest
{
    auto list = group(text("["),
        indented(softline, text("1"), text(","), line, text("2"),
            ifBreak(",", "")),
        softline, text("]"));
    RenderOptions wide = {width: 20};
    assert(layout(list, wide) == "[1, 2]");
    RenderOptions narrow = {width: 4};
    assert(layout(list, narrow) == "[\n    1,\n    2,\n]");
}

@("doc.conditional.first-fitting-alternative-wins")
@safe unittest
{
    auto d = conditional(
        text("the-long-alternative"),
        text("medium-alt"),
        sequence(text("short"), hardline, text("rest")));
    RenderOptions w12 = {width: 12};
    assert(layout(d, w12) == "medium-alt");
    RenderOptions w30 = {width: 30};
    assert(layout(d, w30) == "the-long-alternative");
    RenderOptions w4 = {width: 4};
    assert(layout(d, w4) == "short\nrest");
}

@("doc.lineSuffix.flushes-before-the-newline")
@safe unittest
{
    auto d = sequence(text("int a;"), lineSuffix(" // trailing"), hardline,
        text("int b;"));
    RenderOptions opt = {width: 80};
    assert(layout(d, opt) == "int a; // trailing\nint b;");
}

@("doc.verbatim.untouched-and-column-reset")
@safe unittest
{
    auto d = sequence(text("a"), verbatim("<raw\n  raw>"),
        group(text("bb"), line, text("cc")));
    RenderOptions opt = {width: 12};
    // After the verbatim, the column is 7 (`  raw>`), so `bb cc` fits.
    assert(layout(d, opt) == "a<raw\n  raw>bb cc");
}

@("doc.mid-document-start")
@safe unittest
{
    auto d = group(text("aaa"), line, text("bbb"));
    RenderOptions opt = {width: 10, startColumn: 6, startIndent: 8};
    // 6 + 7 > 10, so the group breaks; the new line lands at indent 8.
    assert(layout(d, opt) == "aaa\n        bbb");
}

@("doc.tabs-and-indent-size")
@safe unittest
{
    auto d = sequence(text("{"), indented(hardline, text("x")), hardline,
        text("}"));
    RenderOptions tabs = {width: 80, useTabs: true, indentSize: 4, tabWidth: 4};
    assert(layout(d, tabs) == "{\n\tx\n}");
    RenderOptions two = {width: 80, indentSize: 2};
    assert(layout(d, two) == "{\n  x\n}");
}

@("doc.measure.injected-width-model")
@safe unittest
{
    static size_t wideW(const(char)[] s) @safe pure nothrow @nogc
    {
        size_t n;
        foreach (ch; s)
            n += ch == 'W' ? 3 : 1;
        return n;
    }

    auto d = group(text("WW"), line, text("x"));
    RenderOptions opt = {width: 7, measure: &wideW};
    assert(layout(d, opt) == "WW\nx"); // 6 + 1 + 1 > 7
    RenderOptions dflt = {width: 7};
    assert(layout(d, dflt) == "WW x");
}

@("doc.displayWidth.east-asian-and-combining")
@safe unittest
{
    assert(displayWidth("abc") == 3);
    assert(displayWidth("日本語") == 6);
    assert(displayWidth("é") == 1); // e + combining acute
    assert(displayWidth("ｆｕｌｌ") == 8); // full-width forms
}

@("doc.fill.breaks-only-at-line-ends")
@safe unittest
{
    auto d = fill(text("one"), line, text("two"), line, text("three"), line,
        text("four"));
    RenderOptions opt = {width: 9};
    assert(layout(d, opt) == "one two\nthree\nfour");
}
