/**
`PypiVersion` — PEP 440 (Python packaging) versions.

A _structural_ scheme: its ordering compares `epoch`, then the `release`
tuple, then the pre/post/dev ranking, then the local version. There is no
fixed-width integer whose unsigned compare reproduces this order — the
release tuple is unbounded, the pre/post/dev ranking is a small enum crossed
with an unbounded number, and the local version is an arbitrary mix of
numeric and lexicographic segments — so `PypiVersion` declares **no**
`orderKey` and its `opCmp` walks the structure.

Canonical ordering (PEP 440, verbatim):

```
1.dev0 < 1.0.dev456 < 1.0a1 < 1.0a2.dev456 < 1.0a12 < 1.0b1
    < 1.0b2 < 1.0rc1 < 1.0 < 1.0.post456 < 1.0.15 < 1.1.dev1
```

See `docs/specs/versions/PRESETS.md` §3.8.
*/
module sparkles.versions.schemes.pypi;

import sparkles.versions.parsing : parseOk, parseErr;

import sparkles.versions.parsing :
    NoGcHook, ParseError, ParseErrorCode, ParseExpected;
import sparkles.versions.ranges : Ranges;
import sparkles.versions.traits :
    hasBuildMetadata, hasComponents, hasOrderKey,
    isVersion, isVersionScheme, supportsPrerelease;

@safe:

/// The class of a PEP 440 pre-release segment, ordered `a < b < rc`.
enum PreKind : ubyte
{
    alpha = 0, /// `aN`
    beta = 1,  /// `bN`
    rc = 2,    /// `rcN` (also spelled `c`/`pre`/`preview`)
}

/// One dot-separated segment of a PEP 440 local version label. A numeric
/// segment outranks a lexicographic one.
struct LocalSegment
{
    bool isNumeric; /// true when the segment is all digits
    ulong num;      /// numeric value when `isNumeric`
    string text;    /// the verbatim text (lowercased)
}

/**
A PEP 440 version.

The fields capture the full structure: `epoch`, the `release` tuple, an
optional pre-release (`hasPre`/`preKind`/`preNum`), an optional post-release
(`hasPost`/`postNum`), an optional dev-release (`hasDev`/`devNum`), and the
optional local version label.
*/
struct PypiVersion
{
    /// Explicit epoch (default `0`); dominates everything in ordering.
    ulong epoch;

    /// The release tuple, most-significant-first (e.g. `[3, 13, 0]`).
    uint[] release;

    /// SemVer-triple accessors over the release tuple (zero when absent), so
    /// `hasComponents` holds. `scope`, so the generic component helpers can
    /// read them off a `scope`/`in` version (e.g. inside `satisfies`).
    uint major() const scope @safe pure nothrow @nogc
        => release.length > 0 ? release[0] : 0;
    /// ditto
    uint minor() const scope @safe pure nothrow @nogc
        => release.length > 1 ? release[1] : 0;
    /// ditto
    uint patch() const scope @safe pure nothrow @nogc
        => release.length > 2 ? release[2] : 0;

    /// Pre-release segment, if any.
    bool hasPre;
    PreKind preKind; /// class of the pre-release
    ulong preNum;    /// pre-release number

    /// Post-release segment, if any.
    bool hasPost;
    ulong postNum; /// post-release number

    /// Dev-release segment, if any.
    bool hasDev;
    ulong devNum; /// dev-release number

    /// Local version label segments (the part after `+`), if any.
    LocalSegment[] local;

    /// The verbatim local label text (without the leading `+`), for
    /// round-tripping.
    string localText;

    // ----- scheme handle -----

    alias Version = PypiVersion;
    alias Range = Ranges!PypiVersion;
    enum string purlType = "pypi";
    enum string[] components = ["major", "minor", "patch"];

    // ----- required surface -----

    /// PEP 440 structural three-way order.
    int opCmp(in PypiVersion other) const @safe pure nothrow @nogc
    {
        if (epoch != other.epoch)
            return epoch < other.epoch ? -1 : 1;

        // Release tuple, padded with implicit zeros to equal length.
        const n = release.length > other.release.length
            ? release.length : other.release.length;
        foreach (i; 0 .. n)
        {
            const x = i < release.length ? release[i] : 0;
            const y = i < other.release.length ? other.release[i] : 0;
            if (x != y)
                return x < y ? -1 : 1;
        }

        if (const c = comparePrePostDev(other))
            return c;

        return compareLocal(other);
    }

