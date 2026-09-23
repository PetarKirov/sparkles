/**
The degradation report (`CAP6`): what a frame asked for that its target could
not honour, and the published substitution it got instead.

A capability the target lacks is never silently dropped. Each way of making do
is a member of $(LREF Substitution), and each member names — as data, checked
at compile time — the $(REF TargetCapabilities, sparkles,ui,tokens) field whose
absence triggers it (`CAP2`). $(LREF degradationsOf) walks a built display list
against a declaration and counts the substitutions, so the same frame can be
asked "what did this cost at `baseline`?" and "at `full`?" without painting it
twice.

The report describes the $(I contract), not one painter: a cell backend that
receives `unicode = false` must draw ASCII chrome, and the report says it will.
Each row carries a test against `sparkles:ui-tui`'s grid painter that the
painter does what the row claims.
*/
module sparkles.ui.degradation;

import std.traits : EnumMembers, getUDAs;

import sparkles.base.term_color : ColorDepth;
import sparkles.base.term_style : UnderlineStyle;
import sparkles.ui.canvas : DrawOp, FillRect, Glyph, Ink, Line, LineStyle, match,
    PopClip, PushClip, Rule, Scrollbar, TextRun;
import sparkles.ui.style : BorderStyle, FontRole;
import sparkles.ui.tokens : BoxCharset, projectBorder, TargetCapabilities;
import sparkles.wired.policy : AnyFormat, CaseStyle, resolveCaseStyle, WireCase,
    wireNames;

/// The capability field whose absence triggers a $(LREF Substitution) — a
/// UDA, so the mapping is declared on the member and checked against
/// $(REF TargetCapabilities, sparkles,ui,tokens) at compile time.
struct needs
{
    string field; /// a member of `TargetCapabilities` (or of its `output`)
}

/**
Each published way a frame makes do (`CAP6`), in report order.

Adding a member means naming its capability; the `static assert` below rejects
a name that is not a `TargetCapabilities` field, so a substitution can never
cite a capability the declaration cannot express (`CAP2`).
*/
@WireCase(CaseStyle.kebabCase)
enum Substitution : ubyte
{
    @needs("colorDepth") colorFolded,        /// RGB folded to the 256/16-color palette
    @needs("colorDepth") colorDropped,       /// no SGR color at all
    @needs("unicode") asciiBorder,           /// box, bar and rule chrome drawn with `+-|`
    @needs("unicode") asciiScrollbar,        /// scrollbar drawn with `|` and `#`
    @needs("radius") radiusAsGlyph,          /// a corner radius became rounded box corners
    @needs("radius") radiusDropped,          /// a corner radius became square corners
    @needs("shadow") shadowDropped,          /// a drop shadow was not drawn
    @needs("alpha") alphaFlattened,          /// translucency pre-composited or drawn opaque
    @needs("hyperlinks") linkAsText,         /// a link run painted as plain styled text
    @needs("extendedUnderline") plainUnderline, /// a curly, dotted or dashed underline became a straight one
    @needs("textSizing") textSizeIgnored,    /// a scaled run painted at 1em
    @needs("proportionalText") monospaceDocs, /// a docs run painted in the monospace face
}

/// The kebab-case names (`ascii-border`, …), from the enum's own `@WireCase`.
alias substitutionNames = wireNames!(AnyFormat, Substitution,
    resolveCaseStyle!(AnyFormat, Substitution));

/// The capability each substitution cites, from its `@needs` UDA.
static immutable string[] substitutionCapabilities = () {
    string[] r;
    static foreach (m; EnumMembers!Substitution)
        r ~= getUDAs!(m, needs)[0].field;
    return r;
}();

static foreach (i, m; EnumMembers!Substitution)
{
    static assert(m == i, "Substitution must stay a contiguous 0-based enum");
    static assert(getUDAs!(m, needs).length == 1,
        "every Substitution names exactly one capability");
    static assert(__traits(hasMember, TargetCapabilities, getUDAs!(m, needs)[0].field),
        "`" ~ getUDAs!(m, needs)[0].field ~ "` is not a TargetCapabilities field");
}

/// How many operations of one frame took each substitution.
struct DegradationReport
{
    uint[EnumMembers!Substitution.length] counts; /// indexed by `Substitution`

    /// The count for `s`.
    uint opIndex(Substitution s) const @safe pure nothrow @nogc => counts[s];

    /// `true` iff the frame rendered exactly as authored.
    bool empty() const @safe pure nothrow @nogc
    {
        foreach (c; counts)
            if (c)
                return false;
        return true;
    }

