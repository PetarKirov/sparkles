/**
 * Style template processing for IES (Interpolated Expression Sequences).
 *
 * Provides a template syntax for applying terminal styles to IES strings:
 * ---
 * import sparkles.base.styled_template;
 *
 * int cpu = 75;
 * styledWriteln(i"CPU: {red $(cpu)%} Status: {green OK}");
 * ---
 *
 * Supported syntax:
 * - `{red text}` — Apply single style
 * - `{bold.red text}` — Chain multiple styles
 * - `{bold outer {red nested}}` — Nested blocks (inner inherits outer)
 * - `{red text {~red normal}}` — Negation with `~` removes a style
 * - `#{` — Escaped literal `{`
 * - `#}` — Escaped literal `}`
 */
module sparkles.base.styled_template;

import core.interpolation;
import std.algorithm.mutation : remove;
import std.algorithm.searching : canFind;
import std.sumtype : match, SumType;

import sparkles.base.term_style : Style;
import sparkles.base.text.readers : hexNibble, isHexDigit;

// ─────────────────────────────────────────────────────────────────────────────
// Core Processing Functions
// ─────────────────────────────────────────────────────────────────────────────

/// Writes styled IES output to an output range.
///
/// Processes IES (Interpolated Expression Sequences) containing style template
/// syntax and writes the resulting ANSI-styled text to the given output range.
///
/// Style blocks use `{styleName content}` syntax, where `styleName` is one or
/// more dot-separated style names. Blocks can be nested, and inner blocks
/// inherit styles from outer blocks. Use `~` prefix to negate (remove) an
/// inherited style.
///
/// Params:
///     colored = when `false`, style markup is parsed and stripped but no ANSI
///              escape sequences are emitted — producing plain text output.
void writeStyled(bool colored = true, Writer, Args...)(
    ref Writer w,
    InterpolationHeader,
    Args args,
    InterpolationFooter
)
{
    import sparkles.base.text.writers : writeValue;

    ParserContext ctx;

    static foreach (arg; args)
    {{
        alias T = typeof(arg);
        static if (is(T == InterpolatedLiteral!lit, string lit))
        {
            parseLiteral!colored(w, lit, ctx);
        }
        else static if (is(T == InterpolatedExpression!code, string code))
        {
            // Skip expression metadata
        }
        else
        {
            // Output interpolated value — best-effort @nogc via writeValue,
            // falls back to std.conv.to!string for types without @nogc conversion.
            writeValue(w, arg);
        }
    }}
}

/// Single style: `{red text}` wraps text with red foreground escape codes.
@("writeStyled.singleStyle")
@safe unittest
{
    assert(styledText(i"{red error}") == "\x1b[31merror\x1b[39m");
}

/// Chained styles: `{bold.red text}` applies multiple styles separated by dots.
@("writeStyled.chainedStyles")
@safe unittest
{
    // bold.red applies both styles, closed in reverse order
    assert(styledText(i"{bold.red text}") == "\x1b[1m\x1b[31mtext\x1b[39m\x1b[22m");
}

/// Interpolated expressions: `{green $(expr)}` styles the result of an expression.
@("writeStyled.withInterpolation")
@safe unittest
{
    int val = 42;
    assert(styledText(i"Value: {green $(val)}") == "Value: \x1b[32m42\x1b[39m");
}

/// Nested blocks: `{bold outer {red inner}}` — inner inherits outer's styles.
@("writeStyled.nested")
@safe unittest
{
    // bold applies to all, red only to inner "B"
    auto result = styledText(i"{bold A {red B} C}");
    assert(result == "\x1b[1mA \x1b[31mB\x1b[39m C\x1b[22m");
}

/// Negation: `{~red text}` removes the named style from the inherited set.
@("writeStyled.negation")
@safe unittest
{
    // Start bold+red, then ~red removes red while keeping bold
    auto result = styledText(i"{bold.red styled {~red plain}}");
    assert(result ==
        "\x1b[1m\x1b[31m" ~ // bold ON, red ON
        "styled " ~
        "\x1b[39m" ~         // red OFF (negated)
        "plain" ~
        "\x1b[31m" ~         // red ON (restored on exit)
        "\x1b[39m\x1b[22m"   // red OFF, bold OFF
    );
}

/// Escaped braces: `#{` produces literal `{`, `#}` produces literal `}`.
@("writeStyled.escapedBraces")
@safe unittest
{
    assert(styledText(i"Use #{style#} syntax") == "Use {style} syntax");
}

/// Escaped braces inside styled blocks.
@("writeStyled.escapedBracesInStyledBlock")
@safe unittest
{
    assert(styledText(i"{bold use #{braces#}}") == "\x1b[1muse {braces}\x1b[22m");
}

/// Escaped `#}` inside styled block produces literal `}`.
@("writeStyled.escapedCloseBraceInBlock")
@safe unittest
{
    assert(styledText(i"{red hey#} still red}") == "\x1b[31mhey} still red\x1b[39m");
}

/// Plain text without any style blocks passes through unchanged.
@("writeStyled.noStyle")
@safe unittest
{
    assert(styledText(i"plain text") == "plain text");
}

/// Empty block `{}` is treated as a literal `{}`.
@("writeStyled.emptyBlock")
@safe unittest
{
    assert(styledText(i"test {} here") == "test {} here");
}

/// Style block with no content (e.g. `{red}`) yields empty output.
@("writeStyled.styleBlockWithNoContent")
@safe unittest
{
    assert(styledText(i"{red}") == "");
    assert(styledText(i"a{bold}b") == "ab");
    assert(styledText(i"{bold.red}") == "");
}

/// Multiple adjacent blocks are independent.
@("writeStyled.multipleBlocks")
@safe unittest
{
    auto result = styledText(i"{red error} and {green success}");
    assert(result == "\x1b[31merror\x1b[39m and \x1b[32msuccess\x1b[39m");
}

/// When `colored` is `false`, style markup is stripped, producing plain text.
@("writeStyled.uncolored")
@safe unittest
{
    assert(plainText(i"{red error}") == "error");
    assert(plainText(i"{bold.red text}") == "text");
    assert(plainText(i"plain text") == "plain text");
    int val = 42;
    assert(plainText(i"Value: {green $(val)}") == "Value: 42");
    assert(plainText(i"{bold A {red B} C}") == "A B C");
}

// ─────────────────────────────────────────────────────────────────────────────
// String Conversion
// ─────────────────────────────────────────────────────────────────────────────

/// Returns styled IES as a string.
string styledText(Args...)(InterpolationHeader header, Args args, InterpolationFooter footer)
{
    import std.array : appender;

    auto buf = appender!string;
    writeStyled(buf, header, args, footer);
    return buf[];
}

/// Returns IES with style markup stripped as a plain string.
string plainText(Args...)(InterpolationHeader header, Args args, InterpolationFooter footer)
{
    import std.array : appender;

    auto buf = appender!string;
    writeStyled!false(buf, header, args, footer);
    return buf[];
}

// ─────────────────────────────────────────────────────────────────────────────
// Lazy Wrapper
// ─────────────────────────────────────────────────────────────────────────────

