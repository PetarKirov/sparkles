/++
HTML templating over IES (Interpolated Expression Sequences), the sibling of
[`styled_template`](./styled_template.d)
([design](../../../../docs/specs/base/html-template.md), `HTL1`–`HTL15`).

```d
writeHtml(w, i`<a class=$(cls) href="/users/$(id)/profile?q=$(q)">$(name)</a>`);
```

Four interpolations, four escapes, none of them named by the caller: `cls` is
quoted and entity-escaped, `id` is percent-encoded as a $(I path segment) (so a
`/` inside it cannot open a new one), `q` as a $(I query component) (so an `&`
cannot append a parameter), `name` entity-escaped as text. The escape follows
from $(B where the value lands), and only the library sees both the literal
skeleton and the value — which is the whole reason this is a template and not a
concatenation.

The classification happens during CTFE: a byte scanner walks the
`InterpolatedLiteral` parts, and each interpolation's context is a template
constant by the time code is generated (`HTL2`). Nothing about the scan
survives into the binary — a value compiles to one call to the escape its
context selected, straight into the caller's output range, with no intermediate
buffer (`HTL13`, `HTL15`).

Placements that no escape can rescue do not compile, and the message names the
offending expression's own source text (`HTL3`):

```
Error: static assert:  "`cls` interpolates into a tag or attribute NAME
position: HTML structure must be static (docs/specs/base/html-template.md HTL7)"
```

$(H2 What is not here)

`raw`, `attrs`, `json`/`cssValue` and the `Expected`-returning arm are `HTLM3`
and `HTLM4`; this module is `HTLM1` + `HTLM2` — the scanner, the text and
attribute contexts, and the URL contexts.
+/
module sparkles.base.html_template;

import core.interpolation;

import sparkles.base.text.html : writeHtmlEscaped;
import sparkles.base.text.percent : encodePercent, percentComponent,
    percentPathSegment, PercentSet;
import sparkles.base.text.writers : writeValue;

// ─────────────────────────────────────────────────────────────────────────────
// Public surface
// ─────────────────────────────────────────────────────────────────────────────

/++
Writes the interpolated HTML literal to `w`, escaping every interpolated value
for the context the skeleton puts it in (`HTL1`).

Attributes are inferred and the path allocates nothing (`HTL15`): with a
`@nogc` writer and values whose conversion is `@nogc` (everything
$(LREF sparkles.base.text.writers.writeValue) handles natively), this is
`@safe pure nothrow @nogc`.
+/
void writeHtml(Writer, Args...)(
    ref Writer w, InterpolationHeader, Args args, InterpolationFooter)
{
    import std.range.primitives : put;

    enum contexts = contextsOf!Args;

    static foreach (idx, arg; args)
    {{
        alias T = typeof(arg);
        static if (is(T == InterpolatedLiteral!lit, string lit))
            put(w, lit);
        else static if (is(T == InterpolatedExpression!code, string code))
        {
            enum ctx = contexts[exprIndexAt!(idx, Args)];
            static assert(ctx != HtmlContext.tagName && ctx != HtmlContext.attrName,
                "`" ~ code ~ "` interpolates into a tag or attribute NAME position:"
                ~ " HTML structure must be static"
                ~ " (docs/specs/base/html-template.md HTL7)");
            static assert(ctx != HtmlContext.rawText,
                "`" ~ code ~ "` interpolates into a <script>/<style> element, where"
                ~ " no escape is safe — pass json(…) / cssValue(…) instead"
                ~ " (docs/specs/base/html-template.md HTL8)");
            static assert(ctx != HtmlContext.comment,
                "`" ~ code ~ "` interpolates into an HTML comment, where `--` and `>`"
                ~ " terminate unpredictably (docs/specs/base/html-template.md HTL9)");
            static assert(ctx != HtmlContext.unquotedTail,
                "`" ~ code ~ "` continues an UNQUOTED attribute value; quote the"
                ~ " attribute so the value cannot end at a space"
                ~ " (docs/specs/base/html-template.md HTL4)");
        }
        else
        {
            // The value follows its own `InterpolatedExpression` marker.
            enum ctx = contexts[exprIndexAt!(idx - 1, Args)];
            writeInContext!ctx(w, arg);
        }
    }}
}