    bool opEquals(in PypiVersion other) const @safe pure nothrow @nogc
        => opCmp(other) == 0;

    size_t toHash() const @trusted pure nothrow @nogc
    {
        import core.internal.hash : hashOf;
        size_t h = hashOf(epoch);
        foreach (r; release)
            h = hashOf(r, h);
        h = hashOf(hasPre, h);
        h = hashOf(preKind, h);
        h = hashOf(preNum, h);
        h = hashOf(hasPost, h);
        h = hashOf(postNum, h);
        h = hashOf(hasDev, h);
        h = hashOf(devNum, h);
        return hashOf(localText, h);
    }

    /// Writes the canonical PEP 440 form
    /// `[N!]release[{a,b,rc}N][.postN][.devN][+local]`.
    void toString(W)(ref W w) const
    {
        import sparkles.core_cli.text.writers : writeInteger;
        import std.range.primitives : put;

        if (epoch != 0)
        {
            writeInteger(w, epoch);
            put(w, '!');
        }
        foreach (i, r; release)
        {
            if (i)
                put(w, '.');
            writeInteger(w, r);
        }
        if (hasPre)
        {
            final switch (preKind)
            {
                case PreKind.alpha: put(w, 'a'); break;
                case PreKind.beta: put(w, 'b'); break;
                case PreKind.rc: put(w, "rc"); break;
            }
            writeInteger(w, preNum);
        }
        if (hasPost)
        {
            put(w, ".post");
            writeInteger(w, postNum);
        }
        if (hasDev)
        {
            put(w, ".dev");
            writeInteger(w, devNum);
        }
        if (localText.length)
        {
            put(w, '+');
            put(w, localText);
        }
    }

    // ----- optional capabilities -----

    /// True for an alpha/beta/rc or a dev release (PEP 440 pre-releases).
    bool isPrerelease() const @safe pure nothrow @nogc
        => hasPre || hasDev;

    // ----- parsing -----

    /// Parses canonical PEP 440 syntax.
    static ParseExpected!PypiVersion parse(string s) @safe pure nothrow
        => parsePypi(s, false);

    /// Parses with PEP 440 normalisation: case-folding, a leading `v`,
    /// and separator canonicalisation (`1.0-a1` → `1.0a1`).
    static ParseExpected!PypiVersion parseLoose(string s) @safe pure nothrow
        => parsePypi(s, true);

    /// Native PEP 440 specifier-set grammar: a comma-separated AND of
    /// clauses using `==`, `!=`, `<`, `<=`, `>`, `>=`, `~=` (compatible
    /// release) and `===` (arbitrary equality), with trailing `.*`
    /// wildcards on `==`/`!=`. `~=1.4.5` desugars to `>=1.4.5,==1.4.*`.
    static ParseExpected!Range parseNativeRange(string s) @safe pure nothrow
        => parsePypiRange(s);

    // ----- private structural compare helpers -----

    private int comparePrePostDev(in PypiVersion other)
        const @safe pure nothrow @nogc
    {
        // Order within a release, low → high:
        //   dev-only < pre[.dev] < final < post[.dev]
        if (const c = compareInt(phaseRank, other.phaseRank))
            return c;

        // Same phase rank → compare the phase's own number, then dev.
        if (hasPre && other.hasPre)
        {
            if (const c = compareInt(preKind, other.preKind))
                return c;
            if (const c = compareInt(preNum, other.preNum))
                return c;
        }
        if (hasPost && other.hasPost)
            if (const c = compareInt(postNum, other.postNum))
                return c;

        // A dev release sorts before the same version without one.
        if (hasDev != other.hasDev)
            return hasDev ? -1 : 1;
        if (hasDev && other.hasDev)
            if (const c = compareInt(devNum, other.devNum))
                return c;

        return 0;
    }

    /// Coarse phase rank: a pure-dev release (`1.dev0`) sorts below a
    /// pre-release, which sorts below the final, which sorts below a post.
    private int phaseRank() const scope @safe pure nothrow @nogc
    {
        if (hasPost)
            return 3;
        if (!hasPre && !hasDev)
            return 2; // final release
        if (hasPre)
            return 1; // pre-release (possibly with .dev)
        return 0;     // pure dev release
    }