/// Lazy wrapper that defers styled processing until consumed.
struct StyledText(Args...)
{
    Args args;

    /// Convert to string (allocates)
    string toString() const
    {
        import std.array : appender;

        auto buf = appender!string;
        writeStyled(buf, args);
        return buf[];
    }

    /// Callback-based toString for writeln compatibility
    void toString(scope void delegate(const(char)[]) sink) const
    {
        sink(toString());
    }
}

/// Returns a lazy wrapper that can be converted to string or written to output range.
auto styled(Args...)(InterpolationHeader header, Args args, InterpolationFooter footer)
{
    // Store all components including header/footer
    return StyledText!(InterpolationHeader, Args, InterpolationFooter)(header, args, footer);
}

///
@("styled.lazyWrapper")
@safe unittest
{
    int val = 99;
    auto lazy_ = styled(i"Test: {blue $(val)}");
    assert(lazy_.toString == "Test: \x1b[34m99\x1b[39m");
}

// ─────────────────────────────────────────────────────────────────────────────
// stdout/stderr Write Functions
// ─────────────────────────────────────────────────────────────────────────────

/// Write styled IES to stdout.
void styledWrite(Args...)(InterpolationHeader header, Args args, InterpolationFooter footer)
{
    import std.stdio : stdout;

    auto w = stdout.lockingTextWriter;
    writeStyled(w, header, args, footer);
}

/// Write styled IES to stdout with newline.
void styledWriteln(Args...)(InterpolationHeader header, Args args, InterpolationFooter footer)
{
    import std.stdio : stdout;

    auto w = stdout.lockingTextWriter;
    writeStyled(w, header, args, footer);
    w.put('\n');
}

/// Write styled IES to stderr.
void styledWriteErr(Args...)(InterpolationHeader header, Args args, InterpolationFooter footer)
{
    import std.stdio : stderr;

    auto w = stderr.lockingTextWriter;
    writeStyled(w, header, args, footer);
}

/// Write styled IES to stderr with newline.
void styledWritelnErr(Args...)(InterpolationHeader header, Args args, InterpolationFooter footer)
{
    import std.stdio : stderr;

    auto w = stderr.lockingTextWriter;
    writeStyled(w, header, args, footer);
    w.put('\n');
}

// ─────────────────────────────────────────────────────────────────────────────
// Style Name Lookup
// ─────────────────────────────────────────────────────────────────────────────

/// Parses a style name string to a Style enum value.
/// Returns Style.none if the name is not recognized.
@safe pure nothrow @nogc
Style styleFromName(const(char)[] name)
{
    switch (name)
    {
        // Special
        case "none": return Style.none;
        case "reset": return Style.reset;

        // Text attributes
        case "bold": return Style.bold;
        case "dim": return Style.dim;
        case "italic": return Style.italic;
        case "underline": return Style.underline;
        case "inverse": return Style.inverse;
        case "hidden": return Style.hidden;
        case "strikethrough": return Style.strikethrough;

        // Foreground colors
        case "black": return Style.black;
        case "red": return Style.red;
        case "green": return Style.green;
        case "yellow": return Style.yellow;
        case "blue": return Style.blue;
        case "magenta": return Style.magenta;
        case "cyan": return Style.cyan;
        case "white": return Style.white;
        case "gray": return Style.gray;

        // Bright foreground colors
        case "brightRed": return Style.brightRed;
        case "brightGreen": return Style.brightGreen;
        case "brightYellow": return Style.brightYellow;
        case "brightBlue": return Style.brightBlue;
        case "brightMagenta": return Style.brightMagenta;
        case "brightCyan": return Style.brightCyan;
        case "brightWhite": return Style.brightWhite;

        // Background colors
        case "bgBlack": return Style.bgBlack;
        case "bgRed": return Style.bgRed;
        case "bgGreen": return Style.bgGreen;
        case "bgYellow": return Style.bgYellow;
        case "bgBlue": return Style.bgBlue;
        case "bgMagenta": return Style.bgMagenta;
        case "bgCyan": return Style.bgCyan;
        case "bgWhite": return Style.bgWhite;
        case "bgGray": return Style.bgGray;

        // Bright background colors
        case "bgBrightRed": return Style.bgBrightRed;
        case "bgBrightGreen": return Style.bgBrightGreen;
        case "bgBrightYellow": return Style.bgBrightYellow;
        case "bgBrightBlue": return Style.bgBrightBlue;
        case "bgBrightMagenta": return Style.bgBrightMagenta;
        case "bgBrightCyan": return Style.bgBrightCyan;
        case "bgBrightWhite": return Style.bgBrightWhite;

        default: return Style.none;
    }
}

///
@("styleFromName.basic")
@safe pure nothrow @nogc
unittest
{
    assert(styleFromName("red") == Style.red);
    assert(styleFromName("bold") == Style.bold);
    assert(styleFromName("bgBlue") == Style.bgBlue);
    assert(styleFromName("unknown") == Style.none);
    assert(styleFromName("") == Style.none);
}

/// All text attributes are recognized.
@("styleFromName.textAttributes")
@safe pure nothrow @nogc
unittest
{
    assert(styleFromName("dim") == Style.dim);
    assert(styleFromName("italic") == Style.italic);
    assert(styleFromName("underline") == Style.underline);
    assert(styleFromName("inverse") == Style.inverse);
    assert(styleFromName("hidden") == Style.hidden);
    assert(styleFromName("strikethrough") == Style.strikethrough);
}

/// Special style names: "none" and "reset".
@("styleFromName.special")
@safe pure nothrow @nogc
unittest
{
    assert(styleFromName("none") == Style.none);
    assert(styleFromName("reset") == Style.reset);
}

/// Bright foreground colors are recognized.
@("styleFromName.brightColors")
@safe pure nothrow @nogc
unittest
{
    assert(styleFromName("brightRed") == Style.brightRed);
    assert(styleFromName("brightGreen") == Style.brightGreen);
    assert(styleFromName("brightYellow") == Style.brightYellow);
    assert(styleFromName("brightBlue") == Style.brightBlue);
    assert(styleFromName("brightMagenta") == Style.brightMagenta);
    assert(styleFromName("brightCyan") == Style.brightCyan);
    assert(styleFromName("brightWhite") == Style.brightWhite);
}

/// Background colors are recognized.
@("styleFromName.bgColors")
@safe pure nothrow @nogc
unittest
{
    assert(styleFromName("bgBlack") == Style.bgBlack);
    assert(styleFromName("bgRed") == Style.bgRed);
    assert(styleFromName("bgGreen") == Style.bgGreen);
    assert(styleFromName("bgYellow") == Style.bgYellow);
    assert(styleFromName("bgBlue") == Style.bgBlue);
    assert(styleFromName("bgMagenta") == Style.bgMagenta);
    assert(styleFromName("bgCyan") == Style.bgCyan);
    assert(styleFromName("bgWhite") == Style.bgWhite);
    assert(styleFromName("bgGray") == Style.bgGray);
}