/++
The interpolated HTML literal as a fresh string. Allocates (GC) — the
`@nogc` path is $(LREF writeHtml) into a caller-owned range.
+/
string htmlText(Args...)(InterpolationHeader header, Args args, InterpolationFooter footer)
{
    import std.array : appender;

    auto w = appender!string;
    writeHtml(w, header, args, footer);
    return w[];
}

/// A value the URL policy rejected is replaced by this, never emitted and never
/// silently dropped (`HTL6`). `about:invalid` is the WHATWG-blessed inert URL.
enum unsafeUrlPlaceholder = "about:invalid#unsafe-scheme";

// ─────────────────────────────────────────────────────────────────────────────
// Contexts
// ─────────────────────────────────────────────────────────────────────────────

/// Where an interpolation lands, as decided by the literal skeleton (`HTL1`).
enum HtmlContext
{
    text,          /// outside any tag: `<p>HERE</p>`
    attrQuoted,    /// inside a quoted attribute value: `<p class="HERE">`
    attrUnquoted,  /// the whole of an unquoted value: `<p class=HERE>` (auto-quoted)
    unquotedTail,  /// continuing an unquoted value: `<p class=a-HERE>` — rejected
    urlWhole,          /// a quoted URL attribute the value fills: `<a href="HERE">`
    urlWholeUnquoted,  /// the same, unquoted: `<a href=HERE>` (auto-quoted)
    urlPath,       /// inside a URL, before `?`/`#`: `<a href="/u/HERE">`
    urlQuery,      /// inside a URL, after `?`: `<a href="/s?q=HERE">`
    urlFragment,   /// inside a URL, after `#`: `<a href="/p#HERE">`
    tagName,       /// `<HERE …>` — rejected
    attrName,      /// `<p HERE="1">` — rejected
    rawText,       /// inside `<script>`/`<style>` — rejected
    comment,       /// inside `<!-- … -->` — rejected
}

/++
The attributes whose value is a URL, and therefore percent-encoded rather than
merely entity-escaped (`HTL5`). Matched case-insensitively.
+/
bool isUrlAttribute(scope const(char)[] name) @safe pure nothrow @nogc
{
    switch (name)
    {
        case "href", "src", "action", "formaction", "cite", "poster", "data",
            "ping", "manifest", "srcset", "background", "longdesc":
            return true;
        default:
            return false;
    }
}

///
@("html_template.isUrlAttribute")
@safe pure nothrow @nogc
unittest
{
    assert(isUrlAttribute("href") && isUrlAttribute("src") && isUrlAttribute("poster"));
    assert(!isUrlAttribute("class") && !isUrlAttribute("hreflang") && !isUrlAttribute(""));
}

// ─────────────────────────────────────────────────────────────────────────────
// The skeleton scanner (CTFE)
// ─────────────────────────────────────────────────────────────────────────────

/// Longest attribute name the scanner remembers. Only the URL-attribute test
/// reads it, and the longest of those is `background` — a longer name is
/// truncated, which can only make it *not* match, never match wrongly.
private enum maxAttrName = 24;

/// Elements whose content is raw text: no character references, so nothing can
/// be escaped into them (`HTL8`).
private bool isRawTextElement(scope const(char)[] name) @safe pure nothrow @nogc
{
    switch (name)
    {
        case "script", "style", "textarea", "title":
            return true;
        default:
            return false;
    }
}

/++
The scanner's state between literal parts. Deliberately a plain value with
fixed storage: it is folded through CTFE, and `@nogc` keeps it usable (and
testable) at run time as well.
+/
struct SkeletonScan
{
    private
    {
        bool inTag;          // between `<name` and `>`
        bool readingName;    // still inside the tag's name
        bool afterEq;        // an `=` was seen, a value is expected/underway
        bool valueStarted;   // the current attribute value has literal bytes
        bool urlAttr;        // the current attribute takes a URL
        bool sawQuery;       // a `?` appeared in the current URL value
        bool sawFragment;    // a `#` appeared in the current URL value
        bool tagIsRawText;   // the tag being opened is script/style/…
        bool endTag;         // the tag being read is `</name>`, which opens nothing
        bool inRawText;      // inside such an element's content
        bool inComment;      // inside `<!-- … -->`
        char quote;          // active attribute quote, 0 when unquoted
        char[maxAttrName] nameBuf;
        ubyte nameLen;

        void resetName() @safe pure nothrow @nogc
        {
            nameLen = 0;
        }

        void appendName(char c) @safe pure nothrow @nogc
        {
            if (nameLen < nameBuf.length)
                nameBuf[nameLen++] = lower(c);
        }

        const(char)[] name() const return @safe pure nothrow @nogc
            => nameBuf[0 .. nameLen];
    }
}

