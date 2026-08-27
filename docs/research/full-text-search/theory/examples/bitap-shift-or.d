#!/usr/bin/env dub
/+ dub.sdl:
    name "fts_bitap_shift_or"
    targetPath "build"
    dflags "-preview=in" "-preview=dip1000"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
 * Shift-or: an NFA simulated in the bits of one machine word.
 *
 * Backs the claim in `theory/bit-parallel.md` that bit-parallel matching is the
 * cheapest primitive in the catalog — the whole matcher state is a `size_t`, the
 * whole preprocessing is a 256-entry table, and case folding costs nothing at
 * match time because it is folded into the table instead.
 *
 * `std.regex`'s `kickstart.d` ships this same algorithm as a prefilter in front
 * of both of D's regex engines; this is the ~30-line core of it, written under
 * the attributes a `sparkles:fuzzy`-style implementation would need.
 */
module fts_bitap_shift_or;

import std.stdio : writefln, writeln;

@safe:

/// The needle's compiled form: one mask per byte, plus the accept bit.
///
/// `masks[b]` has a 0 bit at every needle position where byte `b` may occur, so
/// the update `state = (state << 1) | masks[b]` keeps a 0 exactly where a
/// prefix still matches. Needles are capped at the word size; longer ones need
/// a multi-word state, which is a fallback a real implementation must carry.
struct ShiftOr
{
    private size_t[256] masks = size_t.max;
    private size_t acceptBit;
    private size_t length_;

    /// Compiles `needle`, folding ASCII case when `foldCase` is set.
    ///
    /// Returns false when the needle is empty or longer than a machine word —
    /// an explicit outcome rather than a silent truncation.
    bool compile(scope const(char)[] needle, bool foldCase) pure nothrow @nogc
    {
        if (needle.length == 0 || needle.length > size_t.sizeof * 8)
            return false;

        masks[] = size_t.max;
        foreach (i, c; needle)
        {
            const bit = ~(cast(size_t) 1 << i);
            masks[cast(ubyte) c] &= bit;
            if (foldCase)
            {
                // Both cases clear the same position: the fold is paid once,
                // here, instead of once per comparison in the match loop.
                if (c >= 'a' && c <= 'z')
                    masks[cast(ubyte)(c - 32)] &= bit;
                else if (c >= 'A' && c <= 'Z')
                    masks[cast(ubyte)(c + 32)] &= bit;
            }
        }
        length_ = needle.length;
        acceptBit = cast(size_t) 1 << (needle.length - 1);
        return true;
    }

    /// The start offset of the first match, or `haystack.length` when there is
    /// none. Two instructions per input byte, no allocation, no branches on the
    /// needle.
    size_t find(scope const(char)[] haystack) const pure nothrow @nogc
    {
        size_t state = size_t.max;
        foreach (i, c; haystack)
        {
            state = (state << 1) | masks[cast(ubyte) c];
            if ((state & acceptBit) == 0)
                return i + 1 - length_;
        }
        return haystack.length;
    }
}

void main()
{
    static struct Case
    {
        string needle;
        string haystack;
        bool fold;
        size_t want;
    }

    // `want == haystack.length` means "no match".
    static immutable Case[] cases = [
        Case("fn", "pub fn parse() {}", false, 4),
        Case("Fn", "pub fn parse() {}", false, 17),
        Case("Fn", "pub fn parse() {}", true, 4),
        Case("parse", "pub fn parse() {}", false, 7),
        Case("zzz", "pub fn parse() {}", false, 17),
        Case("a", "a", false, 0),
        Case("bc", "abcabc", false, 1),
    ];

    size_t failures;
    foreach (c; cases)
    {
        ShiftOr so;
        if (!so.compile(c.needle, c.fold))
        {
            writefln("FAIL compile rejected %s", c.needle);
            ++failures;
            continue;
        }
        const got = so.find(c.haystack);
        const ok = got == c.want;
        writefln("%-6s %-20s fold=%-5s -> %s%s", c.needle, c.haystack,
            c.fold, got == c.haystack.length ? "no match" : "match at " ~ digits(got),
            ok ? "" : "   EXPECTED " ~ digits(c.want));
        if (!ok)
            ++failures;
    }

    // The capacity boundary is an outcome, not a truncation.
    ShiftOr tooLong;
    const rejected = !tooLong.compile(new char[size_t.sizeof * 8 + 1], false);
    writeln(rejected
        ? "\nover-long needle rejected (the multi-word fallback's trigger)"
        : "\nFAIL over-long needle accepted");
    if (!rejected)
        ++failures;

    assert(failures == 0, "shift-or disagreed with the expected offsets");
    writeln("all cases agree");
}

/// Tiny `@nogc`-shaped integer rendering, so the demo does not lean on `format`.
private string digits(size_t n) pure nothrow
{
    if (n == 0)
        return "0";
    char[20] buf;
    size_t i = buf.length;
    while (n)
    {
        buf[--i] = cast(char)('0' + n % 10);
        n /= 10;
    }
    return buf[i .. $].idup;
}