/// Bright background colors are recognized.
@("styleFromName.bgBrightColors")
@safe pure nothrow @nogc
unittest
{
    assert(styleFromName("bgBrightRed") == Style.bgBrightRed);
    assert(styleFromName("bgBrightGreen") == Style.bgBrightGreen);
    assert(styleFromName("bgBrightYellow") == Style.bgBrightYellow);
    assert(styleFromName("bgBrightBlue") == Style.bgBrightBlue);
    assert(styleFromName("bgBrightMagenta") == Style.bgBrightMagenta);
    assert(styleFromName("bgBrightCyan") == Style.bgBrightCyan);
    assert(styleFromName("bgBrightWhite") == Style.bgBrightWhite);
}

/// Name matching is case-sensitive — wrong case returns Style.none.
@("styleFromName.caseSensitive")
@safe pure nothrow @nogc
unittest
{
    assert(styleFromName("Red") == Style.none);
    assert(styleFromName("BOLD") == Style.none);
    assert(styleFromName("BgBlue") == Style.none);
}

/// 24-bit RGB foreground/background via `#RRGGBB` / `bg#RRGGBB`, and the short
/// `#RGB` form (each nibble doubled).
@("writeStyled.rgbColor")
@safe unittest
{
    // 0xcba6f7 = 203,166,247 fg; reset with 39.
    assert(styledText(i"{#cba6f7 text}") == "\x1b[38;2;203;166;247mtext\x1b[39m");
    // 0x1e2e2e background; reset with 49.
    assert(styledText(i"{bg#1e2e2e bg}") == "\x1b[48;2;30;46;46mbg\x1b[49m");
    // short form #f00 → 255,0,0.
    assert(styledText(i"{#f00 r}") == "\x1b[38;2;255;0;0mr\x1b[39m");
    // malformed hex → token ignored, plain text.
    assert(styledText(i"{#xyz z}") == "z");
}

/// 256-palette foreground/background via `@N` / `bg@N`.
@("writeStyled.paletteColor")
@safe unittest
{
    assert(styledText(i"{@183 kw}") == "\x1b[38;5;183mkw\x1b[39m");
    assert(styledText(i"{bg@235 bg}") == "\x1b[48;5;235mbg\x1b[49m");
    // out-of-range index → token ignored.
    assert(styledText(i"{@256 x}") == "x");
}

/// Colors compose with named styles (dots), nesting, and interpolation, just
/// like the named styles do.
@("writeStyled.colorComposition")
@safe unittest
{
    // bold + palette fg: opened in order, closed in reverse.
    assert(styledText(i"{bold.@183 x}") == "\x1b[1m\x1b[38;5;183mx\x1b[39m\x1b[22m");
    // nested: inner rgb inherits outer bold.
    assert(styledText(i"{bold A {#00ff00 B} C}")
        == "\x1b[1mA \x1b[38;2;0;255;0mB\x1b[39m C\x1b[22m");
    int n = 7;
    assert(styledText(i"n={@201 $(n)}") == "n=\x1b[38;5;201m7\x1b[39m");
    // uncolored mode strips color markup too.
    assert(plainText(i"{#cba6f7 text} {@5 x}") == "text x");
}

/// Nesting a color inside a same-channel color restores the outer color on
/// exit: closing the inner color emits the absolute reset (39/49), which clears
/// the shared fg/bg channel, so the inherited outer color must be re-opened.
@("writeStyled.colorNestingRestoresOuter")
@safe unittest
{
    // Foreground over foreground: exiting red must bring blue back, not default.
    assert(styledText(i"{blue A {red B} C}")
        == "\x1b[34mA \x1b[31mB\x1b[39m\x1b[34m C\x1b[39m");
    // Background over background: same restoration via 49.
    assert(styledText(i"{bg@235 A {bg@200 B} C}")
        == "\x1b[48;5;235mA \x1b[48;5;200mB\x1b[49m\x1b[48;5;235m C\x1b[49m");
}

// ─────────────────────────────────────────────────────────────────────────────
// Implementation Details
// ─────────────────────────────────────────────────────────────────────────────

private enum maxStylesPerBlock = 8;
private enum maxNestingDepth = 16;

/// A named `Style` — the classic 16 attrs/colors, an `[open, close]` code pair.
private struct NamedStyle
{
    Style style;
}

/// A 256-palette color (`38;5;n` / `48;5;n`).
private struct PaletteColor
{
    bool bg;     /// background vs foreground
    ubyte index;
}

/// A 24-bit RGB color (`38;2;r;g;b` / `48;2;r;g;b`).
private struct RgbColor
{
    bool bg;     /// background vs foreground
    ubyte r, g, b;
}

/// One resolved style token on the block stack. Named tokens emit and compare
/// exactly as before (existing markup is byte-for-byte unchanged); the palette /
/// RGB alternatives carry the multi-parameter SGR that `Style` (`uint[2]`)
/// cannot hold. As a `SumType`, `==` gives structural equality for free and
/// `match` keeps the emit paths exhaustive.
private alias StyleAtom = SumType!(NamedStyle, PaletteColor, RgbColor);

/// The inert sentinel — a `Style.none` named token (also `StyleAtom.init`).
private bool isNone(in StyleAtom a) @safe @nogc nothrow
    => a.match!(
        (NamedStyle n) => n.style == Style.none,
        (PaletteColor _) => false,
        (RgbColor _) => false,
    );

/// Emit the opening SGR sequence for `a`.
private void emitOpen(Writer)(in StyleAtom a, ref Writer w)
{
    import sparkles.base.text.writers : writeEscapeSeq, writeInteger;
    import std.range.primitives : put;

    a.match!(
        (NamedStyle n) => writeEscapeSeq(w, n.style[0]),
        (PaletteColor c) {
            put(w, c.bg ? "\x1b[48;5;" : "\x1b[38;5;");
            writeInteger(w, c.index);
            put(w, 'm');
        },
        (RgbColor c) {
            put(w, c.bg ? "\x1b[48;2;" : "\x1b[38;2;");
            writeInteger(w, c.r);
            put(w, ';');
            writeInteger(w, c.g);
            put(w, ';');
            writeInteger(w, c.b);
            put(w, 'm');
        },
    );
}

/// Emit the closing SGR sequence for `a` (colors reset with `39`/`49`).
private void emitClose(Writer)(in StyleAtom a, ref Writer w)
{
    import sparkles.base.text.writers : writeEscapeSeq;

    a.match!(
        (NamedStyle n) => writeEscapeSeq(w, n.style[1]),
        (PaletteColor c) => writeEscapeSeq(w, c.bg ? 49 : 39),
        (RgbColor c) => writeEscapeSeq(w, c.bg ? 49 : 39),
    );
}

/// The absolute SGR reset code an atom closes with: `39` = default foreground,
/// `49` = default background, otherwise an independent attribute-off code.
/// Two atoms sharing a code contend for the same terminal channel, so closing
/// one clears the other — colors do not stack.
@safe pure nothrow @nogc
private int closeCode(in StyleAtom a)
    => a.match!(
        (NamedStyle n) => cast(int) n.style[1],
        (PaletteColor c) => c.bg ? 49 : 39,
        (RgbColor c) => c.bg ? 49 : 39,
    );