    /**
    One line per substitution taken, in declaration order:
    `ascii-border ×3 (unicode)`. An empty report writes nothing — a caller
    that wants a verdict asks $(LREF DegradationReport.empty).
    */
    void toString(W)(ref W w) const
    {
        import std.range.primitives : put;
        import sparkles.base.text.writers : writeInteger;

        foreach (i, c; counts)
        {
            if (!c)
                continue;
            put(w, substitutionNames[i]);
            put(w, " ×");
            writeInteger(w, c);
            put(w, " (");
            put(w, substitutionCapabilities[i]);
            put(w, ")\n");
        }
    }

    private void note(Substitution s) @safe pure nothrow @nogc
    {
        ++counts[s];
    }
}

/**
The substitutions `ops` takes on a target declaring `caps` (`CAP6`).

One count per operation per substitution: a bordered, translucent box on a
`baseline` terminal counts once under `ascii-border`, once under
`alpha-flattened` and once under `color-dropped`.
*/
DegradationReport degradationsOf(in DrawOp[] ops, in TargetCapabilities caps)
    @safe pure nothrow @nogc
{
    DegradationReport r;

    void color()
    {
        if (caps.colorDepth == ColorDepth.none)
            r.note(Substitution.colorDropped);
        else if (caps.colorDepth != ColorDepth.trueColor)
            r.note(Substitution.colorFolded);
    }

    void ink(in Ink k)
    {
        color();
        if (!caps.alpha && (k.fgAlpha != 0xFF || (k.hasBg && k.bgAlpha != 0xFF)
                || (k.underline != UnderlineStyle.none && k.underlineAlpha != 0xFF)))
            r.note(Substitution.alphaFlattened);
        if (!caps.hyperlinks && k.linkId != 0)
            r.note(Substitution.linkAsText);
        if (!caps.extendedUnderline && k.underline != UnderlineStyle.none
                && k.underline != UnderlineStyle.single)
            r.note(Substitution.plainUnderline);
        if (!caps.textSizing && k.fontScale != 100)
            r.note(Substitution.textSizeIgnored);
        if (!caps.proportionalText && k.fontRole == FontRole.docs)
            r.note(Substitution.monospaceDocs);
    }

    foreach (ref op; ops)
        op.match!(
            (in FillRect f) {
                if (f.hasBg || f.chrome !is null)
                    color();
                if (!caps.alpha && f.hasBg && f.bgAlpha != 0xFF)
                    r.note(Substitution.alphaFlattened);
                if (f.chrome is null)
                    return;
                const ch = f.chrome;
                // A cell target strokes a bottom-only border as the row's
                // underline (a one-row solid one is a `─` rule instead), so
                // it takes no glyph — but a dotted or dashed one needs the
                // styled underline.
                const bw = ch.border.width;
                const underline = bw.bottom > 0 && bw.top == 0 && bw.left == 0
                    && bw.right == 0
                    && !(ch.border.style == BorderStyle.solid && f.rect.height == 1);
                if (ch.border.any && !caps.unicode && !underline)
                    r.note(Substitution.asciiBorder);
                if (underline && !caps.extendedUnderline
                        && (ch.border.style == BorderStyle.dotted
                            || ch.border.style == BorderStyle.dashed))
                    r.note(Substitution.plainUnderline);
                if (ch.borderRadius > 0 && !caps.radius)
                    r.note(projectBorder(ch.border, ch.borderRadius, caps).charset
                        == BoxCharset.rounded
                        ? Substitution.radiusAsGlyph : Substitution.radiusDropped);
                if (ch.shadow.any && !caps.shadow)
                    r.note(Substitution.shadowDropped);
            },
            (in TextRun t) => ink(t.ink),
            (in Glyph g) => ink(g.ink),
            (in Line l) {
                ink(l.ink);
                if (!caps.extendedUnderline && l.style == LineStyle.wavy)
                    r.note(Substitution.plainUnderline);
                // A vertical line is drawn as a bar glyph on a cell target.
                if (!caps.unicode && l.from.x == l.to.x && l.from.y != l.to.y)
                    r.note(Substitution.asciiBorder);
            },
            (in Rule ru) {
                ink(ru.ink);
                if (!caps.unicode)
                    r.note(Substitution.asciiBorder);
            },
            (in Scrollbar s) {
                color();
                if (!caps.unicode)
                    r.note(Substitution.asciiScrollbar);
                if (!caps.alpha && (s.fgAlpha != 0xFF || (s.trackLit && s.trackAlpha != 0xFF)))
                    r.note(Substitution.alphaFlattened);
            },
            (in PushClip _) {},
            (in PopClip _) {},
        );
    return r;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest)
{
    import sparkles.base.term_color : RgbColor;
    import sparkles.ui.canvas : BoxChrome;
    import sparkles.ui.geometry : Insets, Point, Rect;
    import sparkles.ui.style : BoxBorder, Shadow;
    import sparkles.ui.tokens : capabilitiesOf, Profile;
}

