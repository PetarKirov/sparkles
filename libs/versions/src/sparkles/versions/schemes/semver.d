/**
`SemVer` — strict Semantic Versioning 2.0.0.

The reference scheme. It declares every optional capability: an `orderKey`
that packs `major:minor:patch:stable` into a `ulong`, the SemVer triple in
`components` (so it gets caret/tilde), `isPrerelease`, and build metadata.

This module also hosts the SemVer identifier grammar
($(LREF compareSemVerPrerelease), $(LREF validateIdentifierList),
$(LREF IdentifierKind)) `package`-scoped, so the other SemVer-shaped schemes
(`Dmd`, …) reuse it without re-importing the engine.

See `docs/specs/versions/SPEC.md` §3 and `PRESETS.md` §3.1.
*/
module sparkles.versions.schemes.semver;

import sparkles.versions.parsing : parseOk, parseErr;

import sparkles.versions.parsing :
    NoGcHook, ParseError, ParseErrorCode, ParseExpected, ParseMode;
import sparkles.versions.ranges : Ranges;
import sparkles.versions.traits :
    compareComponents, hasComponents, hasOrderKey, hasSemVerComponents,
    hasBuildMetadata, isVersion, isVersionScheme, supportsPrerelease;

@safe:

// ---------------------------------------------------------------------------
// Field bit widths (shared with the SemVer-shaped schemes)
// ---------------------------------------------------------------------------

/// Bit width of the `major` field in the packed `orderKey` (max 32767).
package enum int majorBits = 15;
/// Bit width of the `minor` field (max 16,777,215).
package enum int minorBits = 24;
/// Bit width of the `patch` field (max 16,777,215).
package enum int patchBits = 24;

/// Maximum representable value of an `n`-bit unsigned field.
package enum ulong fieldMax(int n) = (n >= 64) ? ulong.max : ((1UL << n) - 1);

// ---------------------------------------------------------------------------
// SemVer
// ---------------------------------------------------------------------------

/**
A strict SemVer 2.0.0 version: `major.minor.patch` with optional
`-prerelease` and `+build` metadata.

Ordering follows SemVer §11: compare `major`, then `minor`, then `patch`
numerically; a version with a prerelease has lower precedence than the same
triple without one; prerelease identifiers compare per §11.4; build metadata
is ignored in ordering (§10).
*/
struct SemVer
{
    /// Numeric core. `major ≤ 32767`, `minor`/`patch ≤ 16,777,215`.
    uint major, minor, patch;

    /// Prerelease identifier list without the leading `-` (empty when the
    /// version is a stable release). Compared per SemVer §11.4.
    string prerelease;

    /// Build metadata without the leading `+`. Ignored in ordering (§10).
    string build;

    // ----- scheme handle -----

    /// This struct is its own version type.
    alias Version = SemVer;

    /// The range type for this scheme.
    alias Range = Ranges!SemVer;

    /// pURL type string.
    enum string purlType = "semver";

    /// Named numeric components, most-significant-first.
    enum string[] components = ["major", "minor", "patch"];

    // ----- required surface -----

    /// SemVer §11 three-way order.
    int opCmp(in SemVer other) const @safe pure nothrow @nogc
    {
        if (const c = compareComponents(this, other))
            return c;
        return compareSemVerPrerelease(prerelease, other.prerelease);
    }

    /// Equality consistent with $(LREF opCmp). Build metadata is ignored.
    bool opEquals(in SemVer other) const @safe pure nothrow @nogc
        => opCmp(other) == 0;

    /// Hash consistent with $(LREF opEquals).
    size_t toHash() const @trusted pure nothrow @nogc
    {
        import core.internal.hash : hashOf;
        auto h = hashOf(orderKey);
        return hashOf(prerelease, h);
    }

    /// Writes `major.minor.patch[-prerelease][+build]`.
    void toString(W)(ref W w) const
    {
        import sparkles.core_cli.text.writers : writeInteger;
        import std.range.primitives : put;

        writeInteger(w, major);
        put(w, '.');
        writeInteger(w, minor);
        put(w, '.');
        writeInteger(w, patch);
        if (prerelease.length)
        {
            put(w, '-');
            put(w, prerelease);
        }
        if (build.length)
        {
            put(w, '+');
            put(w, build);
        }
    }

    // ----- optional capabilities -----

    /// Monotone `ulong` order key: `major:minor:patch:stableFlag`, the
    /// stable flag (set when there is no prerelease) at the LSB. Equal keys
    /// fall through to $(LREF opCmp) for the prerelease-identifier tiebreak.
    ulong orderKey() const @safe pure nothrow @nogc
    {
        const stable = prerelease.length == 0 ? 1UL : 0UL;
        return (cast(ulong) major << (minorBits + patchBits + 1))
            | (cast(ulong) minor << (patchBits + 1))
            | (cast(ulong) patch << 1)
            | stable;
    }

    /// True when this version carries a prerelease tag.
    bool isPrerelease() const @safe pure nothrow @nogc
        => prerelease.length != 0;

    // ----- parsing -----

    /// Parses strict SemVer 2.0.0 syntax.
    static ParseExpected!SemVer parse(string s) @safe pure nothrow @nogc
        => parseSemVerShaped!SemVer(s, ParseMode.strict, noWidths);

    /// Parses with the loose compatibility forms: a leading `v`, leading
    /// `=`, surrounding spaces, partial versions (zero-filled), and leading
    /// zeroes on numeric components.
    static ParseExpected!SemVer parseLoose(string s) @safe pure nothrow @nogc
        => parseSemVerShaped!SemVer(s, ParseMode.loose, noWidths);