@safe
private struct StyleState
{
    // Fixed array, not `SmallBuffer`: its accessors take a non-`scope` `this`,
    // which the `in` (scope) `StyleState` parameters below reject under dip1000.
    StyleAtom[maxStylesPerBlock] styles;
    size_t count;

    /// Emit escape sequences for transition FROM parent TO this state
    void emitOpenDiff(Writer)(ref Writer w, in StyleState parent) const
    {
        // Close styles that were in parent but removed in this (negation)
        foreach_reverse (i; 0 .. parent.count)
            if (!parent.styles[i].isNone && !hasStyle(parent.styles[i]))
                parent.styles[i].emitClose(w);

        // Open styles that are new in this (not in parent)
        foreach (i; 0 .. count)
            if (!styles[i].isNone && !parent.hasStyle(styles[i]))
                styles[i].emitOpen(w);

        // A negated close above may emit a *shared* SGR reset (22 clears both
        // bold and dim, 39 every fg colour, 49 every bg colour) that also turned
        // off a style this block keeps (present in both). Re-open it so the kept
        // style survives the negation — e.g. `~dim` must not also drop an active
        // bold.
        foreach (i; 0 .. count)
            if (!styles[i].isNone && parent.hasStyle(styles[i])
                && negatedClosesWith(styles[i].closeCode, parent))
                styles[i].emitOpen(w);
    }

    /// Emit escape sequences for transition FROM this state back TO parent
    void emitCloseDiff(Writer)(ref Writer w, in StyleState parent) const
    {
        // Close styles that were added in this (not in parent)
        foreach_reverse (i; 0 .. count)
            if (!styles[i].isNone && !parent.hasStyle(styles[i]))
                styles[i].emitClose(w);

        // A close above may emit a *shared* SGR reset (22 clears both bold and
        // dim, 39 every fg colour, 49 every bg colour) that also turned off an
        // inherited parent style with the same close code this block keeps
        // (shadowed, not negated). The negation-restore loop below skips it
        // because it is present here, so re-open it now.
        foreach (i; 0 .. parent.count)
            if (!parent.styles[i].isNone && hasStyle(parent.styles[i])
                && closedByChildOnly(parent.styles[i].closeCode, parent))
                parent.styles[i].emitOpen(w);

        // Restore styles that were negated (in parent but not in this)
        foreach (i; 0 .. parent.count)
            if (!parent.styles[i].isNone && !hasStyle(parent.styles[i]))
                parent.styles[i].emitOpen(w);
    }

    /// True if a style this block adds (present here, not in `parent`) closes
    /// with SGR code `code` — i.e. its `emitClose` turns off that shared group.
    private bool closedByChildOnly(int code, in StyleState parent) const @safe nothrow @nogc
    {
        foreach (i; 0 .. count)
            if (!styles[i].isNone && !parent.hasStyle(styles[i])
                && styles[i].closeCode == code)
                return true;
        return false;
    }

    /// True if a style this block negates (in `parent`, removed here) closes
    /// with SGR code `code`.
    private bool negatedClosesWith(int code, in StyleState parent) const @safe nothrow @nogc
    {
        foreach (i; 0 .. parent.count)
            if (!parent.styles[i].isNone && !hasStyle(parent.styles[i])
                && parent.styles[i].closeCode == code)
                return true;
        return false;
    }

    /// Emit opening escape sequences for all active styles
    void emitOpen(Writer)(ref Writer w) const
    {
        emitOpenDiff(w, StyleState.init);
    }

    /// Emit closing escape sequences for all active styles (reverse order)
    void emitClose(Writer)(ref Writer w) const
    {
        emitCloseDiff(w, StyleState.init);
    }

    /// Check if a style is currently active
    bool hasStyle(in StyleAtom s) const @nogc nothrow => styles[0 .. count].canFind(s);

    /// Add a style if not already present
    void addStyle(in StyleAtom s) @nogc nothrow
    {
        if (!s.isNone && !hasStyle(s) && count < styles.length)
            styles[count++] = s;
    }

    /// Remove a style
    void removeStyle(in StyleAtom s) @nogc nothrow
        => cast(void)(count = styles[0 .. count].remove!(a => a == s).length);

    /// Check if any styles are active
    bool empty() const @nogc nothrow => count == 0;
}

private enum ParseState
{
    normal,
    styleName,
    content
}

@safe
private struct ParserContext
{
    // Fixed array (see `StyleState.styles`); overflow past the cap is tracked,
    // not allocated.
    StyleState[maxNestingDepth] styleStack;
    size_t stackDepth;
    /// Tracks pushes that were dropped due to stack overflow
    size_t overflowDepth;
    ParseState state = ParseState.normal;
    size_t styleNameStart;
    size_t styleNameEnd;

    void pushStyle(StyleState s) @nogc nothrow
    {
        if (stackDepth < styleStack.length)
            styleStack[stackDepth++] = s;
        else
            overflowDepth++;
    }

    void popStyle() @nogc nothrow
    {
        if (overflowDepth > 0)
            overflowDepth--;
        else if (stackDepth > 0)
            stackDepth--;
    }

    ref StyleState topStyle() return @nogc nothrow
    {
        return styleStack[stackDepth > 0 ? stackDepth - 1 : 0];
    }

    StyleState parentStyle() const @nogc nothrow
    {
        return stackDepth > 1 ? styleStack[stackDepth - 2] : StyleState.init;
    }

    bool hasStyles() const @nogc nothrow => stackDepth > 0;
}

