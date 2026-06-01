/**
VERS interop — the `vers:` version-range URI surface and per-scheme
constraint translation.

[VERS](https://github.com/package-url/vers-spec) is a URI scheme for
version-range expressions: `vers:<scheme>/<constraint>|<constraint>|…`. A
constraint is `<comparator><version>` with the comparator one of `=` (the
default when omitted), `!=`, `<`, `<=`, `>`, `>=`, or the bare star `*`
meaning all versions.

This module provides three layers:

$(UL
    $(LI The URI surface — $(LREF VersUri), $(LREF parseVersUri),
        $(LREF formatVersUri): scheme extraction, `|`-splitting, and
        ASCII/lowercase normalisation. No version is typed at this layer.)
    $(LI The per-scheme constraint translation —
        $(LREF fromVersConstraint) (one `<op><version>` segment → a
        `Ranges!S`) and $(LREF toVersConstraint) (a `Ranges!S` → VERS
        constraint text, reusing `Ranges.toString`).)
    $(LI Static dispatch — $(LREF parseVersAs), which folds the constraint
        segments of a `vers:` URI into a single `Ranges!(Scheme.Version)`
        following the vers-spec multi-constraint interval semantics (a port
        of the univers `contains_version` containment algorithm — $(B not)
        naive AND/OR), plus the compile-time
        $(LREF schemeForPurlType)/$(LREF versSchemeRegistry) that the runtime
        `parseVersAny` (M5) will dispatch through.)
)

The multi-constraint semantics is the subtle part: sorted constraints define
a sequence of contiguous intervals, not a plain conjunction or disjunction.
`>=1.0.0|<2.0.0` is the interval `[1.0.0, 2.0.0)`, while the bare
`1.0.0|2.0.0` is the two-point set `{1.0.0} ∪ {2.0.0}`. $(LREF parseVersAs)
builds the equivalent `Ranges!S` via set algebra so its `contains` agrees
with the vers-spec containment rules.

See `docs/specs/versions/SPEC.md` §9 (VERS interop).
*/
module sparkles.versions.vers;

import sparkles.versions.any : AnyRange;
import sparkles.versions.parsing :
    NoGcHook, ParseError, ParseErrorCode, ParseExpected, parseErr, parseOk;
import sparkles.versions.ranges : Ranges;
import sparkles.versions.traits : isVersion, isVersionScheme;

@safe:

// ---------------------------------------------------------------------------
// The URI surface
// ---------------------------------------------------------------------------

/**
The parsed surface of a `vers:` URI: the lowercased versioning scheme and the
constraint segments, pre-split on `|` but not yet typed against any scheme.

`parseVersUri` populates this from the URI text; `formatVersUri` renders it
back to `vers:scheme/c1|c2` form, preserving the stored constraint order
(see $(LREF formatVersUri) for why version-sorted canonical output needs a
scheme — that is $(LREF formatVersAs)'s job).
*/
struct VersUri
{
    /// The versioning scheme, lowercased: `"npm"`, `"pypi"`, `"semver"`, …
    string scheme;

    /// The constraint segments, split on `|` with surrounding spaces
    /// stripped. Each is a `<comparator><version>` token (or the bare `*`).
    string[] constraints;
}

/**
Parses the `vers:` URI surface of `s` into a $(LREF VersUri).

Handles only the URI surface: it requires the `vers:` prefix, rejects
non-ASCII input, lowercases the scheme, splits the constraint list on `|`,
and strips surrounding spaces from each segment (spaces are insignificant in
the canonical form). It does $(B not) type the constraints against any
scheme — that is $(LREF fromVersConstraint)'s job.

Errors (with the offset of the offending position):

$(UL
    $(LI `emptyInput` — `s` is empty or all-blank.)
    $(LI `unexpectedCharacter` — a non-ASCII byte, a missing `vers:` prefix,
        or a missing `/` separator.)
    $(LI `unexpectedEnd` — no constraint text after the `/`.)
)
*/
ParseExpected!VersUri parseVersUri(string s) @safe
{
    import std.ascii : isASCII, toLower;

    // Reject non-ASCII bytes up front (VERS is ASCII-only).
    foreach (i, char c; s)
        if (!c.isASCII)
            return parseErr!VersUri(
                ParseError(ParseErrorCode.unexpectedCharacter, i));

    // Strip surrounding whitespace; spaces are insignificant.
    string trimmed = stripSpaces(s);
    if (trimmed.length == 0)
        return parseErr!VersUri(ParseError(ParseErrorCode.emptyInput, 0));

    // Require the `vers:` URI scheme (case-insensitive).
    enum prefix = "vers:";
    if (trimmed.length < prefix.length || !startsWithCI(trimmed, prefix))
        return parseErr!VersUri(
            ParseError(ParseErrorCode.unexpectedCharacter, 0));

    string rest = trimmed[prefix.length .. $];

    // Split scheme and constraint list on the first `/`.
    size_t slash = 0;
    while (slash < rest.length && rest[slash] != '/')
        slash++;
    if (slash == rest.length)
        return parseErr!VersUri(
            ParseError(ParseErrorCode.unexpectedCharacter, prefix.length));

    // Lowercase the scheme.
    auto schemeBuf = new char[slash];
    foreach (i; 0 .. slash)
        schemeBuf[i] = rest[i].toLower;
    string scheme = schemeBuf.idup;

    string constraintText = removeSpaces(rest[slash + 1 .. $]);
    if (constraintText.length == 0)
        return parseErr!VersUri(
            ParseError(ParseErrorCode.unexpectedEnd, trimmed.length));

    // Trim leading/trailing `|` and split on `|`.
    constraintText = trimPipes(constraintText);
    string[] constraints;
    size_t start = 0;
    foreach (i, char c; constraintText)
        if (c == '|')
        {
            constraints ~= constraintText[start .. i];
            start = i + 1;
        }
    constraints ~= constraintText[start .. $];

    return parseOk(VersUri(scheme, constraints));
}