@("ui.degradation.names.fromTheEnum")
@safe pure nothrow @nogc
unittest
{
    assert(substitutionNames[Substitution.asciiBorder] == "ascii-border");
    assert(substitutionNames[Substitution.plainUnderline] == "plain-underline");
    assert(substitutionCapabilities[Substitution.asciiBorder] == "unicode");
    assert(substitutionCapabilities[Substitution.colorFolded] == "colorDepth");
}

@("ui.degradation.everyCapabilityCitedIsAField")
@safe pure nothrow @nogc
unittest
{
    // `CAP2`, the half a compiler can check: the static asserts above reject
    // an unknown field; this pins that the check is live by naming one that
    // is not.
    static assert(!__traits(hasMember, TargetCapabilities, "roundedCorners"));
}

@("ui.degradation.decoratedBoxAcrossProfiles")
@safe pure nothrow @nogc
unittest
{
    static immutable BoxChrome chrome = () {
        BoxChrome c;
        c.border.width = Insets(1, 1, 1, 1);
        c.border.style = BorderStyle.solid;
        c.borderRadius = 4;
        c.shadow.dy = 2;
        c.shadow.blur = 6;
        c.shadow.color = RgbColor(0, 0, 0);
        c.shadow.alpha = 0x80;
        return c;
    }();
    FillRect f;
    f.rect = Rect(0, 0, 10, 4);
    f.chrome = &chrome;
    f.hasBg = true;
    f.bgAlpha = 0xC0;
    const DrawOp[1] ops = [DrawOp(f)];

    const b = degradationsOf(ops[], capabilitiesOf(Profile.baseline));
    assert(b[Substitution.asciiBorder] == 1);
    assert(b[Substitution.radiusDropped] == 1, "ASCII has no rounded corner");
    assert(b[Substitution.radiusAsGlyph] == 0);
    assert(b[Substitution.shadowDropped] == 1);
    assert(b[Substitution.alphaFlattened] == 1);
    assert(b[Substitution.colorDropped] == 1);

    const e = degradationsOf(ops[], capabilitiesOf(Profile.enhanced));
    assert(e[Substitution.asciiBorder] == 0);
    assert(e[Substitution.radiusAsGlyph] == 1, "a unicode cell target rounds with `╭`");
    assert(e[Substitution.colorFolded] == 1 && e[Substitution.colorDropped] == 0);

    // A target that honours every axis reports nothing: `full` is a terminal,
    // so only a window-shaped declaration clears radius/shadow/alpha.
    auto window = capabilitiesOf(Profile.full);
    window.radius = window.shadow = window.alpha = true;
    assert(degradationsOf(ops[], window).empty);
}

@("ui.degradation.inkRows")
@safe pure nothrow @nogc
unittest
{
    TextRun t;
    t.text = "x";
    t.ink.linkId = 3;
    t.ink.underline = UnderlineStyle.curly;
    t.ink.fontScale = 150;
    t.ink.fontRole = FontRole.docs;
    Line squiggle;
    squiggle.from = Point(0, 1);
    squiggle.to = Point(4, 1);
    squiggle.style = LineStyle.wavy;
    const DrawOp[2] ops = [DrawOp(t), DrawOp(squiggle)];

    const b = degradationsOf(ops[], capabilitiesOf(Profile.baseline));
    assert(b[Substitution.linkAsText] == 1);
    assert(b[Substitution.plainUnderline] == 2);
    assert(b[Substitution.textSizeIgnored] == 1);
    assert(b[Substitution.monospaceDocs] == 1);
    assert(b[Substitution.asciiBorder] == 0, "a horizontal line is an underline, not a glyph");

    const f = degradationsOf(ops[], capabilitiesOf(Profile.full));
    assert(f[Substitution.linkAsText] == 0 && f[Substitution.plainUnderline] == 0);
    assert(f[Substitution.textSizeIgnored] == 0);
    assert(f[Substitution.monospaceDocs] == 1, "a terminal has one face at every profile");
}

@("ui.degradation.report.toString")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.buffer : checkToString;

    DegradationReport r;
    checkToString(r, "");
    r.counts[Substitution.asciiBorder] = 3;
    r.counts[Substitution.colorDropped] = 7;
    checkToString(r, "color-dropped ×7 (colorDepth)\nascii-border ×3 (unicode)\n");
    assert(!r.empty && DegradationReport.init.empty);
}
