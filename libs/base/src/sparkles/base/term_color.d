/**
Terminal color-capability tiers and their pure classifier.

$(LREF ColorDepth) names how many colors a terminal can address; $(LREF
classifyColorDepth) picks the tier from `$COLORTERM`/`$TERM` values. The
classifier is deliberately pure and CTFE-able — it reads no environment
itself. Reading the environment (and the separate decision of whether to
emit color $(I at all) — tty checks, `$NO_COLOR`, `$CLICOLOR_FORCE`) belongs
to the caller's edge: `sparkles.core_cli.term_caps` folds this tier into its
`TermCaps` snapshot, and `sparkles.syntax.color.detectColorDepth` is a thin
env-reading wrapper for standalone use.
*/
module sparkles.base.term_color;

@safe pure nothrow @nogc:

/// Terminal color capability tiers, most capable last.
enum ColorDepth : ubyte
{
    none,      /// no color output (TERM=dumb, redirected without force, …)
    ansi16,    /// the classic 16 SGR colors
    ansi256,   /// the xterm 256-color palette
    trueColor, /// 24-bit `38;2;r;g;b` SGR sequences
}

/**
Pure classification of terminal color depth from `$COLORTERM` and `$TERM`
values (testable, CTFE-able): `COLORTERM=truecolor|24bit` or a `-direct`
`TERM` ⇒ `trueColor`; a `256color` `TERM` ⇒ `ansi256`; `TERM=dumb` ⇒ `none`;
anything else ⇒ `ansi16`.

Whether color should be emitted $(I at all) is a separate decision the caller
owns; this classifier only picks the tier.
*/
ColorDepth classifyColorDepth(scope const(char)[] colorterm, scope const(char)[] term)
{
    import std.algorithm.searching : canFind;

    if (term == "dumb")
        return ColorDepth.none;
    if (colorterm == "truecolor" || colorterm == "24bit")
        return ColorDepth.trueColor;
    if (term.canFind("direct"))
        return ColorDepth.trueColor;
    if (term.canFind("256color"))
        return ColorDepth.ansi256;
    return ColorDepth.ansi16;
}

///
@("term_color.classifyColorDepth")
unittest
{
    assert(classifyColorDepth("truecolor", "xterm-256color") == ColorDepth.trueColor);
    assert(classifyColorDepth("24bit", "xterm") == ColorDepth.trueColor);
    assert(classifyColorDepth("", "xterm-direct") == ColorDepth.trueColor);
    assert(classifyColorDepth("", "xterm-256color") == ColorDepth.ansi256);
    assert(classifyColorDepth("", "xterm") == ColorDepth.ansi16);
    assert(classifyColorDepth("", "dumb") == ColorDepth.none);
    assert(classifyColorDepth("truecolor", "dumb") == ColorDepth.none);
}

@("term_color.classifyColorDepth.ctfe")
unittest
{
    // The classifier is CTFE-able (no environment reads).
    static assert(classifyColorDepth("truecolor", "xterm") == ColorDepth.trueColor);
    static assert(classifyColorDepth("", "screen-256color") == ColorDepth.ansi256);
}
