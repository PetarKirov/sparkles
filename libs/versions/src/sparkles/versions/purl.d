/**
pURL interop — the `pkg:` Package-URL surface this library $(B consumes).

[pURL](https://github.com/package-url/purl-spec) (Package URL) names a
package across ecosystems with the URI form

```
pkg:<type>/<namespace>/<name>@<version>?<qualifiers>#<subpath>
```

where `type` and `name` are required, `namespace` is optional and may itself
contain `/`, and the `version`, `qualifiers`, and `subpath` are optional.
This module parses that surface into a $(LREF PackageUrl); it does $(B not)
generate purls (SPEC §10).

Two facilities:

$(UL
    $(LI The URI surface — $(LREF PackageUrl) and $(LREF parsePurl):
        `pkg:` scheme validation, type lowercasing, `#subpath` /
        `?qualifiers` / `@version` splitting, namespace/name separation, and
        percent-decoding of each component. No version is typed at this
        layer — the raw `ver` string is handed on verbatim.)
    $(LI The non-identity type → scheme mapping —
        $(LREF purlTypeToSchemeName): a CTFE table folding the many
        SemVer-shaped ecosystem purl types (`npm`, `cargo`, `gem`,
        `composer`, `golang`, `hex`, `conan`, `nginx`, `mozilla`, `github`,
        and `semver` itself) onto the single `"semver"` scheme, with
        `pypi`/`maven`/`deb`/`generic` mapping to their own schemes. This is
        the static counterpart to
        $(REF schemeForPurlType, sparkles,versions,schemes,registry): a purl
        type is resolved to a scheme struct via
        `schemeForPurlType!(purlTypeToSchemeName(type))`.)
)

The purl `type` does not always equal the scheme verbatim (e.g.
`pkg:npm/…` is interpreted with the `semver` scheme), so dispatch routes
through the mapping table rather than identity.

See `docs/specs/versions/SPEC.md` §10 (pURL interop) and §3.1 / PRESETS §3.1
(the SemVer-shaped ecosystem purl types).
*/
module sparkles.versions.purl;

import sparkles.versions.any : AnyVersion;
import sparkles.versions.parsing :
    ParseError, ParseErrorCode, ParseExpected, parseErr, parseOk;

@safe:

// ---------------------------------------------------------------------------
// The URI surface
// ---------------------------------------------------------------------------

/**
The parsed surface of a `pkg:` Package-URL: the lowercased `type`, the
optional `namespace` (which may contain `/`), the required `name`, the raw
`ver` string (untyped — not yet parsed against any scheme), the parsed
`qualifiers` map, and the optional `subpath`. All components are
percent-decoded.

`parsePurl` populates this from the URI text. The `ver` field is deliberately
left as raw text: typing it requires a scheme, which the pURL dispatch layer
selects via $(LREF purlTypeToSchemeName).
*/
struct PackageUrl
{
    /// The package type, lowercased: `"pypi"`, `"npm"`, `"deb"`, `"maven"`, …
    string type;

    /// The optional namespace; empty when absent. May contain `/`.
    string namespace;

    /// The required package name (the last path segment).
    string name;

    /// The raw version string; empty when absent. Not yet parsed.
    string ver;

    /// The parsed `?key=value&key=value` qualifiers; empty when absent.
    string[string] qualifiers;

    /// The optional `#subpath`; empty when absent.
    string subpath;
}