    private int compareLocal(in PypiVersion other)
        const @safe pure nothrow @nogc
    {
        // A version with a local label sorts after the same public version.
        const n = local.length > other.local.length
            ? local.length : other.local.length;
        foreach (i; 0 .. n)
        {
            if (i >= local.length)
                return -1; // shorter prefix loses
            if (i >= other.local.length)
                return 1;
            if (const c = compareLocalSeg(local[i], other.local[i]))
                return c;
        }
        return 0;
    }
}

private int compareInt(T)(T a, T b) @safe pure nothrow @nogc
    => a < b ? -1 : (a > b ? 1 : 0);

private int compareLocalSeg(in LocalSegment a, in LocalSegment b)
    @safe pure nothrow @nogc
{
    import std.algorithm.comparison : cmp;

    // A numeric segment outranks a lexicographic one.
    if (a.isNumeric && b.isNumeric)
        return compareInt(a.num, b.num);
    if (a.isNumeric != b.isNumeric)
        return a.isNumeric ? 1 : -1;
    const c = cmp(a.text, b.text);
    return c < 0 ? -1 : (c > 0 ? 1 : 0);
}

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------

private ParseExpected!PypiVersion parsePypi(string input, bool loose)
    @safe pure nothrow
{
    import std.ascii : isDigit, toLower;

    PypiVersion result;
    // Normalise to lowercase for matching (PEP 440 is case-insensitive).
    auto lowered = new char[input.length];
    foreach (i, c; input)
        lowered[i] = cast(char) toLower(c);
    const(char)[] s = lowered;
    size_t off = 0;

    ParseExpected!PypiVersion fail(ParseErrorCode code)
        => parseErr!(PypiVersion)(ParseError(code, off));

    void advance(size_t n) @safe pure nothrow @nogc
    {
        s = s[n .. $];
        off += n;
    }

    if (loose)
    {
        while (s.length && (s[0] == ' ' || s[0] == '\t'))
            advance(1);
        if (s.length && s[0] == 'v')
            advance(1);
    }

    if (s.length == 0)
        return fail(ParseErrorCode.emptyInput);

    // Reads an unsigned integer, advancing the cursor.
    bool readUint(out ulong value)
    {
        if (s.length == 0 || !s[0].isDigit)
            return false;
        value = 0;
        while (s.length && s[0].isDigit)
        {
            const d = cast(ulong)(s[0] - '0');
            if (value > (ulong.max - d) / 10)
                return false;
            value = value * 10 + d;
            advance(1);
        }
        return true;
    }

    // Optional separator (`.`, `-`, `_`) used between segments; loose mode
    // accepts any, strict accepts a `.` (or none) per the canonical form.
    bool eatSep()
    {
        if (s.length && (s[0] == '.' || s[0] == '-' || s[0] == '_'))
        {
            advance(1);
            return true;
        }
        return false;
    }

    // --- epoch ---
    {
        // Look ahead for `N!`.
        size_t i = 0;
        while (i < s.length && s[i].isDigit)
            i++;
        if (i < s.length && s[i] == '!')
        {
            ulong ep;
            if (!readUint(ep))
                return fail(ParseErrorCode.unexpectedCharacter);
            advance(1); // the '!'
            result.epoch = ep;
        }
    }

    // --- release tuple ---
    {
        ulong r;
        if (!readUint(r))
            return fail(ParseErrorCode.unexpectedCharacter);
        result.release ~= cast(uint) r;
        while (s.length && s[0] == '.')
        {
            // Only consume the dot if a digit follows (otherwise it may be a
            // `.post`/`.dev` separator).
            if (s.length < 2 || !s[1].isDigit)
                break;
            advance(1);
            if (!readUint(r))
                return fail(ParseErrorCode.unexpectedCharacter);
            result.release ~= cast(uint) r;
        }
    }

    // --- pre-release ---
    {
        const(char)[] save = s;
        const saveOff = off;
        eatSep(); // optional separator before a pre-release tag
        PreKind kind;
        bool matched = true;
        if (startsWith(s, "alpha"))
        { kind = PreKind.alpha; advance(5); }
        else if (startsWith(s, "beta"))
        { kind = PreKind.beta; advance(4); }
        else if (startsWith(s, "preview"))
        { kind = PreKind.rc; advance(7); }
        else if (startsWith(s, "pre"))
        { kind = PreKind.rc; advance(3); }
        else if (startsWith(s, "rc"))
        { kind = PreKind.rc; advance(2); }
        else if (s.length && s[0] == 'a')
        { kind = PreKind.alpha; advance(1); }
        else if (s.length && s[0] == 'b')
        { kind = PreKind.beta; advance(1); }
        else if (s.length && s[0] == 'c')
        { kind = PreKind.rc; advance(1); }
        else
            matched = false;

        if (matched)
        {
            eatSep(); // optional separator before the number
            ulong num;
            if (readUint(num))
                result.preNum = num;
            // an implicit pre-release number of 0 is allowed (`1.0a`)
            result.hasPre = true;
            result.preKind = kind;
        }
        else
        {
            s = save;
            off = saveOff;
        }
    }

    // --- post-release ---
    {
        const(char)[] save = s;
        const saveOff = off;
        eatSep();
        bool matched = false;
        if (startsWith(s, "post"))
        { advance(4); matched = true; }
        else if (startsWith(s, "rev"))
        { advance(3); matched = true; }
        else if (startsWith(s, "r") && s.length > 1 && s[1].isDigit)
        { advance(1); matched = true; }

        if (matched)
        {
            eatSep();
            ulong num;
            if (readUint(num))
                result.postNum = num;
            result.hasPost = true;
        }
        else
        {
            s = save;
            off = saveOff;
        }
    }

    // --- dev-release ---
    {
        const(char)[] save = s;
        const saveOff = off;
        eatSep();
        if (startsWith(s, "dev"))
        {
            advance(3);
            eatSep();
            ulong num;
            if (readUint(num))
                result.devNum = num;
            result.hasDev = true;
        }
        else
        {
            s = save;
            off = saveOff;
        }
    }

    // --- local version label ---
    if (s.length && s[0] == '+')
    {
        advance(1);
        const start = off;
        size_t i = 0;
        while (i < s.length)
            i++;
        const label = s[0 .. i].idup;
        advance(i);
        result.localText = label;
        // Split on `.`/`-`/`_` into typed segments.
        size_t segStart = 0;
        foreach (k, c; label)
        {
            if (c == '.' || c == '-' || c == '_')
            {
                result.local ~= makeLocalSeg(label[segStart .. k]);
                segStart = k + 1;
            }
        }
        if (segStart <= label.length)
            result.local ~= makeLocalSeg(label[segStart .. $]);
        cast(void) start;
    }

    if (s.length != 0)
        return fail(ParseErrorCode.unexpectedCharacter);

    return parseOk(result);
}

