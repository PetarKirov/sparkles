/**
Semantic Versioning 2.0.0 parsing and comparison.

The parser exposes a non-throwing $(LREF Expected)-based API for validation
and a convenience constructor for callers that prefer exceptions.

Standards: $(LINK2 https://semver.org/, Semantic Versioning 2.0.0)
*/
module sparkles.semver.core;

import expected : Expected, err, ok;

@safe:

/// Parsing mode for $(LREF SemVer.parse).
enum SemVerParseMode
{
    /// Accept only Semantic Versioning 2.0.0 syntax.
    strict,

    /// Accept common compatibility forms such as `v1.2.3`, `1`, and `1.2`.
    loose,
}

/// Machine-readable parse error code.
enum SemVerParseErrorCode
{
    emptyInput,
    unexpectedCharacter,
    unexpectedEnd,
    leadingZero,
    emptyIdentifier,
    invalidIdentifier,
    duplicateBuildMetadata,
    numericOverflow,
}

/// Structured parse error returned by $(LREF SemVer.parse).
struct SemVerParseError
{
    SemVerParseErrorCode code; /// Error kind.
    size_t index;              /// Byte offset where parsing failed.
}

/**
Exception thrown by the convenience $(LREF SemVer) string constructor.

Use $(LREF SemVer.parse) when parse errors should stay allocation-free and
non-throwing.
*/
class SemVerException : Exception
{
    SemVerParseError error; /// Structured parse failure.

    /// Constructs the exception from a structured parse error.
    this(
        in SemVerParseError error,
        string file = __FILE__,
        size_t line = __LINE__,
    )
    pure nothrow
    {
        this.error = error;
        super("Invalid Semantic Version", file, line);
    }
}

private struct SemVerExpectedHook
{
    static immutable bool enableDefaultConstructor = false;
}

private alias SemVerExpected(T) = Expected!(
    T,
    SemVerParseError,
    SemVerExpectedHook,
);

/// Result type returned by non-throwing SemVer parsers.
alias SemVerParseResult = SemVerExpected!SemVer;

/**
Semantic Versioning value.

`opCmp`, `opEquals`, and `toHash` use SemVer precedence, so build metadata is
ignored. Use $(LREF exactEquals) or $(LREF compareBuild) when build metadata is
part of the comparison.
*/
struct SemVer
{
    private ulong _major;
    private ulong _minor;
    private ulong _patch;
    private string _prerelease;
    private string _build;

    pure
    {
    /**
    Parses `s` using loose compatibility rules.

    Params:
        s = Version string to parse.

    Throws: $(LREF SemVerException) if `s` is not accepted by loose parsing.
    */
    this(string s)
    {
        auto parsed = parse(s, SemVerParseMode.loose);
        if (parsed.hasError)
            throw new SemVerException(parsed.error);

        auto value = parsed.value;
        _major = value._major;
        _minor = value._minor;
        _patch = value._patch;
        _prerelease = value._prerelease;
        _build = value._build;
    }

    ///
    unittest
    {
        auto ver = SemVer("v1.2.3-alpha.1+build.5");
        assert(ver.major == 1);
        assert(ver.minor == 2);
        assert(ver.patch == 3);
        assert(ver.prerelease == "alpha.1");
        assert(ver.build == "build.5");
        import std.conv : text;

        assert(text(ver) == "1.2.3-alpha.1+build.5");
    }

    /**
    Constructs a version from already separated components.

    Params:
        major      = Major version number.
        minor      = Minor version number.
        patch      = Patch version number.
        prerelease = Optional pre-release identifier list.
        build      = Optional build metadata identifier list.

    Throws: $(LREF SemVerException) if `prerelease` or `build` is invalid.
    */
    this(
        ulong major,
        ulong minor,
        ulong patch,
        string prerelease = null,
        string build = null,
    )
    {
        auto preError = validateIdentifierList(prerelease, 0, IdentifierKind.prerelease);
        if (preError.hasError)
            throw new SemVerException(preError.error);

        auto buildError = validateIdentifierList(build, 0, IdentifierKind.build);
        if (buildError.hasError)
            throw new SemVerException(buildError.error);

        _major = major;
        _minor = minor;
        _patch = patch;
        _prerelease = prerelease;
        _build = build;
    }

    ///
    unittest
    {
        import std.conv : text;

        assert(text(SemVer(1, 2, 3, "rc.1", "build.7"))
            == "1.2.3-rc.1+build.7");
    }
    }

