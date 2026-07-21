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

import sparkles.base.term_color : Color, ColorDepth, parseHexColor;
import sparkles.base.term_style : Style, SgrGroupReset, openCode, closeCode,
    TextAttr, UnderlineStyle, TermStyle, writeStyleTransition;

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
///     depth = terminal color capability. `ColorDepth.none` parses and strips
///              the style markup, emitting no escapes (plain text); otherwise
///              24-bit/256-palette colors are folded down to the nearest
///              representable form (`trueColor`, the no-argument default, does no
///              folding).
void writeStyled(Writer, Args...)(
    ref Writer w,
    ColorDepth depth,
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
            parseLiteral(w, lit, ctx, depth);
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

/// ditto — defaults to `ColorDepth.trueColor` (no color folding). `depth`
/// precedes the interpolated string so the IES template still deduces cleanly.
void writeStyled(Writer, Args...)(
    ref Writer w, InterpolationHeader header, Args args, InterpolationFooter footer)
    => writeStyled(w, ColorDepth.trueColor, header, args, footer);

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
    // bold.red applies both styles; groups close in a fixed order
    // (intensity, then foreground color).
    assert(styledText(i"{bold.red text}") == "\x1b[1;31mtext\x1b[22;39m");
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
        "\x1b[1;31m" ~      // bold ON, red ON
        "styled " ~
        "\x1b[39m" ~         // red OFF (negated)
        "plain" ~
        "\x1b[31m" ~         // red ON (restored on exit)
        "\x1b[22;39m"       // bold OFF, red OFF (group order: intensity, color)
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

/// `plainText` (i.e. `ColorDepth.none`) strips style markup, producing plain text.
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

/// Renders IES to a fresh string at `depth` (`ColorDepth.none` = markup stripped).
private string renderToString(Args...)(
    ColorDepth depth, InterpolationHeader header, Args args, InterpolationFooter footer)
{
    import std.array : appender;

    auto buf = appender!string;
    writeStyled(buf, depth, header, args, footer);
    return buf[];
}

/// Returns styled IES as a string; `depth` folds colors to the terminal's tier.
string styledText(Args...)(ColorDepth depth, InterpolationHeader header, Args args, InterpolationFooter footer)
    => renderToString(depth, header, args, footer);

/// ditto — defaults to `ColorDepth.trueColor` (no folding).
string styledText(Args...)(InterpolationHeader header, Args args, InterpolationFooter footer)
    => renderToString(ColorDepth.trueColor, header, args, footer);

/// Returns the IES with all style markup stripped — plain text. This is
/// `styledText` at `ColorDepth.none`.
string plainText(Args...)(InterpolationHeader header, Args args, InterpolationFooter footer)
    => renderToString(ColorDepth.none, header, args, footer);

// ─────────────────────────────────────────────────────────────────────────────
// Lazy Wrapper
// ─────────────────────────────────────────────────────────────────────────────

/// Lazy wrapper that defers styled processing until consumed.
struct StyledText(Args...)
{
    Args args;
    ColorDepth depth = ColorDepth.trueColor;

    /// Convert to string (allocates)
    string toString() const
    {
        import std.array : appender;

        auto buf = appender!string;
        writeStyled(buf, depth, args);
        return buf[];
    }

    /// Callback-based toString for writeln compatibility
    void toString(scope void delegate(const(char)[]) sink) const
    {
        sink(toString());
    }
}

/// Returns a lazy wrapper that can be converted to string or written to output
/// range; `depth` folds colors to the terminal's tier.
auto styled(Args...)(ColorDepth depth, InterpolationHeader header, Args args, InterpolationFooter footer)
    => StyledText!(InterpolationHeader, Args, InterpolationFooter)(header, args, footer, depth);

/// ditto — defaults to `ColorDepth.trueColor` (no folding).
auto styled(Args...)(InterpolationHeader header, Args args, InterpolationFooter footer)
    => StyledText!(InterpolationHeader, Args, InterpolationFooter)(header, args, footer);

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

/// Backs the four public write wrappers: pick the stream (`toErr`) and whether
/// to append a newline (`newline`).
private void styledWriteTo(bool toErr, bool newline, Args...)(
    ColorDepth depth, InterpolationHeader header, Args args, InterpolationFooter footer)
{
    import std.stdio : stdout, stderr;

    static if (toErr)
        auto w = stderr.lockingTextWriter;
    else
        auto w = stdout.lockingTextWriter;
    writeStyled(w, depth, header, args, footer);
    static if (newline)
        w.put('\n');
}

/// Write styled IES to stdout (`depth` folds colors to the terminal's tier).
void styledWrite(Args...)(ColorDepth depth, InterpolationHeader header, Args args, InterpolationFooter footer)
    => styledWriteTo!(false, false)(depth, header, args, footer);
/// ditto — defaults to `ColorDepth.trueColor`.
void styledWrite(Args...)(InterpolationHeader header, Args args, InterpolationFooter footer)
    => styledWriteTo!(false, false)(ColorDepth.trueColor, header, args, footer);

/// Write styled IES to stdout with newline.
void styledWriteln(Args...)(ColorDepth depth, InterpolationHeader header, Args args, InterpolationFooter footer)
    => styledWriteTo!(false, true)(depth, header, args, footer);
/// ditto — defaults to `ColorDepth.trueColor`.
void styledWriteln(Args...)(InterpolationHeader header, Args args, InterpolationFooter footer)
    => styledWriteTo!(false, true)(ColorDepth.trueColor, header, args, footer);

/// Write styled IES to stderr.
void styledWriteErr(Args...)(ColorDepth depth, InterpolationHeader header, Args args, InterpolationFooter footer)
    => styledWriteTo!(true, false)(depth, header, args, footer);
/// ditto — defaults to `ColorDepth.trueColor`.
void styledWriteErr(Args...)(InterpolationHeader header, Args args, InterpolationFooter footer)
    => styledWriteTo!(true, false)(ColorDepth.trueColor, header, args, footer);

/// Write styled IES to stderr with newline.
void styledWritelnErr(Args...)(ColorDepth depth, InterpolationHeader header, Args args, InterpolationFooter footer)
    => styledWriteTo!(true, true)(depth, header, args, footer);
/// ditto — defaults to `ColorDepth.trueColor`.
void styledWritelnErr(Args...)(InterpolationHeader header, Args args, InterpolationFooter footer)
    => styledWriteTo!(true, true)(ColorDepth.trueColor, header, args, footer);

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
    // palette index < 16 is palette-native: a classic SGR code, not 38;5;N.
    assert(styledText(i"{@5 x}") == "\x1b[35mx\x1b[39m");
    assert(styledText(i"{@12 x}") == "\x1b[94mx\x1b[39m");
    assert(styledText(i"{bg@1 x}") == "\x1b[41mx\x1b[49m");
}