    /// Native node-semver range grammar (caret/tilde, x-ranges, hyphen
    /// ranges, `||` unions, AND-by-space, and the `=`/`<`/`<=`/`>`/`>=`
    /// comparators). Desugars to a $(LREF Range) via $(REF parseNpmRange,
    /// sparkles,versions,schemes,semver).
    static ParseExpected!Range parseNativeRange(string s) @safe
        => parseNpmRange!SemVer(s);
}

// ---------------------------------------------------------------------------
// Generic node-semver range parser (shared by every SemVer-shaped scheme)
// ---------------------------------------------------------------------------

/**
Parses an npm/node-semver-style range expression into a `Ranges!S` for any
SemVer-shaped scheme `S` (`hasSemVerComponents!S`, i.e. a `components` list
beginning `["major","minor","patch"]`).

The grammar (a practical subset of node-semver, PRESETS §3.1):

$(UL
    $(LI `||` separates alternatives — their union.)
    $(LI Whitespace inside one alternative is AND (intersection):
        `>=1.2.0 <2.0.0`.)
    $(LI A hyphen range `a - b` is the inclusive interval `[a, b]`.)
    $(LI Comparators `=` `<` `<=` `>` `>=` prefix a (possibly partial)
        version.)
    $(LI Caret `^` and tilde `~` desugar via $(REF caret,
        sparkles,versions,operations) / $(REF tilde,
        sparkles,versions,operations) — only available when
        `hasSemVerComponents!S`, which the template constraint requires.)
    $(LI `x` / `X` / `*` wildcards and missing trailing components form
        x-ranges: `1.2.x` → `[1.2.0, 1.3.0)`, `1` → `[1.0.0, 2.0.0)`,
        `*` → the full set.)
)

The caret/tilde operators are gated by the `hasSemVerComponents!S`
constraint, so a calendar scheme (`["year","month","day"]`) can route its
`parseNativeRange` here for the comparator/x-range forms while a `^`/`~`
token is rejected as `unexpectedCharacter`.
*/
package ParseExpected!(Ranges!S) parseNpmRange(S)(string input) @safe
if (hasComponents!S && S.components.length >= 3)
{
    import sparkles.core_cli.text.readers : skipSpaces;

    alias R = Ranges!S;

    // Split on `||` into alternatives; the whole range is their union. An
    // empty input (or all-blank) is the full set, matching node-semver.
    R acc = R.empty();
    bool any = false;

    scope const(char)[] s = input;
    size_t base = 0; // byte offset of `s[0]` within `input`, for errors

    void advance(size_t n) @safe { s = s[n .. $]; base += n; }

    while (true)
    {
        // Find the next `||` (or end) — that bounds one alternative.
        size_t cut = 0;
        while (cut + 1 < s.length && !(s[cut] == '|' && s[cut + 1] == '|'))
            cut++;
        const bool atEnd = !(cut + 1 < s.length);
        const size_t altLen = atEnd ? s.length : cut;

        auto alt = parseNpmAlternative!S(s[0 .. altLen], base);
        if (!alt.hasValue)
            return parseErr!R(alt.error);

        acc = any ? acc.union_(alt.value) : alt.value;
        any = true;

        if (atEnd)
            break;
        advance(altLen + 2); // skip the alternative and the `||`
    }

    if (!any)
        return parseOk(R.full());
    return parseOk(acc);
}

/// Parses one `||`-free alternative: whitespace-separated comparators
/// AND-ed together, with hyphen-range desugaring. `offset` is the byte
/// offset of `text` within the original input (for error reporting).
private ParseExpected!(Ranges!S) parseNpmAlternative(S)(
    scope const(char)[] text, size_t offset,
) @safe
if (hasComponents!S && S.components.length >= 3)
{
    import sparkles.core_cli.text.readers : skipSpaces;

    alias R = Ranges!S;

    scope const(char)[] s = text;
    size_t base = offset;

    void advance(size_t n) @safe { s = s[n .. $]; base += n; }
    void skipWs() @safe { advance(skipSpacesCount(s)); }

    skipWs();
    if (s.length == 0)
        return parseOk(R.full()); // blank alternative ⇒ everything

    // Gather the space-separated tokens of this alternative so a hyphen
    // range `a - b` (three tokens) can be recognised. Tokens are slices of
    // `s`; their offsets are tracked for errors.
    R result = R.full();
    bool first = true;

    while (s.length)
    {
        // Read one token (up to the next run of spaces).
        const tokOff = base;
        size_t i = 0;
        while (i < s.length && s[i] != ' ' && s[i] != '\t')
            i++;
        scope const(char)[] tok = s[0 .. i];
        advance(i);
        skipWs();

        // Hyphen range: `tok - upper`. A bare `-` token joins two versions.
        if (tok == "-")
            return parseErr!R(
                ParseError(ParseErrorCode.unexpectedCharacter, tokOff));

        // Look ahead for an infix `-` (next token is exactly `-`).
        if (s.length && s[0] == '-'
            && (s.length == 1 || s[1] == ' ' || s[1] == '\t'))
        {
            advance(1);          // consume `-`
            skipWs();
            // Read the upper token.
            const upOff = base;
            size_t j = 0;
            while (j < s.length && s[j] != ' ' && s[j] != '\t')
                j++;
            scope const(char)[] upTok = s[0 .. j];
            advance(j);
            skipWs();

            auto hr = hyphenRange!S(tok, tokOff, upTok, upOff);
            if (!hr.hasValue)
                return parseErr!R(hr.error);
            result = first ? hr.value : result.intersection(hr.value);
            first = false;
            continue;
        }

        auto cmp = parseComparator!S(tok, tokOff);
        if (!cmp.hasValue)
            return parseErr!R(cmp.error);
        result = first ? cmp.value : result.intersection(cmp.value);
        first = false;
    }

    return parseOk(result);
}