/**
Parses the `pkg:` Package-URL surface of `s` into a $(LREF PackageUrl).

Implements the purl-spec grammar
`pkg:<type>/<namespace>/<name>@<version>?<qualifiers>#<subpath>`:

$(UL
    $(LI Requires the `pkg:` URI scheme.)
    $(LI Lowercases the `type` (the segment before the first `/`).)
    $(LI Splits off `#subpath`, then `?qualifiers` (`k=v&k=v`), then
        `@version`, in that order.)
    $(LI Splits the remaining path into the `namespace` (everything up to the
        last `/`, possibly empty and possibly containing further `/`) and the
        `name` (the last segment).)
    $(LI Percent-decodes every component.)
)

Errors (with the byte offset of the offending position):

$(UL
    $(LI `emptyInput` — `s` is empty.)
    $(LI `unexpectedCharacter` — a missing `pkg:` prefix, or a malformed
        percent-escape.)
    $(LI `unexpectedEnd` — a missing `type` or a missing `name`.)
)
*/
ParseExpected!PackageUrl parsePurl(string s) @safe
{
    import std.ascii : toLower;

    if (s.length == 0)
        return parseErr!PackageUrl(ParseError(ParseErrorCode.emptyInput, 0));

    // Require the `pkg:` URI scheme (case-insensitive per purl-spec).
    enum prefix = "pkg:";
    if (s.length < prefix.length || !startsWithCI(s, prefix))
        return parseErr!PackageUrl(
            ParseError(ParseErrorCode.unexpectedCharacter, 0));

    string rest = s[prefix.length .. $];

    // Per purl-spec, leading slashes after `pkg:` are ignored.
    while (rest.length && rest[0] == '/')
        rest = rest[1 .. $];

    // Split off `#subpath` first.
    string subpathRaw;
    {
        const i = indexOf(rest, '#');
        if (i != -1)
        {
            subpathRaw = rest[i + 1 .. $];
            rest = rest[0 .. i];
        }
    }

    // Then `?qualifiers`.
    string qualifiersRaw;
    {
        const i = indexOf(rest, '?');
        if (i != -1)
        {
            qualifiersRaw = rest[i + 1 .. $];
            rest = rest[0 .. i];
        }
    }

    // Split the `type` off the front (before the first `/`).
    const slash = indexOf(rest, '/');
    if (slash == -1)
        return parseErr!PackageUrl(
            ParseError(ParseErrorCode.unexpectedEnd, prefix.length));

    string typeRaw = rest[0 .. slash];
    if (typeRaw.length == 0)
        return parseErr!PackageUrl(
            ParseError(ParseErrorCode.unexpectedEnd, prefix.length));

    string pathPart = rest[slash + 1 .. $];

    // Then `@version` off the (remaining) path tail. The `@` belongs to the
    // last path segment, so search from the last `/`.
    string verRaw;
    {
        const lastSlash = lastIndexOf(pathPart, '/');
        const searchFrom = lastSlash == -1 ? 0 : lastSlash + 1;
        const at = indexOf(pathPart[searchFrom .. $], '@');
        if (at != -1)
        {
            const abs = searchFrom + at;
            verRaw = pathPart[abs + 1 .. $];
            pathPart = pathPart[0 .. abs];
        }
    }

    // Split the path into namespace (everything up to the last `/`) and name
    // (the last segment).
    string namespaceRaw, nameRaw;
    {
        const i = lastIndexOf(pathPart, '/');
        if (i != -1)
        {
            namespaceRaw = pathPart[0 .. i];
            nameRaw = pathPart[i + 1 .. $];
        }
        else
        {
            nameRaw = pathPart;
        }
    }

    if (nameRaw.length == 0)
        return parseErr!PackageUrl(
            ParseError(ParseErrorCode.unexpectedEnd, s.length));

    // Lowercase the type (the scheme label is case-insensitive); the type is
    // a bare identifier and is never percent-encoded.
    auto typeBuf = new char[typeRaw.length];
    foreach (i, char c; typeRaw)
        typeBuf[i] = c.toLower;

    // Percent-decode every other component. The namespace is decoded
    // per-segment so an encoded `%2F` stays inside a segment.
    auto ns = percentDecodePath(namespaceRaw);
    if (!ns.hasValue)
        return parseErr!PackageUrl(ns.error);
    auto nm = percentDecode(nameRaw);
    if (!nm.hasValue)
        return parseErr!PackageUrl(nm.error);
    auto vr = percentDecode(verRaw);
    if (!vr.hasValue)
        return parseErr!PackageUrl(vr.error);
    auto sp = percentDecode(subpathRaw);
    if (!sp.hasValue)
        return parseErr!PackageUrl(sp.error);

    auto quals = parseQualifiers(qualifiersRaw);
    if (!quals.hasValue)
        return parseErr!PackageUrl(quals.error);

    return parseOk(PackageUrl(
        type: typeBuf.idup,
        namespace: ns.value,
        name: nm.value,
        ver: vr.value,
        qualifiers: quals.value,
        subpath: sp.value,
    ));
}

// ---------------------------------------------------------------------------
// purl type → scheme name mapping (non-identity)
// ---------------------------------------------------------------------------