/**
Renders `v` to `vers:scheme/c1|c2` form into the output range `w`, a faithful
$(B textual) renderer: the constraint segments are emitted in their stored
order, with only an order-preserving dedupe of exactly-equal segments (after
normalising a redundant leading `=`, so `=1.0` and bare `1.0` are recognised
as the same singleton).

This is $(B not) the vers-spec canonical form, which sorts constraints by
$(I parsed version) then comparator. $(LREF VersUri) carries untyped
`string[]` constraints, so it has no scheme to parse versions with and cannot
version-sort. For vers-spec-canonical (version-ordered) output, use the
scheme-typed $(LREF formatVersAs) / $(LREF toVersUriStringAs): a
`Ranges!Scheme` is a sorted, disjoint interval list, so it emits constraints
in version order by construction.
*/
void formatVersUri(W)(ref W w, in VersUri v) @safe
{
    import std.range.primitives : put;

    put(w, "vers:");
    put(w, v.scheme);
    put(w, "/");

    // Order-preserving dedupe of exactly-equal segments (with a redundant
    // leading `=` normalised away). No version sort — that needs a scheme.
    auto cs = dedupedConstraints(v.constraints);
    foreach (i, c; cs)
    {
        if (i > 0)
            put(w, "|");
        put(w, c);
    }
}

/// `toString`-style convenience: render `v` to a freshly-allocated string.
string toVersUriString(in VersUri v) @safe
{
    import std.array : appender;

    auto w = appender!string;
    formatVersUri(w, v);
    return w[];
}

/**
Renders the $(B vers-spec canonical) `vers:` URI for the range `r` under the
statically-known scheme `Scheme`, into the output range `w`:
`vers:` ~ `Scheme.purlType` ~ `/` followed by $(LREF toVersConstraint).

Unlike $(LREF formatVersUri) (a textual renderer with no scheme), this emits
constraints in $(I version) order: `Ranges!(Scheme.Version)` is a sorted,
disjoint interval list, so `toVersConstraint` — which walks those intervals —
yields the version-ordered comparator sequence the vers-spec canonical form
requires.

Note `toVersConstraint` separates a single two-bound interval with `,` (e.g.
`>=1.2.0,<2.0.0`) rather than the canonical `|`; `parseVersAs` re-folds either
separator into the same intervals. Callers needing the strict `|`-only
grammar can post-process the comma (see the round-trip test harness).
*/
void formatVersAs(Scheme, W)(ref W w, in Ranges!(Scheme.Version) r) @safe
if (isVersionScheme!Scheme)
{
    import std.range.primitives : put;

    put(w, "vers:");
    put(w, Scheme.purlType);
    put(w, "/");
    toVersConstraint!Scheme(w, r);
}

/// `toString`-style convenience: render the canonical `vers:` URI for `r`
/// under `Scheme` to a freshly-allocated string. See $(LREF formatVersAs).
string toVersUriStringAs(Scheme)(in Ranges!(Scheme.Version) r) @safe
if (isVersionScheme!Scheme)
{
    import std.array : appender;

    auto w = appender!string;
    formatVersAs!Scheme(w, r);
    return w[];
}

// ---------------------------------------------------------------------------
// Per-scheme constraint ↔ Range translation
// ---------------------------------------------------------------------------

/// The VERS comparators, ordered most-specific-prefix-first so a two-char
/// operator (`>=`) is matched before its one-char prefix (`>`).
private enum VersOp
{
    eq,         // `=` (default when omitted)
    neq,        // `!=`
    lt,         // `<`
    lte,        // `<=`
    gt,         // `>`
    gte,        // `>=`
    star,       // `*`
}

/// Splits a constraint segment into its comparator and the remaining version
/// text. The bare star is its own operator; a leading comparator otherwise
/// defaults to `=`.
private struct OpSplit
{
    VersOp op;
    string version_;
}