private char lower(char c) @safe pure nothrow @nogc
    => c >= 'A' && c <= 'Z' ? cast(char)(c + 32) : c;

private bool isSpace(char c) @safe pure nothrow @nogc
    => c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f';

/++
Advances `s` over one literal part.

A single pass, no lookbehind: every decision the context model makes
($(LREF contextAt)) is a field of the state, so an interpolation can sit
anywhere — including mid-attribute, mid-URL, or between two tags.
+/
void advance(ref SkeletonScan s, scope const(char)[] lit) @safe pure nothrow @nogc
{
    size_t i = 0;
    while (i < lit.length)
    {
        const c = lit[i];

        if (s.inComment)
        {
            if (c == '-' && i + 2 < lit.length && lit[i + 1] == '-' && lit[i + 2] == '>')
            {
                s.inComment = false;
                i += 3;
                continue;
            }
            ++i;
            continue;
        }

        if (s.inRawText)
        {
            // Leaves at the element's own end tag; any other `<` is content.
            if (c == '<' && i + 1 < lit.length && lit[i + 1] == '/')
            {
                s.inRawText = false;
                s.inTag = true;
                s.readingName = true;
                s.endTag = true;
                s.resetName();
                i += 2;
                continue;
            }
            ++i;
            continue;
        }

        if (!s.inTag)
        {
            if (c == '<')
            {
                if (i + 3 < lit.length && lit[i + 1] == '!' && lit[i + 2] == '-'
                    && lit[i + 3] == '-')
                {
                    s.inComment = true;
                    i += 4;
                    continue;
                }
                s.inTag = true;
                s.readingName = true;
                s.tagIsRawText = false;
                s.endTag = false;
                s.afterEq = false;
                s.quote = 0;
                s.resetName();
                if (i + 1 < lit.length && lit[i + 1] == '/')
                {
                    s.endTag = true;
                    ++i; // the `/` belongs to the delimiter, not the name
                }
            }
            ++i;
            continue;
        }

        // ── inside a tag ────────────────────────────────────────────────────
        if (s.quote)
        {
            if (c == s.quote)
                s.endAttribute();
            else
            {
                s.valueStarted = true;
                if (s.urlAttr)
                {
                    if (c == '?')
                        s.sawQuery = true;
                    else if (c == '#')
                        s.sawFragment = true;
                }
            }
            ++i;
            continue;
        }

        if (s.readingName)
        {
            if (isSpace(c) || c == '>' || c == '/')
            {
                s.tagIsRawText = !s.endTag && isRawTextElement(s.name);
                s.readingName = false;
                s.resetName();
                // fall through so `>` closes the tag on this iteration
            }
            else
            {
                s.appendName(c);
                ++i;
                continue;
            }
        }

        if (c == '>')
        {
            s.inTag = false;
            s.inRawText = s.tagIsRawText;
            s.afterEq = false;
            s.resetName();
            ++i;
            continue;
        }

        if (c == '=' && !s.afterEq)
        {
            s.afterEq = true;
            s.valueStarted = false;
            s.urlAttr = isUrlAttribute(s.name);
            s.sawQuery = false;
            s.sawFragment = false;
            ++i;
            continue;
        }

        if (s.afterEq && !s.valueStarted && (c == '"' || c == '\''))
        {
            s.quote = c;
            ++i;
            continue;
        }

        if (isSpace(c))
        {
            if (s.afterEq)
                s.endAttribute(); // an unquoted value ends at whitespace
            else
                s.resetName();
            ++i;
            continue;
        }

        if (s.afterEq)
        {
            s.valueStarted = true;
            if (s.urlAttr)
            {
                if (c == '?')
                    s.sawQuery = true;
                else if (c == '#')
                    s.sawFragment = true;
            }
        }
        else
            s.appendName(c);
        ++i;
    }
}