private LocalSegment makeLocalSeg(in char[] text) @safe pure nothrow
{
    import std.ascii : isDigit;

    LocalSegment seg;
    seg.text = text.idup;
    bool allDigits = text.length > 0;
    foreach (c; text)
        if (!c.isDigit)
            allDigits = false;
    if (allDigits)
    {
        seg.isNumeric = true;
        ulong v = 0;
        foreach (c; text)
            v = v * 10 + (c - '0');
        seg.num = v;
    }
    return seg;
}

private bool startsWith(in char[] s, string prefix) @safe pure nothrow @nogc
{
    if (s.length < prefix.length)
        return false;
    return s[0 .. prefix.length] == prefix;
}

// ---------------------------------------------------------------------------
// Native range parser (PEP 440 specifier set)
// ---------------------------------------------------------------------------

/// Builds a `PypiVersion` whose public version is exactly the given release
/// tuple (epoch 0, no pre/post/dev/local).
private PypiVersion releaseVersion(in uint[] release) @safe pure nothrow
{
    PypiVersion v;
    v.release = release.dup;
    return v;
}

/// Parses a comma-separated PEP 440 specifier set into a `Ranges!PypiVersion`,
/// intersecting every clause.
private ParseExpected!(Ranges!PypiVersion) parsePypiRange(string input)
    @safe pure nothrow
{
    alias R = Ranges!PypiVersion;

    ParseExpected!R fail(size_t off)
        => parseErr!R(ParseError(ParseErrorCode.unexpectedCharacter, off));

    if (input.length == 0)
        return parseErr!R(ParseError(ParseErrorCode.emptyInput, 0));

    R acc = R.full();
    size_t off = 0;

    // Walk comma-separated clauses, intersecting each into `acc`.
    while (off < input.length)
    {
        // Skip leading whitespace.
        while (off < input.length
            && (input[off] == ' ' || input[off] == '\t'))
            off++;
        if (off >= input.length)
            return fail(off);

        const clauseStart = off;
        // A clause runs to the next comma.
        size_t end = off;
        while (end < input.length && input[end] != ',')
            end++;
        // Trim trailing whitespace.
        size_t clauseEnd = end;
        while (clauseEnd > clauseStart
            && (input[clauseEnd - 1] == ' ' || input[clauseEnd - 1] == '\t'))
            clauseEnd--;

        auto clause = input[clauseStart .. clauseEnd];
        auto sub = parsePypiClause(clause, clauseStart);
        if (!sub.hasValue)
            return sub;
        acc = acc.intersection(sub.value);

        off = end;
        if (off < input.length && input[off] == ',')
            off++; // consume the comma and continue
    }

    return parseOk(acc);
}