/// The optional `depth` argument folds 24-bit and 256-palette colors to the
/// terminal's tier (default `trueColor` = no folding).
@("writeStyled.depthFolding")
@safe unittest
{
    import sparkles.base.term_color : ColorDepth;

    // Default (trueColor): emitted verbatim.
    assert(styledText(i"{#cba6f7 x}") == "\x1b[38;2;203;166;247mx\x1b[39m");
    // 24-bit → nearest 256-palette entry.
    assert(styledText(ColorDepth.ansi256, i"{#cba6f7 x}") == "\x1b[38;5;183mx\x1b[39m");
    // 24-bit → nearest classic-16 (mauve → white, 37).
    assert(styledText(ColorDepth.ansi16, i"{#cba6f7 x}") == "\x1b[37mx\x1b[39m");
    // A 256-palette index passes through at ansi256; classic-16 indices are
    // unaffected by depth.
    assert(styledText(ColorDepth.ansi256, i"{@183 x}") == "\x1b[38;5;183mx\x1b[39m");
    assert(styledText(ColorDepth.ansi16, i"{@5 x}") == "\x1b[35mx\x1b[39m");
    // Stripped output (plainText) has no color at any tier.
    assert(plainText(i"{#cba6f7 x}") == "x");
}

/// Extended underline shapes (`curlyUnderline`/`doubleUnderline`/…) and an
/// independent underline color via `ul#`/`ul@`.
@("writeStyled.underline")
@safe unittest
{
    import sparkles.base.term_color : ColorDepth;

    // Plain underline is single (bare 4); the extended shapes use the colon form.
    assert(styledText(i"{underline x}") == "\x1b[4mx\x1b[24m");
    assert(styledText(i"{doubleUnderline x}") == "\x1b[4:2mx\x1b[24m");
    assert(styledText(i"{curlyUnderline x}") == "\x1b[4:3mx\x1b[24m");
    assert(styledText(i"{dottedUnderline x}") == "\x1b[4:4mx\x1b[24m");
    assert(styledText(i"{dashedUnderline x}") == "\x1b[4:5mx\x1b[24m");

    // Underline color (`ul#`/`ul@`): 58;… at truecolor, not emitted below ansi256.
    assert(styledText(i"{curlyUnderline.ul#ff5555 x}")
        == "\x1b[4:3;58;2;255;85;85mx\x1b[24;59m");
    assert(styledText(ColorDepth.ansi16, i"{curlyUnderline.ul#ff5555 x}")
        == "\x1b[4:3mx\x1b[24m");
    assert(styledText(i"{ul@201 x}") == "\x1b[58;5;201mx\x1b[59m");

    // Negation clears the underline and restores it on exit.
    assert(styledText(i"{curlyUnderline a {~curlyUnderline b} c}")
        == "\x1b[4:3ma \x1b[24mb\x1b[4:3m c\x1b[24m");
}

