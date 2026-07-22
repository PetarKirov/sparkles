module sparkles.base.term_style;

import sparkles.base.term_color : Color, ColorChannel, ColorDepth,
    writeSgrColorPacked, packColor, unpackColor;

// ─────────────────────────────────────────────────────────────────────────────
// Resolved terminal style + the minimal-transition SGR encoder
//
// These live before the module's `@safe pure nothrow:` label so
// `writeStyleTransition` (a template also driven by non-pure stdout writers)
// infers its attributes instead of being forced pure.
// ─────────────────────────────────────────────────────────────────────────────

/// The text attributes of a resolved style, as a typed bitflag set. `underline`
/// is deliberately NOT here — on both $(LREF TermStyle) forms it is a first-class
/// $(LREF UnderlineStyle) stored in its own word (the shaped form additionally
/// carries an independent underline color). Bit 3 is $(LREF strikethrough) in
/// both modes. The typed `|`/`&`/`~` operators keep a set a `TextAttr` (no `cast`
/// back from the integer promotion an `enum` would give).
struct TextAttr
{
    ubyte bits; /// the raw flag bits

    enum TextAttr none          = TextAttr(0);      ///
    enum TextAttr bold          = TextAttr(1 << 0); /// SGR 1 / off 22 (shared with dim)
    enum TextAttr dim           = TextAttr(1 << 1); /// SGR 2 / off 22 (shared with bold)
    enum TextAttr italic        = TextAttr(1 << 2); /// SGR 3 / off 23
    enum TextAttr strikethrough = TextAttr(1 << 3); /// SGR 9 / off 29
    enum TextAttr inverse       = TextAttr(1 << 4); /// SGR 7 / off 27
    enum TextAttr hidden        = TextAttr(1 << 5); /// SGR 8 / off 28

@safe pure nothrow @nogc:

    /// Set union / intersection / difference — all stay `TextAttr`.
    TextAttr opBinary(string op)(TextAttr rhs) const
    if (op == "|" || op == "&" || op == "^")
        => TextAttr(cast(ubyte) mixin("bits " ~ op ~ " rhs.bits"));

    /// Complement (for clearing flags: `attrs & ~TextAttr.italic`).
    TextAttr opUnary(string op : "~")() const
        => TextAttr(cast(ubyte) ~bits);

    /// Non-empty test, so `if (attrs & TextAttr.bold)` works.
    pragma(inline, true)
    bool opCast(T : bool)() const => bits != 0;

    /// `true` iff every bit of `flag` is set (and `flag` is not `none`).
    pragma(inline, true)
    bool has(TextAttr flag) const
        => (bits & flag.bits) == flag.bits && flag.bits != 0;
}

/// Underline shape. `single` emits the legacy SGR `4`; the extended shapes emit
/// the colon sub-parameter form (`4:2`…`4:5`); all clear with `24`.
enum UnderlineStyle : ubyte
{
    none,    /// not underlined (SGR 24)
    single,  /// SGR 4
    double_, /// SGR 4:2
    curly,   /// SGR 4:3
    dotted,  /// SGR 4:4
    dashed,  /// SGR 4:5
}

// ── TermStyle bit-packing ──
//
// Colors and attributes are inlined into 32-bit words rather than composed as
// sub-type fields. A color needs 26 bits (a 2-bit `Color.Kind` tag over a
// 24-bit payload), so one color fits per word with room for a small attribute
// group alongside it. See the layout tables on $(LREF TermStyle).

private enum uint colorBits = 26;               // bits 0-25 of a word hold one packed color
private enum uint colorMask = (1u << colorBits) - 1;
private enum ubyte attrsMask = 0x3F;            // 6 `TextAttr` flag bits
private enum ubyte underlineMask = 0x07;        // 3 bits — `UnderlineStyle` 0-5 (both modes, in words[1])

// The Color <-> 26-bit codec (packColor/unpackColor) and the bit-decoding SGR
// emitter (writeSgrColorPacked) live in sparkles.base.term_color, which owns
// the Color vocabulary; they are imported at the top of this module.

