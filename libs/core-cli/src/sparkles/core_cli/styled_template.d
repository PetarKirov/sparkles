/**
 * Style template processing for IES (Interpolated Expression Sequences).
 *
 * Provides a template syntax for applying terminal styles to IES strings:
 * ---
 * import sparkles.core_cli.styled_template;
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
 * - `{{` — Escaped literal `{`
 * - `}}` — Escaped literal `}`
 */
module sparkles.core_cli.styled_template;

import core.interpolation;

import sparkles.core_cli.term_style : Style;

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

// ─────────────────────────────────────────────────────────────────────────────
// Core Processing Functions
// ─────────────────────────────────────────────────────────────────────────────

/// Writes styled IES output to an output range.
void writeStyled(Writer, Args...)(
    ref Writer w,
    InterpolationHeader,
    Args args,
    InterpolationFooter
)
{
    import std.conv : to;
    import std.range.primitives : put;

    ParserContext ctx;

    static foreach (arg; args)
    {{
        alias T = typeof(arg);
        static if (is(T == InterpolatedLiteral!lit, string lit))
        {
            parseLiteral(w, lit, ctx);
        }
        else static if (is(T == InterpolatedExpression!code, string code))
        {
            // Skip expression metadata
        }
        else
        {
            // Output interpolated value - styles already active from block
            put(w, arg.to!string);
        }
    }}
}