/// Parses one clause `<op><version>[.*]` into a `Ranges!PypiVersion`.
/// `base` is the offset of the clause within the original input, used for
/// error reporting.
private ParseExpected!(Ranges!PypiVersion) parsePypiClause(
    string clause, size_t base) @safe pure nothrow
{
    alias R = Ranges!PypiVersion;

    ParseExpected!R fail(size_t off)
        => parseErr!R(ParseError(ParseErrorCode.unexpectedCharacter, off));

    if (clause.length == 0)
        return fail(base);

    // --- operator ---
    enum Op { eq, ne, lt, le, gt, ge, compat, arbitrary }
    Op op;
    size_t i = 0;
    if (clause.length >= 3 && clause[0 .. 3] == "===")
    { op = Op.arbitrary; i = 3; }
    else if (clause.length >= 2 && clause[0 .. 2] == "==")
    { op = Op.eq; i = 2; }
    else if (clause.length >= 2 && clause[0 .. 2] == "!=")
    { op = Op.ne; i = 2; }
    else if (clause.length >= 2 && clause[0 .. 2] == "<=")
    { op = Op.le; i = 2; }
    else if (clause.length >= 2 && clause[0 .. 2] == ">=")
    { op = Op.ge; i = 2; }
    else if (clause.length >= 2 && clause[0 .. 2] == "~=")
    { op = Op.compat; i = 2; }
    else if (clause[0] == '<')
    { op = Op.lt; i = 1; }
    else if (clause[0] == '>')
    { op = Op.gt; i = 1; }
    else
        return fail(base);

    // Skip whitespace between operator and version.
    while (i < clause.length && (clause[i] == ' ' || clause[i] == '\t'))
        i++;
    if (i >= clause.length)
        return fail(base + i);

    auto verText = clause[i .. $];

    // --- trailing `.*` wildcard (only legal on ==/!=) ---
    bool wildcard = false;
    if (verText.length >= 2 && verText[$ - 2 .. $] == ".*")
    {
        wildcard = true;
        verText = verText[0 .. $ - 2];
    }

    if (wildcard && op != Op.eq && op != Op.ne)
        return fail(base + i);

    auto parsed = PypiVersion.parse(verText.idup);
    if (!parsed.hasValue)
        return fail(base + i + parsed.error.offset);
    auto v = parsed.value;

    if (wildcard)
    {
        // `==V.*` matches every version whose release has `V`'s release as a
        // prefix: `[V_release, nextPrefix)` where `nextPrefix` bumps the last
        // release component. `!=V.*` is the complement.
        if (v.release.length == 0)
            return fail(base + i);
        auto lo = releaseVersion(v.release);
        auto hi = releaseVersion(bumpLast(v.release));
        auto prefix = R.between(lo, hi);
        return parseOk(op == Op.eq ? prefix : prefix.complement());
    }

    final switch (op)
    {
        case Op.eq:
            return parseOk(R.singleton(v));
        case Op.ne:
            return parseOk(R.singleton(v).complement());
        case Op.arbitrary:
            // Arbitrary equality is an exact string match in PEP 440; modelled
            // here as the singleton of the parsed version.
            return parseOk(R.singleton(v));
        case Op.lt:
            return parseOk(R.strictlyLowerThan(v));
        case Op.le:
            return parseOk(R.lowerThan(v));
        case Op.gt:
            return parseOk(R.strictlyHigherThan(v));
        case Op.ge:
            return parseOk(R.higherThan(v));
        case Op.compat:
            // `~=X.Y.Z` ≡ `>=X.Y.Z, ==X.Y.*`: at least two release segments,
            // upper bound bumps the second-to-last component.
            if (v.release.length < 2)
                return fail(base + i);
            auto lo = v;
            auto hi = releaseVersion(bumpLast(v.release[0 .. $ - 1]));
            return parseOk(R.between(lo, hi));
    }
}