private void endAttribute(ref SkeletonScan s) @safe pure nothrow @nogc
{
    s.quote = 0;
    s.afterEq = false;
    s.valueStarted = false;
    s.urlAttr = false;
    s.sawQuery = false;
    s.sawFragment = false;
    s.resetName();
}

/// The context an interpolation lands in, given the state before it (`HTL1`).
HtmlContext contextAt(in SkeletonScan s) @safe pure nothrow @nogc
{
    if (s.inComment)
        return HtmlContext.comment;
    if (s.inRawText)
        return HtmlContext.rawText;
    if (!s.inTag)
        return HtmlContext.text;
    if (s.readingName)
        return HtmlContext.tagName;

    if (s.quote)
    {
        if (!s.urlAttr)
            return HtmlContext.attrQuoted;
        if (!s.valueStarted)
            return HtmlContext.urlWhole;
        if (s.sawFragment)
            return HtmlContext.urlFragment;
        return s.sawQuery ? HtmlContext.urlQuery : HtmlContext.urlPath;
    }

    if (s.afterEq)
    {
        // Unquoted: the emitter adds the quotes (`HTL4`), which it can only do
        // when the interpolation is the *whole* value.
        if (s.valueStarted)
            return HtmlContext.unquotedTail;
        return s.urlAttr ? HtmlContext.urlWholeUnquoted : HtmlContext.attrUnquoted;
    }
    return HtmlContext.attrName;
}

/// Every interpolation's context, in order — folded over the literal parts at
/// compile time (`HTL2`).
private template contextsOf(Args...)
{
    enum contextsOf = () {
        SkeletonScan s;
        HtmlContext[] found;
        static foreach (A; Args)
        {{
            static if (is(A == InterpolatedLiteral!lit, string lit))
                advance(s, lit);
            else static if (is(A == InterpolatedExpression!code, string code))
                found ~= contextAt(s);
        }}
        return found;
    }();
}

/// The number of interpolated expressions strictly before tuple position `idx`
/// — i.e. the index into $(LREF contextsOf) of the one *at* `idx`.
private template exprIndexAt(size_t idx, Args...)
{
    enum exprIndexAt = () {
        size_t n;
        static foreach (i, A; Args)
        {{
            static if (i < idx && is(A == InterpolatedExpression!c, string c))
                ++n;
        }}
        return n;
    }();
}

// ─────────────────────────────────────────────────────────────────────────────
// Escaping sinks — the reason nothing is buffered (HTL15)
// ─────────────────────────────────────────────────────────────────────────────

/++
An output range that entity-escapes what is written through it.

The value is rendered $(I into) this, so `writeValue`'s bytes are escaped as
they are produced — no "render to a temporary, then escape" step, which is what
would otherwise force an allocation.
+/
private struct HtmlEscapeSink(Writer)
{
    private Writer* target;

    void put(char c)
    {
        char[1] one = c;
        writeHtmlEscaped(*target, one[]);
    }

    void put(scope const(char)[] s)
    {
        writeHtmlEscaped(*target, s);
    }
}

/++
Percent-encodes under `set`, then entity-escapes, in one sink (`HTL5`).

The two stages are fused rather than chained because a chain would mean taking
the address of a `scope` local, which `@safe` dip1000 rightly refuses. Fusing
also keeps the URL path one level deep: a byte either becomes `%XX` (already
inert in an attribute) or survives percent-encoding and is then entity-escaped,
which is where a `&` or `'` the set leaves unreserved is dealt with.

Percent-encoding is a stateless per-byte escape, so encoding a byte at a time
gives the same bytes as encoding the slice.
+/
private struct PercentHtmlSink(PercentSet set, Writer)
{
    private Writer* target;