private OpSplit splitConstraint(string seg) @safe pure nothrow @nogc
{
    if (seg == "*")
        return OpSplit(VersOp.star, null);

    if (seg.length >= 2 && seg[0] == '>' && seg[1] == '=')
        return OpSplit(VersOp.gte, seg[2 .. $]);
    if (seg.length >= 2 && seg[0] == '<' && seg[1] == '=')
        return OpSplit(VersOp.lte, seg[2 .. $]);
    if (seg.length >= 2 && seg[0] == '!' && seg[1] == '=')
        return OpSplit(VersOp.neq, seg[2 .. $]);
    if (seg.length >= 1 && seg[0] == '>')
        return OpSplit(VersOp.gt, seg[1 .. $]);
    if (seg.length >= 1 && seg[0] == '<')
        return OpSplit(VersOp.lt, seg[1 .. $]);
    if (seg.length >= 1 && seg[0] == '=')
        return OpSplit(VersOp.eq, seg[1 .. $]);

    return OpSplit(VersOp.eq, seg);
}

/**
Parses one VERS constraint segment (`>=1.2.0`, `!=1.5.0`, `1.0.0`, `*`, …)
into a `Ranges!S` for scheme `S`.

The operator maps to a range constructor:

$(UL
    $(LI `>=v` → `higherThan(v)`; `>v` → `strictlyHigherThan(v)`.)
    $(LI `<=v` → `lowerThan(v)`; `<v` → `strictlyLowerThan(v)`.)
    $(LI `=v` / bare `v` → `singleton(v)`.)
    $(LI `!=v` → `singleton(v).complement()`.)
    $(LI `*` → `full()`.)
)

The version part is parsed by `S.parse`; a parse failure (or an empty version
where one is required) is surfaced as the corresponding `ParseError`.
*/
ParseExpected!(Ranges!S) fromVersConstraint(S)(string segment) @safe
if (isVersionScheme!S)
{
    alias R = Ranges!S;

    const split = splitConstraint(stripSpaces(segment));

    if (split.op == VersOp.star)
        return parseOk(R.full());

    if (split.version_.length == 0)
        return parseErr!R(ParseError(ParseErrorCode.unexpectedEnd, 0));

    auto pv = S.parse(split.version_);
    if (!pv.hasValue)
        return parseErr!R(pv.error);
    const v = pv.value;

    final switch (split.op)
    {
    case VersOp.eq:
        return parseOk(R.singleton(v));
    case VersOp.neq:
        return parseOk(R.singleton(v).complement());
    case VersOp.lt:
        return parseOk(R.strictlyLowerThan(v));
    case VersOp.lte:
        return parseOk(R.lowerThan(v));
    case VersOp.gt:
        return parseOk(R.strictlyHigherThan(v));
    case VersOp.gte:
        return parseOk(R.higherThan(v));
    case VersOp.star:
        return parseOk(R.full()); // unreachable (handled above)
    }
}

/**
Emits the VERS constraint text for a `Ranges!S` into the output range `w`,
reusing `Ranges.toString` (which already renders the VERS comparator syntax,
SPEC §9): each interval as `>=`/`>`/`<=`/`<` (or a bare version for a
singleton, `*` for the full set), intervals joined by `|`.

Note `Ranges.toString` separates a two-bound interval with `,` (e.g.
`>=1.2.0,<2.0.0`); the multi-bound `|`-pipe form is recovered on the
$(LREF parseVersAs) round-trip, which re-folds bounds into intervals.
*/
void toVersConstraint(S, W)(ref W w, in Ranges!S r) @safe
if (isVersionScheme!S)
{
    r.toString(w);
}

// ---------------------------------------------------------------------------
// Static dispatch — parseVersAs!Scheme
// ---------------------------------------------------------------------------

/**
Parses a `vers:` URI for the statically-known scheme `Scheme`, folding its
constraint segments into a single `Ranges!(Scheme.Version)`.

The fold follows the vers-spec multi-constraint interval semantics — a direct
port of the univers `contains_version` containment algorithm — $(B not) a
naive AND or OR of the per-segment ranges:

$(UL
    $(LI A lone `*` is the full set.)
    $(LI `=v` and bare `v` segments contribute the singleton `{v}`.)
    $(LI `!=v` segments are removed (the result is intersected with
        `{v}`'s complement).)
    $(LI The remaining `<`/`<=`/`>`/`>=` segments, sorted by version, define
        a sequence of contiguous intervals: a leading `<`/`<=` opens at
        `-∞`; a `>`/`>=` followed by a `<`/`<=` forms a bounded interval
        between them; a trailing `>`/`>=` runs to `+∞`.)
)

Building the result as a `Ranges!(Scheme.Version)` (whose `contains` is
already interval-correct) makes its membership agree with the vers-spec
containment rules by construction.

The URI's scheme field is $(B not) required to equal `Scheme.purlType`: the
caller has already chosen the scheme statically, so any scheme label is
accepted and only the constraints are interpreted.
*/
template parseVersAs(Scheme)
if (isVersionScheme!Scheme)
{
    ParseExpected!(Ranges!(Scheme.Version)) parseVersAs(string versUri) @safe
    {
        alias V = Scheme.Version;
        alias R = Ranges!V;

        auto uri = parseVersUri(versUri);
        if (!uri.hasValue)
            return parseErr!R(uri.error);

        return foldConstraints!Scheme(uri.value.constraints);
    }
}

