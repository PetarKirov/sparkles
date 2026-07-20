module sparkles.base.term_style;

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
/// colour with 39; every background colour with 49), so a close code identifies
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
    foreground = Style.red[1],           /// 39 — every foreground colour
    background = Style.bgRed[1],          /// 49 — every background colour
}

///
@("term_style.openClose.groupReset")
@safe pure nothrow @nogc unittest
{
    assert(Style.bold.openCode == 1 && Style.bold.closeCode == 22);
    assert(Style.red.openCode == 31 && Style.red.closeCode == 39);
    // bold and dim share the intensity reset; every colour shares fg/bg resets.
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