/// Parses a literal segment and writes styled output
@safe
private void parseLiteral(bool colored = true, Writer)(
    ref Writer w,
    const(char)[] literal,
    ref ParserContext ctx
)
{
    import std.range.primitives : put;

    size_t i = 0;
    while (i < literal.length)
    {
        const char c = literal[i];

        final switch (ctx.state)
        {
            case ParseState.normal:
                if (c == '#' && i + 1 < literal.length)
                {
                    const char next = literal[i + 1];
                    if (next == '{' || next == '}')
                    {
                        put(w, next);
                        i += 2;
                        continue;
                    }
                    put(w, c);
                }
                else if (c == '{')
                {
                    ctx.state = ParseState.styleName;
                    ctx.styleNameStart = i + 1;
                    ctx.styleNameEnd = i + 1;
                }
                else if (c == '}')
                {
                    put(w, c);
                }
                else
                {
                    put(w, c);
                }
                break;

            case ParseState.styleName:
                if (c == ' ')
                {
                    // End of style names, apply and switch to content
                    auto spec = literal[ctx.styleNameStart .. ctx.styleNameEnd];
                    applyStyleSpec(spec, ctx);
                    // Only emit styles that are NEW (not inherited from parent);
                    // a block dropped past the depth cap was never pushed, so
                    // `topStyle` still refers to its parent — emitting would
                    // re-diff the parent against its own parent (spurious codes).
                    static if (colored)
                        if (ctx.overflowDepth == 0)
                            ctx.topStyle.emitOpenDiff(w, ctx.parentStyle);
                    ctx.state = ParseState.content;
                }
                else if (c == '}')
                {
                    auto spec = literal[ctx.styleNameStart .. ctx.styleNameEnd];
                    if (spec.length == 0)
                    {
                        // Empty block like {} - treat as literal
                        put(w, '{');
                        put(w, '}');
                    }
                    // else: Style block with no content, e.g. {red} - discard (empty output)
                    ctx.state = ctx.hasStyles ? ParseState.content : ParseState.normal;
                }
                else
                {
                    // Accumulate style name
                    ctx.styleNameEnd = i + 1;
                }
                break;

            case ParseState.content:
                if (c == '#' && i + 1 < literal.length)
                {
                    const char next = literal[i + 1];
                    if (next == '{' || next == '}')
                    {
                        put(w, next);
                        i += 2;
                        continue;
                    }
                    put(w, c);
                }
                else if (c == '{')
                {
                    // Nested block
                    ctx.state = ParseState.styleName;
                    ctx.styleNameStart = i + 1;
                    ctx.styleNameEnd = i + 1;
                }
                else if (c == '}')
                {
                    // End of block - close only styles that were added in this
                    // block; a block dropped past the depth cap emitted nothing
                    // on entry, so it must emit nothing on exit either.
                    static if (colored)
                        if (ctx.overflowDepth == 0)
                            ctx.topStyle.emitCloseDiff(w, ctx.parentStyle);
                    ctx.popStyle();
                    ctx.state = ctx.hasStyles ? ParseState.content : ParseState.normal;
                }
                else
                {
                    put(w, c);
                }
                break;
        }
        i++;
    }
}

/// Parses style specification like "bold.red" or "~red.bold"
@safe nothrow @nogc
private void applyStyleSpec(const(char)[] spec, ref ParserContext ctx)
{
    // Create new style state based on parent (or empty if root)
    StyleState newState = ctx.hasStyles ? ctx.topStyle : StyleState.init;

    // Parse dot-separated style names
    size_t start = 0;
    foreach (i, c; spec)
    {
        if (c == '.')
        {
            if (i > start)
                applyStylePart(spec[start .. i], newState);
            start = i + 1;
        }
    }
    // Handle last part
    if (start < spec.length)
        applyStylePart(spec[start .. $], newState);

    ctx.pushStyle(newState);
}

@safe nothrow @nogc
private void applyStylePart(const(char)[] part, ref StyleState state)
{
    if (part.length == 0)
        return;

    const negate = part[0] == '~';
    const(char)[] name = negate ? part[1 .. $] : part;

    StyleAtom atom;
    if (!resolveStyleAtom(name, atom))
        return;

    if (negate)
        state.removeStyle(atom);
    else
        state.addStyle(atom);
}

/// Resolves one style token to a `StyleAtom`. Beyond the named styles
/// (`styleFromName`), recognizes 24-bit `#RGB`/`#RRGGBB` and 256-palette `@N`
/// foreground colors, each with a `bg` prefix (`bg#…`, `bg@N`) for background.
/// Returns `false` (token ignored) on an unknown name or malformed color.
@safe nothrow @nogc
private bool resolveStyleAtom(const(char)[] name, out StyleAtom atom)
{
    bool bg;
    // `bg` only prefixes a color literal here; named `bgRed` etc. fall through.
    if (name.length > 2 && name[0 .. 2] == "bg" && (name[2] == '#' || name[2] == '@'))
    {
        bg = true;
        name = name[2 .. $];
    }

    if (name.length && name[0] == '#')
    {
        ubyte r, g, b;
        if (!parseHexColor(name[1 .. $], r, g, b))
            return false;
        atom = StyleAtom(RgbColor(bg, r, g, b));
        return true;
    }

    if (name.length && name[0] == '@')
    {
        import sparkles.base.text.readers : readInteger;

        auto rest = name[1 .. $];
        auto idx = readInteger!ubyte(rest);
        if (idx.hasError || rest.length != 0) // the whole token must be the index
            return false;
        atom = StyleAtom(PaletteColor(bg, idx.value));
        return true;
    }

    const s = styleFromName(name);
    if (s == Style.none)
        return false;
    atom = StyleAtom(NamedStyle(s));
    return true;
}

/// A hex-digit pair → one byte (`"ff"` → 255). Reuses `readers.hexNibble`; both
/// characters must be hex digits (validated by `parseHexColor` before the call).
private ubyte hexOctet(char[2] chars) @safe nothrow @nogc
in (isHexDigit(chars[0]) && isHexDigit(chars[1]))
    => cast(ubyte)(hexNibble(chars[0]) * 16 + hexNibble(chars[1]));

/// `#RGB` (each nibble doubled) or `#RRGGBB` hex → 8-bit channels. Digit
/// decoding reuses `sparkles.base.text.readers` (`isHexDigit`/`hexNibble`).
@safe nothrow @nogc
private bool parseHexColor(const(char)[] hex, out ubyte r, out ubyte g, out ubyte b)
{
    if (hex.length != 3 && hex.length != 6)
        return false;
    foreach (c; hex) // validate up front so `hexOctet`'s `in` contract holds
        if (!isHexDigit(c))
            return false;

    if (hex.length == 3) // #RGB → each nibble doubled (0xN → 0xNN, i.e. ×17)
    {
        r = hexOctet([hex[0], hex[0]]);
        g = hexOctet([hex[1], hex[1]]);
        b = hexOctet([hex[2], hex[2]]);
    }
    else // #RRGGBB
    {
        r = hexOctet(hex[0 .. 2]);
        g = hexOctet(hex[2 .. 4]);
        b = hexOctet(hex[4 .. 6]);
    }
    return true;
}

/// `#RGB` shorthand doubles each nibble (`0xN → 0xNN`), same as the old
/// `hexNibble(c) * 17`; a regression guard for the `hexOctet` refactor.
@("writeStyled.rgbShorthandDoubling")
@safe unittest
{
    // #abc → aa,bb,cc = 170,187,204; #f0a → ff,00,aa = 255,0,170.
    assert(styledText(i"{#abc x}") == "\x1b[38;2;170;187;204mx\x1b[39m");
    assert(styledText(i"{#f0a x}") == "\x1b[38;2;255;0;170mx\x1b[39m");
    // Shorthand and full form agree: #fff == #ffffff.
    assert(styledText(i"{#fff x}") == styledText(i"{#ffffff x}"));
}

// ─────────────────────────────────────────────────────────────────────────────
// Non-Ddoc Unit Tests
// ─────────────────────────────────────────────────────────────────────────────