/// Folds a list of (already URI-split) constraint segments into one
/// `Ranges!(Scheme.Version)` per the vers-spec containment algorithm.
private ParseExpected!(Ranges!(Scheme.Version)) foldConstraints(Scheme)(
    in string[] segments,
) @safe
if (isVersionScheme!Scheme)
{
    alias V = Scheme.Version;
    alias R = Ranges!V;

    if (segments.length == 0)
        return parseErr!R(ParseError(ParseErrorCode.unexpectedEnd, 0));

    // A `*` must occur alone.
    foreach (seg; segments)
        if (stripSpaces(seg) == "*")
        {
            if (segments.length != 1)
                return parseErr!R(
                    ParseError(ParseErrorCode.unexpectedCharacter, 0));
            return parseOk(R.full());
        }

    // Parse each segment into (op, version).
    struct Parsed { VersOp op; V version_; }
    Parsed[] parsed;
    foreach (seg; segments)
    {
        const split = splitConstraint(stripSpaces(seg));
        if (split.version_.length == 0)
            return parseErr!R(ParseError(ParseErrorCode.unexpectedEnd, 0));
        auto pv = Scheme.parse(split.version_);
        if (!pv.hasValue)
            return parseErr!R(pv.error);
        parsed ~= Parsed(split.op, pv.value);
    }

    // Sort by version (the vers-spec canonical ordering needed for the
    // contiguous-interval fold). A stable insertion sort keeps it `@safe`
    // and avoids pulling in a comparator-predicate template.
    foreach (i; 1 .. parsed.length)
    {
        auto key = parsed[i];
        size_t j = i;
        while (j > 0 && key.version_ < parsed[j - 1].version_)
        {
            parsed[j] = parsed[j - 1];
            j--;
        }
        parsed[j] = key;
    }

    // Build the positive interval set from the order-comparator segments,
    // then add the `=` singletons and subtract the `!=` singletons. This
    // reproduces `contains_version`: equality versions are members; unequal
    // versions are holes; the `<`/`<=`/`>`/`>=` segments alternate to form
    // contiguous intervals.

    R positive = R.empty();

    // Order-comparator segments, in sorted order.
    Parsed[] ords;
    foreach (p; parsed)
        if (p.op == VersOp.lt || p.op == VersOp.lte
            || p.op == VersOp.gt || p.op == VersOp.gte)
            ords ~= p;

    {
        size_t i = 0;
        // A leading `<`/`<=` opens the first interval at -∞.
        if (ords.length && (ords[0].op == VersOp.lt || ords[0].op == VersOp.lte))
        {
            positive = positive.union_(upperRange!V(ords[0].op, ords[0].version_));
            i = 1;
        }
        // Then walk `>`/`>=` lower bounds, each optionally paired with the
        // next `<`/`<=` upper bound.
        while (i < ords.length)
        {
            const loOp = ords[i].op;
            if (loOp != VersOp.gt && loOp != VersOp.gte)
            {
                // A stray `<`/`<=` here would be an invalid sequence; treat
                // it leniently as its own (-∞, v] interval.
                positive = positive.union_(upperRange!V(loOp, ords[i].version_));
                i++;
                continue;
            }

            if (i + 1 < ords.length
                && (ords[i + 1].op == VersOp.lt || ords[i + 1].op == VersOp.lte))
            {
                positive = positive.union_(
                    lowerRange!V(loOp, ords[i].version_)
                        .intersection(
                            upperRange!V(ords[i + 1].op, ords[i + 1].version_)));
                i += 2;
            }
            else
            {
                positive = positive.union_(lowerRange!V(loOp, ords[i].version_));
                i++;
            }
        }
    }

    // Add `=` singletons.
    R result = positive;
    foreach (p; parsed)
        if (p.op == VersOp.eq)
            result = result.union_(R.singleton(p.version_));

    // Subtract `!=` singletons.
    foreach (p; parsed)
        if (p.op == VersOp.neq)
            result = result.intersection(R.singleton(p.version_).complement());

    return parseOk(result);
}