/// `skipSpaces` count without mutating a `ref` cursor in the caller's frame
/// (so the alternative parser keeps its own `base` offset in sync).
private size_t skipSpacesCount(scope const(char)[] s) @safe pure nothrow @nogc
{
    size_t i = 0;
    while (i < s.length && (s[i] == ' ' || s[i] == '\t'))
        i++;
    return i;
}

/// A parsed partial version: the SemVer triple, how many components were
/// explicitly given (a wildcard or a missing tail caps this), and the
/// optional prerelease text.
private struct PartialVersion
{
    uint[3] core;
    size_t specified;     // 0..3 concrete leading components
    string prerelease;    // without the leading '-'
    bool hasPrerelease;
}

/// Parses a partial/wildcard version token (`1.2.3`, `1.2.x`, `1`, `*`,
/// `1.2.3-rc.1`) into a $(LREF PartialVersion). `offset` is the byte offset
/// of `text` for error reporting.
private ParseExpected!PartialVersion parsePartial(
    scope const(char)[] text, size_t offset,
) @safe
{
    import std.ascii : isDigit;

    PartialVersion pv;
    scope const(char)[] s = text;
    size_t base = offset;

    void advance(size_t n) @safe { s = s[n .. $]; base += n; }

    // Optional leading `v`/`=` (loose-friendly).
    if (s.length && (s[0] == 'v' || s[0] == 'V'))
        advance(1);

    size_t comp = 0;
    bool wildcardSeen = false;
    while (comp < 3)
    {
        if (s.length == 0)
            break;
        if (s[0] == 'x' || s[0] == 'X' || s[0] == '*')
        {
            advance(1);
            wildcardSeen = true;
            // A wildcard caps the specified count at the current component.
            if (s.length && s[0] == '.')
                advance(1);
            break;
        }
        if (!s[0].isDigit)
            break;

        uint value = 0;
        size_t len = 0;
        while (s.length && s[0].isDigit)
        {
            const d = cast(uint)(s[0] - '0');
            if (value > (uint.max - d) / 10)
                return parseErr!PartialVersion(
                    ParseError(ParseErrorCode.numericOverflow, base));
            value = value * 10 + d;
            advance(1);
            len++;
        }
        pv.core[comp] = value;
        comp++;

        if (s.length && s[0] == '.')
        {
            advance(1);
            continue;
        }
        break;
    }

    pv.specified = wildcardSeen ? comp : comp;

    // Prerelease tail (only meaningful when all three are concrete).
    if (s.length && s[0] == '-')
    {
        advance(1);
        size_t k = 0;
        while (k < s.length && s[k] != '+')
            k++;
        pv.prerelease = cast(string) s[0 .. k].idup;
        pv.hasPrerelease = pv.prerelease.length != 0;
        advance(s.length); // consume the rest (build metadata ignored here)
    }

    if (s.length != 0)
        return parseErr!PartialVersion(
            ParseError(ParseErrorCode.unexpectedCharacter, base));

    return parseOk(pv);
}

/// Builds a concrete `S` version from a SemVer triple plus optional
/// prerelease.
///
/// The numeric core is assigned structurally to the first three
/// `S.components` (so per-component print widths — Dmd's 3-digit minor,
/// CalVer's 2-digit month — never trip a parser, since no string is
/// re-parsed) with bounds-checking against the scheme's field maxes. A
/// prerelease is only meaningful for schemes carrying a `string prerelease`
/// member; for a scheme whose prerelease is encoded differently
/// (`DmdCompact`), the `-tag` is routed through `S.parse` of the canonical
/// form so its bespoke encoder runs. Returns a `numericOverflow` error at
/// `offset` when a component exceeds the scheme's field width.
private ParseExpected!S mkVersion(S)(
    in uint[3] core, string prerelease, size_t offset,
) @safe
if (hasComponents!S && S.components.length >= 3)
{
    import sparkles.versions.traits : componentAt;

    // A non-string prerelease encoding (DmdCompact) needs its own parser to
    // map `-beta.N` / `-rc.N` onto the packed phase; reconstruct and parse.
    static if (!__traits(hasMember, S, "prerelease"))
    {
        if (prerelease.length)
        {
            import std.array : appender;
            import sparkles.core_cli.text.writers : writeInteger;

            auto w = appender!string;
            writeInteger(w, core[0]);
            w.put('.');
            writeInteger(w, core[1]);
            w.put('.');
            writeInteger(w, core[2]);
            w.put('-');
            w.put(prerelease);
            auto r = S.parse(w[]);
            if (!r.hasValue)
                return parseErr!S(ParseError(r.error.code, offset));
            return parseOk(r.value);
        }
    }

    S result;
    static foreach (i; 0 .. 3)
    {{
        alias FieldT = typeof(__traits(getMember, result, S.components[i]));
        // Bounds-check against the scheme's natural field width.
        if (core[i] > cast(uint) FieldT.max)
            return parseErr!S(ParseError(ParseErrorCode.numericOverflow, offset));
        __traits(getMember, result, S.components[i]) = cast(FieldT) core[i];
    }}

    static if (__traits(hasMember, S, "prerelease"))
        if (prerelease.length)
            __traits(getMember, result, "prerelease") = prerelease;

    return parseOk(result);
}