/**
The resolved terminal style of one span/block.

The only difference between the two forms is the independent underline color:
`attrs` (bit 3 = strikethrough) and the `underline` shape live in the same bit
positions in both, so every getter/setter except `underlineColor` is shared.

$(PARAM shapedUnderline)
    $(LIST
        * `true` (default) — full design: `UnderlineStyle` shapes $(I plus) an
            independent underline color, bit-packed into $(B three) words. Used by
            `styled_template` and `sparkles.syntax` (`StyleSpec`).
        * `false` — compact cell-grid design: `UnderlineStyle` shapes but $(I no)
            underline color, bit-packed into $(B two) words (8 bytes). Used by
            `tui-render-bench` cells.
    )

Shaped layout (`shapedUnderline: true`):

$(TABLE
    $(TR $(TH word) $(TH bits 0-25) $(TH bits 26-31))
    $(TR $(TD 0) $(TD `fg`) $(TD `attrs` (6 flags; bit 3 = strikethrough)))
    $(TR $(TD 1) $(TD `bg`) $(TD `underline` shape (3 bits) + 3 spare))
    $(TR $(TD 2) $(TD `underlineColor`) $(TD 6 spare)))
)

Compact layout (`shapedUnderline: false`) — the shaped layout minus word 2:

$(TABLE
    $(TR $(TH word) $(TH bits 0-25) $(TH bits 26-31))
    $(TR $(TD 0) $(TD `fg`) $(TD `attrs` (6 flags; bit 3 = strikethrough)))
    $(TR $(TD 1) $(TD `bg`) $(TD `underline` shape (3 bits) + 3 spare)))
)

Storage is `align(1)` so cell grids pack styles without padding.
Bare $(LREF TermStyle) is an alias of the shaped form (`TermStyleImpl!true`).
*/
align(1) struct TermStyleImpl(bool shapedUnderline = true)
{
    enum wordCount = shapedUnderline ? 3 : 2;

    /// The packed words. `align(1)` so a cell grid packs styles without
    /// padding between cells. Stored as a bare array (not a `ubyte`/`uint`
    /// union): a union whose *active* member is not the first-declared one
    /// serializes to the first member's initializer when a value is baked
    /// into static data via CTFE — so a `static immutable TermStyle` (every
    /// `sparkles.syntax` builtin theme is one) would silently zero out,
    /// dropping all foreground colors and attributes at render time.
    align(1) private uint[wordCount] _words;

@safe pure nothrow @nogc:

    /// Construct from the logical fields. Named arguments bind to these
    /// parameters. This is a `static opCall` rather than a constructor
    /// because D forbids a struct constructor whose parameters all have
    /// defaults.
    static TermStyleImpl opCall(
        Color fg = Color.init,
        Color bg = Color.init,
        Color underlineColor = Color.init,
        TextAttr attrs = TextAttr.none,
        UnderlineStyle underline = UnderlineStyle.none,
    )
    {
        TermStyleImpl s;
        s._words[0] = packColor(fg) | (cast(uint)(attrs.bits & attrsMask) << colorBits);
        s._words[1] = packColor(bg) | (cast(uint)(underline & underlineMask) << colorBits);
        static if (shapedUnderline)
            s._words[2] = packColor(underlineColor);
        // else: compact drops underlineColor (no word 2).
        return s;
    }

    /// Foreground color; `unset` = unspecified.
    pragma(inline, true)
    Color fg() const scope => unpackColor(_words[0]);
    /// ditto
    pragma(inline, true)
    void fg(Color c) scope { _words[0] = packColor(c) | (_words[0] & ~colorMask); }

    /// Background color; `unset` = unspecified.
    pragma(inline, true)
    Color bg() const scope => unpackColor(_words[1]);
    /// ditto
    pragma(inline, true)
    void bg(Color c) scope { _words[1] = packColor(c) | (_words[1] & ~colorMask); }

    /// Underline color (SGR 58/59); always `unset` in compact mode.
    pragma(inline, true)
    Color underlineColor() const scope
    {
        static if (shapedUnderline)
            return unpackColor(_words[2]);
        else
            return Color.init;
    }
    /// ditto
    pragma(inline, true)
    void underlineColor(Color c) scope
    {
        static if (shapedUnderline)
            _words[2] = packColor(c);
        // compact: no storage — ignore
    }

    /// Text attributes (see `TextAttr` for mode-dependent bit 3).
    pragma(inline, true)
    TextAttr attrs() const scope => TextAttr(cast(ubyte)((_words[0] >> colorBits) & attrsMask));
    /// ditto
    pragma(inline, true)
    void attrs(TextAttr a) scope
        { _words[0] = (_words[0] & colorMask) | (cast(uint)(a.bits & attrsMask) << colorBits); }

    /// Underline shape (`none` = off). Stored in `words[1]` in both modes.
    pragma(inline, true)
    UnderlineStyle underline() const scope
        => cast(UnderlineStyle)((_words[1] >> colorBits) & underlineMask);
    /// ditto
    pragma(inline, true)
    void underline(UnderlineStyle u) scope
        { _words[1] = (_words[1] & colorMask) | (cast(uint)(u & underlineMask) << colorBits); }

    /// `true` iff nothing is set at all (renders unstyled).
    pragma(inline, true)
    bool empty() const scope
    {
        static if (shapedUnderline)
            return _words[0] == 0 && _words[1] == 0 && _words[2] == 0;
        else
            return _words[0] == 0 && _words[1] == 0;
    }

    /// Packed words for hot-path emission without materializing `Color`.
    /// Visible to `sparkles.*` — not part of the public style API.
    pragma(inline, true)
    package(sparkles) uint packed0() const scope => _words[0];
    /// ditto
    pragma(inline, true)
    package(sparkles) uint packed1() const scope => _words[1];
    /// ditto (always 0 in compact mode)
    pragma(inline, true)
    package(sparkles) uint packed2() const scope
    {
        static if (shapedUnderline)
            return _words[2];
        else
            return 0;
    }
}