/// The `[v, +∞)` / `(v, +∞)` lower-bounded range for a `>=` / `>` constraint.
///
/// `v` is taken by value (not `in`): the `Ranges!V` interval constructors
/// accept `V` by value, and a scheme carrying mutable indirection
/// (`MavenVersion`/`DebianVersion`/`PypiVersion` hold arrays) cannot copy a
/// `const V` into that mutable parameter. The caller passes a mutable lvalue.
private Ranges!V lowerRange(V)(VersOp op, V v) @safe
if (isVersion!V)
in (op == VersOp.gt || op == VersOp.gte)
{
    return op == VersOp.gte
        ? Ranges!V.higherThan(v)
        : Ranges!V.strictlyHigherThan(v);
}

/// The `(-∞, v]` / `(-∞, v)` upper-bounded range for a `<=` / `<` constraint.
/// `v` is by value for the same reason as $(LREF lowerRange).
private Ranges!V upperRange(V)(VersOp op, V v) @safe
if (isVersion!V)
in (op == VersOp.lt || op == VersOp.lte)
{
    return op == VersOp.lte
        ? Ranges!V.lowerThan(v)
        : Ranges!V.strictlyLowerThan(v);
}

// ---------------------------------------------------------------------------
// Runtime dispatch — parseVersAny → AnyRange
// ---------------------------------------------------------------------------

/**
Parses a `vers:` URI of statically-unknown scheme and returns its range typed
as an $(REF AnyRange, sparkles,versions,any) — the runtime VERS entry point
(SPEC §9/§11). This closes the M3 deferral.

The pipeline:

$(UL
    $(LI $(LREF parseVersUri) the URI surface (scheme label + constraint
        segments).)
    $(LI Map the scheme label through
        $(REF purlTypeToSchemeName, sparkles,versions,purl) onto a built-in
        scheme name (so `vers:npm/…` resolves to the `semver` scheme, matching
        $(LREF parseVersAny)'s pURL counterpart).)
    $(LI Resolve that name to a scheme struct via
        $(LREF schemeForPurlType) and run $(LREF parseVersAs) for it, wrapping
        the resulting `Ranges!Scheme` in `AnyRange`.)
)

Errors:

$(UL
    $(LI Any $(LREF parseVersUri) surface error is propagated verbatim.)
    $(LI An unknown / unmapped scheme label (no built-in scheme) is
        `unexpectedCharacter` at offset 0.)
    $(LI A constraint that the resolved scheme rejects propagates that
        scheme's $(LREF parseVersAs) error.)
)
*/
ParseExpected!AnyRange parseVersAny(string versUri) @safe
{
    import sparkles.versions.purl : purlTypeToSchemeName;
    import sparkles.versions.schemes.registry : publishedSchemeEntries;

    auto uri = parseVersUri(versUri);
    if (!uri.hasValue)
        return parseErr!AnyRange(uri.error);

    const schemeName = purlTypeToSchemeName(uri.value.scheme);
    if (schemeName.length == 0)
        return parseErr!AnyRange(
            ParseError(ParseErrorCode.unexpectedCharacter, 0));

    // Generate a runtime switch over the published scheme catalogue: each arm
    // recovers the scheme struct statically and folds parseVersAs's result
    // into AnyRange. The mapped `schemeName` is always a published purlType.
    switch (schemeName)
    {
        static foreach (e; publishedSchemeEntries)
        {
        case e.purlType:
            {
                alias Scheme = schemeForPurlType!(e.purlType);
                auto pr = parseVersAs!Scheme(versUri);
                if (!pr.hasValue)
                    return parseErr!AnyRange(pr.error);
                return parseOk(AnyRange(pr.value));
            }
        }
        default:
            return parseErr!AnyRange(
                ParseError(ParseErrorCode.unexpectedCharacter, 0));
    }
}

// ---------------------------------------------------------------------------
// Compile-time scheme registry (purlType → scheme struct)
// ---------------------------------------------------------------------------

// The registry lives in `sparkles.versions.schemes.registry` (alongside the
// scheme modules, so the VERS and pURL layers — and the M5 sum-type assembly —
// share one source of truth). It is re-exported here for callers reaching the
// VERS layer directly; `parseVersAs!(schemeForPurlType!"semver")` ties the
// static resolver to this module's static dispatch.
public import sparkles.versions.schemes.registry :
    allSchemes,
    publishedSchemes,
    publishedPurlTypes,
    schemeForPurlType,
    hasSchemeForPurlType;

// ---------------------------------------------------------------------------
// Internal text helpers
// ---------------------------------------------------------------------------

/// Strips leading/trailing ASCII spaces and tabs.
private string stripSpaces(string s) @safe pure nothrow @nogc
{
    size_t lo = 0, hi = s.length;
    while (lo < hi && (s[lo] == ' ' || s[lo] == '\t'))
        lo++;
    while (hi > lo && (s[hi - 1] == ' ' || s[hi - 1] == '\t'))
        hi--;
    return s[lo .. hi];
}