/// Desugars a single comparator token (`^1.2.0`, `~1.2`, `>=1.2.0`, `1.2.x`,
/// `*`, …) into a `Ranges!S`.
private ParseExpected!(Ranges!S) parseComparator(S)(
    scope const(char)[] tok, size_t offset,
) @safe
if (hasComponents!S && S.components.length >= 3)
{
    import sparkles.versions.operations : caret, tilde;

    alias R = Ranges!S;

    if (tok.length == 0)
        return parseOk(R.full());

    // Operator prefix.
    enum Op { eq, lt, lte, gt, gte, caretOp, tildeOp }
    Op op = Op.eq;
    size_t skip = 0;

    switch (tok[0])
    {
        case '^':
            op = Op.caretOp;
            skip = 1;
            break;
        case '~':
            op = Op.tildeOp;
            skip = 1;
            break;
        case '=':
            op = Op.eq;
            skip = 1;
            break;
        case '<':
            if (tok.length > 1 && tok[1] == '=')
            {
                op = Op.lte;
                skip = 2;
            }
            else
            {
                op = Op.lt;
                skip = 1;
            }
            break;
        case '>':
            if (tok.length > 1 && tok[1] == '=')
            {
                op = Op.gte;
                skip = 2;
            }
            else
            {
                op = Op.gt;
                skip = 1;
            }
            break;
        default:
            op = Op.eq;
            skip = 0;
            break;
    }

    // Caret/tilde need the SemVer triple; reject on a non-SemVer scheme.
    static if (!hasSemVerComponents!S)
    {
        if (op == Op.caretOp || op == Op.tildeOp)
            return parseErr!R(
                ParseError(ParseErrorCode.unexpectedCharacter, offset));
    }

    auto pp = parsePartial(tok[skip .. $], offset + skip);
    if (!pp.hasValue)
        return parseErr!R(pp.error);
    const pv = pp.value;

    // A bare `*` / `x` (zero specified components, no operator) is the full
    // set; with a comparator it is an x-range over the missing tail.
    static if (hasSemVerComponents!S)
    {
        if (op == Op.caretOp || op == Op.tildeOp)
        {
            auto lo = mkVersion!S(pv.core,
                pv.hasPrerelease ? pv.prerelease : null, offset);
            if (!lo.hasValue)
                return parseErr!R(lo.error);
            return parseOk(op == Op.caretOp ? caret(lo.value) : tilde(lo.value));
        }
    }

    // Equality / x-range: zero specified components → full set.
    if (op == Op.eq && pv.specified == 0)
        return parseOk(R.full());

    // Build the named version at the specified prefix (missing tail zeroed).
    auto vr = mkVersion!S(pv.core,
        pv.hasPrerelease ? pv.prerelease : null, offset);
    if (!vr.hasValue)
        return parseErr!R(vr.error);
    const v = vr.value;

    final switch (op)
    {
        case Op.gt:
            return parseOk(R.strictlyHigherThan(v));
        case Op.gte:
            return parseOk(R.higherThan(v));
        case Op.lt:
            return parseOk(R.strictlyLowerThan(v));
        case Op.lte:
            return parseOk(R.lowerThan(v));
        case Op.eq:
            // Fully specified ⇒ a singleton; a partial prefix ⇒ an x-range
            // `[prefix.0, bumped)`.
            if (pv.specified >= 3)
                return parseOk(R.singleton(v));
            return xRange!S(pv, offset);
        case Op.caretOp:
        case Op.tildeOp:
            // Handled above for SemVer schemes; unreachable otherwise.
            return parseErr!R(
                ParseError(ParseErrorCode.unexpectedCharacter, offset));
    }
}

/// Desugars an x-range partial (`1.2.x`, `1`) into `[lower, upper)`, where
/// `upper` bumps the last specified component. `specified == 0` is the full
/// set (a bare `*`).
private ParseExpected!(Ranges!S) xRange(S)(
    in PartialVersion pv, size_t offset,
) @safe
if (hasComponents!S && S.components.length >= 3)
{
    alias R = Ranges!S;

    if (pv.specified == 0)
        return parseOk(R.full());

    auto lo = mkVersion!S(pv.core, null, offset);
    if (!lo.hasValue)
        return parseErr!R(lo.error);

    // Bump the (specified-1)-th component, zeroing the lower ones.
    uint[3] hi = pv.core;
    const idx = pv.specified - 1;
    hi[idx] = hi[idx] + 1;
    foreach (k; idx + 1 .. 3)
        hi[k] = 0;

    auto up = mkVersion!S(hi, null, offset);
    if (!up.hasValue)
        return parseErr!R(up.error);

    return parseOk(R.between(lo.value, up.value));
}

/// Desugars a hyphen range `lower - upper` into the inclusive interval
/// `[lower, upper]`. A partial upper bound widens to the end of its tail
/// (`1.2.0 - 1.5` ⇒ `< 1.6.0`), matching node-semver.
private ParseExpected!(Ranges!S) hyphenRange(S)(
    scope const(char)[] loTok, size_t loOff,
    scope const(char)[] upTok, size_t upOff,
) @safe
if (hasComponents!S && S.components.length >= 3)
{
    alias R = Ranges!S;

    auto lp = parsePartial(loTok, loOff);
    if (!lp.hasValue)
        return parseErr!R(lp.error);
    auto up = parsePartial(upTok, upOff);
    if (!up.hasValue)
        return parseErr!R(up.error);

    const lpv = lp.value;
    const upv = up.value;

    auto lo = mkVersion!S(lpv.core,
        lpv.hasPrerelease ? lpv.prerelease : null, loOff);
    if (!lo.hasValue)
        return parseErr!R(lo.error);

    // A fully-specified upper bound is inclusive; a partial one becomes an
    // exclusive bump of its last specified component.
    if (upv.specified >= 3)
    {
        auto hi = mkVersion!S(upv.core,
            upv.hasPrerelease ? upv.prerelease : null, upOff);
        if (!hi.hasValue)
            return parseErr!R(hi.error);
        // [lo, hi] = [lo, hi') with hi' the successor — model inclusive via
        // higherThan ∩ lowerThan.
        return parseOk(
            R.higherThan(lo.value).intersection(R.lowerThan(hi.value)));
    }

    uint[3] hiCore = upv.core;
    const idx = upv.specified == 0 ? 0 : upv.specified - 1;
    if (upv.specified == 0)
        return parseOk(R.higherThan(lo.value)); // `a - *`
    hiCore[idx] = hiCore[idx] + 1;
    foreach (k; idx + 1 .. 3)
        hiCore[k] = 0;
    auto hi = mkVersion!S(hiCore, null, upOff);
    if (!hi.hasValue)
        return parseErr!R(hi.error);
    return parseOk(R.between(lo.value, hi.value));
}