/// Returns styled IES as a string.
string styledText(Args...)(InterpolationHeader header, Args args, InterpolationFooter footer)
{
    import std.array : appender;

    auto buf = appender!string;
    writeStyled(buf, header, args, footer);
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
        import std.conv : to;
        import std.range.primitives : put;

        auto buf = appender!string;
        ParserContext ctx;

        foreach (arg; args)
        {
            alias T = typeof(arg);
            static if (is(T == InterpolatedLiteral!lit, string lit))
            {
                parseLiteral(buf, lit, ctx);
            }
            else static if (is(T == InterpolatedExpression!code, string code))
            {
                // Skip expression metadata
            }
            else static if (is(T == InterpolationHeader) || is(T == InterpolationFooter))
            {
                // Skip header/footer
            }
            else
            {
                // Output interpolated value - styles already active from block
                put(buf, arg.to!string);
            }
        }
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
// Implementation Details
// ─────────────────────────────────────────────────────────────────────────────

private struct StyleState
{
    Style[8] styles;
    size_t count;

    /// Emit escape sequences for transition FROM parent TO this state
    void emitOpenDiff(Writer)(ref Writer w, in StyleState parent) const
    {
        import sparkles.core_cli.text_writers : writeEscapeSeq;

        // Close styles that were in parent but removed in this (negation)
        foreach_reverse (i; 0 .. parent.count)
            if (parent.styles[i] != Style.none && !hasStyle(parent.styles[i]))
                writeEscapeSeq(w, parent.styles[i][1]);

        // Open styles that are new in this (not in parent)
        foreach (i; 0 .. count)
            if (styles[i] != Style.none && !parent.hasStyle(styles[i]))
                writeEscapeSeq(w, styles[i][0]);
    }

    /// Emit escape sequences for transition FROM this state back TO parent
    void emitCloseDiff(Writer)(ref Writer w, in StyleState parent) const
    {
        import sparkles.core_cli.text_writers : writeEscapeSeq;

        // Close styles that were added in this (not in parent)
        foreach_reverse (i; 0 .. count)
            if (styles[i] != Style.none && !parent.hasStyle(styles[i]))
                writeEscapeSeq(w, styles[i][1]);

        // Restore styles that were negated (in parent but not in this)
        foreach (i; 0 .. parent.count)
            if (parent.styles[i] != Style.none && !hasStyle(parent.styles[i]))
                writeEscapeSeq(w, parent.styles[i][0]);
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
    bool hasStyle(Style s) const @nogc nothrow
    {
        foreach (i; 0 .. count)
            if (styles[i] == s)
                return true;
        return false;
    }

    /// Add a style if not already present
    void addStyle(Style s) @nogc nothrow
    {
        if (s != Style.none && !hasStyle(s) && count < styles.length)
            styles[count++] = s;
    }

    /// Remove a style
    void removeStyle(Style s) @nogc nothrow
    {
        size_t writeIdx = 0;
        foreach (i; 0 .. count)
        {
            if (styles[i] != s)
            {
                if (writeIdx != i)
                    styles[writeIdx] = styles[i];
                writeIdx++;
            }
        }
        count = writeIdx;
    }

    /// Check if any styles are active
    bool empty() const @nogc nothrow
    {
        return count == 0;
    }
}

private enum ParseState
{
    normal,
    styleName,
    content
}

private struct ParserContext
{
    StyleState[16] styleStack;
    size_t stackDepth;
    ParseState state = ParseState.normal;
    size_t styleNameStart;
    size_t styleNameEnd;

    void pushStyle(StyleState s) @nogc nothrow
    {
        if (stackDepth < styleStack.length)
            styleStack[stackDepth++] = s;
    }

    void popStyle() @nogc nothrow
    {
        if (stackDepth > 0)
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

    bool hasStyles() const @nogc nothrow
    {
        return stackDepth > 0;
    }
}

/// Parses a literal segment and writes styled output
private void parseLiteral(Writer)(
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
                if (c == '{')
                {
                    // Check for escaped {{ -> literal {
                    if (i + 1 < literal.length && literal[i + 1] == '{')
                    {
                        put(w, '{');
                        i += 2;
                        continue;
                    }
                    ctx.state = ParseState.styleName;
                    ctx.styleNameStart = i + 1;
                    ctx.styleNameEnd = i + 1;
                }
                else if (c == '}')
                {
                    // Check for escaped }} -> literal }
                    if (i + 1 < literal.length && literal[i + 1] == '}')
                    {
                        put(w, '}');
                        i += 2;
                        continue;
                    }
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
                    // Only emit styles that are NEW (not inherited from parent)
                    ctx.topStyle.emitOpenDiff(w, ctx.parentStyle);
                    ctx.state = ParseState.content;
                }
                else if (c == '}')
                {
                    // Empty block like {} - treat as literal
                    put(w, '{');
                    put(w, '}');
                    ctx.state = ParseState.normal;
                }
                else
                {
                    // Accumulate style name
                    ctx.styleNameEnd = i + 1;
                }
                break;

            case ParseState.content:
                if (c == '{')
                {
                    // Check for escaped {{ -> literal {
                    if (i + 1 < literal.length && literal[i + 1] == '{')
                    {
                        put(w, '{');
                        i += 2;
                        continue;
                    }
                    // Nested block
                    ctx.state = ParseState.styleName;
                    ctx.styleNameStart = i + 1;
                    ctx.styleNameEnd = i + 1;
                }
                else if (c == '}')
                {
                    // Check for escaped }} -> literal }
                    if (i + 1 < literal.length && literal[i + 1] == '}')
                    {
                        put(w, '}');
                        i += 2;
                        continue;
                    }
                    // End of block - close only styles that were added in this block
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

private void applyStylePart(const(char)[] part, ref StyleState state)
{
    if (part.length == 0)
        return;

    bool negate = part[0] == '~';
    const(char)[] styleName = negate ? part[1 .. $] : part;

    Style s = styleFromName(styleName);
    if (s != Style.none)
    {
        if (negate)
            state.removeStyle(s);
        else
            state.addStyle(s);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Unit Tests
// ─────────────────────────────────────────────────────────────────────────────

@("styled.singleStyle")
unittest
{
    assert(styledText(i"{red error}") == "\x1b[31merror\x1b[39m");
}

@("styled.chainedStyles")
unittest
{
    // bold.red applies both styles
    auto result = styledText(i"{bold.red text}");
    // Should have bold open, red open, text, red close, bold close
    assert(result == "\x1b[1m\x1b[31mtext\x1b[39m\x1b[22m");
}

@("styled.withInterpolation")
unittest
{
    int val = 42;
    assert(styledText(i"Value: {green $(val)}") == "Value: \x1b[32m42\x1b[39m");
}

@("styled.nested")
unittest
{
    // Nested: bold applies to all, red only to inner
    auto result = styledText(i"{bold A {red B} C}");
    // A gets bold, B gets bold+red (inherited), C gets bold (red removed)
    // Expected: bold open, "A ", red open, "B", red close, " C", bold close
    assert(result == "\x1b[1mA \x1b[31mB\x1b[39m C\x1b[22m");
}

@("styled.negation")
unittest
{
    // ~red removes red, but bold remains
    auto result = styledText(i"{bold.red styled {~red unbold}}");
    // "styled" = bold+red, "unbold" = bold only (red removed)
    assert(result.length > 0); // Basic sanity check
    // Verify structure: should have reset codes
    import std.algorithm.searching : canFind;
    assert(result.canFind("\x1b[1m")); // bold on
    assert(result.canFind("\x1b[31m")); // red on
}

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
unittest
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
unittest
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
unittest
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
unittest
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
unittest
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

@("styled.escapedOpenBrace")
unittest
{
    // {{ produces literal {
    assert(styledText(i"Use {{style}} syntax") == "Use {style} syntax");
}

@("styled.escapedCloseBrace")
unittest
{
    // }} produces literal } inside styled block
    assert(styledText(i"{red hey}} still red}") == "\x1b[31mhey} still red\x1b[39m");
}

@("styled.escapedBracesInContent")
unittest
{
    // {{ and }} inside a styled block
    assert(styledText(i"{bold use {{braces}}}") == "\x1b[1muse {braces}\x1b[22m");
}

@("styled.noStyle")
unittest
{
    assert(styledText(i"plain text") == "plain text");
}

@("styled.emptyBlock")
unittest
{
    // Empty {} should be treated as literal
    assert(styledText(i"test {} here") == "test {} here");
}

@("styled.multipleBlocks")
unittest
{
    auto result = styledText(i"{red error} and {green success}");
    assert(result == "\x1b[31merror\x1b[39m and \x1b[32msuccess\x1b[39m");
}

@("styled.lazyWrapper")
unittest
{
    int val = 99;
    auto lazy_ = styled(i"Test: {blue $(val)}");
    assert(lazy_.toString == "Test: \x1b[34m99\x1b[39m");
}