/// Removes every ASCII space/tab from `s` (spaces are insignificant in VERS).
private string removeSpaces(string s) @safe pure nothrow
{
    bool anySpace = false;
    foreach (char c; s)
        if (c == ' ' || c == '\t')
        {
            anySpace = true;
            break;
        }
    if (!anySpace)
        return s;

    auto buf = new char[s.length];
    size_t n = 0;
    foreach (char c; s)
        if (c != ' ' && c != '\t')
            buf[n++] = c;
    return buf[0 .. n].idup;
}

/// Trims leading and trailing `|` from `s`.
private string trimPipes(string s) @safe pure nothrow @nogc
{
    size_t lo = 0, hi = s.length;
    while (lo < hi && s[lo] == '|')
        lo++;
    while (hi > lo && s[hi - 1] == '|')
        hi--;
    return s[lo .. hi];
}

/// Case-insensitive prefix test (`prefix` is assumed ASCII-lowercase).
private bool startsWithCI(string s, string prefix) @safe pure nothrow @nogc
{
    import std.ascii : toLower;

    if (s.length < prefix.length)
        return false;
    foreach (i; 0 .. prefix.length)
        if (s[i].toLower != prefix[i])
            return false;
    return true;
}

/// Strips a redundant leading `=` from a constraint segment so that the
/// explicit-equality form (`=1.0`) and the bare singleton (`1.0`) — which
/// univers treats as equal — normalise to the same text. `!=`/`<=`/`>=` and
/// the bare `*` are left untouched.
private string normaliseEq(string seg) @safe pure nothrow @nogc
{
    return seg.length >= 1 && seg[0] == '=' ? seg[1 .. $] : seg;
}

/// Returns the constraint segments in their original order, with an
/// order-preserving dedupe of segments that are equal once a redundant
/// leading `=` is normalised away. The first occurrence's text is kept.
private string[] dedupedConstraints(in string[] cs) @safe pure nothrow
{
    string[] out_;
    foreach (c; cs)
    {
        const key = normaliseEq(c);
        bool seen = false;
        foreach (k; out_)
            if (normaliseEq(k) == key)
            {
                seen = true;
                break;
            }
        if (!seen)
            out_ ~= c;
    }
    return out_;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest)
{
    import sparkles.versions.schemes.semver : SemVer;

    private SemVer sv(string s) @safe
    {
        auto r = SemVer.parse(s);
        assert(r.hasValue, s);
        return r.value;
    }
}

@("vers.parseVersUri.basic")
@safe
unittest
{
    auto r = parseVersUri("vers:npm/>=1.2.0|<2.0.0");
    assert(r.hasValue);
    assert(r.value.scheme == "npm");
    assert(r.value.constraints == [">=1.2.0", "<2.0.0"]);
}

@("vers.parseVersUri.lowercasesScheme")
@safe
unittest
{
    auto r = parseVersUri("VERS:NPM/1.0.0");
    assert(r.hasValue);
    assert(r.value.scheme == "npm");
    assert(r.value.constraints == ["1.0.0"]);
}

@("vers.parseVersUri.stripsSpacesAndPipes")
@safe
unittest
{
    auto r = parseVersUri("  vers:pypi/ |>=1.0 | <2.0| ");
    assert(r.hasValue);
    assert(r.value.scheme == "pypi");
    assert(r.value.constraints == [">=1.0", "<2.0"]);
}

@("vers.parseVersUri.rejects")
@safe
unittest
{
    assert(!parseVersUri("").hasValue);              // empty
    assert(!parseVersUri("   ").hasValue);           // blank
    assert(!parseVersUri("npm/1.0.0").hasValue);     // no vers: prefix
    assert(!parseVersUri("vers:npm").hasValue);      // no `/`
    assert(!parseVersUri("vers:npm/").hasValue);     // no constraints
    assert(!parseVersUri("vers:npm/1.0.0é").hasValue); // non-ASCII
}

@("vers.formatVersUri.preservesOrderAndDedupes")
@safe
unittest
{
    // formatVersUri is a textual renderer: it keeps the stored order and only
    // dedupes exactly-equal segments (it does NOT version-sort).
    auto v = VersUri("npm", ["2.0.0", "1.0.0", "2.0.0"]);
    assert(toVersUriString(v) == "vers:npm/2.0.0|1.0.0");

    // A redundant leading `=` normalises, so `=1.0` and bare `1.0` dedupe.
    auto eq = VersUri("npm", ["=1.0", "1.0"]);
    assert(toVersUriString(eq) == "vers:npm/=1.0");
}

@("vers.formatVersAs.canonicalVersionOrder")
@safe
unittest
{
    // The scheme-typed emitter produces vers-spec canonical (version-ordered)
    // output. Crucially this is NOT text order: `<10.0.0` sorts BEFORE
    // `<9.0.0` textually ('1' < '9'), but by version 9.0.0 < 10.0.0, so the
    // canonical form is `<9.0.0|<10.0.0`.
    auto r = parseVersAs!SemVer("vers:semver/<10.0.0|<9.0.0");
    assert(r.hasValue);
    // <10.0.0 ∪ <9.0.0 = <10.0.0 (the wider upper bound); the canonical text
    // collapses to the single dominating comparator.
    assert(toVersUriStringAs!SemVer(r.value) == "vers:semver/<10.0.0");

    // A diverging two-singleton set keeps both, in version (not text) order.
    auto two = parseVersAs!SemVer("vers:semver/10.0.0|9.0.0");
    assert(two.hasValue);
    assert(toVersUriStringAs!SemVer(two.value) == "vers:semver/9.0.0|10.0.0");
}