// ---------------------------------------------------------------------------
// SemVer-shaped parsing (shared by SemVer, Dmd, Tiny, CalVer*, Vim)
// ---------------------------------------------------------------------------

/// Per-component minimum print width: `0` = unpadded/unconstrained,
/// `n > 0` = the strict parser requires at least `n` digits (Dmd's 3-digit
/// minor, Vim's 4-digit patch, CalVer's 2-digit month/day).
package alias ComponentWidths = const(int)[];

/// All-unpadded widths for a 3-component SemVer-shaped scheme.
package enum ComponentWidths noWidths = [0, 0, 0];

/**
Generic SemVer-shaped parser, used by every scheme that follows the
`major.minor.patch[-prerelease][+build]` shape. The `widths` array gives the
strict minimum digit width per component (in `S.components` order); `0` means
unpadded with the strict leading-zero rule. Prerelease/build slots are only
populated when `S` declares the matching `prerelease`/`build` members.
*/
package ParseExpected!S parseSemVerShaped(S)(
    string input, ParseMode mode, ComponentWidths widths,
) @safe pure nothrow @nogc
{
    enum ncomp = S.components.length;
    assert(widths.length == ncomp);

    S result;
    scope const(char)[] s = input;
    size_t consumed = 0; // byte offset within `input` for error reporting

    // Helper closures advance `s` and `consumed` together.
    void advance(size_t n) @safe pure nothrow @nogc
    {
        s = s[n .. $];
        consumed += n;
    }

    if (mode == ParseMode.loose)
    {
        while (s.length && (s[0] == ' ' || s[0] == '\t'))
            advance(1);
        if (s.length && (s[0] == 'v' || s[0] == 'V' || s[0] == '='))
        {
            advance(1);
            while (s.length && (s[0] == ' ' || s[0] == '\t'))
                advance(1);
        }
    }

    if (s.length == 0)
        return parseErr!(S)(
            ParseError(ParseErrorCode.emptyInput, consumed));

    bool stop = false;
    static foreach (idx, name; S.components)
    {{
        if (!stop)
        {
            if (idx > 0)
            {
                if (s.length == 0 || s[0] != '.')
                {
                    if (mode == ParseMode.strict)
                        return parseErr!(S)(ParseError(
                            s.length == 0
                                ? ParseErrorCode.unexpectedEnd
                                : ParseErrorCode.unexpectedCharacter,
                            consumed));
                    stop = true;
                }
                else
                    advance(1);
            }

            if (!stop)
            {
                ulong value;
                ParseError e = readComponent(
                    s, consumed, mode, widths[idx],
                    componentFieldMax!(S, name, idx), value);
                // `e.offset == size_t.max` is the "no error" sentinel.
                if (e.offset != size_t.max)
                    return parseErr!(S)(e);
                __traits(getMember, result, name) =
                    cast(typeof(__traits(getMember, result, name))) value;
            }
        }
    }}

    // Prerelease / build slots, only when the scheme declares them.
    static if (__traits(hasMember, S, "prerelease"))
    {
        if (s.length && s[0] == '-')
        {
            advance(1);
            const start = consumed;
            // Prerelease runs up to a `+` (build separator) or end. Recover
            // the immutable slice from `input` directly (no `@system` cast):
            // `readSlot` advanced `consumed` past the slot.
            readSlot(s, consumed, '+');
            string seg = input[start .. consumed];
            auto check = validateIdentifierList(
                seg, start, IdentifierKind.prerelease);
            if (check.hasError)
                return parseErr!(S)(check.error);
            __traits(getMember, result, "prerelease") = seg;
        }
    }
    static if (__traits(hasMember, S, "build"))
    {
        if (s.length && s[0] == '+')
        {
            advance(1);
            const start = consumed;
            readSlot(s, consumed, '\0');
            string seg = input[start .. consumed];
            auto check = validateIdentifierList(
                seg, start, IdentifierKind.build);
            if (check.hasError)
                return parseErr!(S)(check.error);
            __traits(getMember, result, "build") = seg;
        }
    }

    if (mode == ParseMode.loose)
        while (s.length && (s[0] == ' ' || s[0] == '\t'))
            advance(1);

    if (s.length != 0)
        return parseErr!(S)(
            ParseError(ParseErrorCode.unexpectedCharacter, consumed));

    return parseOk(result);
}

/// Max value of the `idx`-th component's backing field. A scheme may declare
/// an `enum ulong[] componentMaxes` to override the bounds (e.g. `Tiny`'s
/// 16/8/8-bit split or the calendar schemes); otherwise the SemVer triple
/// uses the SemVer bit widths and any other field its natural type max.
private template componentFieldMax(S, string name, size_t idx)
{
    static if (is(typeof(S.componentMaxes) : const(ulong)[]))
        enum componentFieldMax = S.componentMaxes[idx];
    else static if (name == "major")
        enum componentFieldMax = fieldMax!majorBits;
    else static if (name == "minor")
        enum componentFieldMax = fieldMax!minorBits;
    else static if (name == "patch")
        enum componentFieldMax = fieldMax!patchBits;
    else
        enum componentFieldMax =
            cast(ulong) typeof(__traits(getMember, S.init, name)).max;
}