/// Elaborate test combining chained styles, deep nesting, and negation.
///
/// This test verifies the complete style state machine by building up a complex
/// hierarchy of styles and selectively removing/adding styles at each level.
///
/// Visual representation of the test case:
/// ---
/// {bold.italic.red                           ← Level 1: bold + italic + red
///     "A"
///     {~red.underline                        ← Level 2: bold + italic + underline (red removed)
///         "B"
///         {cyan                              ← Level 3: bold + italic + underline + cyan
///             "C"
///             {~bold.~italic                 ← Level 4: underline + cyan (bold & italic removed)
///                 "D"
///             }                              ← Back to Level 3: bold + italic + underline + cyan
///             "E"
///         }                                  ← Back to Level 2: bold + italic + underline
///         "F"
///     }                                      ← Back to Level 1: bold + italic + red
///     "G"
/// }
/// ---
///
/// Expected escape sequence flow:
/// - [1m[3m[31m  → bold on, italic on, red on
/// - "A"
/// - [39m[4m     → red off, underline on
/// - "B"
/// - [36m        → cyan on
/// - "C"
/// - [23m[22m    → italic off, bold off (reverse order of parent array)
/// - "D"
/// - [1m[3m      → bold on, italic on (restore)
/// - "E"
/// - [39m        → cyan off
/// - "F"
/// - [24m[31m    → underline off, red on (restore)
/// - "G"
/// - [39m[23m[22m → red off, italic off, bold off
@("styled.complexNestingWithNegation")
@safe unittest
{
    auto result = styledText(
        i"{bold.italic.red A{~red.underline B{cyan C{~bold.~italic D}E}F}G}"
    );

    // Verify the exact escape sequence
    // Note: styles are closed in reverse order of their position in the style array
    assert(result ==
        "\x1b[1m\x1b[3m\x1b[31m" ~  // bold, italic, red ON
        "A" ~
        "\x1b[39m" ~                // red OFF (negated)
        "\x1b[4m" ~                 // underline ON (added)
        "B" ~
        "\x1b[36m" ~                // cyan ON (added)
        "C" ~
        "\x1b[23m\x1b[22m" ~        // italic OFF, bold OFF (reverse order)
        "D" ~
        "\x1b[1m\x1b[3m" ~          // bold ON, italic ON (restored)
        "E" ~
        "\x1b[39m" ~                // cyan OFF (exiting cyan block)
        "F" ~
        "\x1b[24m" ~                // underline OFF (exiting underline block)
        "\x1b[31m" ~                // red ON (restored from negation)
        "G" ~
        "\x1b[39m\x1b[23m\x1b[22m"  // red OFF, italic OFF, bold OFF
    );
}

/// Test negation restores parent styles correctly when multiple styles are negated.
@("styled.multipleNegationRestore")
@safe unittest
{
    // Negate two styles, then exit - both should be restored
    // Parent: [bold, italic, underline], Child negates: bold, underline
    // Close order is reverse of array position: underline (idx 2), then bold (idx 0)
    auto result = styledText(i"{bold.italic.underline outer {~bold.~underline inner} outer}");

    assert(result ==
        "\x1b[1m\x1b[3m\x1b[4m" ~   // bold, italic, underline ON
        "outer " ~
        "\x1b[24m\x1b[22m" ~        // underline OFF, bold OFF (reverse order)
        "inner" ~
        "\x1b[1m\x1b[4m" ~          // bold ON, underline ON (restored)
        " outer" ~
        "\x1b[24m\x1b[23m\x1b[22m"  // underline OFF, italic OFF, bold OFF
    );
}

/// Test adding new styles in nested block while parent has styles.
@("styled.nestedStyleAddition")
@safe unittest
{
    // Parent has bold, child adds underline and cyan
    auto result = styledText(i"{bold parent {underline.cyan child} parent}");

    assert(result ==
        "\x1b[1m" ~                 // bold ON
        "parent " ~
        "\x1b[4m\x1b[36m" ~         // underline ON, cyan ON (new styles)
        "child" ~
        "\x1b[39m\x1b[24m" ~        // cyan OFF, underline OFF
        " parent" ~
        "\x1b[22m"                  // bold OFF
    );
}

/// Test three levels of nesting with style additions at each level.
@("styled.threeLevelNesting")
@safe unittest
{
    auto result = styledText(i"{red L1 {bold L2 {underline L3} L2} L1}");

    assert(result ==
        "\x1b[31m" ~      // red ON
        "L1 " ~
        "\x1b[1m" ~       // bold ON
        "L2 " ~
        "\x1b[4m" ~       // underline ON
        "L3" ~
        "\x1b[24m" ~      // underline OFF
        " L2" ~
        "\x1b[22m" ~      // bold OFF
        " L1" ~
        "\x1b[39m"        // red OFF
    );
}

/// Test negation combined with addition in same block.
@("styled.negationWithAddition")
@safe unittest
{
    // Start with bold+red, then remove red but add cyan
    auto result = styledText(i"{bold.red start {~red.cyan middle} end}");

    assert(result ==
        "\x1b[1m\x1b[31m" ~  // bold ON, red ON
        "start " ~
        "\x1b[39m" ~         // red OFF (negated)
        "\x1b[36m" ~         // cyan ON (added)
        "middle" ~
        "\x1b[39m" ~         // cyan OFF
        "\x1b[31m" ~         // red ON (restored)
        " end" ~
        "\x1b[39m\x1b[22m"   // red OFF, bold OFF
    );
}

/// Text attribute styles (dim, italic, underline, etc.) each use their own
/// open/close escape codes.
@("styled.textAttributes")
@safe unittest
{
    assert(styledText(i"{dim text}") == "\x1b[2mtext\x1b[22m");
    assert(styledText(i"{italic text}") == "\x1b[3mtext\x1b[23m");
    assert(styledText(i"{underline text}") == "\x1b[4mtext\x1b[24m");
    assert(styledText(i"{inverse text}") == "\x1b[7mtext\x1b[27m");
    assert(styledText(i"{hidden text}") == "\x1b[8mtext\x1b[28m");
    assert(styledText(i"{strikethrough text}") == "\x1b[9mtext\x1b[29m");
}

/// Background color styles use codes 40-49 (open) and 49 (close).
@("styled.backgroundColors")
@safe unittest
{
    assert(styledText(i"{bgRed text}") == "\x1b[41mtext\x1b[49m");
    assert(styledText(i"{bgGreen text}") == "\x1b[42mtext\x1b[49m");
    assert(styledText(i"{bgBlue text}") == "\x1b[44mtext\x1b[49m");
}

/// Foreground and background can be combined in a single block.
@("styled.foregroundAndBackground")
@safe unittest
{
    auto result = styledText(i"{red.bgWhite text}");
    assert(result == "\x1b[31m\x1b[47mtext\x1b[49m\x1b[39m");
}

/// Unknown style names in a spec are silently ignored (treated as Style.none).
@("styled.unknownStyleIgnored")
@safe unittest
{
    // "unknown" maps to Style.none so addStyle is a no-op
    assert(styledText(i"{unknown text}") == "text");
}

/// Unknown style mixed with a known style — only the known one applies.
@("styled.unknownMixedWithKnown")
@safe unittest
{
    assert(styledText(i"{unknown.bold text}") == "\x1b[1mtext\x1b[22m");
}

/// Negating a style that isn't active is a no-op.
@("styled.negateInactiveStyle")
@safe unittest
{
    // ~red on a block that doesn't have red — nothing to remove
    assert(styledText(i"{bold {~red text}}") == "\x1b[1mtext\x1b[22m");
}