/**
Maps a (lowercased) purl `type` to the name of the built-in scheme that
interprets its version strings, at compile time.

The mapping is $(B not) identity: every SemVer-shaped ecosystem purl type —
`npm`, `cargo`, `gem`, `composer`, `packagist`, `golang`, `hex`, `conan`,
`nginx`, `mozilla`, `github`, and `semver` itself — folds onto the single
`"semver"` scheme (SPEC §3.1 / PRESETS §3.1; `packagist` is Composer's
historical purl type, so it shares the SemVer value grammar). The remaining published types map to their
own scheme: `pypi`→`"pypi"`, `maven`→`"maven"`, `deb`→`"deb"`,
`generic`→`"generic"`.

An unrecognised purl type returns the empty string; callers should treat that
as "no built-in scheme" and either fall back to `"generic"` or report an
error. The returned name is intended to feed
$(REF schemeForPurlType, sparkles,versions,schemes,registry):
`schemeForPurlType!(purlTypeToSchemeName(type))` resolves the scheme struct.
*/
string purlTypeToSchemeName(string purlType) @safe pure nothrow @nogc
{
    switch (purlType)
    {
        // SemVer-shaped ecosystems (PRESETS §3.1).
        case "semver":
        case "npm":
        case "cargo":
        case "gem":
        case "composer":
        case "golang":
        case "hex":
        case "conan":
        case "nginx":
        case "mozilla":
        case "github":
        case "packagist":
            return "semver";

        // Schemes published under their own type.
        case "pypi":
            return "pypi";
        case "maven":
            return "maven";
        case "deb":
            return "deb";
        case "generic":
            return "generic";

        default:
            return null;
    }
}

/// `true` when `purlType` maps to a known built-in scheme — the non-failing
/// probe behind $(LREF purlTypeToSchemeName), useful in `static if`.
bool hasSchemeNameForPurlType(string purlType) @safe pure nothrow @nogc
    => purlTypeToSchemeName(purlType).length != 0;

// ---------------------------------------------------------------------------
// Runtime dispatch — parsePurlVersion → AnyVersion
// ---------------------------------------------------------------------------

/**
Parses a `pkg:` Package-URL and returns its version typed as an
$(REF AnyVersion, sparkles,versions,any) — the runtime pURL entry point
(SPEC §10).

The pipeline:

$(UL
    $(LI $(LREF parsePurl) the URI into a $(LREF PackageUrl).)
    $(LI Map `type` through $(LREF purlTypeToSchemeName) onto a built-in
        scheme name (the non-identity fold — `npm`/`cargo`/… all become
        `"semver"`).)
    $(LI Resolve that name to a scheme struct via
        $(REF schemeForPurlType, sparkles,versions,schemes,registry) and call
        its `parse` on the raw `ver` string, wrapping the result in
        `AnyVersion`.)
)

Errors:

$(UL
    $(LI Any $(LREF parsePurl) surface error is propagated verbatim.)
    $(LI An unknown / unmapped purl `type` (no built-in scheme) is
        `unexpectedCharacter` at offset 0.)
    $(LI A missing version (`pkg:npm/foo` with no `@version`) is
        `emptyInput`.)
    $(LI A version that the resolved scheme rejects propagates that scheme's
        `parse` error.)
)
*/
ParseExpected!AnyVersion parsePurlVersion(string purlUri) @safe
{
    import sparkles.versions.schemes.registry :
        publishedSchemeEntries, schemeForPurlType;

    auto purl = parsePurl(purlUri);
    if (!purl.hasValue)
        return parseErr!AnyVersion(purl.error);

    const schemeName = purlTypeToSchemeName(purl.value.type);
    if (schemeName.length == 0)
        return parseErr!AnyVersion(
            ParseError(ParseErrorCode.unexpectedCharacter, 0));

    // A missing `@version` component is `unexpectedEnd` (distinct from
    // `emptyInput`, which `parsePurl` uses for a wholly empty URI string).
    if (purl.value.ver.length == 0)
        return parseErr!AnyVersion(
            ParseError(ParseErrorCode.unexpectedEnd, purlUri.length));

    const ver = purl.value.ver;

    // Generate a runtime switch over the published scheme catalogue: each arm
    // recovers the scheme struct statically and folds its parse result into
    // AnyVersion. The mapped `schemeName` is always a published purlType, so a
    // matching arm exists.
    switch (schemeName)
    {
        static foreach (e; publishedSchemeEntries)
        {
        case e.purlType:
            {
                alias Scheme = schemeForPurlType!(e.purlType);
                auto pv = Scheme.parse(ver);
                if (!pv.hasValue)
                    return parseErr!AnyVersion(pv.error);
                return parseOk(AnyVersion(pv.value));
            }
        }
        default:
            return parseErr!AnyVersion(
                ParseError(ParseErrorCode.unexpectedCharacter, 0));
    }
}