@("vers.parseFormat.roundTrip")
@safe
unittest
{
    // formatVersUri preserves the stored textual order verbatim.
    auto r = parseVersUri("vers:semver/>=1.2.0|<2.0.0");
    assert(r.hasValue);
    assert(toVersUriString(r.value) == "vers:semver/>=1.2.0|<2.0.0");

    // The scheme-typed canonical path emits version-ordered constraints:
    // `>=1.2.0|<2.0.0` → `>=1.2.0,<2.0.0` (the bounded interval [1.2.0,2.0.0)).
    auto typed = parseVersAs!SemVer("vers:semver/>=1.2.0|<2.0.0");
    assert(typed.hasValue);
    assert(toVersUriStringAs!SemVer(typed.value) == "vers:semver/>=1.2.0,<2.0.0");
}

@("vers.fromVersConstraint.eachOperator")
@safe
unittest
{
    alias R = Ranges!SemVer;

    auto eq = fromVersConstraint!SemVer("1.2.0");
    assert(eq.hasValue);
    assert(eq.value == R.singleton(sv("1.2.0")));

    auto eqExplicit = fromVersConstraint!SemVer("=1.2.0");
    assert(eqExplicit.hasValue);
    assert(eqExplicit.value == R.singleton(sv("1.2.0")));

    auto gte = fromVersConstraint!SemVer(">=1.2.0");
    assert(gte.hasValue);
    assert(gte.value == R.higherThan(sv("1.2.0")));

    auto gt = fromVersConstraint!SemVer(">1.2.0");
    assert(gt.hasValue);
    assert(gt.value == R.strictlyHigherThan(sv("1.2.0")));

    auto lte = fromVersConstraint!SemVer("<=1.2.0");
    assert(lte.hasValue);
    assert(lte.value == R.lowerThan(sv("1.2.0")));

    auto lt = fromVersConstraint!SemVer("<1.2.0");
    assert(lt.hasValue);
    assert(lt.value == R.strictlyLowerThan(sv("1.2.0")));

    auto neq = fromVersConstraint!SemVer("!=1.2.0");
    assert(neq.hasValue);
    assert(neq.value == R.singleton(sv("1.2.0")).complement());

    auto star = fromVersConstraint!SemVer("*");
    assert(star.hasValue);
    assert(star.value == R.full());
}

@("vers.fromVersConstraint.rejects")
@safe
unittest
{
    assert(!fromVersConstraint!SemVer(">=").hasValue);   // empty version
    assert(!fromVersConstraint!SemVer(">=abc").hasValue); // bad version
}

@("vers.toVersConstraint.reusesRangeToString")
@safe
unittest
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    SmallBuffer!(char, 64) buf;
    auto r = Ranges!SemVer.between(sv("1.2.0"), sv("2.0.0"));
    toVersConstraint!SemVer(buf, r);
    assert(buf[] == ">=1.2.0,<2.0.0");
}

@("vers.parseVersAs.boundedInterval")
@safe
unittest
{
    import sparkles.versions.operations : satisfies;

    // >=1.2.0|<2.0.0 is the contiguous interval [1.2.0, 2.0.0).
    auto r = parseVersAs!SemVer("vers:semver/>=1.2.0|<2.0.0");
    assert(r.hasValue);
    assert(r.value == Ranges!SemVer.between(sv("1.2.0"), sv("2.0.0")));
    assert(r.value.contains(sv("1.5.0")));
    assert(!r.value.contains(sv("1.0.0")));
    assert(!r.value.contains(sv("2.0.0")));
}

@("vers.parseVersAs.twoSingletons")
@safe
unittest
{
    // Bare `1.0.0|2.0.0` is the two-point set {1.0.0} ∪ {2.0.0}.
    auto r = parseVersAs!SemVer("vers:semver/1.0.0|2.0.0");
    assert(r.hasValue);
    auto expected = Ranges!SemVer.singleton(sv("1.0.0"))
        .union_(Ranges!SemVer.singleton(sv("2.0.0")));
    assert(r.value == expected);
    assert(r.value.contains(sv("1.0.0")));
    assert(r.value.contains(sv("2.0.0")));
    assert(!r.value.contains(sv("1.5.0")));
}

@("vers.parseVersAs.star")
@safe
unittest
{
    auto r = parseVersAs!SemVer("vers:semver/*");
    assert(r.hasValue);
    assert(r.value == Ranges!SemVer.full());
}