/// Shaped form (three words) — the default for syntax / styled templates.
alias TermStyle = TermStyleImpl!true;

/// Compact cell-grid form (two words: the shaped layout without underline color).
alias CompactTermStyle = TermStyleImpl!false;

/// A differential ANSI encoder: writes the minimal merged SGR sequence moving
/// the terminal FROM style `from` TO style `to` at color `depth` — a single
/// `ESC[p1;p2;…m` carrying only the groups that changed, or nothing when the two
/// styles are equal. Each group is set absolutely, so the same function drives
/// both span entry (`writeStyleTransition(w, parent, child)`) and exit
/// (`writeStyleTransition(w, child, parent)`).
///
/// Group order: intensity (bold/dim), italic, underline, inverse, hidden,
/// strikethrough, foreground, background, underline color.
///
/// The `from == to` guard is load-bearing: past it the `ESC[`/`m` wrapper is
/// written unconditionally, and callers (e.g. `styled_template`) may issue no-op
/// transitions that must emit nothing rather than a spurious `ESC[m`.
void writeStyleTransition(Writer, bool shapedUnderline = true)(
    ref Writer w,
    in TermStyleImpl!shapedUnderline from,
    in TermStyleImpl!shapedUnderline to,
    ColorDepth depth,
)
{
    import std.range.primitives : put;
    import sparkles.base.text.writers : writeInteger;

    if (from == to)
        return;

    put(w, "\x1b[");
    bool first = true;
    void sep() { if (!first) put(w, ';'); first = false; }
    void code(uint c) { sep(); writeInteger(w, c); }

    // Read each grouped field off the packed words once. `attrs`/`underline`
    // are cheap bit extractions cached here to avoid re-extracting per check;
    // the three colors compare by their packed 26-bit slice directly (canonical
    // packing ⇒ masked-word equality *is* Color equality), so an unchanged color
    // costs one masked compare instead of materializing a Color on every span —
    // a Color is only rebuilt (`to.fg` etc.) on the rare span where it changed.
    const fromAttrs = from.attrs;
    const toAttrs = to.attrs;

    // Intensity: bold and dim share the off-code 22 (Style.bold[1] == Style.dim[1]).
    // If either is cleared, 22 clears both, so re-issue the survivor.
    const fromBD = fromAttrs & (TextAttr.bold | TextAttr.dim);
    const toBD = toAttrs & (TextAttr.bold | TextAttr.dim);
    if (fromBD != toBD)
    {
        if (fromBD & ~toBD)
        {
            code(Style.bold[1]); // 22 clears both bold and dim
            if (toBD & TextAttr.bold) code(Style.bold[0]);
            if (toBD & TextAttr.dim)  code(Style.dim[0]);
        }
        else
        {
            if ((toBD & TextAttr.bold) && !(fromBD & TextAttr.bold)) code(Style.bold[0]);
            if ((toBD & TextAttr.dim)  && !(fromBD & TextAttr.dim))  code(Style.dim[0]);
        }
    }

    if (fromAttrs.has(TextAttr.italic) != toAttrs.has(TextAttr.italic))
        code(toAttrs.has(TextAttr.italic) ? Style.italic[0] : Style.italic[1]);

    const toUnderline = to.underline;
    if (from.underline != toUnderline)
    {
        sep();
        final switch (toUnderline)
        {
            case UnderlineStyle.none:    writeInteger(w, Style.underline[1]); break; // 24
            case UnderlineStyle.single:  writeInteger(w, Style.underline[0]); break; // 4
            case UnderlineStyle.double_: put(w, "4:2"); break;
            case UnderlineStyle.curly:   put(w, "4:3"); break;
            case UnderlineStyle.dotted:  put(w, "4:4"); break;
            case UnderlineStyle.dashed:  put(w, "4:5"); break;
        }
    }

    if (fromAttrs.has(TextAttr.inverse) != toAttrs.has(TextAttr.inverse))
        code(toAttrs.has(TextAttr.inverse) ? Style.inverse[0] : Style.inverse[1]);
    if (fromAttrs.has(TextAttr.hidden) != toAttrs.has(TextAttr.hidden))
        code(toAttrs.has(TextAttr.hidden) ? Style.hidden[0] : Style.hidden[1]);
    if (fromAttrs.has(TextAttr.strikethrough) != toAttrs.has(TextAttr.strikethrough))
        code(toAttrs.has(TextAttr.strikethrough) ? Style.strikethrough[0] : Style.strikethrough[1]);

    // words[0]/[1] hold fg/bg in their low 26 bits; XOR-then-mask is nonzero iff
    // the color slice differs (the attribute bits in 26-31 are ignored here).
    // On a change we emit straight from the packed word — writeSgrColorPacked
    // reads only bits 0-25, so no Color is ever materialized on this hot path.
    if ((from.packed0 ^ to.packed0) & colorMask)
    {
        sep();
        writeSgrColorPacked(w, to.packed0, depth, ColorChannel.foreground);
    }
    if ((from.packed1 ^ to.packed1) & colorMask)
    {
        sep();
        writeSgrColorPacked(w, to.packed1, depth, ColorChannel.background);
    }
    static if (shapedUnderline)
    {
        // The underline color only exists at 256/truecolor; below that it is not
        // emitted at all (rather than a redundant reset), so the sequence stays clean.
        if (((from.packed2 ^ to.packed2) & colorMask) && depth >= ColorDepth.ansi256)
        {
            sep();
            writeSgrColorPacked(w, to.packed2, depth, ColorChannel.underline);
        }
    }

    put(w, 'm');
}