    pure nothrow @nogc
    {
        /**
        Parses `s` without throwing.

        Params:
            s    = Version string to parse.
            mode = Strict SemVer or loose compatibility parsing.

        Returns: `Expected!(SemVer, SemVerParseError)` containing either the
            normalized version or a structured parse error.
        */
        static SemVerParseResult parse(string s, SemVerParseMode mode)
        {
            return parseImpl(s, mode);
        }

        ///
        unittest
        {
            auto parsed = SemVer.parse("1.2.3-alpha.1+build.5", SemVerParseMode.strict);
            assert(parsed.hasValue);
            assert(parsed.value.major == 1);
            assert(parsed.value.prerelease == "alpha.1");
            assert(parsed.value.build == "build.5");
        }

        /// Major version number.
        @property ulong major() const => _major;

        /// Minor version number.
        @property ulong minor() const => _minor;

        /// Patch version number.
        @property ulong patch() const => _patch;

        /// Pre-release identifier list without the leading `-`.
        @property string prerelease() const => _prerelease;

        /// Build metadata identifier list without the leading `+`.
        @property string build() const => _build;
    }

    /**
    Writes the normalized SemVer text to an output range.

    Params:
        w = Output range accepting `char` and `const(char)[]`.
    */
    void toString(Writer)(ref Writer w) const
    {
        import std.conv : toChars;
        import std.range.primitives : put;

        put(w, toChars(_major));
        put(w, '.');
        put(w, toChars(_minor));
        put(w, '.');
        put(w, toChars(_patch));

        if (_prerelease.length != 0)
        {
            put(w, '-');
            put(w, _prerelease);
        }

        if (_build.length != 0)
        {
            put(w, '+');
            put(w, _build);
        }
    }

    ///
    @safe pure nothrow @nogc
    unittest
    {
        import sparkles.core_cli.smallbuffer : checkToString;

        checkToString(
            SemVer.parse("1.2.3-alpha.1+build.5", SemVerParseMode.strict).value,
            "1.2.3-alpha.1+build.5");
        checkToString(
            SemVer.parse("01.002.0003", SemVerParseMode.loose).value, "1.2.3");
        checkToString(
            SemVer.parse("1.2", SemVerParseMode.loose).value, "1.2.0");
    }

    // `toString` infers its attributes from the `Writer` type — verify it
    // still compiles with a writer whose `put` methods carry no purity,
    // nothrow, or `@nogc` attributes (only `@safe`, mandated by the module).
    @("SemVer.toString.unattributedWriter")
    unittest
    {
        static struct PlainWriter
        {
            char[] buf;
            @safe void put(char c) { buf ~= c; }
            @safe void put(in char[] s) { buf ~= s; }
        }

        PlainWriter w;
        SemVer.parse("1.2.3-alpha.1+build.5", SemVerParseMode.strict)
            .value.toString(w);
        assert(w.buf == "1.2.3-alpha.1+build.5");
    }

    pure nothrow @nogc
    {
    /**
    Compares versions by SemVer precedence.

    Build metadata is ignored.

    Params:
        other = Version to compare against.

    Returns: A negative value, zero, or a positive value.
    */
    int opCmp(in SemVer other) const
    {
        if (_major != other._major) return _major < other._major ? -1 : 1;
        if (_minor != other._minor) return _minor < other._minor ? -1 : 1;
        if (_patch != other._patch) return _patch < other._patch ? -1 : 1;
        return comparePrerelease(_prerelease, other._prerelease);
    }

    /**
    Compares versions by SemVer precedence equality.

    Build metadata is ignored.

    Params:
        other = Version to compare against.

    Returns: `true` if both versions have equal SemVer precedence.
    */
    bool opEquals(in SemVer other) const
        => opCmp(other) == 0;

    /**
    Hashes the version according to $(LREF opEquals).

    Returns: Hash value that ignores build metadata.
    */
    size_t toHash() const @trusted
    {
        import core.internal.hash : hashOf;

        return hashOf(_prerelease,
            hashOf(_patch, hashOf(_minor, hashOf(_major))));
    }

    /**
    Compares versions by precedence and then build metadata text.

    Params:
        other = Version to compare against.

    Returns: A negative value, zero, or a positive value.
    */
    int compareBuild(in SemVer other) const
    {
        import std.algorithm.comparison : cmp;

        if (auto c = opCmp(other))
            return c;
        return cmp(_build, other._build);
    }

    /**
    Compares all version fields, including build metadata.

    Params:
        other = Version to compare against.

    Returns: `true` if all fields are equal.
    */
    bool exactEquals(in SemVer other) const
        => _major == other._major
        && _minor == other._minor
        && _patch == other._patch
        && _prerelease == other._prerelease
        && _build == other._build;
    }
}

private enum IdentifierKind
{
    prerelease,
    build,
}