/// Colors compose with named styles (dots), nesting, and interpolation, just
/// like the named styles do.
@("writeStyled.colorComposition")
@safe unittest
{
    // bold + palette fg: opened and closed in a fixed group order.
    assert(styledText(i"{bold.@183 x}") == "\x1b[1;38;5;183mx\x1b[22;39m");
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
    // Foreground over foreground: exiting red sets the fg straight back to blue
    // (one absolute set, no redundant reset-then-reopen).
    assert(styledText(i"{blue A {red B} C}")
        == "\x1b[34mA \x1b[31mB\x1b[34m C\x1b[39m");
    // Background over background: exiting the inner bg sets bg straight back.
    assert(styledText(i"{bg@235 A {bg@200 B} C}")
        == "\x1b[48;5;235mA \x1b[48;5;200mB\x1b[48;5;235m C\x1b[49m");
}

// ─────────────────────────────────────────────────────────────────────────────
// Implementation Details
// ─────────────────────────────────────────────────────────────────────────────

private enum maxNestingDepth = 16;

// The resolved-style type (`TermStyle`), the color type (`Color`), and the
// minimal-transition encoder (`writeStyleTransition`) are shared, in
// `sparkles.base.term_style` / `sparkles.base.term_color`. The parser resolves
// each block eagerly (seed from the parent, apply each dot-part), so a plain
// field diff between adjacent blocks is all the emitter needs.

private enum ParseState
{
    normal,
    styleName,
    content
}

@safe
private struct ParserContext
{
    // Fixed stack; nesting past the cap is tracked (overflowDepth), not pushed.
    TermStyle[maxNestingDepth] styleStack;
    size_t stackDepth;
    /// Tracks pushes that were dropped due to stack overflow
    size_t overflowDepth;
    ParseState state = ParseState.normal;
    size_t styleNameStart;
    size_t styleNameEnd;

    void pushStyle(TermStyle s) @nogc nothrow
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

    ref TermStyle topStyle() return @nogc nothrow
        => styleStack[stackDepth > 0 ? stackDepth - 1 : 0];

    TermStyle parentStyle() const @nogc nothrow
        => stackDepth > 1 ? styleStack[stackDepth - 2] : TermStyle.init;

    bool hasStyles() const @nogc nothrow => stackDepth > 0;
}