///
@("term_style.writeStyleTransition.basics")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.smallbuffer : checkWriter;

    checkWriter!((ref w) => writeStyleTransition(w, TermStyle.init, TermStyle.init, ColorDepth.trueColor))("");
    checkWriter!((ref w) => writeStyleTransition(w, TermStyle.init, TermStyle(attrs: TextAttr.bold), ColorDepth.trueColor))("\x1b[1m");
    // bold + red arrive in one escape
    checkWriter!((ref w) => writeStyleTransition(w, TermStyle.init,
        TermStyle(fg: Color.fromPalette(1), attrs: TextAttr.bold), ColorDepth.trueColor))("\x1b[1;31m");
    // bold → dim: 22 clears both, dim re-issued
    checkWriter!((ref w) => writeStyleTransition(w, TermStyle(attrs: TextAttr.bold),
        TermStyle(attrs: TextAttr.dim), ColorDepth.trueColor))("\x1b[22;2m");
    checkWriter!((ref w) => writeStyleTransition(w, TermStyle(fg: Color.fromPalette(1), attrs: TextAttr.bold),
        TermStyle.init, ColorDepth.trueColor))("\x1b[22;39m");
}

///
@("term_style.writeStyleTransition.underline")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.smallbuffer : checkWriter;

    checkWriter!((ref w) => writeStyleTransition(w, TermStyle.init,
        TermStyle(underline: UnderlineStyle.single), ColorDepth.trueColor))("\x1b[4m");
    checkWriter!((ref w) => writeStyleTransition(w, TermStyle(underline: UnderlineStyle.single),
        TermStyle.init, ColorDepth.trueColor))("\x1b[24m");
    checkWriter!((ref w) => writeStyleTransition(w, TermStyle.init,
        TermStyle(underline: UnderlineStyle.curly), ColorDepth.trueColor))("\x1b[4:3m");
    checkWriter!((ref w) => writeStyleTransition(w, TermStyle.init,
        TermStyle(underline: UnderlineStyle.dashed), ColorDepth.trueColor))("\x1b[4:5m");
    checkWriter!((ref w) => writeStyleTransition(w, TermStyle.init,
        TermStyle(underlineColor: Color.fromRgb(255, 0, 0), underline: UnderlineStyle.curly),
        ColorDepth.trueColor))("\x1b[4:3;58;2;255;0;0m");
    // underline color is dropped below ansi256
    checkWriter!((ref w) => writeStyleTransition(w, TermStyle.init,
        TermStyle(underlineColor: Color.fromRgb(255, 0, 0), underline: UnderlineStyle.curly),
        ColorDepth.ansi16))("\x1b[4:3m");
}