/**
Reads one numeric component, advancing the cursor. Returns a $(LREF ParseError)
whose `offset == size_t.max` signals success (so the caller can distinguish a
genuine `emptyInput`-coded error at offset 0 from "no error").
*/
private ParseError readComponent(
    ref scope const(char)[] s, ref size_t consumed, ParseMode mode,
    int width, ulong maxValue, out ulong value,
) @safe pure nothrow @nogc
{
    import std.ascii : isDigit;

    enum ParseError success = ParseError(ParseErrorCode.init, size_t.max);
    const start = consumed;

    if (s.length == 0)
        return ParseError(ParseErrorCode.unexpectedEnd, consumed);
    if (!s[0].isDigit)
        return ParseError(ParseErrorCode.unexpectedCharacter, consumed);

    const firstDigit = s[0];
    value = 0;
    size_t len = 0;
    while (s.length && s[0].isDigit)
    {
        const digit = cast(ulong)(s[0] - '0');
        if (value > (ulong.max - digit) / 10)
            return ParseError(ParseErrorCode.numericOverflow, consumed);
        value = value * 10 + digit;
        s = s[1 .. $];
        consumed++;
        len++;
    }

    if (value > maxValue)
        return ParseError(ParseErrorCode.numericOverflow, start);

    if (width > 0)
    {
        // Width-constrained: at least `width` digits; leading zeroes are
        // part of the canonical format.
        if (len < cast(size_t) width)
            return ParseError(ParseErrorCode.widthMismatch, start);
    }
    else if (mode == ParseMode.strict && len > 1 && firstDigit == '0')
    {
        // Strict mode rejects leading zeroes on unpadded components.
        return ParseError(ParseErrorCode.leadingZero, start);
    }

    return success;
}

/// Reads a slot (prerelease/build) segment up to `terminator` (or end when
/// `terminator == '\0'`), advancing the cursor.
// Advances `s`/`consumed` past the next slot (up to `terminator` or end).
// Callers recover the slot text as an immutable slice of the original input
// via the recorded `consumed` offsets, so no slice need be returned.
private void readSlot(
    ref scope const(char)[] s, ref size_t consumed, char terminator,
) @safe pure nothrow @nogc
{
    size_t i = 0;
    while (i < s.length && !(terminator != '\0' && s[i] == terminator))
        i++;
    s = s[i .. $];
    consumed += i;
}

// ---------------------------------------------------------------------------
// SemVer identifier grammar (package-scoped, reused by Dmd, …)
// ---------------------------------------------------------------------------

/// Discriminates SemVer prerelease (numeric identifiers must not have
/// leading zeros) from build metadata (no such rule).
package enum IdentifierKind { prerelease, build }

/**
Validates a dot-separated identifier list per SemVer 2.0.0 §9 (prerelease)
or §10 (build metadata). `listOffset` is the byte offset of `list` within
the original input; reported errors carry the offset of the failing
character.
*/
package ParseExpected!void validateIdentifierList(
    in string list, size_t listOffset, IdentifierKind kind,
) @safe pure nothrow @nogc
{
    import std.algorithm.searching : all;
    import std.ascii : isAlphaNum, isDigit;
    import std.utf : byCodeUnit;

    if (list.length == 0)
        return parseErr!(void)(
            ParseError(ParseErrorCode.invalidIdentifier, listOffset));

    size_t segStart;
    while (true)
    {
        size_t segEnd = segStart;
        while (segEnd < list.length && list[segEnd] != '.')
            segEnd++;

        const seg = list[segStart .. segEnd];
        const segOff = listOffset + segStart;

        if (seg.length == 0)
            return parseErr!(void)(
                ParseError(ParseErrorCode.invalidIdentifier, segOff));

        foreach (idx, c; seg)
        {
            if (!(c.isAlphaNum || c == '-'))
                return parseErr!(void)(
                    ParseError(ParseErrorCode.invalidIdentifier, segOff + idx));
        }

        if (kind == IdentifierKind.prerelease
            && seg.length > 1
            && seg[0] == '0'
            && seg.byCodeUnit.all!isDigit)
            return parseErr!(void)(
                ParseError(ParseErrorCode.leadingZero, segOff));

        if (segEnd == list.length)
            break;
        segStart = segEnd + 1;
    }

    return parseOk();
}

/**
SemVer §11.4 precedence for two prerelease identifier lists:

$(UL
    $(LI Empty (no prerelease) ranks higher than any non-empty list.)
    $(LI Lists are compared identifier-by-identifier left to right.)
    $(LI Numeric identifiers compare numerically; alphanumeric compare
        lexically; numeric < alphanumeric at the same position.)
    $(LI A shorter prefix loses against a longer one with an equal prefix.)
)
*/
package int compareSemVerPrerelease(in string lhs, in string rhs)
    @safe pure nothrow @nogc
{
    if (lhs.length == 0)
        return rhs.length == 0 ? 0 : 1;
    if (rhs.length == 0)
        return -1;

    size_t li, ri;
    while (li < lhs.length || ri < rhs.length)
    {
        if (li >= lhs.length)
            return -1;
        if (ri >= rhs.length)
            return 1;

        size_t lEnd = li;
        while (lEnd < lhs.length && lhs[lEnd] != '.')
            lEnd++;
        size_t rEnd = ri;
        while (rEnd < rhs.length && rhs[rEnd] != '.')
            rEnd++;

        if (const c = compareSegment(lhs[li .. lEnd], rhs[ri .. rEnd]))
            return c;

        li = lEnd < lhs.length ? lEnd + 1 : lEnd;
        ri = rEnd < rhs.length ? rEnd + 1 : rEnd;
    }
    return 0;
}

