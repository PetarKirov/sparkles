module sparkles.core_cli.term_style;

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
    grey = [90, 39],

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
    bgGrey = [100, 49],

    bgBrightRed = [101, 49],
    bgBrightGreen = [102, 49],
    bgBrightYellow = [103, 49],
    bgBrightBlue = [104, 49],
    bgBrightMagenta = [105, 49],
    bgBrightCyan = [106, 49],
    bgBrightWhite = [107, 49],
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