///
@("term_style.TermStyle.packing")
@safe pure nothrow @nogc
unittest
{
    // Shaped form is three words; compact is two — both byte-aligned.
    static assert(TermStyle.sizeof == 12);
    static assert(TermStyle.alignof == 1);
    static assert(CompactTermStyle.sizeof == 8);
    static assert(CompactTermStyle.alignof == 1);

    // Every Color.Kind round-trips through the packed representation.
    static foreach (c; [
        Color.init,                // unset
        Color.defaultColor,        // default_
        Color.fromPalette(200),    // palette
        Color.fromRgb(12, 34, 56), // rgb
    ])
        assert(unpackColor(packColor(c)) == c);

    // unset packs distinctly from a black RGB (matches Color's field-wise ==).
    assert(Color.init != Color.fromRgb(0, 0, 0));
    assert(packColor(Color.init) != packColor(Color.fromRgb(0, 0, 0)));

    // TermStyle.init is fully empty; setting any single group is not.
    assert(TermStyle.init.empty);
    assert(!TermStyle(attrs: TextAttr.bold).empty);

    // Getters materialize exactly what the named-arg constructor packed.
    const s = TermStyle(
        fg: Color.fromRgb(1, 2, 3),
        bg: Color.fromPalette(9),
        underlineColor: Color.defaultColor,
        attrs: TextAttr.bold | TextAttr.italic,
        underline: UnderlineStyle.curly,
    );
    assert(s.fg == Color.fromRgb(1, 2, 3));
    assert(s.bg == Color.fromPalette(9));
    assert(s.underlineColor == Color.defaultColor);
    assert(s.attrs == (TextAttr.bold | TextAttr.italic));
    assert(s.underline == UnderlineStyle.curly);

    // Mutating one group leaves the neighbouring bit-group in the same word intact.
    TermStyle m;
    m.fg = Color.fromRgb(200, 100, 50);
    m.attrs = TextAttr.strikethrough;    // shares words[0] with fg
    m.bg = Color.fromPalette(7);
    m.underline = UnderlineStyle.dotted; // shares words[1] with bg
    assert(m.fg == Color.fromRgb(200, 100, 50));
    assert(m.attrs == TextAttr.strikethrough);
    assert(m.bg == Color.fromPalette(7));
    assert(m.underline == UnderlineStyle.dotted);

    // Reconstructing from the getters compares equal to the original (canonical
    // packing → the default three-word opEquals is logical equality).
    assert(TermStyle(fg: m.fg, bg: m.bg, attrs: m.attrs, underline: m.underline) == m);

    // Compact stores underline in words[1] (like shaped) rather than aliasing the
    // strikethrough bit, so the two are fully independent — set together, read
    // back distinctly.
    const both = CompactTermStyle(attrs: TextAttr.strikethrough, underline: UnderlineStyle.single);
    assert(both.attrs.has(TextAttr.strikethrough));
    assert(both.underline == UnderlineStyle.single);
    assert(CompactTermStyle(attrs: TextAttr.strikethrough).underline == UnderlineStyle.none);
    assert(!CompactTermStyle(underline: UnderlineStyle.single).attrs.has(TextAttr.strikethrough));
}