/// Negating all styles in a child block — content has no styling.
@("styled.negateAllStyles")
@safe unittest
{
    auto result = styledText(i"{bold.red outer {~bold.~red inner} outer}");
    assert(result ==
        "\x1b[1m\x1b[31m" ~  // bold ON, red ON
        "outer " ~
        "\x1b[39m\x1b[22m" ~ // red OFF, bold OFF (negated)
        "inner" ~
        "\x1b[1m\x1b[31m" ~  // bold ON, red ON (restored)
        " outer" ~
        "\x1b[39m\x1b[22m"   // red OFF, bold OFF
    );
}

/// The same style applied redundantly at multiple nesting levels is not
/// duplicated — the inner block is a no-op since it inherits the style.
@("styled.duplicateStyleInherited")
@safe unittest
{
    // Inner {red ...} when parent is already red — should not re-emit red
    auto result = styledText(i"{red outer {red inner} outer}");
    // Inner block inherits red, emitOpenDiff produces nothing new,
    // emitCloseDiff produces nothing since nothing was added
    assert(result ==
        "\x1b[31m" ~  // red ON
        "outer " ~
        "inner" ~     // no extra codes — red already active
        " outer" ~
        "\x1b[39m"    // red OFF
    );
}

/// Multiple interpolated expressions in one styled block.
@("styled.multipleInterpolations")
@safe unittest
{
    int a = 1;
    int b = 2;
    auto result = styledText(i"{green $(a) + $(b)}");
    assert(result == "\x1b[32m1 + 2\x1b[39m");
}

/// Interpolated expression at the boundary of a styled block — expression
/// right after the style name space separator and right before closing brace.
@("styled.interpolationAtBoundaries")
@safe unittest
{
    int val = 7;
    assert(styledText(i"{red $(val)}") == "\x1b[31m7\x1b[39m");
}

/// Text before and after styled blocks is unaffected.
@("styled.textAroundBlocks")
@safe unittest
{
    auto result = styledText(i"before {bold middle} after");
    assert(result == "before \x1b[1mmiddle\x1b[22m after");
}

/// Adjacent styled blocks with no gap between them.
@("styled.adjacentBlocks")
@safe unittest
{
    auto result = styledText(i"{red A}{green B}{blue C}");
    assert(result ==
        "\x1b[31mA\x1b[39m" ~
        "\x1b[32mB\x1b[39m" ~
        "\x1b[34mC\x1b[39m"
    );
}

/// Leading dot in style spec — the empty segment before the dot is ignored.
@("styled.leadingDotInSpec")
@safe unittest
{
    // ".bold" → empty part (skipped), then "bold"
    assert(styledText(i"{.bold text}") == "\x1b[1mtext\x1b[22m");
}

/// Trailing dot in style spec — the empty segment after the dot is ignored.
@("styled.trailingDotInSpec")
@safe unittest
{
    // "bold." → "bold", then empty part (skipped)
    assert(styledText(i"{bold. text}") == "\x1b[1mtext\x1b[22m");
}

/// Consecutive dots in style spec — empty segments are skipped.
@("styled.consecutiveDotsInSpec")
@safe unittest
{
    // "bold..red" → "bold", empty (skipped), "red"
    assert(styledText(i"{bold..red text}") == "\x1b[1m\x1b[31mtext\x1b[39m\x1b[22m");
}

/// Single character content in a styled block.
@("styled.singleCharContent")
@safe unittest
{
    assert(styledText(i"{red X}") == "\x1b[31mX\x1b[39m");
}

/// Content consisting entirely of spaces.
@("styled.spacesOnly")
@safe unittest
{
    assert(styledText(i"{red   }") == "\x1b[31m  \x1b[39m");
}

/// Nesting depth of exactly maxNestingDepth (16) — should still work.
@("styled.maxNestingDepth")
@safe unittest
{
    // Build 16 levels of nesting: {bold {bold {bold ... text ...}}}...}
    // Each level re-specifies bold, so the inherited style is the same.
    auto result = styledText(
        i"{bold {bold {bold {bold {bold {bold {bold {bold {bold {bold {bold {bold {bold {bold {bold {bold deep}}}}}}}}}}}}}}}}"
    );

    // "bold" inherited at every level — only emitted once at the outermost
    assert(result ==
        "\x1b[1m" ~
        "deep" ~
        "\x1b[22m"
    );
}

/// Nesting beyond maxNestingDepth (16) is gracefully handled via overflowDepth.
/// Overflow levels are silently ignored (content still passes through).
@("styled.overflowNesting")
@safe unittest
{
    // 17 levels — the 17th push overflows; its pop decrements overflowDepth
    auto result = styledText(
        i"{bold {bold {bold {bold {bold {bold {bold {bold {bold {bold {bold {bold {bold {bold {bold {bold {red overflow}}}}}}}}}}}}}}}}}"
    );

    // The 17th {red ...} overflows, so red is never emitted.
    // Content "overflow" still appears, wrapped in the outermost bold.
    assert(result ==
        "\x1b[1m" ~
        "overflow" ~
        "\x1b[22m"
    );
}

/// An overflowed block whose (dropped) state differs from the real top must not
/// emit spurious codes. Here level 16 negates bold, then the 17th block
/// overflows: entering/exiting it must add nothing to the escape stream.
@("styled.overflowNestingNoSpuriousEmit")
@safe unittest
{
    auto result = styledText(
        i"{bold {bold {bold {bold {bold {bold {bold {bold {bold {bold {bold {bold {bold {bold {bold {~bold {red overflow}}}}}}}}}}}}}}}}}"
    );

    // bold ON, then OFF at ~bold, "overflow" plain, bold restored on exit of the
    // ~bold block, bold OFF at the end — no doubled 22/1 from the overflow.
    assert(result ==
        "\x1b[1m" ~   // bold ON (outermost)
        "\x1b[22m" ~  // bold OFF (level 16 ~bold)
        "overflow" ~
        "\x1b[1m" ~   // bold restored (exit ~bold)
        "\x1b[22m"    // bold OFF (exit outermost)
    );
}

/// Maximum styles per block (8) — adding an 8th style works.
@("styled.maxStylesPerBlock")
@safe unittest
{
    // 8 distinct styles: bold, italic, underline, dim, inverse, strikethrough, red, bgBlue
    auto result = styledText(
        i"{bold.italic.underline.dim.inverse.strikethrough.red.bgBlue X}"
    );

    // All 8 open codes, then text, then all 8 close codes (reverse order)
    assert(result ==
        "\x1b[1m\x1b[3m\x1b[4m\x1b[2m\x1b[7m\x1b[9m\x1b[31m\x1b[44m" ~
        "X" ~
        "\x1b[49m\x1b[39m\x1b[29m\x1b[27m\x1b[22m\x1b[24m\x1b[23m\x1b[22m"
    );
}