/// Parses a literal segment and writes styled output
@safe
private void parseLiteral(Writer)(
    ref Writer w,
    const(char)[] literal,
    ref ParserContext ctx,
    ColorDepth depth
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
                if (tryBraceEscape(w, literal, i))
                    continue;
                if (c == '{')
                {
                    ctx.state = ParseState.styleName;
                    ctx.styleNameStart = i + 1;
                    ctx.styleNameEnd = i + 1;
                }
                else
                    put(w, c); // regular char, or a lone '}' outside any block
                break;

            case ParseState.styleName:
                if (c == ' ')
                {
                    // End of style names: resolve the block and open it. A block
                    // dropped past the depth cap was never pushed, so `topStyle`
                    // still refers to its parent — emitting would re-diff the
                    // parent against its own parent (spurious codes).
                    auto spec = literal[ctx.styleNameStart .. ctx.styleNameEnd];
                    applyStyleSpec(spec, ctx);
                    if (depth != ColorDepth.none && ctx.overflowDepth == 0)
                        writeStyleTransition(w, ctx.parentStyle, ctx.topStyle, depth);
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
                    // Accumulate style name (# / @ color literals live here too)
                    ctx.styleNameEnd = i + 1;
                }
                break;

            case ParseState.content:
                if (tryBraceEscape(w, literal, i))
                    continue;
                if (c == '{')
                {
                    // Nested block
                    ctx.state = ParseState.styleName;
                    ctx.styleNameStart = i + 1;
                    ctx.styleNameEnd = i + 1;
                }
                else if (c == '}')
                {
                    // End of block; a block dropped past the depth cap emitted
                    // nothing on entry, so it emits nothing on exit either.
                    if (depth != ColorDepth.none && ctx.overflowDepth == 0)
                        writeStyleTransition(w, ctx.topStyle, ctx.parentStyle, depth);
                    ctx.popStyle();
                    ctx.state = ctx.hasStyles ? ParseState.content : ParseState.normal;
                }
                else
                    put(w, c);
                break;
        }
        i++;
    }
}

/// Consume a `#{` / `#}` escape at `literal[i]`, emitting the literal brace and
/// advancing `i` past both characters. Returns `true` (caller should `continue`)
/// when an escape was consumed; a lone `#` is left for the normal path. Used by
/// the `normal` and `content` states, which handle escapes identically.
private bool tryBraceEscape(Writer)(ref Writer w, const(char)[] literal, ref size_t i)
{
    import std.range.primitives : put;

    if (literal[i] == '#' && i + 1 < literal.length
        && (literal[i + 1] == '{' || literal[i + 1] == '}'))
    {
        put(w, literal[i + 1]);
        i += 2;
        return true;
    }
    return false;
}

/// Resolves a dot-separated spec ("bold.red", "~red.bold") into a child style
/// seeded from the current top, and pushes it onto the block stack.
@safe nothrow @nogc
private void applyStyleSpec(const(char)[] spec, ref ParserContext ctx)
{
    // Inherit the parent block's style (or the terminal default at the root).
    TermStyle newState = ctx.hasStyles ? ctx.topStyle : TermStyle.init;

    size_t start = 0;
    foreach (i, c; spec)
    {
        if (c == '.')
        {
            if (i > start)
                applyStyleName(spec[start .. i], newState);
            start = i + 1;
        }
    }
    if (start < spec.length)
        applyStyleName(spec[start .. $], newState);

    ctx.pushStyle(newState);
}

/// Applies one dot-part token to `style`: strips the `~` negation prefix, then
/// dispatches to a color literal (`#RGB`/`#RRGGBB`, `@N`, each `bg`- or `ul`-
/// prefixable), an underline shape (`curlyUnderline`, …), or a named style.
/// Unknown/malformed tokens are ignored.
@safe nothrow @nogc
private void applyStyleName(const(char)[] token, ref TermStyle style)
{
    if (token.length == 0)
        return;

    const negate = token[0] == '~';
    const(char)[] name = negate ? token[1 .. $] : token;

    // Color literal (`#…` / `@…`), on the fg channel or, with a `bg`/`ul`
    // prefix, the background / underline channel. Named `bgRed` etc. fall
    // through to `styleFromName`.
    bool bg, ul;
    if (name.length > 2 && (name[2] == '#' || name[2] == '@'))
    {
        if (name[0 .. 2] == "bg")
        {
            bg = true;
            name = name[2 .. $];
        }
        else if (name[0 .. 2] == "ul")
        {
            ul = true;
            name = name[2 .. $];
        }
    }
    if (name.length && (name[0] == '#' || name[0] == '@'))
    {
        Color c;
        if (parseColorLiteral(name, c))
        {
            if (ul)
                applyUnderlineColor(style, c, negate);
            else
                applyColor(style, bg, c, negate);
        }
        return;
    }

    // Extended underline shapes (not in the `Style` [open, close] table).
    UnderlineStyle shape;
    if (underlineShapeFromName(name, shape))
    {
        style.underline = negate ? UnderlineStyle.none : shape;
        return;
    }

    // Named style: `none` is a no-op, `reset` clears every group, otherwise
    // dispatch by SGR group.
    const s = styleFromName(name);
    if (s == Style.none)
        return;
    if (s == Style.reset)
    {
        if (!negate)
            style = TermStyle.init;
        return;
    }
    applyNamed(style, s, negate);
}