/// A style baked into static data at compile time (every `sparkles.syntax`
/// builtin theme is a `static immutable` table of these) must survive
/// serialization with every field intact. Regression: when the packed words
/// lived in a `union { ubyte[…]; uint[…]; }`, CTFE emitted the union's *first*
/// (zero-initialized `ubyte`) member into the object file rather than the
/// active `uint` member, so a `static immutable TermStyle` silently read back
/// as `.init` — dropping all foreground colors and attributes at render time.
@("term_style.TermStyle.ctfeStaticInit")
@safe pure nothrow @nogc
unittest
{
    static immutable shaped = TermStyle(
        fg: Color.fromRgb(0xa6, 0xe3, 0xa1),
        bg: Color.fromPalette(235),
        attrs: TextAttr.bold | TextAttr.italic,
        underline: UnderlineStyle.curly,
    );
    assert(!shaped.empty);
    assert(shaped.fg == Color.fromRgb(0xa6, 0xe3, 0xa1));
    assert(shaped.bg == Color.fromPalette(235));
    assert(shaped.attrs == (TextAttr.bold | TextAttr.italic));
    assert(shaped.underline == UnderlineStyle.curly);
    // Byte-identical to the same value built at runtime — no CTFE/runtime skew.
    assert(shaped == TermStyle(
        fg: Color.fromRgb(0xa6, 0xe3, 0xa1),
        bg: Color.fromPalette(235),
        attrs: TextAttr.bold | TextAttr.italic,
        underline: UnderlineStyle.curly,
    ));

    static immutable compact = CompactTermStyle(
        fg: Color.fromRgb(1, 2, 3),
        attrs: TextAttr.bold,
    );
    assert(!compact.empty);
    assert(compact.fg == Color.fromRgb(1, 2, 3));
    assert(compact.attrs.has(TextAttr.bold));
}

///
@("term_style.TextAttr.ops")
@safe pure nothrow @nogc
unittest
{
    const flags = TextAttr.bold | TextAttr.italic;
    assert(flags.has(TextAttr.bold));
    assert(flags.has(TextAttr.italic));
    assert(!flags.has(TextAttr.strikethrough));
    assert(!flags.has(TextAttr.none));
    assert((flags & ~TextAttr.bold) == TextAttr.italic);
    assert(TextAttr.init == TextAttr.none);
}

@safe pure nothrow:

///
enum Style : uint[2]
{
    none = [uint.max, uint.max],
    reset = [0, 0],
    bold = [1, 22],
    dim = [2, 22],
    italic = [3, 23],
    underline = [4, 24],
    inverse = [7, 27],
    hidden = [8, 28],
    strikethrough = [9, 29],

    black = [30, 39],
    red = [31, 39],
    green = [32, 39],
    yellow = [33, 39],
    blue = [34, 39],
    magenta = [35, 39],
    cyan = [36, 39],
    white = [37, 39],
    gray = [90, 39],

    brightRed = [91, 39],
    brightGreen = [92, 39],
    brightYellow = [93, 39],
    brightBlue = [94, 39],
    brightMagenta = [95, 39],
    brightCyan = [96, 39],
    brightWhite = [97, 39],

