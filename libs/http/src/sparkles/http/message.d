/**
HTTP/1.1 message vocabulary and an incremental, `@nogc`-friendly request
parser (RFC 9112). The parser is a pure function over a byte slice — it owns
no I/O and no allocation — so it composes with any transport: the
`sparkles:event-horizon` verbs feed it received bytes, but so could a test
harness feeding a literal buffer.

Header storage is a fixed small array (typical requests carry few headers);
`ParseResult.incomplete` asks the caller for more bytes. This covers the
request line, headers, and `Content-Length` bodies — enough for the M13
plaintext showcase and the M14 benchmark; chunked transfer-encoding is a
documented follow-up.
*/
module sparkles.http.message;

import sparkles.base.smallbuffer : SmallBuffer;

/// The HTTP methods the parser recognizes (others parse as `unknown`).
enum Method : ubyte
{
    unknown,
    get,
    head,
    post,
    put,
    delete_,
    patch,
    options,
    connect,
    trace,
}

/// One header field (borrowed slices into the caller's buffer).
struct Header
{
    const(char)[] name;  /// field name (as received; compare case-insensitively)
    const(char)[] value; /// field value (leading/trailing OWS trimmed)
}

/// Maximum headers a parsed request retains (excess → `tooManyHeaders`).
enum size_t maxHeaders = 32;

/// A parsed request. All slices borrow the caller's byte buffer — valid only
/// while that buffer lives and is unmodified.
struct Request
{
    Method method;              /// parsed method
    const(char)[] rawMethod;    /// method token as received
    const(char)[] target;       /// request target (path + query)
    const(char)[] httpVersion;  /// e.g. "HTTP/1.1"
    Header[maxHeaders] headers; /// header fields
    size_t headerCount;         /// valid entries in `headers`
    size_t headerBytes;         /// byte length of the request-line + headers block
    size_t contentLength;       /// parsed Content-Length (0 if absent)
    bool keepAlive;             /// connection reuse per version + Connection header

    /// Looks up a header value case-insensitively; empty slice if absent.
    const(char)[] header(scope const(char)[] name) const @safe pure nothrow @nogc
    {
        foreach (i; 0 .. headerCount)
            if (asciiEqualFold(headers[i].name, name))
                return headers[i].value;
        return null;
    }
}

/// Parse outcome.
enum ParseStatus : ubyte
{
    complete,       /// a full request head was parsed
    incomplete,     /// need more bytes (no error)
    badRequest,     /// malformed request line or header
    tooManyHeaders, /// exceeded `maxHeaders`
}

/// Result of `parseRequest`.
struct ParseResult
{
    ParseStatus status;
    Request request; /// valid when `status == complete`
}

/**
Parses an HTTP/1.1 request head from `data` (up to and including the blank
line terminating the headers). Returns `incomplete` if the terminator is not
yet present — the caller reads more and retries. Borrows `data`; does not
allocate.
*/
ParseResult parseRequest(const(char)[] data) @safe pure nothrow @nogc
{
    ParseResult r;

    // The head ends at the first CRLFCRLF.
    const headEnd = findHeadEnd(data);
    if (headEnd == size_t.max)
    {
        r.status = ParseStatus.incomplete;
        return r;
    }
    auto head = data[0 .. headEnd];
    r.request.headerBytes = headEnd;

    // Request line: METHOD SP target SP version CRLF.
    const lineEnd = indexOfCrlf(head);
    if (lineEnd == size_t.max)
    {
        r.status = ParseStatus.badRequest;
        return r;
    }
    auto line = head[0 .. lineEnd];
    if (!parseRequestLine(line, r.request))
    {
        r.status = ParseStatus.badRequest;
        return r;
    }

    // Header block follows the request line.
    auto rest = head[lineEnd + 2 .. $];
    while (rest.length > 0)
    {
        const hEnd = indexOfCrlf(rest);
        const fieldLine = hEnd == size_t.max ? rest : rest[0 .. hEnd];
        if (fieldLine.length == 0)
            break; // blank line: end of headers
        if (r.request.headerCount >= maxHeaders)
        {
            r.status = ParseStatus.tooManyHeaders;
            return r;
        }
        Header h;
        if (!parseHeaderLine(fieldLine, h))
        {
            r.status = ParseStatus.badRequest;
            return r;
        }
        r.request.headers[r.request.headerCount++] = h;
        if (hEnd == size_t.max)
            break;
        rest = rest[hEnd + 2 .. $];
    }

    finalizeSemantics(r.request);
    r.status = ParseStatus.complete;
    return r;
}

// ── internals ───────────────────────────────────────────────────────────────

private size_t findHeadEnd(scope const(char)[] d) @safe pure nothrow @nogc
{
    // Look for CRLFCRLF; return index just past it (the head length).
    if (d.length < 4)
        return size_t.max;
    foreach (i; 0 .. d.length - 3)
        if (d[i] == '\r' && d[i + 1] == '\n' && d[i + 2] == '\r' && d[i + 3] == '\n')
            return i + 4;
    return size_t.max;
}

private size_t indexOfCrlf(scope const(char)[] d) @safe pure nothrow @nogc
{
    if (d.length < 2)
        return size_t.max;
    foreach (i; 0 .. d.length - 1)
        if (d[i] == '\r' && d[i + 1] == '\n')
            return i;
    return size_t.max;
}

