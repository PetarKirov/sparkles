/**
SemVer 2.0.0 identifier rules — validation and prerelease comparison.

These rules are SemVer-specific and live outside the engine: layouts
that follow SemVer's prerelease/build grammar (e.g. $(LREF SemVerLayout),
$(LREF DmdLayout)) reference the pre-built $(LREF semVerPrereleaseSlot)
and $(LREF semVerBuildSlot) constants in their `stringSlots`
declaration. The engine itself only sees these as opaque
`SlotValidator` / `SlotComparator` function pointers.

See `docs/specs/versions/SPEC.md` §8 and §9.
*/
module sparkles.versions.semver_rules;

import expected : err, ok;
import sparkles.versions.engine;

@safe pure nothrow @nogc:

// ---------------------------------------------------------------------------
// Identifier validation
// ---------------------------------------------------------------------------

/// Discriminates SemVer prerelease (numeric identifiers must not have
/// leading zeros) from build metadata (no such rule).
package enum IdentifierKind { prerelease, build }

/**
Validates a dot-separated identifier list per SemVer 2.0.0 §9 (prerelease)
or §10 (build metadata). `listOffset` is the byte offset of `list` within
the original input; reported errors include the offset of the failing
character.
*/
package ParseExpected!void validateIdentifierList(
    in string list, size_t listOffset, IdentifierKind kind,
)
{
    import std.algorithm.searching : all;
    import std.ascii : isAlphaNum, isDigit;
    import std.utf : byCodeUnit;

    if (list.length == 0)
        return parseErrV(ParseErrorCode.emptyIdentifier, listOffset);

    size_t segStart;
    while (true)
    {
        size_t segEnd = segStart;
        while (segEnd < list.length && list[segEnd] != '.')
            segEnd++;

        const seg = list[segStart .. segEnd];
        const segOff = listOffset + segStart;

        if (seg.length == 0)
            return parseErrV(ParseErrorCode.emptyIdentifier, segOff);

        foreach (idx, c; seg)
        {
            if (!(c.isAlphaNum || c == '-'))
                return parseErrV(
                    ParseErrorCode.invalidIdentifier, segOff + idx);
        }

        if (kind == IdentifierKind.prerelease
            && seg.length > 1
            && seg[0] == '0'
            && seg.byCodeUnit.all!isDigit)
            return parseErrV(ParseErrorCode.leadingZero, segOff);

        if (segEnd == list.length) break;
        segStart = segEnd + 1;
    }

    return ok!(ParseError, ParseExpectedHook)();
}

/// SlotValidator for SemVer prerelease segments.
ParseExpected!void validateSemVerPrerelease(in string seg, size_t offset)
{
    return validateIdentifierList(seg, offset, IdentifierKind.prerelease);
}

/// SlotValidator for SemVer build-metadata segments.
ParseExpected!void validateSemVerBuild(in string seg, size_t offset)
{
    return validateIdentifierList(seg, offset, IdentifierKind.build);
}

// ---------------------------------------------------------------------------
// Prerelease comparison (SemVer §11)
// ---------------------------------------------------------------------------

/**
SlotComparator implementing SemVer §11.4 precedence for prerelease
identifier lists:

$(UL
    $(LI Empty (no prerelease) ranks higher than any non-empty list.)
    $(LI Lists are compared identifier-by-identifier from left to right.)
    $(LI Numeric identifiers compare numerically; alphanumeric compare
        lexically; numeric < alphanumeric when both kinds appear at the
        same position.)
    $(LI A shorter prefix loses against a longer one with the prefix
        equal.)
)
*/
int compareSemVerPrerelease(in string lhs, in string rhs)
{
    if (lhs.length == 0) return rhs.length == 0 ? 0 : 1;
    if (rhs.length == 0) return -1;

    size_t li, ri;
    while (li < lhs.length || ri < rhs.length)
    {
        if (li >= lhs.length) return -1;
        if (ri >= rhs.length) return 1;

        size_t lEnd = li;
        while (lEnd < lhs.length && lhs[lEnd] != '.') lEnd++;
        size_t rEnd = ri;
        while (rEnd < rhs.length && rhs[rEnd] != '.') rEnd++;

        if (auto c = compareSegment(lhs[li .. lEnd], rhs[ri .. rEnd]))
            return c;

        li = lEnd < lhs.length ? lEnd + 1 : lEnd;
        ri = rEnd < rhs.length ? rEnd + 1 : rEnd;
    }
    return 0;
}

private int compareSegment(in string lhs, in string rhs)
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

    if (lhsNumeric) return -1;
    if (rhsNumeric) return 1;

    return cmp(lhs, rhs);
}

private bool isNumericIdentifier(in string value)
{
    import std.algorithm.searching : all;
    import std.ascii : isDigit;
    import std.utf : byCodeUnit;

    return value.length > 0 && value.byCodeUnit.all!isDigit;
}

// ---------------------------------------------------------------------------
// Pre-built SemVer slot constants
// ---------------------------------------------------------------------------

/// SemVer prerelease slot: prefixed by `-`, participates in ordering,
/// validates identifiers per SemVer §9, compares per SemVer §11.4.
immutable StringSlot semVerPrereleaseSlot = StringSlot(
    name: "prerelease",
    prefix: '-',
    includeInOrdering: true,
    validate: &validateSemVerPrerelease,
    compare: &compareSemVerPrerelease,
);

/// SemVer build-metadata slot: prefixed by `+`, excluded from ordering,
/// validates identifiers per SemVer §10.
immutable StringSlot semVerBuildSlot = StringSlot(
    name: "build",
    prefix: '+',
    includeInOrdering: false,
    validate: &validateSemVerBuild,
    compare: null,
);

// ---------------------------------------------------------------------------
// Error helper
// ---------------------------------------------------------------------------

private ParseExpected!void parseErrV(ParseErrorCode code, size_t index)
{
    return err!(void, ParseExpectedHook)(
        ParseError(code: code, index: index));
}