    bgBlack = [40, 49],
    bgRed = [41, 49],
    bgGreen = [42, 49],
    bgYellow = [43, 49],
    bgBlue = [44, 49],
    bgMagenta = [45, 49],
    bgCyan = [46, 49],
    bgWhite = [47, 49],
    bgGray = [100, 49],

    bgBrightRed = [101, 49],
    bgBrightGreen = [102, 49],
    bgBrightYellow = [103, 49],
    bgBrightBlue = [104, 49],
    bgBrightMagenta = [105, 49],
    bgBrightCyan = [106, 49],
    bgBrightWhite = [107, 49],
}

/// The SGR "on" code of a style — the first of its `[open, close]` pair.
uint openCode(Style s) @nogc => s[0];

/// The SGR "off" code of a style — the second of its `[open, close]` pair.
/// Several styles share one (bold and dim both close with 22; every foreground
/// color with 39; every background color with 49), so a close code identifies
/// a *group* rather than a single style — see $(LREF SgrGroupReset).
uint closeCode(Style s) @nogc => s[1];

/// The SGR reset code of each attribute group. Because a group's members share
/// their close code, the reset names the group, not any one `Style`; the values
/// are sourced from the representative `Style` members so the numbers live in
/// exactly one place (the $(LREF Style) table above).
enum SgrGroupReset : uint
{
    intensity  = Style.bold[1],          /// 22 — bold and dim
    italic     = Style.italic[1],        /// 23
    underline  = Style.underline[1],     /// 24
    inverse    = Style.inverse[1],       /// 27
    hidden     = Style.hidden[1],        /// 28
    strike     = Style.strikethrough[1], /// 29
    foreground = Style.red[1],           /// 39 — every foreground color
    background = Style.bgRed[1],          /// 49 — every background color
}

///
@("term_style.openClose.groupReset")
@safe pure nothrow @nogc unittest
{
    assert(Style.bold.openCode == 1 && Style.bold.closeCode == 22);
    assert(Style.red.openCode == 31 && Style.red.closeCode == 39);
    // bold and dim share the intensity reset; every color shares fg/bg resets.
    assert(SgrGroupReset.intensity == Style.dim.closeCode);
    assert(SgrGroupReset.foreground == Style.brightBlue.closeCode);
    assert(SgrGroupReset.background == Style.bgWhite.closeCode);
}

///
auto stylizedTextBuilder(string text, bool resetAfter = true)
{
    static immutable struct StyleBuilder
    {
        alias payload this;
        string payload;
        bool resetAfter;

        this(string text, Style style, bool resetAfter)
        {
            payload = text.stylize(style, resetAfter);
            this.resetAfter = resetAfter;
        }

        import std.typecons : Ternary;
        StyleBuilder opDispatch(string styleName)(bool resetAfter)
        {
            return this.opDispatch!styleName(Ternary(resetAfter));
        }

        StyleBuilder opDispatch(string styleName)(Ternary resetAfter = Ternary.unknown)
        {
            enum enumMeber = "Style." ~ styleName;
            enum supported = __traits(compiles, mixin(enumMeber));
            static if (supported)
            {
                enum style = mixin(enumMeber);
                return StyleBuilder(
                    payload,
                    style,
                    resetAfter == Ternary.unknown
                        ? this.resetAfter
                        : resetAfter == Ternary.yes
                        ? true
                        : false
                );
            }
            else
                assert(0, "Unsupported style: '" ~ styleName ~ "'");
        }
    }

    return StyleBuilder(text, Style.none, resetAfter);
}

