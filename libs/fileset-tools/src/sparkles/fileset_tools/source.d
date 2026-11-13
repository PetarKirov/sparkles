/**
Naming a source (`XS1`, docs/specs/fsx): a directory, a `file:` URI, or an
iroh ticket, bare or after `iroh:` or `web+iroh-sendme:`.
*/
module sparkles.fileset_tools.source;

import std.algorithm.searching : startsWith;

/// What a source names.
enum SourceKind : ubyte
{
    local, /// a directory
    iroh,  /// a collection a `sendme` ticket names
}

/// A source, as the command line named it.
struct SourceName
{
    SourceKind kind; ///
    string path;     /// a local source's directory
    string ticket;   /// an iroh source's ticket, without a scheme
}

/// What the parse found: a source, or why the text names none.
struct ParsedSource
{
    SourceName source; ///
    string error;      /// empty when `source` is one

    ///
    bool ok() const @safe pure nothrow @nogc => error.length == 0;
}

/**
Whether `text` has the shape of a `sendme` ticket: `blob` and then lowercase
base32, as `sendme send` prints one. The bridge parses it in full when the
source is opened; this only tells a ticket from a path.
*/
bool looksLikeTicket(scope const(char)[] text) @safe pure nothrow @nogc
{
    if (text.length < 40 || !text.startsWith("blob"))
        return false;
    foreach (c; text[4 .. $])
        if (!((c >= 'a' && c <= 'z') || (c >= '2' && c <= '7')))
            return false;
    return true;
}

/**
The source `text` names (`XS1`). `exists` says whether a path is there, so
that a directory named like a ticket stays reachable as a path.
*/
ParsedSource parseSource(string text, scope bool delegate(string) @safe exists) @safe
{
    ParsedSource r;
    if (text.length == 0)
    {
        r.error = "an empty source: expected a directory, a file: URI or an iroh ticket";
        return r;
    }
    foreach (scheme; ["iroh:", "web+iroh-sendme:"])
        if (text.startsWith(scheme))
        {
            const ticket = text[scheme.length .. $];
            if (!looksLikeTicket(ticket))
            {
                r.error = "`" ~ text ~ "`: " ~ scheme ~ " is followed by a sendme ticket, `blob` and base32";
                return r;
            }
            r.source = SourceName(SourceKind.iroh, null, ticket);
            return r;
        }
    if (text.startsWith("file:"))
    {
        auto path = fileUriPath(text);
        if (path is null)
        {
            r.error = "`" ~ text ~ "`: a file: URI names a local path, as file:///dir";
            return r;
        }
        r.source = SourceName(SourceKind.local, path, null);
        return r;
    }
    if (looksLikeTicket(text) && !exists(text))
    {
        r.source = SourceName(SourceKind.iroh, null, text);
        return r;
    }
    r.source = SourceName(SourceKind.local, text, null);
    return r;
}

/// The path a `file:` URI names: `file:///a/b` and `file:/a/b` name `/a/b`,
/// with `%XX` escapes decoded; `null` for a URI with a host.
string fileUriPath(string uri) @safe pure
{
    string rest = uri["file:".length .. $];
    if (rest.startsWith("//"))
    {
        rest = rest[2 .. $];
        if (rest.startsWith("localhost/"))
            rest = rest["localhost".length .. $];
        if (!rest.startsWith("/"))
            return null; // file://host/path names another machine
    }
    if (!rest.startsWith("/"))
        return null;
    string path;
    for (size_t i = 0; i < rest.length; ++i)
    {
        if (rest[i] == '%' && i + 2 < rest.length && isHex(rest[i + 1]) && isHex(rest[i + 2]))
        {
            path ~= cast(char)(hexValue(rest[i + 1]) * 16 + hexValue(rest[i + 2]));
            i += 2;
        }
        else
            path ~= rest[i];
    }
    version (Windows)
    {
        // file:///C:/dir names C:/dir.
        if (path.length >= 3 && path[0] == '/' && path[2] == ':')
            path = path[1 .. $];
    }
    return path;
}

private bool isHex(char c) @safe pure nothrow @nogc
    => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');

private uint hexValue(char c) @safe pure nothrow @nogc
    => c <= '9' ? c - '0' : (c | 0x20) - 'a' + 10;

///
@("fileset_tools.source.parseSource")
@safe unittest
{
    enum ticket = "blobadd6ooplaj7pgoz7sebzgm5oe5gpaqqyznbno4evdgft76adzf6nkajdnb2hi4dthixs6";
    bool nothing(string) @safe => false;
    bool everything(string) @safe => true;

    auto dir = parseSource("src", &nothing);
    assert(dir.ok && dir.source == SourceName(SourceKind.local, "src", null));
    foreach (form; [ticket, "iroh:" ~ ticket, "web+iroh-sendme:" ~ ticket])
    {
        auto t = parseSource(form, &nothing);
        assert(t.ok && t.source == SourceName(SourceKind.iroh, null, ticket), form);
    }
    // A directory named like a ticket is the directory, and `./` says so.
    assert(parseSource(ticket, &everything).source.kind == SourceKind.local);
    assert(parseSource("./" ~ ticket, &nothing).source == SourceName(SourceKind.local, "./" ~ ticket, null));

    assert(parseSource("file:///tmp/a%20b", &nothing).source.path == "/tmp/a b");
    assert(parseSource("file://localhost/tmp", &nothing).source.path == "/tmp");
    assert(!parseSource("file://host/tmp", &nothing).ok);
    assert(!parseSource("iroh:not-a-ticket", &nothing).ok);
    assert(!parseSource("", &nothing).ok);
}