private bool parseRequestLine(const(char)[] line, ref Request req)
    @safe pure nothrow @nogc
{
    const sp1 = indexOf(line, ' ');
    if (sp1 == size_t.max)
        return false;
    req.rawMethod = line[0 .. sp1];
    req.method = methodOf(req.rawMethod);

    auto afterMethod = line[sp1 + 1 .. $];
    const sp2 = indexOf(afterMethod, ' ');
    if (sp2 == size_t.max)
        return false;
    req.target = afterMethod[0 .. sp2];
    req.httpVersion = afterMethod[sp2 + 1 .. $];
    return req.target.length > 0 && req.httpVersion.length > 0;
}

private bool parseHeaderLine(const(char)[] line, ref Header h)
    @safe pure nothrow @nogc
{
    const colon = indexOf(line, ':');
    if (colon == size_t.max || colon == 0)
        return false;
    h.name = line[0 .. colon];
    h.value = trimOws(line[colon + 1 .. $]);
    return true;
}

private void finalizeSemantics(ref Request req) @safe pure nothrow @nogc
{
    import sparkles.base.text.readers : readInteger;

    // Content-Length.
    auto cl = req.header("content-length");
    if (cl.length > 0)
    {
        auto cursor = cl;
        auto parsed = readInteger!size_t(cursor);
        if (parsed.hasValue)
            req.contentLength = parsed.value;
    }

    // Keep-alive: HTTP/1.1 defaults to keep-alive unless Connection: close.
    const isHttp11 = asciiEqualFold(req.httpVersion, "HTTP/1.1");
    auto conn = req.header("connection");
    if (isHttp11)
        req.keepAlive = !asciiContainsFold(conn, "close");
    else
        req.keepAlive = asciiContainsFold(conn, "keep-alive");
}

private Method methodOf(scope const(char)[] m) @safe pure nothrow @nogc
{
    switch (m)
    {
        case "GET": return Method.get;
        case "HEAD": return Method.head;
        case "POST": return Method.post;
        case "PUT": return Method.put;
        case "DELETE": return Method.delete_;
        case "PATCH": return Method.patch;
        case "OPTIONS": return Method.options;
        case "CONNECT": return Method.connect;
        case "TRACE": return Method.trace;
        default: return Method.unknown;
    }
}

private size_t indexOf(scope const(char)[] d, char c) @safe pure nothrow @nogc
{
    foreach (i, ch; d)
        if (ch == c)
            return i;
    return size_t.max;
}

private const(char)[] trimOws(return scope const(char)[] s) @safe pure nothrow @nogc
{
    size_t lo, hi = s.length;
    while (lo < hi && (s[lo] == ' ' || s[lo] == '\t'))
        ++lo;
    while (hi > lo && (s[hi - 1] == ' ' || s[hi - 1] == '\t'))
        --hi;
    return s[lo .. hi];
}

private char toLowerAscii(char c) @safe pure nothrow @nogc
    => (c >= 'A' && c <= 'Z') ? cast(char)(c + 32) : c;

/// ASCII case-insensitive equality (header names/tokens are ASCII).
bool asciiEqualFold(scope const(char)[] a, scope const(char)[] b)
    @safe pure nothrow @nogc
{
    if (a.length != b.length)
        return false;
    foreach (i; 0 .. a.length)
        if (toLowerAscii(a[i]) != toLowerAscii(b[i]))
            return false;
    return true;
}

private bool asciiContainsFold(scope const(char)[] haystack, scope const(char)[] needle)
    @safe pure nothrow @nogc
{
    if (needle.length == 0 || haystack.length < needle.length)
        return false;
    foreach (i; 0 .. haystack.length - needle.length + 1)
    {
        bool match = true;
        foreach (j; 0 .. needle.length)
            if (toLowerAscii(haystack[i + j]) != toLowerAscii(needle[j]))
            {
                match = false;
                break;
            }
        if (match)
            return true;
    }
    return false;
}

@("http.parse.simpleGet")
@safe pure nothrow @nogc
unittest
{
    enum raw = "GET /hello?x=1 HTTP/1.1\r\n"
        ~ "Host: example.com\r\n"
        ~ "Content-Length: 0\r\n"
        ~ "\r\n";
    auto r = parseRequest(raw);
    assert(r.status == ParseStatus.complete);
    assert(r.request.method == Method.get);
    assert(r.request.target == "/hello?x=1");
    assert(r.request.httpVersion == "HTTP/1.1");
    assert(r.request.headerCount == 2);
    assert(r.request.header("host") == "example.com");
    assert(r.request.header("HOST") == "example.com"); // case-insensitive
    assert(r.request.contentLength == 0);
    assert(r.request.keepAlive); // HTTP/1.1 default
}

@("http.parse.incompleteAsksForMore")
@safe pure nothrow @nogc
unittest
{
    // No blank line yet: the parser must request more bytes, not error.
    enum partial = "GET / HTTP/1.1\r\nHost: x\r\n";
    assert(parseRequest(partial).status == ParseStatus.incomplete);
}

@("http.parse.connectionCloseAndBody")
@safe pure nothrow @nogc
unittest
{
    enum raw = "POST /submit HTTP/1.1\r\n"
        ~ "Content-Length: 5\r\n"
        ~ "Connection: close\r\n"
        ~ "\r\n"
        ~ "hello";
    auto r = parseRequest(raw);
    assert(r.status == ParseStatus.complete);
    assert(r.request.method == Method.post);
    assert(r.request.contentLength == 5);
    assert(!r.request.keepAlive); // Connection: close
    // The body follows headerBytes.
    assert(raw[r.request.headerBytes .. $] == "hello");
}

@("http.parse.malformedRejected")
@safe pure nothrow @nogc
unittest
{
    assert(parseRequest("GET\r\n\r\n").status == ParseStatus.badRequest);
    assert(parseRequest("GET / HTTP/1.1\r\nBadHeaderNoColon\r\n\r\n").status
        == ParseStatus.badRequest);
}