// ---------------------------------------------------------------------------
// Internal text helpers
// ---------------------------------------------------------------------------

/// First index of `c` in `s`, or `-1`.
private ptrdiff_t indexOf(string s, char c) @safe pure nothrow @nogc
{
    foreach (i, char ch; s)
        if (ch == c)
            return i;
    return -1;
}

/// Last index of `c` in `s`, or `-1`.
private ptrdiff_t lastIndexOf(string s, char c) @safe pure nothrow @nogc
{
    foreach_reverse (i, char ch; s)
        if (ch == c)
            return i;
    return -1;
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

/// Percent-decodes each `/`-separated segment of `path` independently and
/// rejoins with `/`, per the purl-spec: an encoded `%2F` inside a segment
/// decodes to a literal `/` *within* that segment without becoming a
/// separator. Used for the namespace, which may span several segments.
private ParseExpected!string percentDecodePath(string path) @safe
{
    import std.algorithm.searching : canFind;

    if (!path.canFind('/'))
        return percentDecode(path);

    import std.array : appender, split;

    auto w = appender!string;
    bool first = true;
    foreach (seg; path.split('/'))
    {
        if (!first)
            w.put('/');
        first = false;
        auto d = percentDecode(seg);
        if (!d.hasValue)
            return d;
        w.put(d.value);
    }
    return parseOk(w[]);
}

/// Percent-decodes `s` (`%XX` → byte). A `%` not followed by two hex digits
/// is a malformed escape (`unexpectedCharacter`). Components with no `%`
/// short-circuit to the original slice (no allocation).
private ParseExpected!string percentDecode(string s) @safe pure nothrow
{
    if (indexOf(s, '%') == -1)
        return parseOk(s);

    auto buf = new char[s.length];
    size_t n = 0;
    for (size_t i = 0; i < s.length;)
    {
        if (s[i] == '%')
        {
            if (i + 2 >= s.length)
                return parseErr!string(
                    ParseError(ParseErrorCode.unexpectedCharacter, i));
            const hi = hexDigit(s[i + 1]);
            const lo = hexDigit(s[i + 2]);
            if (hi < 0 || lo < 0)
                return parseErr!string(
                    ParseError(ParseErrorCode.unexpectedCharacter, i));
            buf[n++] = cast(char)((hi << 4) | lo);
            i += 3;
        }
        else
        {
            buf[n++] = s[i];
            i++;
        }
    }
    return parseOk(cast(string) buf[0 .. n].idup);
}

/// The value of an ASCII hex digit, or `-1` when `c` is not a hex digit.
private int hexDigit(char c) @safe pure nothrow @nogc
{
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'a' && c <= 'f')
        return c - 'a' + 10;
    if (c >= 'A' && c <= 'F')
        return c - 'A' + 10;
    return -1;
}

/// Parses a `k=v&k=v` qualifier string into a map, percent-decoding each
/// value. Empty segments and keyless segments are skipped; keys are
/// lowercased per purl-spec.
private ParseExpected!(string[string]) parseQualifiers(string s) @safe
{
    import std.ascii : toLower;

    string[string] result;
    if (s.length == 0)
        return parseOk(result);

    foreach (segment; splitOn(s, '&'))
    {
        if (segment.length == 0)
            continue;
        const eq = indexOf(segment, '=');
        if (eq <= 0)
            continue; // keyless or empty-key segment — skip
        string keyRaw = segment[0 .. eq];
        string valRaw = segment[eq + 1 .. $];

        auto keyBuf = new char[keyRaw.length];
        foreach (i, char c; keyRaw)
            keyBuf[i] = c.toLower;

        auto val = percentDecode(valRaw);
        if (!val.hasValue)
            return parseErr!(string[string])(val.error);

        result[keyBuf.idup] = val.value;
    }

    return parseOk(result);
}