/// Exceeding maxStylesPerBlock (8) — the 9th style is silently dropped.
@("styled.overflowStylesPerBlock")
@safe unittest
{
    // 9 styles: hidden is the 9th
    auto result = styledText(
        i"{bold.italic.underline.dim.inverse.strikethrough.red.bgBlue.hidden X}"
    );

    // "hidden" is dropped (addStyle no-op because count >= length)
    // Same output as maxStylesPerBlock test
    assert(result ==
        "\x1b[1m\x1b[3m\x1b[4m\x1b[2m\x1b[7m\x1b[9m\x1b[31m\x1b[44m" ~
        "X" ~
        "\x1b[49m\x1b[39m\x1b[29m\x1b[27m\x1b[22m\x1b[24m\x1b[23m\x1b[22m"
    );
}

/// Empty string input.
@("styled.emptyInput")
@safe unittest
{
    assert(styledText(i"") == "");
}

/// Lone closing brace outside styled block is passed through.
@("styled.loneClosingBrace")
@safe unittest
{
    assert(styledText(i"a } b") == "a } b");
}

/// Multiple escaped brace pairs in sequence.
@("styled.multipleEscapedBraces")
@safe unittest
{
    assert(styledText(i"#{#{#}#}") == "{{}}");
}

/// Styled block containing only an interpolated expression (no literal text).
@("styled.onlyInterpolation")
@safe unittest
{
    string s = "hi";
    assert(styledText(i"{bold $(s)}") == "\x1b[1mhi\x1b[22m");
}

/// Nested blocks where inner replaces the color (not using negation).
@("styled.innerReplacesColor")
@safe unittest
{
    // {red ... {green ...} ...} — green temporarily shadows the inherited red.
    // Inner block inherits [red] and adds green → [red, green]. Closing green
    // emits 39 (default fg), which also clears red, so red must be re-opened.
    auto result = styledText(i"{red A {green B} C}");
    assert(result ==
        "\x1b[31m" ~      // red ON
        "A " ~
        "\x1b[32m" ~      // green ON (added to inherited red)
        "B" ~
        "\x1b[39m" ~      // green OFF (close code for green = 39, resets fg)
        "\x1b[31m" ~      // red restored (inherited color re-opened on the fg channel)
        " C" ~
        "\x1b[39m"        // red OFF
    );
}

/// Negation with `~` on a style that uses the same close code as another
/// active style (e.g., both bold and dim close with code 22). Closing dim
/// emits 22, which also clears the still-active bold, so bold must be re-opened
/// for the inner content.
@("styled.negationSharedCloseCode")
@safe unittest
{
    // bold and dim both have close code 22
    auto result = styledText(i"{bold.dim text {~dim inner} text}");
    assert(result ==
        "\x1b[1m\x1b[2m" ~   // bold ON, dim ON
        "text " ~
        "\x1b[22m\x1b[1m" ~  // dim OFF (via 22, kills bold too) then bold restored
        "inner" ~
        "\x1b[2m" ~          // dim restored (bold still on)
        " text" ~
        "\x1b[22m\x1b[22m"   // dim OFF, bold OFF
    );
}

/// Shared-close-code restoration across nesting (not negation): an inner block
/// adding a style that shares a close code with an inherited one must restore
/// the inherited style on exit. `22` (bold/dim) mirrors the `39`/`49` colour
/// cases in `colorNestingRestoresOuter`.
@("styled.sharedCloseCodeNestingRestoresOuter")
@safe unittest
{
    // dim inherited, inner adds bold; exiting bold emits 22, which also clears
    // dim, so dim must be re-opened for " C".
    assert(styledText(i"{dim A {bold B} C}")
        == "\x1b[2mA \x1b[1mB\x1b[22m\x1b[2m C\x1b[22m");
    // Negating one fg colour while another remains: `~green` emits 39, clearing
    // the still-active red, which must be restored for "in".
    assert(styledText(i"{red.green o {~green in} o}")
        == "\x1b[31m\x1b[32mo \x1b[39m\x1b[31min\x1b[32m o\x1b[39m\x1b[39m");
}

/// Style block immediately after an escaped brace.
@("styled.styleAfterEscapedBrace")
@safe unittest
{
    assert(styledText(i"#{{red text}") == "{\x1b[31mtext\x1b[39m");
}

/// Escaped brace immediately after a styled block.
@("styled.escapedBraceAfterStyle")
@safe unittest
{
    assert(styledText(i"{red text}#}") == "\x1b[31mtext\x1b[39m}");
}

/// Deeply nested with interleaved text at each level.
@("styled.deepNestingInterleavedText")
@safe unittest
{
    auto result = styledText(i"{bold a{italic b{underline c}d}e}");
    assert(result ==
        "\x1b[1m" ~      // bold ON
        "a" ~
        "\x1b[3m" ~      // italic ON
        "b" ~
        "\x1b[4m" ~      // underline ON
        "c" ~
        "\x1b[24m" ~     // underline OFF
        "d" ~
        "\x1b[23m" ~     // italic OFF
        "e" ~
        "\x1b[22m"       // bold OFF
    );
}

/// Bright foreground colors produce the correct escape codes (90-97).
@("styled.brightForegroundColors")
@safe unittest
{
    assert(styledText(i"{brightRed text}") == "\x1b[91mtext\x1b[39m");
    assert(styledText(i"{brightGreen text}") == "\x1b[92mtext\x1b[39m");
    assert(styledText(i"{brightCyan text}") == "\x1b[96mtext\x1b[39m");
}

/// Bright background colors produce the correct escape codes (100-107).
@("styled.brightBackgroundColors")
@safe unittest
{
    assert(styledText(i"{bgBrightRed text}") == "\x1b[101mtext\x1b[49m");
    assert(styledText(i"{bgBrightBlue text}") == "\x1b[104mtext\x1b[49m");
}

/// Negation of a background color restores the default background.
@("styled.negateBackgroundColor")
@safe unittest
{
    auto result = styledText(i"{bgRed outer {~bgRed inner} outer}");
    assert(result ==
        "\x1b[41m" ~   // bgRed ON
        "outer " ~
        "\x1b[49m" ~   // bgRed OFF (negated, close code 49)
        "inner" ~
        "\x1b[41m" ~   // bgRed ON (restored)
        " outer" ~
        "\x1b[49m"     // bgRed OFF
    );
}

/// Only-negation spec (no positive styles) in a root block.
@("styled.negationOnlyAtRoot")
@safe unittest
{
    // ~bold at root has nothing to negate — content passes through unstyled
    assert(styledText(i"{~bold text}") == "text");
}

/// Chained negations: remove multiple inherited styles at once.
@("styled.chainedNegation")
@safe unittest
{
    auto result = styledText(
        i"{bold.italic.underline outer {~bold.~italic.~underline plain} outer}"
    );
    assert(result ==
        "\x1b[1m\x1b[3m\x1b[4m" ~   // bold, italic, underline ON
        "outer " ~
        "\x1b[24m\x1b[23m\x1b[22m" ~ // underline OFF, italic OFF, bold OFF
        "plain" ~
        "\x1b[1m\x1b[3m\x1b[4m" ~   // bold, italic, underline ON (restored)
        " outer" ~
        "\x1b[24m\x1b[23m\x1b[22m"  // underline OFF, italic OFF, bold OFF
    );
}