/// Returns a copy of `release` with its last component incremented (and any
/// lower-significance components dropped already by the caller).
private uint[] bumpLast(in uint[] release) @safe pure nothrow
in (release.length > 0)
{
    auto next = release.dup;
    next[$ - 1] += 1;
    return next;
}

// ---------------------------------------------------------------------------
// Conformance
// ---------------------------------------------------------------------------

static assert(isVersion!PypiVersion && isVersionScheme!PypiVersion);
static assert(!hasOrderKey!PypiVersion);
static assert(supportsPrerelease!PypiVersion);
static assert(hasComponents!PypiVersion);
static assert(!hasBuildMetadata!PypiVersion);

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

@("pypi.parse.realWorld")
@safe pure
unittest
{
    import sparkles.versions.testing : checkRoundTrip;

    checkRoundTrip!PypiVersion("3.13.0a1");
    checkRoundTrip!PypiVersion("1.0.0.post1");
    checkRoundTrip!PypiVersion("2.0.0.dev1");
    checkRoundTrip!PypiVersion("1.0.0+local");
    checkRoundTrip!PypiVersion("1!2.0.0");
    checkRoundTrip!PypiVersion("1.0");
    checkRoundTrip!PypiVersion("1.0b2");
    checkRoundTrip!PypiVersion("1.0rc1");
}

@("pypi.ordering.pep440Canonical")
@safe pure
unittest
{
    import sparkles.versions.testing : checkAscending;

    // The canonical PEP 440 ordering example, verbatim.
    checkAscending!PypiVersion(
        "1.dev0", "1.0.dev456", "1.0a1", "1.0a2.dev456", "1.0a12",
        "1.0b1", "1.0b2", "1.0rc1", "1.0", "1.0.post456", "1.0.15",
        "1.1.dev1");
}

@("pypi.ordering.epochDominates")
@safe pure
unittest
{
    import sparkles.versions.testing : checkAscending;

    checkAscending!PypiVersion("1.0", "1!1.0");
    checkAscending!PypiVersion("999.0", "1!0.1");
}

@("pypi.ordering.localAfterPublic")
@safe pure
unittest
{
    auto pub = PypiVersion.parse("1.0.0").value;
    auto loc = PypiVersion.parse("1.0.0+local").value;
    assert(pub < loc);
}

@("pypi.prerelease.flag")
@safe pure
unittest
{
    assert(PypiVersion.parse("3.13.0a1").value.isPrerelease);
    assert(PypiVersion.parse("2.0.0.dev1").value.isPrerelease);
    assert(!PypiVersion.parse("1.0.0").value.isPrerelease);
    assert(!PypiVersion.parse("1.0.0.post1").value.isPrerelease);
}

@("pypi.loose.normalisation")
@safe pure
unittest
{
    import sparkles.core_cli.smallbuffer : checkToString;

    auto a = PypiVersion.parseLoose("v1.0");
    assert(a.hasValue);
    checkToString(a.value, "1.0");

    auto b = PypiVersion.parseLoose("1.0-a1");
    assert(b.hasValue);
    checkToString(b.value, "1.0a1");
}

// ---------------------------------------------------------------------------
// Native range tests (PEP 440 specifier set)
// ---------------------------------------------------------------------------

private PypiVersion pv(string s) @safe pure nothrow
    => PypiVersion.parse(s).value;

@("pypi.range.greaterEqual")
@safe pure
unittest
{
    auto r = PypiVersion.parseNativeRange(">=1.2.4");
    assert(r.hasValue);
    auto set = r.value;
    assert(!set.contains(pv("1.2.3")));
    assert(set.contains(pv("1.2.4")));
    assert(set.contains(pv("2.0.0")));
}

@("pypi.range.greaterEqualAndLess")
@safe pure
unittest
{
    auto r = PypiVersion.parseNativeRange(">=1.2.4,<2");
    assert(r.hasValue);
    auto set = r.value;
    assert(!set.contains(pv("1.2.3")));
    assert(set.contains(pv("1.2.4")));
    assert(set.contains(pv("1.9.9")));
    assert(!set.contains(pv("2.0")));
    assert(!set.contains(pv("2.1")));
}