/// The extended underline shapes, as markup names. Plain `underline` (single) is
/// left to `styleFromName`/`applyNamed`. Returns false for any other name.
@safe nothrow @nogc
private bool underlineShapeFromName(const(char)[] name, out UnderlineStyle shape)
{
    switch (name)
    {
        case "doubleUnderline": shape = UnderlineStyle.double_; return true;
        case "curlyUnderline":  shape = UnderlineStyle.curly;   return true;
        case "dottedUnderline": shape = UnderlineStyle.dotted;  return true;
        case "dashedUnderline": shape = UnderlineStyle.dashed;  return true;
        default: return false;
    }
}

/// Sets the underline color, or — when negating — clears it only if it holds
/// exactly `c` (matching the fg/bg "remove if present" semantics).
@safe nothrow @nogc
private void applyUnderlineColor(ref TermStyle style, in Color c, bool negate)
{
    if (negate)
    {
        if (style.underlineColor == c)
            style.underlineColor = Color.init;
    }
    else
        style.underlineColor = c;
}

/// Parses a `#RGB`/`#RRGGBB` or `@N` color literal (the `bg` prefix already
/// stripped) into `c`. Returns false on malformed input.
@safe nothrow @nogc
private bool parseColorLiteral(const(char)[] name, out Color c)
{
    if (name[0] == '#')
    {
        // `parseHexColor` (base) advances a cursor; the whole token must be the
        // color (no trailing bytes).
        const(char)[] rest = name;
        auto parsed = parseHexColor(rest);
        if (parsed.hasError || rest.length != 0)
            return false;
        c = parsed.value;
        return true;
    }

    // name[0] == '@' — 256-palette index; the whole token must be the number.
    import sparkles.base.text.readers : readInteger;

    auto rest = name[1 .. $];
    auto idx = readInteger!ubyte(rest);
    if (idx.hasError || rest.length != 0)
        return false;
    c = Color.fromPalette(idx.value);
    return true;
}

/// Sets the fg (or `bg`) color slot, or — when negating — clears it only if it
/// currently holds exactly `c` (matching the old "remove if present" semantics,
/// so `~red` on a green foreground is a no-op).
@safe nothrow @nogc
private void applyColor(ref TermStyle style, bool bg, in Color c, bool negate)
{
    if (negate)
    {
        if (bg)
        {
            if (style.bg == c)
                style.bg = Color.init;
        }
        else if (style.fg == c)
            style.fg = Color.init;
    }
    else if (bg)
        style.bg = c;
    else
        style.fg = c;
}

/// Applies a named `Style` (never `none`/`reset`) to its SGR group on the base
/// `TermStyle`, keyed by its close code (which names the group). Negation clears
/// the group.
@safe nothrow @nogc
private void applyNamed(ref TermStyle style, Style s, bool negate)
{
    switch (s.closeCode)
    {
        case SgrGroupReset.intensity: // bold or dim, distinguished by open code
            setIntensity(style, s.openCode == Style.bold.openCode ? TextAttr.bold : TextAttr.dim, negate);
            break;
        case SgrGroupReset.italic:    setAttr(style, TextAttr.italic, negate); break;
        case SgrGroupReset.underline: style.underline = negate ? UnderlineStyle.none : UnderlineStyle.single; break;
        case SgrGroupReset.inverse:   setAttr(style, TextAttr.inverse, negate); break;
        case SgrGroupReset.hidden:    setAttr(style, TextAttr.hidden, negate); break;
        case SgrGroupReset.strike:    setAttr(style, TextAttr.strikethrough, negate); break;
        case SgrGroupReset.foreground: applyColor(style, false, colorFromSgr(s.openCode), negate); break;
        case SgrGroupReset.background: applyColor(style, true, colorFromSgr(s.openCode), negate); break;
        default: break; // unknown group — ignore
    }
}

