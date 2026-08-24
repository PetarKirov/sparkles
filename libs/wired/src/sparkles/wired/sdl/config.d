/** Compile-time SDL dialect configuration and normative named profiles. */
module sparkles.wired.sdl.config;

/// Syntax and scalar interpretation compatibility mode.
enum SdlSyntaxCompatibility : ubyte
{
    sparkles,
    dub5efed360,
}

/// Independently selectable SDL scalar families.
struct SdlScalarFeatures
{
    bool nulls;
    bool booleans;
    bool strings;
    bool characters;
    bool integers;
    bool longIntegers;
    bool floats;
    bool doubles;
    bool decimals;
    bool binary;
    bool dates;
    bool dateTimes;
    bool zonedDateTimes;
    bool durations;
}

/// Independently selectable SDL lexical syntax.
struct SdlSyntaxFeatures
{
    bool rawStrings;
    bool unicodeIdentifiers;
    bool unicodeWhitespace;
    bool unicodeNewlines;
    bool hashComments;
    bool slashComments;
    bool dashComments;
    bool blockComments;
    bool continuations;
    bool semicolonTerminators;
    bool anonymousTags;
}

/// Compile-time parser configuration. Boolean features opt in explicitly.
struct SdlParserConfig
{
    SdlScalarFeatures scalars;
    SdlSyntaxFeatures syntax;
    SdlSyntaxCompatibility compatibility = SdlSyntaxCompatibility.sparkles;
    bool validateUtf8 = true;
    uint maxDepth = 1024;
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
