/// The minimal text-attribute set the renderer honors, owned here so each
/// caller translates its own vocabulary into it (hue maps `sparkles:syntax`'s
/// `FontStyle`; apps/terminal maps `GhosttyStyle`). Colors are not here — the
/// caller resolves fg/bg and passes the raylib color to `drawText`.
module sparkles.raylib_text.style;

@safe:

/// A run's/cell's font attributes as a bitflag set.
struct TextStyle
{
    enum uint bold          = 1 << 0;
    enum uint italic        = 1 << 1;
    enum uint underline     = 1 << 2; /// any underline style collapses to one bit
    enum uint strikethrough = 1 << 3;

    uint bits;

    /// `true` iff every bit of `flag` is set.
    bool has(uint flag) const pure nothrow @nogc => (bits & flag) != 0;
}

///
@("raylib_text.TextStyle.flags")
pure nothrow @nogc
unittest
{
    const s = TextStyle(TextStyle.bold | TextStyle.underline);
    assert(s.has(TextStyle.bold) && s.has(TextStyle.underline));
    assert(!s.has(TextStyle.italic) && !s.has(TextStyle.strikethrough));
    assert(TextStyle(0).bits == 0 && !TextStyle(0).has(TextStyle.bold));
}