/// Set (or, when negating, clear) a single `TextAttr` flag.
@safe nothrow @nogc
private void setAttr(ref TermStyle style, TextAttr flag, bool negate)
{
    style.attrs = negate ? style.attrs & ~flag : style.attrs | flag;
}

/// Set the intensity (bold or dim — a single exclusive group; setting one clears
/// the other so the last in a spec wins). Negating clears only the named flag.
@safe nothrow @nogc
private void setIntensity(ref TermStyle style, TextAttr which, bool negate)
{
    style.attrs = negate
        ? style.attrs & ~which
        : (style.attrs & ~(TextAttr.bold | TextAttr.dim)) | which;
}

/// Maps a named color's SGR open code (`Style.<name>[0]`) to its palette index:
/// fg `30`–`37` / bg `40`–`47` → `0`–`7`; bright fg `90`–`97` / bg `100`–`107` →
/// `8`–`15`. `writeSgrColor` renders those palette indices back to the same
/// classic codes, so named colors round-trip byte-for-byte.
@safe nothrow @nogc
private Color colorFromSgr(uint openCode)
{
    ubyte index;
    if (openCode >= 30 && openCode <= 37)
        index = cast(ubyte)(openCode - 30);
    else if (openCode >= 90 && openCode <= 97)
        index = cast(ubyte)(openCode - 90 + 8);
    else if (openCode >= 40 && openCode <= 47)
        index = cast(ubyte)(openCode - 40);
    else if (openCode >= 100 && openCode <= 107)
        index = cast(ubyte)(openCode - 100 + 8);
    return Color.fromPalette(index);
}