@("vers.parseVersAs.notEqualHole")
@safe
unittest
{
    // >=1.0.0|!=1.5.0|<2.0.0 is [1.0.0, 2.0.0) with 1.5.0 removed.
    auto r = parseVersAs!SemVer("vers:semver/>=1.0.0|!=1.5.0|<2.0.0");
    assert(r.hasValue);
    assert(r.value.contains(sv("1.4.0")));
    assert(!r.value.contains(sv("1.5.0")));
    assert(r.value.contains(sv("1.6.0")));
}

@("vers.parseVersAs.multiInterval")
@safe
unittest
{
    // >=1.0.0|<1.5.0|>=2.0.0|<3.0.0 → [1.0.0,1.5.0) ∪ [2.0.0,3.0.0).
    auto r = parseVersAs!SemVer("vers:semver/>=1.0.0|<1.5.0|>=2.0.0|<3.0.0");
    assert(r.hasValue);
    auto expected = Ranges!SemVer.between(sv("1.0.0"), sv("1.5.0"))
        .union_(Ranges!SemVer.between(sv("2.0.0"), sv("3.0.0")));
    assert(r.value == expected);
    assert(r.value.contains(sv("1.2.0")));
    assert(!r.value.contains(sv("1.7.0")));
    assert(r.value.contains(sv("2.5.0")));
    assert(!r.value.contains(sv("3.0.0")));
}

@("vers.parseVersAs.unboundedTails")
@safe
unittest
{
    // Leading `<` and trailing `>=` run to the infinities.
    auto lo = parseVersAs!SemVer("vers:semver/<2.0.0");
    assert(lo.hasValue);
    assert(lo.value == Ranges!SemVer.strictlyLowerThan(sv("2.0.0")));

    auto hi = parseVersAs!SemVer("vers:semver/>=2.0.0");
    assert(hi.hasValue);
    assert(hi.value == Ranges!SemVer.higherThan(sv("2.0.0")));
}

@("vers.parseVersAs.roundTripFromNative")
@safe
unittest
{
    // Round-trip law (SPEC §9): a native range → VERS text → parseVersAs
    // yields an equal Ranges.
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    auto native = SemVer.parseNativeRange("^1.2.0").value; // [1.2.0, 2.0.0)

    SmallBuffer!(char, 64) buf;
    toVersConstraint!SemVer(buf, native);
    // buf is ">=1.2.0,<2.0.0"; rebuild the vers: URI with `|` separators.
    auto uri = "vers:semver/>=1.2.0|<2.0.0";
    auto back = parseVersAs!SemVer(uri);
    assert(back.hasValue);
    assert(back.value == native);
}

@("vers.schemeForPurlType.resolves")
@safe
unittest
{
    static assert(is(schemeForPurlType!"semver" == SemVer));

    import sparkles.versions.schemes.pypi : PypiVersion;
    import sparkles.versions.schemes.generic : Generic;
    static assert(is(schemeForPurlType!"pypi" == PypiVersion));
    static assert(is(schemeForPurlType!"generic" == Generic));

    // An unknown / internal-only type does not resolve.
    static assert(!__traits(compiles, schemeForPurlType!"dmd"));
}

@("vers.parseVersAny.semverInterval")
@safe
unittest
{
    import sparkles.versions.any : AnyRange;
    import std.sumtype : match;

    // Runtime dispatch yields an AnyRange holding the SemVer interval.
    auto r = parseVersAny("vers:semver/>=1.2.0|<2.0.0");
    assert(r.hasValue);

    const expected = Ranges!SemVer.between(sv("1.2.0"), sv("2.0.0"));
    r.value.match!(
        (Ranges!SemVer rng) => assert(rng == expected),
        _ => assert(false, "expected Ranges!SemVer"),
    );
}

@("vers.parseVersAny.npmFoldsToSemVer")
@safe
unittest
{
    import sparkles.versions.any : AnyRange;
    import std.sumtype : match;

    // A vers:npm/… label folds onto the semver scheme.
    auto r = parseVersAny("vers:npm/>=1.0.0");
    assert(r.hasValue);

    const expected = Ranges!SemVer.higherThan(sv("1.0.0"));
    r.value.match!(
        (Ranges!SemVer rng) => assert(rng == expected),
        _ => assert(false, "expected Ranges!SemVer"),
    );
}

@("vers.parseVersAny.rejects")
@safe
unittest
{
    // Unknown / internal-only scheme → no built-in scheme.
    assert(!parseVersAny("vers:dmd/1.0.0").hasValue);
    assert(!parseVersAny("vers:nonexistent/1.0.0").hasValue);

    // Surface error (no vers: prefix) is propagated.
    assert(!parseVersAny("npm/1.0.0").hasValue);

    // A constraint the scheme rejects propagates the parse error.
    assert(!parseVersAny("vers:semver/>=not-a-version").hasValue);
}