///
unittest
{
    enum string formattedText(bool resetAfter1, bool resetAfter2 = resetAfter1) = "Format me"
        .stylizedTextBuilder(resetAfter1)
        .opDispatch!`bold`
        .underline
        .bgWhite
        .italic
        .blue
        .underline(resetAfter2)
        .strikethrough;

    enum expectedPrefix = "\x1b[9m\x1b[4m\x1b[34m\x1b[3m\x1b[47m\x1b[4m\x1b[1m";
    enum expectedSuffix = "\x1b[22m\x1b[24m\x1b[49m\x1b[23m\x1b[39m\x1b[24m\x1b[29m";

    static assert(
        formattedText!true == expectedPrefix ~ "Format me" ~ expectedSuffix
    );

    static assert(
        formattedText!false == expectedPrefix ~ "Format me"
    );

    static assert(
        formattedText!(false, true) == expectedPrefix ~ "Format me" ~ "\x1b[24m\x1b[29m"
    );
}

string escapeSeq(uint code)
{
    return "\x1b[" ~ code.numToString ~ "m";
}

string stylize(string text, Style style, bool resetAfter = true)
{
    return style == Style.none
        ? text
        : resetAfter
        ? style[0].escapeSeq ~ text ~ style[1].escapeSeq
        : style[0].escapeSeq ~ text;
}

/// Returns the string name of a Style enum member.
string styleName(Style style)
{
    enum toKey = (Style s) => (cast(ulong) s[0] << 32) | s[1];

    switch (toKey(style))
    {
        static foreach (member; __traits(allMembers, Style))
            case toKey(__traits(getMember, Style, member)):
                return member;
        default:
            return "unknown";
    }
}

///
@("styleName.basic")
@safe pure nothrow unittest
{
    // Special values
    assert(styleName(Style.none) == "none");
    assert(styleName(Style.reset) == "reset");

    // Text attributes
    assert(styleName(Style.bold) == "bold");
    assert(styleName(Style.dim) == "dim");
    assert(styleName(Style.italic) == "italic");
    assert(styleName(Style.underline) == "underline");
    assert(styleName(Style.strikethrough) == "strikethrough");

    // Foreground colors
    assert(styleName(Style.red) == "red");
    assert(styleName(Style.brightCyan) == "brightCyan");

    // Background colors
    assert(styleName(Style.bgBlue) == "bgBlue");
    assert(styleName(Style.bgBrightYellow) == "bgBrightYellow");
}

/// Unknown style values return "unknown".
@("styleName.unknown")
@safe pure nothrow unittest
{
    // Construct a Style value that doesn't match any enum member
    Style unknown = [999, 999];
    assert(styleName(unknown) == "unknown");

    // Edge case: valid codes but not a defined style
    Style notDefined = [50, 50];
    assert(styleName(notDefined) == "unknown");
}

/// CTFE compatibility.
@("styleName.ctfe")
@safe pure nothrow unittest
{
    static assert(styleName(Style.bold) == "bold");
    static assert(styleName(Style.gray) == "gray");
    static assert(styleName(Style.bgBrightMagenta) == "bgBrightMagenta");

    // Verify all styles can be named at compile time
    static foreach (member; __traits(allMembers, Style))
    {
        static assert(styleName(__traits(getMember, Style, member)).length > 0);
    }
}

/// Returns the name of a Style styled with that style.
///
/// Useful for displaying style palettes where styles demonstrate themselves.
///
/// Example: `styleSample(Style.red)` returns `"red"` rendered in red.
string styleSample(Style style, bool resetAfter = true)
{
    return styleName(style).stylize(style, resetAfter);
}

///
unittest
{
    assert(styleSample(Style.red) == "\x1b[31mred\x1b[39m");
    assert(styleSample(Style.bold) == "\x1b[1mbold\x1b[22m");
    assert(styleSample(Style.green, false) == "\x1b[32mgreen");
}

// Optimized version for CT usage
string numToString(T)(T value)
if (__traits(isUnsigned, T))
{
    char[sizeForUnsignedNumberBuffer!T] buf = void;
    ubyte i = buf.length - 1;
    while (value >= 10)
    {
        buf[i--] = cast(char)('0' + value % 10);
        value /= 10;
    }
    buf[i] = cast(char)('0' + value);
    return buf[i .. $].idup;
}

template sizeForUnsignedNumberBuffer(T)
if (__traits(isUnsigned, T))
{
    import core.internal.string : numDigits;
    enum sizeForUnsignedNumberBuffer = T.max.numDigits;
}