/// `#RGB` shorthand doubles each nibble (`0xN → 0xNN`); a guard that the base
/// `parseHexColor` short form matches the full form byte-for-byte.
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
/// Styles are emitted in a fixed group order (intensity, italic, underline,
/// inverse, hidden, strike, fg, bg) on every transition:
/// - [1m[3m[31m  → bold on, italic on, red on
/// - "A"
/// - [4m[39m     → underline on, red off
/// - "B"
/// - [36m        → cyan on
/// - "C"
/// - [22m[23m    → bold off, italic off
/// - "D"
/// - [1m[3m      → bold on, italic on (restore)
/// - "E"
/// - [39m        → cyan off
/// - "F"
/// - [24m[31m    → underline off, red on (restore)
/// - "G"
/// - [22m[23m[39m → bold off, italic off, red off
@("styled.complexNestingWithNegation")
@safe unittest
{
    auto result = styledText(
        i"{bold.italic.red A{~red.underline B{cyan C{~bold.~italic D}E}F}G}"
    );

    // Verify the exact escape sequence
    // Note: styles are closed in reverse order of their position in the style array
    assert(result ==
        "\x1b[1;3;31m" ~            // bold, italic, red ON
        "A" ~
        "\x1b[4;39m" ~             // underline ON, red OFF (group order)
        "B" ~
        "\x1b[36m" ~                // cyan ON (added)
        "C" ~
        "\x1b[22;23m" ~            // bold OFF, italic OFF (group order)
        "D" ~
        "\x1b[1;3m" ~              // bold ON, italic ON (restored)
        "E" ~
        "\x1b[39m" ~                // cyan OFF (exiting cyan block)
        "F" ~
        "\x1b[24;31m" ~            // underline OFF + red restored
        "G" ~
        "\x1b[22;23;39m"           // bold OFF, italic OFF, red OFF (group order)
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
        "\x1b[1;3;4m" ~            // bold, italic, underline ON
        "outer " ~
        "\x1b[22;24m" ~           // bold OFF, underline OFF (group order)
        "inner" ~
        "\x1b[1;4m" ~             // bold ON, underline ON (restored)
        " outer" ~
        "\x1b[22;23;24m"          // bold OFF, italic OFF, underline OFF (group order)
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
        "\x1b[4;36m" ~             // underline ON, cyan ON (new styles)
        "child" ~
        "\x1b[24;39m" ~           // underline OFF, cyan OFF (group order)
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
        "\x1b[1;31m" ~      // bold ON, red ON
        "start " ~
        "\x1b[36m" ~         // fg: red -> cyan (one absolute set, no 39 first)
        "middle" ~
        "\x1b[31m" ~         // fg: cyan -> red (restored directly)
        " end" ~
        "\x1b[22;39m"       // bold OFF, red OFF (group order)
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
    assert(result == "\x1b[31;47mtext\x1b[39;49m");
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
        "\x1b[1;31m" ~      // bold ON, red ON
        "outer " ~
        "\x1b[22;39m" ~    // bold OFF, red OFF (negated, group order)
        "inner" ~
        "\x1b[1;31m" ~     // bold ON, red ON (restored)
        " outer" ~
        "\x1b[22;39m"      // bold OFF, red OFF (group order)
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
    assert(styledText(i"{bold..red text}") == "\x1b[1;31mtext\x1b[22;39m");
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

/// Every SGR group can be set in one block — the group model has no
/// styles-per-block cap. Codes are emitted in the fixed group order (intensity,
/// italic, underline, inverse, hidden, strike, fg, bg) and closed the same way.
@("styled.allGroupsInOneBlock")
@safe unittest
{
    auto result = styledText(
        i"{bold.italic.underline.inverse.hidden.strikethrough.red.bgBlue X}"
    );

    assert(result ==
        "\x1b[1;3;4;7;8;9;31;44m" ~ // all groups set in one escape
        "X" ~
        "\x1b[22;23;24;27;28;29;39;49m" // all cleared in one escape
    );
}

/// Two colors on the same channel collapse to the last (one fg / one bg slot),
/// just like the intensity group — there is no hidden stack of shadowed colors.
@("styled.colorGroupLastWins")
@safe unittest
{
    assert(styledText(i"{red.green x}") == "\x1b[32mx\x1b[39m");
    assert(styledText(i"{bgRed.bgBlue x}") == "\x1b[44mx\x1b[49m");
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
    // {red ... {green ...} ...} — green shadows the inherited red on the single
    // fg slot; exiting the inner block sets the fg straight back to red.
    auto result = styledText(i"{red A {green B} C}");
    assert(result ==
        "\x1b[31m" ~      // red ON
        "A " ~
        "\x1b[32m" ~      // green ON (fg: red -> green)
        "B" ~
        "\x1b[31m" ~      // fg: green -> red (one absolute set, no 39 first)
        " C" ~
        "\x1b[39m"        // red OFF
    );
}

/// Intensity is a single group: bold and dim share one SGR slot, so the last
/// one in a spec wins (they can never both be active), and negation clears it.
@("styled.intensityGroupLastWins")
@safe unittest
{
    // Same-group tokens collapse to the last: `bold.dim` == dim, `dim.bold` == bold.
    assert(styledText(i"{bold.dim x}") == "\x1b[2mx\x1b[22m");
    assert(styledText(i"{dim.bold x}") == "\x1b[1mx\x1b[22m");

    // Negating the active intensity clears it (22); the outer intensity is set
    // absolutely on the way back in, no shared-close-code repair needed.
    auto result = styledText(i"{dim text {~dim inner} text}");
    assert(result ==
        "\x1b[2m" ~     // dim ON
        "text " ~
        "\x1b[22m" ~    // dim OFF (negated)
        "inner" ~
        "\x1b[2m" ~     // dim restored
        " text" ~
        "\x1b[22m"      // dim OFF
    );
}

/// Nesting a different intensity: the dim↔bold switch resets the group first
/// (22) then sets the target, so it is deterministic across terminals, and the
/// parent intensity is set absolutely on exit.
@("styled.intensityNestingIsAbsolute")
@safe unittest
{
    // dim inherited, inner switches to bold: 22 then 1 going in, 22 then 2 out —
    // each transition merges its reset+set into one escape.
    assert(styledText(i"{dim A {bold B} C}")
        == "\x1b[2mA \x1b[22;1mB\x1b[22;2m C\x1b[22m");
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
        "\x1b[1;3;4m" ~            // bold, italic, underline ON
        "outer " ~
        "\x1b[22;23;24m" ~        // bold OFF, italic OFF, underline OFF
        "plain" ~
        "\x1b[1;3;4m" ~           // bold, italic, underline ON (restored)
        " outer" ~
        "\x1b[22;23;24m"          // bold OFF, italic OFF, underline OFF
    );
}
