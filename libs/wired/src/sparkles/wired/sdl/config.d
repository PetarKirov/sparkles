/** Compile-time SDL dialect configuration and normative named profiles. */
module sparkles.wired.sdl.config;

/// Syntax and scalar interpretation compatibility mode.
enum SdlSyntaxCompatibility : ubyte
{
    sparkles, /// The sparkles SDL grammar (SPEC §3).
    dub5efed360, /// DUB's bundled SDLang lexer at `5efed360`, quirks included.
}

/// Independently selectable SDL scalar families.
struct SdlScalarFeatures
{
    bool nulls; /// `null`.
    bool booleans; /// `true`/`false` and `on`/`off`.
    bool strings; /// Regular and raw strings.
    bool characters; /// Single-quoted character literals.
    bool integers; /// Unsuffixed 32-bit integers.
    bool longIntegers; /// `L`-suffixed 64-bit integers.
    bool floats; /// `F`-suffixed 32-bit floats.
    bool doubles; /// Unsuffixed or `D`-suffixed 64-bit floats.
    bool decimals; /// `BD`-suffixed extended decimals.
    bool binary; /// Bracketed Base64 binary literals.
    bool dates; /// `year/month/day` dates.
    bool dateTimes; /// Dates with a clock and no zone.
    bool zonedDateTimes; /// Dates with a clock and a zone.
    bool durations; /// Durations.
}

/// Independently selectable SDL lexical syntax.
struct SdlSyntaxFeatures
{
    bool rawStrings; /// Backtick raw strings.
    bool unicodeIdentifiers; /// Non-ASCII identifier characters.
    bool unicodeWhitespace; /// Non-ASCII horizontal whitespace.
    bool unicodeNewlines; /// U+2028 and U+2029 as newlines.
    bool hashComments; /// `#` line comments.
    bool slashComments; /// `//` line comments.
    bool dashComments; /// `--` line comments.
    bool blockComments; /// `/* */` block comments.
    bool continuations; /// Backslash line continuations.
    bool semicolonTerminators; /// `;` as a tag terminator.
    bool anonymousTags; /// Tags that start with a value and have no name.
}

/// Compile-time parser configuration. Boolean features opt in explicitly.
struct SdlParserConfig
{
    SdlScalarFeatures scalars; /// Scalar families the parser accepts.
    SdlSyntaxFeatures syntax; /// Lexical forms the parser accepts.
    SdlSyntaxCompatibility compatibility = SdlSyntaxCompatibility.sparkles; /// Whose grammar resolves the remaining choices.
    bool validateUtf8 = true; /// Validate the whole input before lexing (SPEC §11).
    uint maxDepth = 1024; /// Deepest child-block nesting; `0` permits root tags only.
}

private enum allScalars = SdlScalarFeatures(
    nulls: true,
    booleans: true,
    strings: true,
    characters: true,
    integers: true,
    longIntegers: true,
    floats: true,
    doubles: true,
    decimals: true,
    binary: true,
    dates: true,
    dateTimes: true,
    zonedDateTimes: true,
    durations: true,
);

private enum allSyntax = SdlSyntaxFeatures(
    rawStrings: true,
    unicodeIdentifiers: true,
    unicodeWhitespace: true,
    unicodeNewlines: true,
    hashComments: true,
    slashComments: true,
    dashComments: true,
    blockComments: true,
    continuations: true,
    semicolonTerminators: true,
    anonymousTags: true,
);

/// Complete deterministic Sparkles SDL dialect. This is the public default.
enum sdlFull = SdlParserConfig(
    scalars: allScalars,
    syntax: allSyntax,
);

/// Complete dialect compatible with DUB's pinned bundled SDLang lexer.
enum sdlDubCompat = SdlParserConfig(
    scalars: allScalars,
    syntax: allSyntax,
    compatibility: SdlSyntaxCompatibility.dub5efed360,
);

/// DUB recipe dialect with only string and boolean semantic scalar kernels.
enum sdlDubRecipe = SdlParserConfig(
    scalars: SdlScalarFeatures(booleans: true, strings: true),
    syntax: allSyntax,
    compatibility: SdlSyntaxCompatibility.dub5efed360,
);

@("sdl.config.namedProfiles")
@safe pure nothrow @nogc
unittest
{
    static assert(SdlParserConfig.init.scalars == SdlScalarFeatures.init);
    static assert(SdlParserConfig.init.syntax == SdlSyntaxFeatures.init);
    static assert(SdlParserConfig.init.validateUtf8);
    static assert(sdlFull.scalars.durations && sdlFull.syntax.blockComments);
    static assert(sdlDubCompat.compatibility == SdlSyntaxCompatibility.dub5efed360);
    static assert(sdlDubRecipe.scalars.strings && sdlDubRecipe.scalars.booleans);
    static assert(!sdlDubRecipe.scalars.integers && sdlDubRecipe.syntax.rawStrings);
}
