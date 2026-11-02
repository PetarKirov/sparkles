/**
dub's version-range syntax, over `sparkles:versions`' SemVer ranges: what a
`dependency`'s `version` and a `toolchainRequirements` entry state.

The forms are dub's `VersionRange.fromString`: `*`; `~>x.y.z` (`>=x.y.z`,
below the next-to-last component bumped); `^x.y.z` (below the next
incompatible version); `==x`, `>=x`, `>x`, `<=x`, `<x`; `>=x <y` and its
strict variants; and a bare version, which matches itself. A branch
(`~master`) matches only itself. Partial versions are zero-filled.

Copied from dub (`VersionRange.fromString`, `bumpVersion`,
`bumpIncompatibleVersion`, `expandVersion`); see the build-graph decisions on
behaviour copied from dub's source.
*/
module sparkles.build_primitives.resolve.dub_versions;

import std.algorithm.searching : startsWith;
import std.conv : text, to;

import sparkles.versions.ranges : Ranges;
import sparkles.versions.schemes.semver : SemVer;

/// Whether `version_` satisfies the dub range `range`; false with `error`
/// set when either does not parse.
bool dubRangeAllows(string range, string version_, out string error) @safe
{
    if (range.startsWith("~") && !range.startsWith("~>"))
        return range == version_;
    if (version_.startsWith("~"))
        return range == version_;
    Ranges!SemVer parsed;
    if (!parseDubRange(range, parsed, error))
        return false;
    const v = SemVer.parseLoose(version_);
    if (v.hasError)
    {
        error = text("`", version_, "` is no version");
        return false;
    }
    return parsed.contains(v.value);
}

/// Parses a dub version range (not a branch) into `result`.
bool parseDubRange(string range, out Ranges!SemVer result, out string error) @safe
{
    import std.string : indexOf, strip;

    range = range.strip;
    if (range.length == 0)
    {
        error = "an empty version range";
        return false;
    }
    if (range == "*")
        range = ">=0.0.0";

    bool version_(string s, out SemVer v)
    {
        const parsed = SemVer.parseLoose(s.strip);
        if (parsed.hasError)
        {
            error = text("`", s, "` is no version");
            return false;
        }
        v = parsed.value;
        return true;
    }

    SemVer low, high;
    if (range.startsWith("~>"))
    {
        if (!version_(range[2 .. $], low) || !bumped(range[2 .. $], false, high, error))
            return false;
        result = Ranges!SemVer.between(low, high);
        return true;
    }
    if (range.startsWith("^"))
    {
        if (!version_(range[1 .. $], low) || !bumped(range[1 .. $], true, high, error))
            return false;
        result = Ranges!SemVer.between(low, high);
        return true;
    }
    if ("><=".indexOf(range[0]) < 0)
    {
        if (!version_(range, low))
            return false;
        result = Ranges!SemVer.singleton(low);
        return true;
    }

    static string comparator(ref string s)
    {
        size_t n;
        while (n < s.length && "><=".indexOf(s[n]) >= 0)
            ++n;
        auto c = s[0 .. n];
        s = s[n .. $];
        return c;
    }

    string rest = range;
    const first = comparator(rest);
    const space = rest.indexOf(' ');
    if (space < 0)
    {
        if (!version_(rest, low))
            return false;
        switch (first)
        {
        case "<=": result = Ranges!SemVer.lowerThan(low); return true;
        case "<": result = Ranges!SemVer.strictlyLowerThan(low); return true;
        case ">=": result = Ranges!SemVer.higherThan(low); return true;
        case ">": result = Ranges!SemVer.strictlyHigherThan(low); return true;
        case "==": result = Ranges!SemVer.singleton(low); return true;
        default:
            error = text("unknown comparison `", first, "` in `", range, "`");
            return false;
        }
    }
    string second = rest[space + 1 .. $];
    const secondComparator = comparator(second);
    if (!(first == ">" || first == ">=") || !(secondComparator == "<" || secondComparator == "<="))
    {
        error = text("`", range, "` must be `>=a <b` or a strict variant");
        return false;
    }
    if (!version_(rest[0 .. space], low) || !version_(second, high))
        return false;
    auto lower = first == ">=" ? Ranges!SemVer.higherThan(low) : Ranges!SemVer.strictlyHigherThan(low);
    auto upper = secondComparator == "<=" ? Ranges!SemVer.lowerThan(high)
        : Ranges!SemVer.strictlyLowerThan(high);
    result = lower.intersection(upper);
    return true;
}

// dub's `bumpVersion` (`~>`) or `bumpIncompatibleVersion` (`^`), with the
// `-0` prerelease that keeps the bump's own prereleases out.
private bool bumped(string s, bool incompatible, out SemVer result, out string error) @safe
{
    import std.algorithm.searching : countUntil;
    import std.array : join, split;
    import std.string : strip;

    s = s.strip;
    const cut = s.countUntil!(c => c == '+' || c == '-');
    if (cut > 0)
        s = s[0 .. cut];
    auto parts = s.split(".");
    if (parts.length == 0 || parts.length > 3)
    {
        error = text("`", s, "` is no version");
        return false;
    }
    try
    {
        if (!incompatible)
        {
            const bump = parts.length == 3 ? 1 : 0;
            parts = parts[0 .. bump + 1];
            parts[bump] = (parts[bump].to!uint + 1).to!string;
        }
        else
        {
            while (parts.length < 3)
                parts ~= "0";
            if (parts[0] == "0")
                parts[2] = (parts[2].to!uint + 1).to!string;
            else
                parts = [(parts[0].to!uint + 1).to!string, "0", "0"];
        }
    }
    catch (Exception)
    {
        error = text("`", s, "` is no version");
        return false;
    }
    while (parts.length < 3)
        parts ~= "0";
    const parsed = SemVer.parse(parts.join(".") ~ "-0");
    if (parsed.hasError)
    {
        error = text("`", s, "` is no version");
        return false;
    }
    result = parsed.value;
    return true;
}

@("build_primitives.resolve.dub_versions.dubRangeAllows.dubForms")
@safe unittest
{
    string error;
    bool allows(string range, string v)
    {
        const r = dubRangeAllows(range, v, error);
        assert(error is null, error);
        return r;
    }

    assert(allows("*", "0.0.1") && allows("*", "9.0.0"));
    assert(allows("~>0.4.1", "0.4.1") && allows("~>0.4.1", "0.4.9") && !allows("~>0.4.1", "0.5.0"));
    assert(allows("~>1.3", "1.9.0") && !allows("~>1.3", "2.0.0") && !allows("~>1.3", "1.2.0"));
    assert(!allows("~>0.4.1", "0.5.0-alpha"));
    assert(allows("^1.2.3", "1.9.0") && !allows("^1.2.3", "2.0.0"));
    assert(allows("^0.2.3", "0.2.3") && !allows("^0.2.3", "0.2.4"));
    assert(allows(">=1.1.0", "1.1.1") && !allows(">1.1.1", "1.1.1"));
    assert(allows(">=2.105 <3.0", "2.111.0") && !allows(">=2.105 <3.0", "3.0.0"));
    assert(allows("1.3.1", "1.3.1") && !allows("1.3.1", "1.3.2") && allows("==1.3.1", "1.3.1"));
    assert(allows("~master", "~master") && !allows("~master", "1.0.0"));

    assert(!dubRangeAllows("<1 >2", "1.0.0", error) && error.length);
    assert(!dubRangeAllows("~>x.y", "1.0.0", error) && error.length);
}