/// Splits `s` on `sep` into its segments (allocating the slice array). Used
/// only by the qualifier parser, where the segment count is small.
private string[] splitOn(string s, char sep) @safe pure nothrow
{
    string[] parts;
    size_t start = 0;
    foreach (i, char c; s)
        if (c == sep)
        {
            parts ~= s[start .. i];
            start = i + 1;
        }
    parts ~= s[start .. $];
    return parts;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

// The `@` version separator, kept as its own token so the test source never
// contains a literal `name@version` (which trips email-redaction tooling).
private enum string AT = "@";

@("purl.parsePurl.pypi")
@safe
unittest
{
    auto r = parsePurl("pkg:pypi/django" ~ AT ~ "1.11.1");
    assert(r.hasValue);
    assert(r.value.type == "pypi");
    assert(r.value.namespace == "");
    assert(r.value.name == "django");
    assert(r.value.ver == "1.11.1");
    assert(r.value.qualifiers.length == 0);
    assert(r.value.subpath == "");
}

@("purl.parsePurl.npm")
@safe
unittest
{
    auto r = parsePurl("pkg:npm/lodash" ~ AT ~ "4.17.21");
    assert(r.hasValue);
    assert(r.value.type == "npm");
    assert(r.value.name == "lodash");
    assert(r.value.ver == "4.17.21");

    // npm folds onto the semver scheme.
    assert(purlTypeToSchemeName(r.value.type) == "semver");
}

@("purl.parsePurl.namespaced.deb")
@safe
unittest
{
    auto r = parsePurl("pkg:deb/debian/curl" ~ AT ~ "7.50.3-1");
    assert(r.hasValue);
    assert(r.value.type == "deb");
    assert(r.value.namespace == "debian");
    assert(r.value.name == "curl");
    assert(r.value.ver == "7.50.3-1");
    assert(purlTypeToSchemeName(r.value.type) == "deb");
}

@("purl.parsePurl.maven.dottedNamespace")
@safe
unittest
{
    auto r = parsePurl(
        "pkg:maven/org.apache.commons/io" ~ AT ~ "1.3.2");
    assert(r.hasValue);
    assert(r.value.type == "maven");
    assert(r.value.namespace == "org.apache.commons");
    assert(r.value.name == "io");
    assert(r.value.ver == "1.3.2");
    assert(purlTypeToSchemeName(r.value.type) == "maven");
}

@("purl.parsePurl.nestedNamespace")
@safe
unittest
{
    // golang namespaces contain `/`: everything up to the last `/` is the
    // namespace, the last segment is the name.
    auto r = parsePurl(
        "pkg:golang/google.golang.org/genproto/googleapis"
        ~ AT ~ "abcdef");
    assert(r.hasValue);
    assert(r.value.type == "golang");
    assert(r.value.namespace == "google.golang.org/genproto");
    assert(r.value.name == "googleapis");
    assert(r.value.ver == "abcdef");
    assert(purlTypeToSchemeName(r.value.type) == "semver");
}

@("purl.parsePurl.qualifiersAndSubpath")
@safe
unittest
{
    auto r = parsePurl(
        "pkg:maven/org.apache.xmlgraphics/batik-anim" ~ AT ~ "1.9.1"
        ~ "?classifier=sources&type=zip#sub/dir");
    assert(r.hasValue);
    assert(r.value.namespace == "org.apache.xmlgraphics");
    assert(r.value.name == "batik-anim");
    assert(r.value.ver == "1.9.1");
    assert(r.value.subpath == "sub/dir");
    assert(r.value.qualifiers["classifier"] == "sources");
    assert(r.value.qualifiers["type"] == "zip");
}

@("purl.parsePurl.percentDecoding")
@safe
unittest
{
    // `%20` decodes to a space inside the name; `%2B` to `+` in the version.
    auto r = parsePurl("pkg:generic/a%20b" ~ AT ~ "1.0%2Bbuild");
    assert(r.hasValue);
    assert(r.value.name == "a b");
    assert(r.value.ver == "1.0+build");
}

@("purl.parsePurl.lowercasesType")
@safe
unittest
{
    auto r = parsePurl("pkg:NPM/foo" ~ AT ~ "1.0.0");
    assert(r.hasValue);
    assert(r.value.type == "npm");
}

@("purl.parsePurl.ignoresLeadingSlashes")
@safe
unittest
{
    auto r = parsePurl("pkg://npm/foo" ~ AT ~ "1.0.0");
    assert(r.hasValue);
    assert(r.value.type == "npm");
    assert(r.value.name == "foo");
    assert(r.value.ver == "1.0.0");
}

@("purl.parsePurl.noVersion")
@safe
unittest
{
    auto r = parsePurl("pkg:npm/lodash");
    assert(r.hasValue);
    assert(r.value.name == "lodash");
    assert(r.value.ver == "");
}

@("purl.parsePurl.rejects")
@safe
unittest
{
    assert(!parsePurl("").hasValue);                 // empty
    assert(!parsePurl("npm/foo" ~ AT ~ "1.0").hasValue); // no pkg: prefix
    assert(!parsePurl("pkg:npm").hasValue);          // no `/` → no name
    assert(!parsePurl("pkg:/foo" ~ AT ~ "1.0").hasValue); // empty type
    assert(!parsePurl("pkg:npm/").hasValue);         // empty name
    assert(!parsePurl("pkg:npm/foo%2").hasValue);    // truncated escape
    assert(!parsePurl("pkg:npm/foo%zz").hasValue);   // bad hex escape
}

@("purl.purlTypeToSchemeName.semverShaped")
@safe pure nothrow @nogc
unittest
{
    static foreach (t; ["semver", "npm", "cargo", "gem", "composer",
            "packagist", "golang", "hex", "conan", "nginx", "mozilla", "github"])
        assert(purlTypeToSchemeName(t) == "semver");
}

@("purl.purlTypeToSchemeName.ownScheme")
@safe pure nothrow @nogc
unittest
{
    assert(purlTypeToSchemeName("pypi") == "pypi");
    assert(purlTypeToSchemeName("maven") == "maven");
    assert(purlTypeToSchemeName("deb") == "deb");
    assert(purlTypeToSchemeName("generic") == "generic");
}

@("purl.purlTypeToSchemeName.unknown")
@safe pure nothrow @nogc
unittest
{
    assert(purlTypeToSchemeName("nonexistent") is null);
    assert(!hasSchemeNameForPurlType("nonexistent"));
    assert(hasSchemeNameForPurlType("npm"));
}

@("purl.purlTypeToSchemeName.resolvesViaRegistry")
@safe
unittest
{
    // The mapped name feeds schemeForPurlType to recover the scheme struct.
    import sparkles.versions.schemes.registry : schemeForPurlType;
    import sparkles.versions.schemes.semver : SemVer;
    import sparkles.versions.schemes.pypi : PypiVersion;

    static assert(is(schemeForPurlType!(purlTypeToSchemeName("npm")) == SemVer));
    static assert(
        is(schemeForPurlType!(purlTypeToSchemeName("pypi")) == PypiVersion));
}

@("purl.parsePurlVersion.pypi")
@safe
unittest
{
    import sparkles.versions.any : AnyVersion;
    import sparkles.versions.schemes.pypi : PypiVersion;
    import std.sumtype : match;

    auto r = parsePurlVersion("pkg:pypi/django" ~ AT ~ "3.13.0a1");
    assert(r.hasValue);

    // The AnyVersion holds a PypiVersion equal to the natively-parsed one.
    const expected = PypiVersion.parse("3.13.0a1").value;
    r.value.match!(
        (PypiVersion v) => assert(v == expected),
        _ => assert(false, "expected PypiVersion"),
    );
}

@("purl.parsePurlVersion.npmFoldsToSemVer")
@safe
unittest
{
    import sparkles.versions.any : AnyVersion;
    import sparkles.versions.schemes.semver : SemVer;
    import std.sumtype : match;

    // npm folds onto the semver scheme, so the result holds a SemVer.
    auto r = parsePurlVersion("pkg:npm/lodash" ~ AT ~ "4.17.21");
    assert(r.hasValue);

    const expected = SemVer.parse("4.17.21").value;
    r.value.match!(
        (SemVer v) => assert(v == expected),
        _ => assert(false, "expected SemVer"),
    );
}

@("purl.parsePurlVersion.deb")
@safe
unittest
{
    import sparkles.versions.schemes.deb : DebianVersion;
    import std.sumtype : match;

    auto r = parsePurlVersion("pkg:deb/debian/curl" ~ AT ~ "7.50.3-1");
    assert(r.hasValue);

    const expected = DebianVersion.parse("7.50.3-1").value;
    r.value.match!(
        (DebianVersion v) => assert(v == expected),
        _ => assert(false, "expected DebianVersion"),
    );
}

@("purl.parsePurlVersion.rejects")
@safe
unittest
{
    // Unknown purl type → no built-in scheme.
    assert(!parsePurlVersion("pkg:nonexistent/foo" ~ AT ~ "1.0.0").hasValue);

    // Missing version.
    assert(!parsePurlVersion("pkg:npm/lodash").hasValue);

    // Bad version for the resolved scheme.
    assert(!parsePurlVersion("pkg:npm/lodash" ~ AT ~ "not-a-version").hasValue);

    // Surface error (no pkg: prefix) is propagated.
    assert(!parsePurlVersion("npm/foo" ~ AT ~ "1.0.0").hasValue);
}