private alias ValidationResult = SemVerExpected!void;

private pure nothrow @nogc:

SemVerParseResult parseImpl(string s, SemVerParseMode mode)
{
    size_t i;

    if (mode == SemVerParseMode.loose)
        skipHorizontalSpace(s, i);

    if (i >= s.length)
        return parseErr!SemVer(SemVerParseErrorCode.emptyInput, i);

    if (mode == SemVerParseMode.loose)
        skipLoosePrefix(s, i);

    ulong[3] coreVals;
    foreach (idx; 0 .. 3)
    {
        if (idx > 0)
        {
            if (i >= s.length || s[i] != '.')
            {
                if (mode == SemVerParseMode.strict)
                    return parseErr!SemVer(
                        i >= s.length
                            ? SemVerParseErrorCode.unexpectedEnd
                            : SemVerParseErrorCode.unexpectedCharacter,
                        i,
                    );
                break; // loose: remaining components stay at default 0
            }
            i++;
        }

        auto num = parseCoreNumber(s, i, mode, coreVals[idx]);
        if (num.hasError)
            return parseErr!SemVer(num.error);
    }

    SemVer result;
    result._major = coreVals[0];
    result._minor = coreVals[1];
    result._patch = coreVals[2];

    if (i < s.length && s[i] == '-')
    {
        const start = ++i;
        while (i < s.length && s[i] != '+')
            i++;
        if (i == start)
            return parseErr!SemVer(SemVerParseErrorCode.emptyIdentifier, start);
        auto check = validateIdentifierList(
            s[start .. i], start, IdentifierKind.prerelease);
        if (check.hasError)
            return parseErr!SemVer(check.error);
        result._prerelease = s[start .. i];
    }

    if (i < s.length && s[i] == '+')
    {
        import std.algorithm.searching : countUntil;
        import std.utf : byCodeUnit;

        const start = ++i;
        auto slice = s[start .. $];
        if (slice.length == 0)
            return parseErr!SemVer(SemVerParseErrorCode.emptyIdentifier, start);
        const dupPlus = slice.byCodeUnit.countUntil('+');
        if (dupPlus >= 0)
            return parseErr!SemVer(
                SemVerParseErrorCode.duplicateBuildMetadata, start + dupPlus);
        auto check = validateIdentifierList(slice, start, IdentifierKind.build);
        if (check.hasError)
            return parseErr!SemVer(check.error);
        result._build = slice;
        i = s.length;
    }

    if (mode == SemVerParseMode.loose)
        skipHorizontalSpace(s, i);

    if (i != s.length)
        return parseErr!SemVer(
            s[i] == '+'
                ? SemVerParseErrorCode.duplicateBuildMetadata
                : SemVerParseErrorCode.unexpectedCharacter,
            i,
        );

    return ok!(SemVerParseError, SemVerExpectedHook)(result);
}

void skipHorizontalSpace(in string s, ref size_t i)
{
    import std.algorithm.comparison : among;

    while (i < s.length && s[i].among(' ', '\t'))
        i++;
}

void skipLoosePrefix(in string s, ref size_t i)
{
    import std.algorithm.comparison : among;

    if (i >= s.length)
        return;

    if (s[i].among('=', 'v', 'V'))
    {
        i++;
        skipHorizontalSpace(s, i);
    }
}

ValidationResult parseCoreNumber(
    in string s,
    ref size_t i,
    SemVerParseMode mode,
    out ulong value,
)
{
    import std.ascii : isDigit;

    const start = i;
    if (i >= s.length)
        return parseErr!void(SemVerParseErrorCode.unexpectedEnd, i);
    if (!s[i].isDigit)
        return parseErr!void(SemVerParseErrorCode.unexpectedCharacter, i);

    value = 0;
    while (i < s.length && s[i].isDigit)
    {
        const digit = cast(ulong)(s[i] - '0');
        if (value > (ulong.max - digit) / 10)
            return parseErr!void(SemVerParseErrorCode.numericOverflow, i);
        value = value * 10 + digit;
        i++;
    }

    if (mode == SemVerParseMode.strict && i - start > 1 && s[start] == '0')
        return parseErr!void(SemVerParseErrorCode.leadingZero, start);

    return ok!(SemVerParseError, SemVerExpectedHook)();
}