    void put(char c)
    {
        import sparkles.base.smallbuffer : SmallBuffer;

        // The longest single-byte expansion is `%XX`; a value buffer keeps this
        // allocation-free and free of pointers to locals.
        SmallBuffer!(char, 4) staged;
        char[1] one = c;
        encodePercent!set(staged, one[]);
        writeHtmlEscaped(*target, staged[]);
    }

    void put(scope const(char)[] s)
    {
        foreach (char c; s)
            put(c);
    }
}

/++
Guards a whole-URL interpolation (`HTL6`): a value that carries its own scheme
cannot be percent-encoded (that would destroy `://`), so the scheme is checked
instead.

Streaming, not buffering-the-whole-value: only the scheme can decide, and a
scheme is short. Bytes are held until the verdict — a `:` (scheme present) or a
byte that cannot appear in one (the URL is relative, hence harmless) — then
either flushed and passed through, or dropped in favour of
$(LREF unsafeUrlPlaceholder). $(LREF finish) covers a value that ends while
still undecided.
+/
private struct UrlSchemeSink(Writer)
{
    private
    {
        enum State { deciding, dataPrefix, passing, blocked }

        Writer* target;
        State state;
        char[maxScheme] held;
        ubyte heldLen;

        enum maxScheme = 16;
        enum dataImage = "image/";
    }

    void put(char c) scope
    {
        final switch (state)
        {
            case State.passing:
                emit(c);
                return;
            case State.blocked:
                return;
            case State.dataPrefix:
                // `data:` is allowed only for images; collect just enough to tell.
                if (heldLen < dataImage.length)
                {
                    held[heldLen++] = lower(c);
                    if (heldLen == dataImage.length)
                    {
                        if (held[0 .. heldLen] == dataImage)
                        {
                            state = State.passing;
                            emit("data:");
                            emit(held[0 .. heldLen]);
                        }
                        else
                            block();
                    }
                }
                return;
            case State.deciding:
                if (c == ':')
                {
                    decide();
                    // `decide` may have moved us to dataPrefix/passing/blocked;
                    // the colon itself is emitted by whichever it chose.
                    return;
                }
                if (!isSchemeChar(c) || heldLen == held.length)
                {
                    // No scheme here: a relative URL, or something longer than any
                    // scheme. Either way there is nothing to reject.
                    state = State.passing;
                    emit(held[0 .. heldLen]);
                    heldLen = 0;
                    emit(c);
                    return;
                }
                held[heldLen++] = c;
                return;
        }
    }

    void put(scope const(char)[] s) scope
    {
        if (state == State.passing)
        {
            emit(s); // the common case, one call
            return;
        }
        foreach (char c; s)
            put(c);
    }

    /// Flushes a value that ended before the scheme question was settled.
    void finish() scope
    {
        final switch (state)
        {
            case State.deciding:
                emit(held[0 .. heldLen]);
                heldLen = 0;
                state = State.passing;
                return;
            case State.dataPrefix:
                block(); // `data:` with nothing after it
                return;
            case State.passing:
            case State.blocked:
                return;
        }
    }

    private void decide() scope
    {
        const scheme = held[0 .. heldLen];
        if (equalsIgnoreCase(scheme, "javascript") || equalsIgnoreCase(scheme, "vbscript"))
        {
            block();
            return;
        }
        if (equalsIgnoreCase(scheme, "data"))
        {
            state = State.dataPrefix;
            heldLen = 0;
            return;
        }
        state = State.passing;
        emit(scheme);
        heldLen = 0;
        emit(':');
    }

    private void block() scope
    {
        state = State.blocked;
        heldLen = 0;
        emit(unsafeUrlPlaceholder);
    }

    private void emit(char c) scope
    {
        char[1] one = c;
        writeHtmlEscaped(*target, one[]);
    }

    private void emit(scope const(char)[] s) scope
    {
        writeHtmlEscaped(*target, s);
    }
}

/// ASCII case-insensitive comparison — a scheme is case-insensitive
/// (RFC 3986 §3.1), so `VBScript:` must be recognised as `vbscript:`.
private bool equalsIgnoreCase(scope const(char)[] a, scope const(char)[] b)
    @safe pure nothrow @nogc
{
    if (a.length != b.length)
        return false;
    foreach (i, char c; a)
        if (lower(c) != lower(b[i]))
            return false;
    return true;
}