@("pypi.range.compatibleRelease")
@safe pure
unittest
{
    // ~=1.4.5 ≡ >=1.4.5, ==1.4.* ≡ [1.4.5, 1.5)
    auto r = PypiVersion.parseNativeRange("~=1.4.5");
    assert(r.hasValue);
    auto set = r.value;
    assert(!set.contains(pv("1.4.4")));
    assert(set.contains(pv("1.4.5")));
    assert(set.contains(pv("1.4.99")));
    assert(!set.contains(pv("1.5.0")));
    assert(!set.contains(pv("2.0.0")));

    // Equivalence with the desugared form.
    auto desugared = PypiVersion.parseNativeRange(">=1.4.5,==1.4.*");
    assert(desugared.hasValue);
    assert(set == desugared.value);
}

@("pypi.range.equalsWildcard")
@safe pure
unittest
{
    // ==1.4.* ≡ [1.4, 1.5)
    auto r = PypiVersion.parseNativeRange("==1.4.*");
    assert(r.hasValue);
    auto set = r.value;
    assert(!set.contains(pv("1.3.9")));
    assert(set.contains(pv("1.4")));
    assert(set.contains(pv("1.4.0")));
    assert(set.contains(pv("1.4.7")));
    assert(!set.contains(pv("1.5")));
}

@("pypi.range.equalsAndNotEquals")
@safe pure
unittest
{
    auto eq = PypiVersion.parseNativeRange("==1.2.3");
    assert(eq.hasValue);
    assert(eq.value.contains(pv("1.2.3")));
    assert(!eq.value.contains(pv("1.2.4")));

    auto ne = PypiVersion.parseNativeRange("!=1.2.3");
    assert(ne.hasValue);
    assert(!ne.value.contains(pv("1.2.3")));
    assert(ne.value.contains(pv("1.2.4")));

    // !=1.4.* excludes the whole 1.4 series.
    auto neWild = PypiVersion.parseNativeRange("!=1.4.*");
    assert(neWild.hasValue);
    assert(!neWild.value.contains(pv("1.4.0")));
    assert(!neWild.value.contains(pv("1.4.9")));
    assert(neWild.value.contains(pv("1.5.0")));
    assert(neWild.value.contains(pv("1.3.0")));
}

@("pypi.range.strictComparators")
@safe pure
unittest
{
    auto lt = PypiVersion.parseNativeRange("<2.0").value;
    assert(lt.contains(pv("1.9")));
    assert(!lt.contains(pv("2.0")));

    auto gt = PypiVersion.parseNativeRange(">1.0").value;
    assert(!gt.contains(pv("1.0")));
    assert(gt.contains(pv("1.0.1")));

    auto le = PypiVersion.parseNativeRange("<=2.0").value;
    assert(le.contains(pv("2.0")));
    assert(!le.contains(pv("2.0.1")));
}

@("pypi.range.whitespaceAndRejects")
@safe pure
unittest
{
    // Whitespace around clauses and operators is tolerated.
    auto r = PypiVersion.parseNativeRange(">= 1.2.4 , < 2.0");
    assert(r.hasValue);
    assert(r.value.contains(pv("1.5")));
    assert(!r.value.contains(pv("2.0")));

    // Empty input and a bare wildcard on an ordered operator are rejected.
    assert(!PypiVersion.parseNativeRange("").hasValue);
    assert(!PypiVersion.parseNativeRange(">=1.4.*").hasValue);
    assert(!PypiVersion.parseNativeRange("@1.0").hasValue);
}

@("pypi.satisfies.prereleaseRule")
@safe
unittest
{
    import sparkles.versions.operations : satisfies;
    import sparkles.versions.ranges : Ranges;

    // `1.1a1` is a prerelease of the 1.1 triple; `>=1.0` names no prerelease
    // of that triple, so PypiVersion (supportsPrerelease + hasSemVerComponents)
    // excludes it via the prerelease-in-range rule.
    assert(!satisfies(pv("1.1a1"), Ranges!PypiVersion.higherThan(pv("1.0"))));

    // `1.0a2` satisfies `>=1.0a1`: the bound names a prerelease of the same
    // `1.0.0` triple.
    assert(satisfies(pv("1.0a2"), Ranges!PypiVersion.higherThan(pv("1.0a1"))));
}