ValidationResult validateIdentifierList(
    in string list,
    size_t listOffset,
    IdentifierKind kind,
)
{
    import std.algorithm.searching : all;
    import std.ascii : isAlphaNum, isDigit;
    import std.utf : byCodeUnit;

    if (list.length == 0)
        return ok!(SemVerParseError, SemVerExpectedHook)();

    size_t segStart;
    while (true)
    {
        size_t segEnd = segStart;
        while (segEnd < list.length && list[segEnd] != '.')
            segEnd++;

        const seg = list[segStart .. segEnd];
        const segOff = listOffset + segStart;

        if (seg.length == 0)
            return parseErr!void(SemVerParseErrorCode.emptyIdentifier, segOff);

        foreach (idx, c; seg)
        {
            if (!(c.isAlphaNum || c == '-'))
                return parseErr!void(
                    SemVerParseErrorCode.invalidIdentifier, segOff + idx);
        }

        if (kind == IdentifierKind.prerelease
            && seg.length > 1
            && seg[0] == '0'
            && seg.byCodeUnit.all!isDigit)
            return parseErr!void(SemVerParseErrorCode.leadingZero, segOff);

        if (segEnd == list.length) break;
        segStart = segEnd + 1;
    }

    return ok!(SemVerParseError, SemVerExpectedHook)();
}

SemVerExpected!T parseErr(T)(
    SemVerParseError error,
)
{
    return err!(T, SemVerExpectedHook)(error);
}

SemVerExpected!T parseErr(T)(
    SemVerParseErrorCode code,
    size_t index,
)
{
    return parseErr!T(SemVerParseError(code: code, index: index));
}

int comparePrerelease(in string lhs, in string rhs)
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

        if (auto c = comparePrereleaseSegment(lhs[li .. lEnd], rhs[ri .. rEnd]))
            return c;

        li = lEnd < lhs.length ? lEnd + 1 : lEnd;
        ri = rEnd < rhs.length ? rEnd + 1 : rEnd;
    }
    return 0;
}

int comparePrereleaseSegment(in string lhs, in string rhs)
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

bool isNumericIdentifier(in string value)
{
    import std.algorithm.searching : all;
    import std.ascii : isDigit;
    import std.utf : byCodeUnit;

    return value.length > 0 && value.byCodeUnit.all!isDigit;
}

@("SemVer.parse.strictValid")
unittest
{
    static immutable cases = [
        "0.0.0",                            // smallest valid
        "1.0.0",
        "1.2.3-alpha.1",
        "1.2.3+build.42",
        "1.2.3-alpha.1+build.42",
        "1.2.3-rc1-with-hyphen",
        "1.2.3+build.01",
        "1.2.3-0abc123",
        "1.0.0-0",                          // single zero numeric prerelease
        "1.2.3-1.alpha1.9+build5.7.3aedf",  // complex prerelease + build
        "1.2.3-0a",                         // alphanumeric prerelease starting with 0
        "0.4.0-beta.1+0851523",             // build metadata may have leading-zero digits
        "18446744073709551615.0.0",         // ulong.max boundary
    ];

    foreach (ver; cases)
        assert(SemVer.parse(ver, SemVerParseMode.strict).hasValue, ver);
}

@("SemVer.parse.looseNormalization")
unittest
{
    import sparkles.core_cli.smallbuffer : checkToString;

    static immutable cases = [
        ["v1.2.3", "1.2.3"],
        ["= 1.2.3", "1.2.3"],
        ["1", "1.0.0"],
        ["1.2", "1.2.0"],
        ["1.2-5", "1.2.0-5"],
        ["1.2-beta.5", "1.2.0-beta.5"],
        ["01.002.0003", "1.2.3"],
    ];

    foreach (testCase; cases)
    {
        auto parsed = SemVer.parse(testCase[0], SemVerParseMode.loose);
        assert(parsed.hasValue);
        checkToString(parsed.value, testCase[1]);
    }
}

@("SemVer.parse.compilerVersions")
unittest
{
    import sparkles.core_cli.smallbuffer : checkToString;

    // Real release tags from github.com/dlang/dmd/tags — DMD uses dotted
    // prerelease segments and historically had zero-padded minor numbers.
    static immutable dmdCases = [
        ["v2.110.0",        "2.110.0"],
        ["v2.110.0-beta.1", "2.110.0-beta.1"],
        ["v2.110.0-rc.1",   "2.110.0-rc.1"],
        ["v2.077.0",        "2.77.0"],     // zero-padded historical minor
        ["v2.076.0-rc1",    "2.76.0-rc1"], // historical undotted prerelease
        ["v2.076.0-b2",     "2.76.0-b2"],
        ["v1.075",          "1.75.0"],     // very old two-component tag
    ];

    // Real release tags from github.com/ldc-developers/ldc/tags — LDC uses
    // undotted single-segment prereleases like "beta1" / "rc1".
    static immutable ldcCases = [
        ["v1.41.0",       "1.41.0"],
        ["v1.41.0-beta1", "1.41.0-beta1"],
        ["v1.42.0-beta3", "1.42.0-beta3"],
        ["v1.40.1",       "1.40.1"],
    ];

    import std.range : chain;

    foreach (testCase; dmdCases[].chain(ldcCases[]))
    {
        auto parsed = SemVer.parse(testCase[0], SemVerParseMode.loose);
        assert(parsed.hasValue, testCase[0]);
        checkToString(parsed.value, testCase[1]);
    }
}