private bool isSchemeChar(char c) @safe pure nothrow @nogc
    => (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
        || c == '+' || c == '-' || c == '.';

/// Renders `value` into `w` with the escape `ctx` calls for (`HTL1`, §4 of the
/// design). Every arm writes straight through a sink — no temporaries.
private void writeInContext(HtmlContext ctx, Writer, T)(ref Writer w, auto ref const T value)
{
    import std.range.primitives : put;

    static if (ctx == HtmlContext.text || ctx == HtmlContext.attrQuoted)
    {
        scope sink = HtmlEscapeSink!Writer(&w);
        writeValue(sink, value);
    }
    else static if (ctx == HtmlContext.attrUnquoted)
    {
        put(w, '"');
        scope sink = HtmlEscapeSink!Writer(&w);
        writeValue(sink, value);
        put(w, '"');
    }
    else static if (ctx == HtmlContext.urlWhole || ctx == HtmlContext.urlWholeUnquoted)
    {
        // The scanner reports the unquoted form only when nothing has started
        // the value, so adding the quotes here is always well-formed (`HTL4`).
        static if (ctx == HtmlContext.urlWholeUnquoted)
            put(w, '"');
        scope sink = UrlSchemeSink!Writer(&w);
        writeValue(sink, value);
        sink.finish();
        static if (ctx == HtmlContext.urlWholeUnquoted)
            put(w, '"');
    }
    else static if (ctx == HtmlContext.urlPath || ctx == HtmlContext.urlQuery
        || ctx == HtmlContext.urlFragment)
    {
        // A query or fragment interpolation is one value, so the strict
        // component set applies: `&`, `=` and `#` must not survive it. A path
        // segment keeps `pchar` but escapes `/`, so a segment stays one segment.
        static if (ctx == HtmlContext.urlPath)
            enum set = percentPathSegment;
        else
            enum set = percentComponent;

        scope sink = PercentHtmlSink!(set, Writer)(&w);
        writeValue(sink, value);
    }
    else
        static assert(0, "context rejected earlier: " ~ ctx.stringof);
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

/// Text content is entity-escaped: markup in a value stays a value.
@("html_template.text.escapesMarkup")
@safe unittest
{
    const name = "<script>alert('x')</script>";
    assert(htmlText(i`<p>Hello, $(name)!</p>`)
        == "<p>Hello, &lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt;!</p>");
}

/// A quoted attribute value cannot break out of its quotes.
@("html_template.attribute.defeatsInjection")
@safe unittest
{
    const cls = `a" onload="evil()`;
    assert(htmlText(i`<p class="$(cls)">x</p>`)
        == `<p class="a&quot; onload=&quot;evil()">x</p>`);
    assert(htmlText(i`<p class='$(cls)'>x</p>`)
        == `<p class='a&quot; onload=&quot;evil()'>x</p>`);
}

/// An unquoted attribute value is quoted by the emitter (`HTL4`) — a value with
/// a space would otherwise become a second attribute.
@("html_template.attribute.autoQuotes")
@safe unittest
{
    const cls = "two words";
    assert(htmlText(i`<p class=$(cls)>x</p>`) == `<p class="two words">x</p>`);
}

/// Inside a URL, a path segment is percent-encoded — `/` included, so an
/// interpolated segment cannot open another one (`HTL5`).
@("html_template.url.pathSegment")
@safe unittest
{
    const seg = "a/../b c";
    assert(htmlText(i`<a href="/files/$(seg)">f</a>`)
        == `<a href="/files/a%2F..%2Fb%20c">f</a>`);
}

/// A query component escapes `&` and `=`, so a value cannot append parameters.
@("html_template.url.queryComponent")
@safe unittest
{
    const term = "rock & roll=x";
    const id = 65;
    assert(htmlText(i`<a href="/users/$(id)?q=$(term)">l</a>`)
        == `<a href="/users/65?q=rock%20%26%20roll%3Dx">l</a>`);
}

/// A fragment is percent-encoded under its own set.
@("html_template.url.fragment")
@safe unittest
{
    const anchor = "a b#c";
    assert(htmlText(i`<a href="/p#$(anchor)">l</a>`) == `<a href="/p#a%20b%23c">l</a>`);
}

/// A value that *is* the whole URL is scheme-checked rather than encoded — a
/// percent-encoded `://` would not be a URL at all (`HTL6`).
@("html_template.url.wholeValuePassesSafeSchemes")
@safe unittest
{
    const abs = "https://example.com/a?b=1&c=2";
    assert(htmlText(i`<a href="$(abs)">l</a>`)
        == `<a href="https://example.com/a?b=1&amp;c=2">l</a>`);

    const rel = "/local/path?x=1";
    assert(htmlText(i`<a href="$(rel)">l</a>`) == `<a href="/local/path?x=1">l</a>`);

    const mail = "mailto:someone@example.com";
    assert(htmlText(i`<a href=$(mail)>l</a>`) == `<a href="mailto:someone@example.com">l</a>`);
}

/// A scripting scheme is replaced, never emitted and never silently dropped.
@("html_template.url.rejectsScriptingSchemes")
@safe unittest
{
    const js = "javascript:alert(1)";
    assert(htmlText(i`<a href="$(js)">l</a>`)
        == `<a href="about:invalid#unsafe-scheme">l</a>`);

    const vb = "VBScript:msgbox(1)";
    assert(htmlText(i`<a href="$(vb)">l</a>`)
        == `<a href="about:invalid#unsafe-scheme">l</a>`);

    // `data:` is allowed for images and refused otherwise.
    const png = "data:image/png;base64,iVBOR";
    assert(htmlText(i`<img src="$(png)">`) == `<img src="data:image/png;base64,iVBOR">`);
    const evil = "data:text/html,<script>alert(1)</script>";
    assert(htmlText(i`<img src="$(evil)">`) == `<img src="about:invalid#unsafe-scheme">`);
}

/// A value that ends mid-verdict (no scheme, nothing to reject) still arrives.
@("html_template.url.shortValueFlushes")
@safe unittest
{
    const short_ = "ab";
    assert(htmlText(i`<a href="$(short_)">l</a>`) == `<a href="ab">l</a>`);
    const empty = "";
    assert(htmlText(i`<a href="$(empty)">l</a>`) == `<a href="">l</a>`);
    const dataOnly = "data:";
    assert(htmlText(i`<a href="$(dataOnly)">l</a>`)
        == `<a href="about:invalid#unsafe-scheme">l</a>`);
}

/// Non-string values render through `writeValue`, like `styled_template` (`HTL14`).
@("html_template.values.renderThroughWriteValue")
@safe unittest
{
    const n = 42;
    const flag = true;
    assert(htmlText(i`<p data-n=$(n) data-f=$(flag)>$(n)</p>`)
        == `<p data-n="42" data-f="true">42</p>`);
}

/// The classification survives an interpolation-free literal, several tags, and
/// values in a row.
@("html_template.mixedSkeleton")
@safe unittest
{
    const cls = "row";
    const href = "/a b";
    const label = "R&D";
    assert(htmlText(i`<ul><li class="$(cls)"><a href="/x/$(href)">$(label)</a></li></ul>`)
        == `<ul><li class="row"><a href="/x/%2Fa%20b">R&amp;D</a></li></ul>`);
}

/// The whole path is `@safe pure nothrow @nogc` with a `@nogc` writer (`HTL15`).
@("html_template.writeHtml.isNogc")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.smallbuffer : SmallBuffer;

    SmallBuffer!(char, 256) buf;
    const cls = "c";
    const seg = "a/b";
    const n = 7;
    writeHtml(buf, i`<a class="$(cls)" href="/x/$(seg)?n=$(n)">t</a>`);
    assert(buf[] == `<a class="c" href="/x/a%2Fb?n=7">t</a>`);
}

/// The four rejected placements do not compile (`HTL3`, `HTL7`–`HTL9`, `HTL4`).
/// `__traits(compiles)` sees the `static assert`s inside `writeHtml`; what a
/// caller sees is the message, which names the expression by its source text.
@("html_template.rejects.doNotCompile")
@safe unittest
{
    const x = "v";

    // tag name and attribute name: structure must be static
    static assert(!__traits(compiles, htmlText(i`<$(x)>hi</$(x)>`)));
    static assert(!__traits(compiles, htmlText(i`<div $(x)="1">hi</div>`)));
    // raw-text elements have no character references
    static assert(!__traits(compiles, htmlText(i`<script>var v = $(x);</script>`)));
    static assert(!__traits(compiles, htmlText(i`<style>.a { color: $(x); }</style>`)));
    // comments terminate unpredictably
    static assert(!__traits(compiles, htmlText(i`<!-- $(x) -->`)));
    // continuing an unquoted value: quote it instead
    static assert(!__traits(compiles, htmlText(i`<p class=a-$(x)>hi</p>`)));

    // …and the shapes just outside each of those DO compile.
    static assert(__traits(compiles, htmlText(i`<div class="$(x)">hi</div>`)));
    static assert(__traits(compiles, htmlText(i`<p>$(x)</p>`)));
    static assert(__traits(compiles, htmlText(i`<script>var v = 1;</script><p>$(x)</p>`)));
}

/// The scanner is a value type usable outside CTFE, and reports the context of
/// a position reached by any sequence of parts.
@("html_template.scanner.contexts")
@safe pure nothrow @nogc
unittest
{
    SkeletonScan s;
    advance(s, "<p>");
    assert(contextAt(s) == HtmlContext.text);
    advance(s, `<a class="`);
    assert(contextAt(s) == HtmlContext.attrQuoted);
    advance(s, `x" href="/p/`);
    assert(contextAt(s) == HtmlContext.urlPath);
    advance(s, "y?q=");
    assert(contextAt(s) == HtmlContext.urlQuery);
    advance(s, "1#");
    assert(contextAt(s) == HtmlContext.urlFragment);
    advance(s, `">`);
    assert(contextAt(s) == HtmlContext.text);
}

/// Rejected positions are classified (the `static assert`s in `writeHtml` are
/// what a caller sees; here the classification itself is pinned).
@("html_template.scanner.rejectedContexts")
@safe pure nothrow @nogc
unittest
{
    SkeletonScan tag;
    advance(tag, "<");
    assert(contextAt(tag) == HtmlContext.tagName);

    SkeletonScan attr;
    advance(attr, "<div ");
    assert(contextAt(attr) == HtmlContext.attrName);

    SkeletonScan script;
    advance(script, "<script>var x = ");
    assert(contextAt(script) == HtmlContext.rawText);
    advance(script, "1;</script>");
    assert(contextAt(script) == HtmlContext.text);

    SkeletonScan style;
    advance(style, "<style>.a{color:");
    assert(contextAt(style) == HtmlContext.rawText);

    SkeletonScan comment;
    advance(comment, "<p><!-- ");
    assert(contextAt(comment) == HtmlContext.comment);
    advance(comment, " -->");
    assert(contextAt(comment) == HtmlContext.text);

    SkeletonScan tail;
    advance(tail, "<p class=a-");
    assert(contextAt(tail) == HtmlContext.unquotedTail);
}

/// An end tag is not an attribute-name position, and a self-closing tag leaves
/// the tag properly.
@("html_template.scanner.endAndVoidTags")
@safe pure nothrow @nogc
unittest
{
    SkeletonScan s;
    advance(s, "<p>a</p>");
    assert(contextAt(s) == HtmlContext.text);

    SkeletonScan v;
    advance(v, `<img src="/a.png"/>`);
    assert(contextAt(v) == HtmlContext.text);

    SkeletonScan t;
    advance(t, "<textarea>");
    assert(contextAt(t) == HtmlContext.rawText);
    advance(t, "</textarea>");
    assert(contextAt(t) == HtmlContext.text);
}

/// Attribute names are matched case-insensitively, and a non-URL attribute
/// whose name merely starts like one is not treated as a URL.
@("html_template.scanner.attributeNameMatching")
@safe pure nothrow @nogc
unittest
{
    SkeletonScan s;
    advance(s, `<a HREF="/p/`);
    assert(contextAt(s) == HtmlContext.urlPath);

    SkeletonScan t;
    advance(t, `<a hreflang="`);
    assert(contextAt(t) == HtmlContext.attrQuoted);
}