private int compareSegment(in string lhs, in string rhs)
    @safe pure nothrow @nogc
{
    import std.algorithm.comparison : cmp;

    const lhsNumeric = isNumericIdentifier(lhs);
    const rhsNumeric = isNumericIdentifier(rhs);

    if (lhsNumeric && rhsNumeric)
    {
        if (lhs.length != rhs.length)
            return lhs.length < rhs.length ? -1 : 1;
        return cmp(lhs, rhs);
    }

    if (lhsNumeric)
        return -1;
    if (rhsNumeric)
        return 1;

    return cmp(lhs, rhs);
}

private bool isNumericIdentifier(in string value) @safe pure nothrow @nogc
{
    import std.algorithm.searching : all;
    import std.ascii : isDigit;
    import std.utf : byCodeUnit;

    return value.length > 0 && value.byCodeUnit.all!isDigit;
}

// ---------------------------------------------------------------------------
// Conformance
// ---------------------------------------------------------------------------

static assert(isVersion!SemVer && isVersionScheme!SemVer);
static assert(hasOrderKey!SemVer);
static assert(supportsPrerelease!SemVer);
static assert(hasComponents!SemVer);
static assert(hasSemVerComponents!SemVer);
static assert(hasBuildMetadata!SemVer);

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

@("semver.parse.realWorld")
@safe pure
unittest
{
    import sparkles.versions.testing : checkRoundTrip;

    static immutable cases = [
        "20.13.1", "1.78.0", "1.30.0", "17.3.0", "18.3.1", "6.8.9",
        "2.45.1", "8.3.7", "3.3.1", "1.26.0", "2.4.59", "7.2.4",
        "7.0.8", "3.45.3", "8.7.1", "7.0.1", "14.5.1", "26.1.1",
        "1.0.0-rc.1", "1.0.0-alpha.1+build.5",
    ];
    foreach (s; cases)
        checkRoundTrip!SemVer(s);
}

@("semver.ordering.precedenceChain")
@safe pure nothrow @nogc
unittest
{
    import sparkles.versions.testing : checkAscending;

    checkAscending!SemVer(
        "1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta",
        "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11",
        "1.0.0-rc.1", "1.0.0");
}

@("semver.ordering.majorDominates")
@safe pure nothrow @nogc
unittest
{
    import sparkles.versions.testing : checkAscending;

    // 2.0.0-alpha > 1.999.999.
    checkAscending!SemVer("1.999999.999999", "2.0.0-alpha", "2.0.0");
}

@("semver.prerelease.lowerThanRelease")
@safe pure nothrow @nogc
unittest
{
    auto pre = SemVer.parse("1.0.0-rc.1").value;
    auto rel = SemVer.parse("1.0.0").value;
    assert(pre < rel);
    assert(pre.isPrerelease);
    assert(!rel.isPrerelease);
}

@("semver.build.ignoredInOrdering")
@safe pure nothrow @nogc
unittest
{
    auto a = SemVer.parse("1.0.0+build.1").value;
    auto b = SemVer.parse("1.0.0+build.2").value;
    assert(a == b);
    assert(a.build == "build.1");
    assert(b.build == "build.2");
}

@("semver.orderKey.matchesOpCmp")
@safe pure nothrow @nogc
unittest
{
    static immutable corpus = [
        "0.0.0", "0.0.1", "0.1.0", "1.0.0", "1.2.3", "2.0.0",
        "1.0.0-alpha", "1.0.0",
    ];
    foreach (i; 0 .. corpus.length)
        foreach (j; 0 .. corpus.length)
        {
            const a = SemVer.parse(corpus[i]).value;
            const b = SemVer.parse(corpus[j]).value;
            if (a.orderKey != b.orderKey)
            {
                const k = a.orderKey < b.orderKey ? -1 : 1;
                const c = a.opCmp(b) < 0 ? -1 : (a.opCmp(b) > 0 ? 1 : 0);
                assert(k == c);
            }
        }
}

@("semver.loose.normalisation")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : checkToString;

    static immutable cases = [
        ["v1.2.3", "1.2.3"],
        ["= 1.2.3", "1.2.3"],
        ["1", "1.0.0"],
        ["1.2", "1.2.0"],
        ["1.2-beta.5", "1.2.0-beta.5"],
        ["01.002.0003", "1.2.3"],
    ];
    foreach (tc; cases)
    {
        auto parsed = SemVer.parseLoose(tc[0]);
        assert(parsed.hasValue, tc[0]);
        checkToString(parsed.value, tc[1]);
    }
}

@("semver.parse.rejects")
@safe pure nothrow @nogc
unittest
{
    import sparkles.versions.testing : checkRejects;

    static immutable bad = [
        "", "   ", "1.2", "1.2.3.4", "v1.2.3", "a.b.c", "01.2.3",
        "1.2.3-", "1.2.3+", "1.2.3-+build", "1.0.0-alpha..1",
        "1.2.3-01", "100000.0.0", "0.16777216.0",
    ];
    foreach (s; bad)
        checkRejects!SemVer(s);
}

// ---------------------------------------------------------------------------
// Native range parser tests
// ---------------------------------------------------------------------------