@("SemVer.parse.invalid")
unittest
{
    static immutable strictInvalid = [
        "",
        "   ",                          // whitespace-only (strict does not strip)
        "1.2",
        "1.2.3.4",                      // extra component
        "1.2.3 abc",                    // trailing junk
        "v1.2.3",
        "a.b.c",                        // non-digit major
        "01.2.3",
        "07",                           // single-component leading zero
        "1.2.3-",
        "1.2.3+",                       // empty build metadata
        "1.2.3++",
        "1.2.3-+build",                 // empty prerelease before '+'
        "1.2.3-.",                      // single dot prerelease
        "1.2.3-α",                      // non-ASCII (Greek alpha)
        "1.2.3-alpha..",                // trailing empty segment
        "1.0.0-alpha_beta",
        "1.0.0-alpha..1",
        "1.2.3-0123",
        "1.2.3-01",                     // short numeric-prerelease leading zero
        "9.8.7+meta+meta",
        "\n1.2.3",
        ".1.2.3",                       // leading dot
        "-1.2.3",                       // negative major
        "18446744073709551616.0.0",
        "111111111111111111111.0.0",    // 21-digit major overflow
    ];

    foreach (ver; strictInvalid)
        assert(SemVer.parse(ver, SemVerParseMode.strict).hasError, ver);
}

@("SemVer.compare.specOrder")
@safe pure
unittest
{
    import std.algorithm.iteration : map;
    import std.algorithm.sorting : isSorted;

    // Semantic Versioning 2.0.0 §11.4 precedence example chain.
    static immutable versions = [
        "1.0.0-alpha",
        "1.0.0-alpha.1",
        "1.0.0-alpha.beta",
        "1.0.0-beta",
        "1.0.0-beta.2",
        "1.0.0-beta.11",
        "1.0.0-rc.1",
        "1.0.0",
    ];
    auto parsed = versions.map!(v => SemVer.parse(v, SemVerParseMode.strict).value);

    assert(parsed.isSorted);
}

@("SemVer.compare.numericCore")
@safe pure
unittest
{
    import std.algorithm.iteration : map;
    import std.algorithm.sorting : isSorted;

    // Core components compare numerically, not lexically: 9 < 10 < 99 < 100.
    static immutable ordered = [
        "0.9.0",
        "0.10.0",
        "0.99.0",
        "0.100.0",
        "1.0.0",
        "1.99.99",
        "2.0.0",
        "10.0.0",
    ];

    assert(ordered.map!(v => SemVer.parse(v, SemVerParseMode.strict).value).isSorted);
}

@("SemVer.compare.edgeCases")
unittest
{
    alias S = (string v) => SemVer.parse(v, SemVerParseMode.strict).value;

    assert(S("1.2.3-a.10") > S("1.2.3-a.5"));
    assert(S("1.2.3-a.b")  > S("1.2.3-a.5"));
    assert(S("1.2.3-a.b")  > S("1.2.3-a"));
    assert(S("1.2.3-r100") > S("1.2.3-R2"));
    assert(S("1.2.3")      > S("1.2.3-4"));

    // Numeric prerelease segment < alphanumeric segment with same digits prefix.
    assert(S("1.2.3-5")    < S("1.2.3-5-foo"));

    // Build metadata never elevates the smaller version.
    assert(S("2.7.2+meta") < S("3.0.0"));
    assert(S("1.0.0+a")    < S("1.1.0"));
}

@("SemVer.compare.buildMetadata")
unittest
{
    auto a = SemVer.parse("1.2.3+abc", SemVerParseMode.strict).value;
    auto b = SemVer.parse("1.2.3+def", SemVerParseMode.strict).value;

    assert(a == b);
    assert(a.opCmp(b) == 0);
    assert(a.toHash() == b.toHash());
    assert(!a.exactEquals(b));
    assert(a.compareBuild(b) < 0);
}

@("SemVer.attributes.parse")
unittest
{
    auto parsed = SemVer.parse("v1.2", SemVerParseMode.loose);
    assert(parsed.hasValue);
    assert(parsed.value == SemVer.parse("1.2.0", SemVerParseMode.strict).value);
}