version (unittest)
{
    import sparkles.versions.operations : caret, tilde;

    private SemVer sv(string s) @safe
    {
        auto r = SemVer.parse(s);
        assert(r.hasValue, s);
        return r.value;
    }

    private Ranges!SemVer nr(string s) @safe
    {
        auto r = SemVer.parseNativeRange(s);
        assert(r.hasValue, s);
        return r.value;
    }
}

@("semver.nativeRange.caretTilde")
@safe
unittest
{
    // ^1.2.0 → [1.2.0, 2.0.0); ~1.2.0 → [1.2.0, 1.3.0).
    assert(nr("^1.2.0") == caret(sv("1.2.0")));
    assert(nr("~1.2.0") == tilde(sv("1.2.0")));
    assert(nr("^1.2.0") == Ranges!SemVer.between(sv("1.2.0"), sv("2.0.0")));
    assert(nr("~1.2.0") == Ranges!SemVer.between(sv("1.2.0"), sv("1.3.0")));
}

@("semver.nativeRange.comparators")
@safe
unittest
{
    import sparkles.versions.operations : satisfies;

    // >=1.2.0 <2.0.0 is the AND of two comparators.
    auto r = nr(">=1.2.0 <2.0.0");
    assert(r == Ranges!SemVer.between(sv("1.2.0"), sv("2.0.0")));
    assert(satisfies(sv("1.5.0"), r));
    assert(!satisfies(sv("2.0.0"), r));

    assert(nr(">1.2.0") == Ranges!SemVer.strictlyHigherThan(sv("1.2.0")));
    assert(nr("<=1.2.0") == Ranges!SemVer.lowerThan(sv("1.2.0")));
    assert(nr("=1.2.0") == Ranges!SemVer.singleton(sv("1.2.0")));
    assert(nr("1.2.0") == Ranges!SemVer.singleton(sv("1.2.0")));
}

@("semver.nativeRange.xRanges")
@safe
unittest
{
    // 1.2.x → [1.2.0, 1.3.0); 1.x → [1.0.0, 2.0.0); * → full.
    assert(nr("1.2.x") == Ranges!SemVer.between(sv("1.2.0"), sv("1.3.0")));
    assert(nr("1.*") == Ranges!SemVer.between(sv("1.0.0"), sv("2.0.0")));
    assert(nr("1") == Ranges!SemVer.between(sv("1.0.0"), sv("2.0.0")));
    assert(nr("1.2") == Ranges!SemVer.between(sv("1.2.0"), sv("1.3.0")));
    assert(nr("*") == Ranges!SemVer.full());
    assert(nr("") == Ranges!SemVer.full());
}

@("semver.nativeRange.hyphen")
@safe
unittest
{
    // 1.2.0 - 1.5.0 is the inclusive interval [1.2.0, 1.5.0].
    auto r = nr("1.2.0 - 1.5.0");
    assert(r.contains(sv("1.2.0")));
    assert(r.contains(sv("1.5.0")));
    assert(!r.contains(sv("1.5.1")));
    assert(!r.contains(sv("1.1.9")));

    // A partial upper bound widens: 1.2.0 - 1.5 ⇒ < 1.6.0.
    auto p = nr("1.2.0 - 1.5");
    assert(p.contains(sv("1.5.9")));
    assert(!p.contains(sv("1.6.0")));
}

@("semver.nativeRange.union")
@safe
unittest
{
    // ^1.2.0 || ^2.0.0 is the union of the two carets.
    auto r = nr("^1.2.0 || ^2.0.0");
    assert(r == caret(sv("1.2.0")).union_(caret(sv("2.0.0"))));
    assert(r.contains(sv("1.5.0")));
    assert(r.contains(sv("2.3.0")));
    assert(!r.contains(sv("3.0.0")));

    // Comparator union with explicit AND in one alternative.
    auto r2 = nr(">=1.0.0 <1.5.0 || >=2.0.0");
    assert(r2.contains(sv("1.2.0")));
    assert(!r2.contains(sv("1.5.0")));
    assert(r2.contains(sv("2.1.0")));
}

@("semver.nativeRange.roundTripThroughVers")
@safe
unittest
{
    import sparkles.core_cli.smallbuffer : checkToString;

    // The VERS textual form of a few ranges (SPEC §9): every comparator
    // `|`-joined, so a bounded interval is `>=lo|<hi`.
    checkToString(nr("^1.2.0"), ">=1.2.0|<2.0.0");
    checkToString(nr("~1.2.0"), ">=1.2.0|<1.3.0");
    checkToString(nr(">=1.2.0 <2.0.0"), ">=1.2.0|<2.0.0");
    checkToString(nr("1.2.0"), "1.2.0");
}

@("semver.nativeRange.rejects")
@safe
unittest
{
    assert(!SemVer.parseNativeRange("^1.2.x.y").hasValue);
    assert(!SemVer.parseNativeRange(">=abc").hasValue);
}

// CalVer schemes route through parseNpmRange too: comparators and x-ranges
// work, but caret/tilde are rejected (no SemVer triple).
@("semver.nativeRange.calVerNoCaret")
@safe
unittest
{
    import sparkles.versions.schemes.calver_yymm : CalVerYYMM;

    // Comparators work on a calendar scheme.
    auto ge = CalVerYYMM.parseNativeRange(">=24.04.1");
    assert(ge.hasValue);
    auto v = CalVerYYMM.parse("24.04.1").value;
    assert(ge.value == Ranges!CalVerYYMM.higherThan(v));

    // Caret/tilde are rejected — no SemVer triple.
    assert(!CalVerYYMM.parseNativeRange("^24.04.1").hasValue);
    assert(!CalVerYYMM.parseNativeRange("~24.04.1").hasValue);
}
