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

import expected : Expected, err, ok;

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
void writeHtml(HtmlCheck check = HtmlCheck.fragment, Writer, Args...)(
    ref Writer w, InterpolationHeader header, Args args, InterpolationFooter footer)
{
    cast(void) writeHtmlImpl!check(w, header, args, footer);
}

/++
$(LREF writeHtml), reporting what it had to substitute rather than only doing
it (`HTL6`, `HTL11`).

The write path is `nothrow`, so a rejected URL or a malformed attribute name
cannot throw; the output is still safe either way (the placeholder is written,
the bad pair is dropped), and this arm is how a caller learns it happened. The
first problem wins — one report per template keeps the result a plain value.
+/
Expected!(void, HtmlError) writeHtmlChecked(HtmlCheck check = HtmlCheck.fragment,
    Writer, Args...)(ref Writer w, InterpolationHeader header, Args args,
    InterpolationFooter footer)
{
    HtmlError e = writeHtmlImpl!check(w, header, args, footer);
    if (e.code == HtmlErrorCode.none)
        return ok!HtmlError();
    return err!void(e);
}

private HtmlError writeHtmlImpl(HtmlCheck check, Writer, Args...)(
    ref Writer w, InterpolationHeader, Args args, InterpolationFooter)
{
    import std.range.primitives : put;

    enum contexts = contextsOf!Args;
    enum skeleton = skeletonReport!(check, Args);
    static assert(skeleton.length == 0, skeleton);

    HtmlError firstError;

    static foreach (idx, arg; args)
    {{
        alias T = typeof(arg);
        static if (is(T == InterpolatedLiteral!lit, string lit))
            put(w, lit);
        else static if (is(T == InterpolatedExpression!code, string code))
        {
            enum ctx = contexts[exprIndexAt!(idx, Args)];
            alias V = typeof(args[idx + 1]);
            static assert(placementIsAllowed!(ctx, V), placementRefusal!(ctx, V, code));
        }
        else
        {
            // The value follows its own `InterpolatedExpression` marker.
            enum ctx = contexts[exprIndexAt!(idx - 1, Args)];
            enum code = expressionAt!(idx - 1, Args);
            const problem = writeInContext!ctx(w, arg);
            if (problem != HtmlErrorCode.none
                && firstError.code == HtmlErrorCode.none)
                firstError = HtmlError(problem, code);
        }
    }}

    return firstError;
}

/// How much structure a template must have on its own (`HTL10`).
enum HtmlCheck
{
    /++
    A fragment of a page: quotes, comments and raw-text elements must close,
    and an end tag must match the element it closes, but an element may be left
    open for a later template to close (which is how a page shell is written).
    +/
    fragment,

    /// Also: every element the template opens, it closes.
    balanced,
}

/// What `writeHtmlChecked` reports (`HTL6`, `HTL11`).
enum HtmlErrorCode
{
    none,
    unsafeUrlScheme,      /// a `javascript:`-family URL, replaced by the placeholder
    invalidAttributeName, /// an `attrs`/`attr` pair whose name is not a name
}

/// ditto — with the interpolated expression's own source text, so a report
/// names the same thing the compile-time refusals do.
struct HtmlError
{
    HtmlErrorCode code;
    string expression;

    void toString(Writer)(ref Writer w) const
    {
        import std.range.primitives : put;

        put(w, "`");
        put(w, expression);
        put(w, code == HtmlErrorCode.unsafeUrlScheme
            ? "` is a URL with a scripting scheme; wrote " ~ unsafeUrlPlaceholder
            : "` carries an attribute name that is not a valid HTML name");
    }
}

/++
The interpolated HTML literal as a fresh string. Allocates (GC) — the
`@nogc` path is $(LREF writeHtml) into a caller-owned range.
+/
string htmlText(HtmlCheck check = HtmlCheck.fragment, Args...)(
    InterpolationHeader header, Args args, InterpolationFooter footer)
{
    import std.array : appender;

    auto w = appender!string;
    writeHtml!check(w, header, args, footer);
    return w[];
}

/// A value the URL policy rejected is replaced by this, never emitted and never
/// silently dropped (`HTL6`). `about:invalid` is the WHATWG-blessed inert URL.
enum unsafeUrlPlaceholder = "about:invalid#unsafe-scheme";

// ─────────────────────────────────────────────────────────────────────────────
// Escape hatches — the explicit, greppable ways past the escaping (HTL11/HTL12)
// ─────────────────────────────────────────────────────────────────────────────

/++
Markup that is already correct for where it lands, written verbatim (`HTL11`).

The one unescaped path in the module, and deliberately a named type rather than
a flag: `raw` at the call site is what a reviewer greps for. It is accepted in
text and quoted-attribute positions only — inside a URL, an unquoted attribute
or a raw-text element there is no such thing as "already escaped", so those stay
compile errors.

`immutable` payload, so a `raw` cannot borrow a buffer that outlives the call.
+/
struct HtmlFragment
{
    string markup;
}

/// ditto
HtmlFragment raw(string markup) @safe pure nothrow @nogc => HtmlFragment(markup);

/++
The result of $(LREF htmlText) is itself an $(LREF HtmlFragment), so templates
compose without double-escaping (`HTL12`):

```d
const row = htmlText(i`<td>$(cell)</td>`);
writeHtml(w, i`<tr>$(row)</tr>`);   // `row` is written as-is
```
+/
alias htmlFragment = raw;

/++
One attribute, rendered in the attribute-name position of a tag (`HTL11`):

```d
writeHtml(w, i`<input $(attr("value", v)) $(attr("disabled", locked))>`);
```

A `bool` makes it a boolean attribute — present or absent, never `="false"`.
A name that is not a valid HTML name is dropped and reported
($(LREF HtmlErrorCode.invalidAttributeName)), because a name cannot be escaped
into safety (`HTL7`).
+/
struct Attr
{
    const(char)[] name;
    const(char)[] value;
    bool boolean;  /// a boolean attribute: rendered as the bare name
    bool present = true;
}

/// ditto
Attr attr(const(char)[] name, const(char)[] value) @safe pure nothrow @nogc
    => Attr(name: name, value: value);

/// ditto
Attr attr(const(char)[] name, bool present) @safe pure nothrow @nogc
    => Attr(name: name, boolean: true, present: present);

/++
A spread of attributes in the same position, from any input range of
$(LREF Attr) (`HTL11`):

```d
Attr[2] a = [attr("class", cls), attr("hidden", !visible)];
writeHtml(w, i`<div $(attrs(a[]))>…</div>`);
```
+/
struct Attrs(R)
{
    R pairs;
}

/// ditto
Attrs!R attrs(R)(R pairs) => Attrs!R(pairs);

/++
A value for `<script>` (`HTL8`): JSON, with `<`, `>`, `&` and the two line
separators escaped as `\uXXXX`, so the text cannot contain `</script` — the
only thing that ends a raw-text element.

Strings are quoted and escaped; `bool`, integers and floats are written as JSON
literals; anything else renders through `writeValue` and is quoted.
+/
struct JsonValue(T)
{
    T value;
}

/// ditto
JsonValue!T json(T)(T value) => JsonValue!T(value);

/++
A value for `<style>` (`HTL8`): every byte outside a conservative CSS-safe set
becomes a `\HH ` escape — including `<`, so the text cannot contain `</style`,
and including `\`, `"`, `'`, `;`, `{`, `}` and `(`, so it cannot end a
declaration or open a function.
+/
struct CssValue
{
    const(char)[] value;
}

/// ditto
CssValue cssValue(const(char)[] value) @safe pure nothrow @nogc => CssValue(value);

/++
Whether a value of type `V` may be interpolated into `ctx`.

The plain-value rules are `HTL7`–`HTL9`; the wrappers each unlock exactly the
context they exist for, and nothing else — a `raw` in a URL, or a `json` in text,
is a mistake worth catching rather than a shortcut.
+/
private template placementIsAllowed(HtmlContext ctx, V)
{
    static if (is(immutable V == immutable HtmlFragment))
        enum placementIsAllowed = ctx == HtmlContext.text
            || ctx == HtmlContext.attrQuoted;
    else static if (is(V == Attrs!R, R) || is(immutable V == immutable Attr))
        enum placementIsAllowed = ctx == HtmlContext.attrName;
    else static if (is(V == JsonValue!T, T) || is(immutable V == immutable CssValue))
        enum placementIsAllowed = ctx == HtmlContext.rawText;
    else
        enum placementIsAllowed = ctx != HtmlContext.tagName
            && ctx != HtmlContext.attrName
            && ctx != HtmlContext.rawText
            && ctx != HtmlContext.comment
            && ctx != HtmlContext.unquotedTail;
}

/// The compile-time message for a placement $(LREF placementIsAllowed) refuses.
private template placementRefusal(HtmlContext ctx, V, string code)
{
    enum where = "`" ~ code ~ "` interpolates into ";
    enum see = " (docs/specs/base/html-template.md ";

    static if (is(immutable V == immutable HtmlFragment))
        enum placementRefusal = where ~ "a position raw markup cannot be trusted"
            ~ " in — `raw` is accepted in text and quoted attributes only" ~ see ~ "HTL11)";
    else static if (is(V == Attrs!R, R) || is(immutable V == immutable Attr))
        enum placementRefusal = where ~ "a value position, but `attr`/`attrs`"
            ~ " render attribute NAMES — put them where an attribute would go,"
            ~ " as `<div $(…)>`" ~ see ~ "HTL11)";
    else static if (is(V == JsonValue!T, T) || is(immutable V == immutable CssValue))
        enum placementRefusal = where ~ "a position outside <script>/<style>;"
            ~ " a plain value belongs there instead" ~ see ~ "HTL8)";
    else static if (ctx == HtmlContext.tagName || ctx == HtmlContext.attrName)
        enum placementRefusal = where ~ "a tag or attribute NAME position: HTML"
            ~ " structure must be static (use attr/attrs for a dynamic"
            ~ " attribute)" ~ see ~ "HTL7)";
    else static if (ctx == HtmlContext.rawText)
        enum placementRefusal = where ~ "a <script>/<style> element, where no"
            ~ " escape is safe — pass json(…) / cssValue(…) instead" ~ see ~ "HTL8)";
    else static if (ctx == HtmlContext.comment)
        enum placementRefusal = where ~ "an HTML comment, where `--` and `>`"
            ~ " terminate unpredictably" ~ see ~ "HTL9)";
    else
        enum placementRefusal = where ~ "the middle of an UNQUOTED attribute"
            ~ " value; quote the attribute so the value cannot end at a space"
            ~ see ~ "HTL4)";
}

/// The interpolated expression's source text at tuple position `idx`.
private template expressionAt(size_t idx, Args...)
{
    static if (is(Args[idx] == InterpolatedExpression!code, string code))
        enum expressionAt = code;
    else
        enum expressionAt = "";
}

/++
The skeleton's structural verdict as a compile-time message (`HTL10`), empty
when it is sound. Folded over the literal parts, so it costs nothing at run
time and names the tag and the byte offset in the literal text.
+/
private template skeletonReport(HtmlCheck check, Args...)
{
    enum skeletonReport = () {
        SkeletonScan s;
        static foreach (A; Args)
        {{
            static if (is(A == InterpolatedLiteral!lit, string lit))
                advance(s, lit);
        }}
        const e = finish(s, check == HtmlCheck.balanced);
        if (e.kind == SkeletonErrorKind.none)
            return "";

        string at()
        {
            // CTFE-only, so plain concatenation is the clearest thing here.
            size_t v = e.at;
            if (v == 0)
                return "0";
            string digits;
            while (v)
            {
                digits = cast(char)('0' + (v % 10)) ~ digits;
                v /= 10;
            }
            return digits;
        }

        const name = e.name.idup;
        final switch (e.kind)
        {
            case SkeletonErrorKind.mismatchedEndTag:
                return "</" ~ name ~ "> at byte " ~ at()
                    ~ " closes an element that is not open"
                    ~ " (docs/specs/base/html-template.md HTL10)";
            case SkeletonErrorKind.unclosedQuote:
                return "an attribute value's quote is never closed, from byte "
                    ~ at() ~ " (docs/specs/base/html-template.md HTL10)";
            case SkeletonErrorKind.unclosedComment:
                return "an HTML comment is never closed"
                    ~ " (docs/specs/base/html-template.md HTL10)";
            case SkeletonErrorKind.unclosedRawText:
                return "<" ~ name ~ "> at byte " ~ at() ~ " is never closed;"
                    ~ " everything after it is its content"
                    ~ " (docs/specs/base/html-template.md HTL10)";
            case SkeletonErrorKind.unclosedElement:
                return "<" ~ name ~ "> at byte " ~ at() ~ " is left open;"
                    ~ " HtmlCheck.balanced requires the template to close what"
                    ~ " it opens (docs/specs/base/html-template.md HTL10)";
            case SkeletonErrorKind.tooDeep:
                return "more than 32 elements are open at <" ~ name ~ ">;"
                    ~ " split the template (docs/specs/base/html-template.md HTL10)";
            case SkeletonErrorKind.none:
                return "";
        }
    }();
}

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
    rawText,       /// inside `<script>`/`<style>` — needs `json`/`cssValue`
    rcdata,        /// inside `<textarea>`/`<title>`: entity-escaped like text
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

/// How deep the skeleton's element stack goes before the scanner gives up on
/// tracking balance (`HTL10`). Templates are fragments of a page, not the page.
private enum maxElementDepth = 32;

/// Longest attribute name the scanner remembers. Only the URL-attribute test
/// reads it, and the longest of those is `background` — a longer name is
/// truncated, which can only make it *not* match, never match wrongly.
private enum maxAttrName = 24;

/// Elements whose content is $(I raw text): no character references at all, so
/// no escape can keep a value inside them (`HTL8`) — only `json`/`cssValue`,
/// which encode into forms that cannot contain `<`.
private bool isRawTextElement(scope const(char)[] name) @safe pure nothrow @nogc
{
    switch (name)
    {
        case "script", "style":
            return true;
        default:
            return false;
    }
}

/++
Elements whose content is $(I RCDATA): no nested markup, but character
references $(B do) work — so a value entity-escaped exactly as text is escaped
is safe, since the `<` that would start `</textarea>` becomes `&lt;`.
+/
private bool isRcdataElement(scope const(char)[] name) @safe pure nothrow @nogc
{
    switch (name)
    {
        case "textarea", "title":
            return true;
        default:
            return false;
    }
}

/++
Elements with no end tag (HTML §13.1.2). They are never pushed on the
skeleton's element stack, so `<br>` does not look like an element left open
(`HTL10`).
+/
private bool isVoidElement(scope const(char)[] name) @safe pure nothrow @nogc
{
    switch (name)
    {
        case "area", "base", "br", "col", "embed", "hr", "img", "input",
            "link", "meta", "param", "source", "track", "wbr":
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
        bool tagIsRcdata;    // the tag being opened is textarea/title
        bool inRawText;      // inside a raw-text element's content
        bool inRcdata;       // inside an RCDATA element's content
        bool inComment;      // inside `<!-- … -->`
        char quote;          // active attribute quote, 0 when unquoted
        char[maxAttrName] nameBuf;
        ubyte nameLen;

        // The tag currently being read, kept once its name run ends (`nameBuf`
        // goes on to hold attribute names).
        char[maxAttrName] tagBuf;
        ubyte tagLen;
        size_t tagStart;     // offset of this tag's `<`, for the error message

        // Open elements, innermost last (`HTL10`).
        char[maxAttrName][maxElementDepth] openBuf;
        ubyte[maxElementDepth] openLen;
        size_t[maxElementDepth] openAt;
        ubyte openDepth;

        size_t offset;       // bytes of literal text consumed so far
        SkeletonError firstError;

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

        const(char)[] tagName() const return @safe pure nothrow @nogc
            => tagBuf[0 .. tagLen];

        void keepTagName() @safe pure nothrow @nogc
        {
            // Slice assignment, not `tagBuf = nameBuf`: CTFE aliases the
            // whole-array form, so the tag name would follow every later write
            // to `nameBuf` (the attribute names) and `<img src=…>` would stop
            // looking like a void element — at compile time only.
            tagBuf[] = nameBuf[];
            tagLen = nameLen;
        }

        void note(SkeletonErrorKind kind, scope const(char)[] what, size_t at)
            @safe pure nothrow @nogc
        {
            if (firstError.kind != SkeletonErrorKind.none)
                return; // the first one is the one worth reporting
            firstError.kind = kind;
            firstError.at = at;
            firstError.nameLen = 0;
            foreach (char c; what)
                if (firstError.nameLen < maxAttrName)
                    firstError.nameBuf[firstError.nameLen++] = c;
        }

        void pushElement() @safe pure nothrow @nogc
        {
            if (openDepth == maxElementDepth)
            {
                note(SkeletonErrorKind.tooDeep, tagName, tagStart);
                return;
            }
            openBuf[openDepth][] = tagBuf[];
            openLen[openDepth] = tagLen;
            openAt[openDepth] = tagStart;
            ++openDepth;
        }

        void popElement() @safe pure nothrow @nogc
        {
            if (openDepth == 0)
                return; // a fragment may close what an earlier one opened
            const top = openBuf[openDepth - 1][0 .. openLen[openDepth - 1]];
            if (top != tagName)
            {
                note(SkeletonErrorKind.mismatchedEndTag, tagName, tagStart);
                return;
            }
            --openDepth;
        }
    }
}

/// What is structurally wrong with a skeleton (`HTL10`).
enum SkeletonErrorKind
{
    none,
    mismatchedEndTag,  /// `</p>` where the innermost open element is not `p`
    unclosedQuote,     /// an attribute value's quote never closes
    unclosedComment,   /// `<!--` with no `-->`
    unclosedRawText,   /// `<script>`/`<style>`/`<textarea>` never closed
    unclosedElement,   /// only checked under `HtmlCheck.balanced`
    tooDeep,           /// more than `maxElementDepth` open elements
}

/// The first structural problem the scan found, with the tag it is about and
/// the byte offset (into the skeleton's literal text) where that tag started.
struct SkeletonError
{
    SkeletonErrorKind kind;
    size_t at;
    private char[maxAttrName] nameBuf;
    private ubyte nameLen;

    /// The element the problem is about, when there is one.
    const(char)[] name() const return @safe pure nothrow @nogc
        => nameBuf[0 .. nameLen];
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
    const base = s.offset;
    scope (exit)
        s.offset = base + lit.length;

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

        if (s.inRawText || s.inRcdata)
        {
            // Leaves at the element's own end tag; any other `<` is content.
            if (c == '<' && i + 1 < lit.length && lit[i + 1] == '/')
            {
                s.inRawText = false;
                s.inRcdata = false;
                s.inTag = true;
                s.readingName = true;
                s.endTag = true;
                s.tagStart = base + i;
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
                s.tagIsRcdata = false;
                s.endTag = false;
                s.afterEq = false;
                s.quote = 0;
                s.tagStart = base + i;
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
                s.keepTagName();
                s.tagIsRawText = !s.endTag && isRawTextElement(s.tagName);
                s.tagIsRcdata = !s.endTag && isRcdataElement(s.tagName);
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
            const selfClosing = i > 0 && lit[i - 1] == '/';
            s.inTag = false;
            s.inRawText = s.tagIsRawText;
            s.inRcdata = s.tagIsRcdata;
            s.afterEq = false;
            if (s.endTag)
                s.popElement();
            else if (!selfClosing && !isVoidElement(s.tagName))
                s.pushElement();
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

/++
The skeleton's structural verdict once every part has been scanned (`HTL10`).

`balanced` additionally requires the template to leave no element open — right
for a whole document, wrong for the fragments a page is assembled from, which
is why it is not the default.
+/
SkeletonError finish(in SkeletonScan s, bool balanced = false) @safe pure nothrow @nogc
{
    if (s.firstError.kind != SkeletonErrorKind.none)
        return s.firstError;

    SkeletonError e;
    if (s.quote != 0)
    {
        e.kind = SkeletonErrorKind.unclosedQuote;
        e.at = s.tagStart;
        return e;
    }
    if (s.inComment)
    {
        e.kind = SkeletonErrorKind.unclosedComment;
        return e;
    }
    if (s.inRawText || s.inRcdata)
    {
        e.kind = SkeletonErrorKind.unclosedRawText;
        e.at = s.tagStart;
        foreach (char c; s.tagName)
            if (e.nameLen < maxAttrName)
                e.nameBuf[e.nameLen++] = c;
        return e;
    }
    if (balanced && s.openDepth > 0)
    {
        const top = s.openDepth - 1;
        e.kind = SkeletonErrorKind.unclosedElement;
        e.at = s.openAt[top];
        foreach (char c; s.openBuf[top][0 .. s.openLen[top]])
            if (e.nameLen < maxAttrName)
                e.nameBuf[e.nameLen++] = c;
        return e;
    }
    return e;
}

/// The context an interpolation lands in, given the state before it (`HTL1`).
HtmlContext contextAt(in SkeletonScan s) @safe pure nothrow @nogc
{
    if (s.inComment)
        return HtmlContext.comment;
    if (s.inRawText)
        return HtmlContext.rawText;
    if (s.inRcdata)
        return HtmlContext.rcdata;
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

    /// Whether the policy replaced this value (`HTL6`) — read after
    /// $(LREF finish), and what `writeHtmlChecked` reports.
    bool rejected() const scope @safe pure nothrow @nogc => state == State.blocked;

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
/++
Renders `value` into `w` with the escape `ctx` calls for (`HTL1`, §4 of the
design), returning what it had to substitute — nothing, in every ordinary case.
Every arm writes straight through a sink; nothing is buffered (`HTL15`).
+/
private HtmlErrorCode writeInContext(HtmlContext ctx, Writer, T)(
    ref Writer w, auto ref const T value)
{
    import std.range.primitives : put;

    // ── the escape hatches (HTL11) ──────────────────────────────────────────
    static if (is(immutable T == immutable HtmlFragment))
    {
        put(w, value.markup);
        return HtmlErrorCode.none;
    }
    else static if (is(immutable T == immutable Attr))
    {
        return writeAttr(w, value);
    }
    else static if (is(T == Attrs!R, R))
    {
        auto worst = HtmlErrorCode.none;
        bool first = true;
        foreach (ref const a; value.pairs)
        {
            // A pair that renders nothing — an absent boolean, or a name that
            // is not a name — must not leave its separator behind either.
            if (!isValidAttributeName(a.name))
            {
                if (worst == HtmlErrorCode.none)
                    worst = HtmlErrorCode.invalidAttributeName;
                continue;
            }
            if (a.boolean && !a.present)
                continue;
            if (!first)
                put(w, ' ');
            first = false;
            const e = writeAttr(w, a);
            if (e != HtmlErrorCode.none && worst == HtmlErrorCode.none)
                worst = e;
        }
        return worst;
    }
    else static if (is(T == JsonValue!V, V))
    {
        writeJsonValue(w, value.value);
        return HtmlErrorCode.none;
    }
    else static if (is(immutable T == immutable CssValue))
    {
        writeCssEscaped(w, value.value);
        return HtmlErrorCode.none;
    }
    // ── the context escapes (HTL1) ──────────────────────────────────────────
    else static if (ctx == HtmlContext.text || ctx == HtmlContext.attrQuoted
        || ctx == HtmlContext.rcdata)
    {
        scope sink = HtmlEscapeSink!Writer(&w);
        writeValue(sink, value);
        return HtmlErrorCode.none;
    }
    else static if (ctx == HtmlContext.attrUnquoted)
    {
        put(w, '"');
        scope sink = HtmlEscapeSink!Writer(&w);
        writeValue(sink, value);
        put(w, '"');
        return HtmlErrorCode.none;
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
        const rejected = sink.rejected;
        static if (ctx == HtmlContext.urlWholeUnquoted)
            put(w, '"');
        return rejected ? HtmlErrorCode.unsafeUrlScheme : HtmlErrorCode.none;
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
        return HtmlErrorCode.none;
    }
    else
        static assert(0, "context rejected earlier: " ~ ctx.stringof);
}

/// One `name="value"` (or a bare boolean attribute). A name that is not a name
/// is dropped rather than written: unlike a value, it cannot be escaped into
/// safety (`HTL7`).
private HtmlErrorCode writeAttr(Writer)(ref Writer w, in Attr a)
{
    import std.range.primitives : put;

    if (!isValidAttributeName(a.name))
        return HtmlErrorCode.invalidAttributeName;
    if (a.boolean)
    {
        if (a.present)
            put(w, a.name);
        return HtmlErrorCode.none;
    }
    put(w, a.name);
    put(w, "=\"");
    if (isUrlAttribute(a.name))
    {
        scope sink = UrlSchemeSink!Writer(&w);
        sink.put(a.value);
        sink.finish();
        const rejected = sink.rejected;
        put(w, '"');
        return rejected ? HtmlErrorCode.unsafeUrlScheme : HtmlErrorCode.none;
    }
    writeHtmlEscaped(w, a.value);
    put(w, '"');
    return HtmlErrorCode.none;
}

/++
HTML's attribute-name production, minus the characters no sane document uses:
a name may not be empty and may not contain a space, quote, `/`, `=`, `<`, `>`
or a control byte (HTML §13.1.2.3). Anything that passes cannot end the tag or
start a second attribute.
+/
bool isValidAttributeName(scope const(char)[] name) @safe pure nothrow @nogc
{
    if (name.length == 0)
        return false;
    foreach (char c; name)
    {
        if (c <= ' ' || c == 0x7f)
            return false;
        switch (c)
        {
            case '"', '\'', '>', '/', '=', '<', '&':
                return false;
            default:
                break;
        }
    }
    return true;
}

///
@("html_template.isValidAttributeName")
@safe pure nothrow @nogc
unittest
{
    assert(isValidAttributeName("class") && isValidAttributeName("data-x")
        && isValidAttributeName("aria-label"));
    assert(!isValidAttributeName("") && !isValidAttributeName("a b")
        && !isValidAttributeName(`x"`) && !isValidAttributeName("a=b")
        && !isValidAttributeName("a>b"));
}

/// A JSON literal for `<script>`, with everything that could end the element
/// escaped (`HTL8`).
private void writeJsonValue(Writer, T)(ref Writer w, auto ref const T value)
{
    import std.range.primitives : put;
    import std.traits : isFloatingPoint, isIntegral;

    static if (is(immutable T == immutable bool))
        put(w, value ? "true" : "false");
    else static if (isIntegral!T || isFloatingPoint!T)
        writeValue(w, value);
    else
    {
        put(w, '"');
        scope sink = JsonStringSink!Writer(&w);
        writeValue(sink, value);
        put(w, '"');
    }
}

/// The JSON string body: RFC 8259 escapes, plus `<`, `>`, `&` and the two
/// line separators as `\uXXXX` — which is what makes `</script` unwritable.
private struct JsonStringSink(Writer)
{
    private Writer* target;
    private ubyte pendingSeparator; // bytes matched of a U+2028/U+2029 sequence

    void put(char c) scope
    {
        import std.range.primitives : put;

        // U+2028/U+2029 are line terminators in JavaScript but not in JSON.
        if (pendingSeparator == 0 && c == '\xe2')
        {
            pendingSeparator = 1;
            return;
        }
        if (pendingSeparator == 1)
        {
            if (c == '\x80')
            {
                pendingSeparator = 2;
                return;
            }
            flushSeparator();
        }
        else if (pendingSeparator == 2)
        {
            if (c == '\xa8' || c == '\xa9')
            {
                pendingSeparator = 0;
                put(*target, c == '\xa8' ? "\\u2028" : "\\u2029");
                return;
            }
            flushSeparator();
        }

        switch (c)
        {
            case '"':  put(*target, "\\\""); return;
            case '\\': put(*target, "\\\\"); return;
            case '\n': put(*target, "\\n"); return;
            case '\r': put(*target, "\\r"); return;
            case '\t': put(*target, "\\t"); return;
            case '<':  put(*target, "\\u003C"); return;
            case '>':  put(*target, "\\u003E"); return;
            case '&':  put(*target, "\\u0026"); return;
            default:
                if (c < 0x20)
                {
                    import sparkles.base.text.writers : writeHexByte;

                    put(*target, "\\u00");
                    writeHexByte(*target, c);
                }
                else
                {
                    char[1] one = c;
                    put(*target, one[]);
                }
                return;
        }
    }

    void put(scope const(char)[] s) scope
    {
        foreach (char c; s)
            put(c);
    }

    private void flushSeparator() scope
    {
        import std.range.primitives : put;

        // Not a separator after all — write the bytes we held back.
        if (pendingSeparator >= 1)
            put(*target, "\xe2");
        if (pendingSeparator == 2)
            put(*target, "\x80");
        pendingSeparator = 0;
    }
}

/++
CSS escaping for `<style>` (`HTL8`): alphanumerics and a small set of harmless
punctuation pass; every other byte becomes `\HH ` — the CSS escape, which is
valid inside both identifiers and strings. `<` is escaped, so `</style` cannot
appear; so are `\`, quotes, `;`, `{`, `}` and `(`, so a value cannot end a
declaration or open a function.
+/
private void writeCssEscaped(Writer)(ref Writer w, scope const(char)[] value)
{
    import std.range.primitives : put;
    import sparkles.base.text.writers : writeHexByte;

    foreach (char c; value)
    {
        const safe = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
            || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.'
            || c == '%' || c == ' ' || c == ',' || c == '#';
        if (safe)
        {
            char[1] one = c;
            put(w, one[]);
        }
        else
        {
            put(w, '\\');
            writeHexByte(w, c);
            put(w, ' ');
        }
    }
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

    // `textarea` is RCDATA, not raw text: character references work there, so a
    // value escaped exactly as text is safe (`<` cannot start `</textarea>`).
    SkeletonScan t;
    advance(t, "<textarea>");
    assert(contextAt(t) == HtmlContext.rcdata);
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

// ── HTLM3: skeleton validation and the reporting arm ─────────────────────────

/// The skeleton itself must be sound (`HTL10`): quotes, comments and raw-text
/// elements close, and an end tag matches what it closes.
@("html_template.skeleton.rejectsMalformedStructure")
@safe unittest
{
    const x = "v";

    static assert(!__traits(compiles, htmlText(i`<div><p>$(x)</div></p>`)));
    static assert(!__traits(compiles, htmlText(i`<a href="/x>$(x)</a>`)));
    static assert(!__traits(compiles, htmlText(i`<p>$(x)<!-- unfinished</p>`)));
    static assert(!__traits(compiles, htmlText(i`<script>ok();<p>$(x)</p>`)));

    // …while the same shapes, closed, are fine.
    static assert(__traits(compiles, htmlText(i`<div><p>$(x)</p></div>`)));
    static assert(__traits(compiles, htmlText(i`<a href="/x">$(x)</a>`)));
    static assert(__traits(compiles, htmlText(i`<p>$(x)<!-- done --></p>`)));
    static assert(__traits(compiles, htmlText(i`<script>ok();</script><p>$(x)</p>`)));
}

/// A template is a fragment by default — it may open an element for a later
/// one to close, which is how a page shell is written. `HtmlCheck.balanced`
/// is the opt-in that forbids it (`HTL10`).
@("html_template.skeleton.fragmentVersusBalanced")
@safe unittest
{
    const title = "Docs";

    // Fragment: opening `<html><body>` here and closing it in another template.
    static assert(__traits(compiles, htmlText(i`<html><body><h1>$(title)</h1>`)));
    static assert(__traits(compiles, htmlText(i`</body></html>`)));

    // Balanced: the same template must close what it opens.
    static assert(!__traits(compiles,
        htmlText!(HtmlCheck.balanced)(i`<html><body><h1>$(title)</h1>`)));
    static assert(__traits(compiles,
        htmlText!(HtmlCheck.balanced)(i`<section><h1>$(title)</h1></section>`)));
    // Void elements are not "left open".
    static assert(__traits(compiles,
        htmlText!(HtmlCheck.balanced)(i`<p>$(title)<br><img src="/a.png"></p>`)));
}

/// `writeHtmlChecked` reports what `writeHtml` silently made safe (`HTL6`).
@("html_template.checked.reportsUnsafeUrl")
@safe unittest
{
    import std.array : appender;

    auto w = appender!string;
    const link = "javascript:alert(1)";
    const r = writeHtmlChecked(w, i`<a href="$(link)">x</a>`);

    assert(r.hasError);
    assert(r.error.code == HtmlErrorCode.unsafeUrlScheme);
    assert(r.error.expression == "link");
    // The output is safe either way — reporting is in addition to substituting.
    assert(w[] == `<a href="about:invalid#unsafe-scheme">x</a>`);

    auto ok_ = appender!string;
    const good = "/docs/index.html";
    assert(!writeHtmlChecked(ok_, i`<a href="$(good)">x</a>`).hasError);
}

// ── HTLM4: the escape hatches ────────────────────────────────────────────────

/// `raw` writes markup verbatim, and `htmlText`'s own result is such a
/// fragment — so templates compose without double-escaping (`HTL11`/`HTL12`).
@("html_template.raw.composesWithoutDoubleEscaping")
@safe unittest
{
    const cell = "a & b";
    const row = raw(htmlText(i`<td>$(cell)</td>`));
    assert(htmlText(i`<tr>$(row)</tr>`) == `<tr><td>a &amp; b</td></tr>`);

    // Without `raw` the same string is a value, and escapes as one.
    const asValue = htmlText(i`<td>$(cell)</td>`);
    assert(htmlText(i`<tr>$(asValue)</tr>`)
        == `<tr>&lt;td&gt;a &amp;amp; b&lt;/td&gt;</tr>`);
}

/// `raw` is refused where "already escaped" has no meaning (`HTL11`).
@("html_template.raw.refusedOutsideTextAndAttributes")
@safe unittest
{
    const frag = raw("<b>x</b>");
    static assert(__traits(compiles, htmlText(i`<p>$(frag)</p>`)));
    static assert(__traits(compiles, htmlText(i`<p title="$(frag)">x</p>`)));
    static assert(!__traits(compiles, htmlText(i`<a href="/x/$(frag)">y</a>`)));
    static assert(!__traits(compiles, htmlText(i`<a href="$(frag)">y</a>`)));
    static assert(!__traits(compiles, htmlText(i`<p class=$(frag)>y</p>`)));
}

/// `attr`/`attrs` are how a NAME becomes dynamic without the structure doing
/// so: names are validated, values escaped, booleans present or absent
/// (`HTL11`).
@("html_template.attrs.renderPairs")
@safe unittest
{
    const cls = `x" onload="evil()`;
    assert(htmlText(i`<div $(attr("class", cls))>y</div>`)
        == `<div class="x&quot; onload=&quot;evil()">y</div>`);

    assert(htmlText(i`<input $(attr("disabled", true))$(attr("readonly", false))>`)
        == `<input disabled>`);
    // In a spread, a pair that renders nothing leaves no separator behind.
    const Attr[3] mixed = [attr("id", "a"), attr("hidden", false), attr("lang", "en")];
    assert(htmlText(i`<div $(attrs(mixed[]))>y</div>`) == `<div id="a" lang="en">y</div>`);

    const Attr[2] pairs = [attr("id", "main"), attr("data-n", "3")];
    assert(htmlText(i`<div $(attrs(pairs[]))>y</div>`)
        == `<div id="main" data-n="3">y</div>`);

    // A URL-valued attribute goes through the same scheme check as `href=…`.
    assert(htmlText(i`<a $(attr("href", "javascript:x()"))>y</a>`)
        == `<a href="about:invalid#unsafe-scheme">y</a>`);
}

/// A name that is not a name cannot be escaped into safety, so the pair is
/// dropped — and `writeHtmlChecked` says so (`HTL7`/`HTL11`).
@("html_template.attrs.invalidNameIsDroppedAndReported")
@safe unittest
{
    import std.array : appender;

    auto w = appender!string;
    const bad = attr(`x" onload="evil()`, "1");
    const r = writeHtmlChecked(w, i`<div $(bad)>y</div>`);

    assert(w[] == `<div >y</div>`);
    assert(r.hasError && r.error.code == HtmlErrorCode.invalidAttributeName);
    assert(r.error.expression == "bad");
}

/// `json` is the only way a value reaches `<script>`, and it cannot end the
/// element: `<`, `>` and `&` leave as `\uXXXX` (`HTL8`).
@("html_template.json.cannotCloseTheScript")
@safe unittest
{
    const payload = `</script><img src=x onerror=alert(1)>`;
    const rendered = htmlText(i`<script>const p = $(json(payload));</script>`);
    assert(rendered ==
        `<script>const p = "\u003C/script\u003E\u003Cimg src=x onerror=alert(1)`
        ~ `\u003E";</script>`, rendered);

    // Numbers and booleans are JSON literals, not quoted strings.
    assert(htmlText(i`<script>let n = $(json(42)), b = $(json(true));</script>`)
        == `<script>let n = 42, b = true;</script>`);

    // JS line terminators that JSON allows raw are escaped.
    const sep = "a\u2028b";
    assert(htmlText(i`<script>const s = $(json(sep));</script>`)
        == `<script>const s = "a\u2028b";</script>`);
}

/// `cssValue` is the same bargain for `<style>`: anything outside a small safe
/// set becomes a CSS escape, so a value cannot end the declaration or the
/// element (`HTL8`).
@("html_template.cssValue.escapesEverythingElse")
@safe unittest
{
    const colour = "red";
    assert(htmlText(i`<style>.a { color: $(cssValue(colour)); }</style>`)
        == `<style>.a { color: red; }</style>`);

    const hostile = "red; } body { display:none } </style><script>";
    const rendered = htmlText(i`<style>.a { color: $(cssValue(hostile)); }</style>`);
    assert(rendered.length > 0);
    // The dangerous characters are gone: no `<`, no `{`, no `;` survives raw.
    import std.algorithm.searching : canFind;

    assert(!rendered["<style>".length .. $ - "</style>".length].canFind("</style>"));
    assert(rendered.canFind(`\3b `) && rendered.canFind(`\7b `));
}

/// `json`/`cssValue` belong to their element and nowhere else — a plain value
/// is what text and attributes take (`HTL8`).
@("html_template.wrappers.refusedOutsideTheirElement")
@safe unittest
{
    const j = json("x");
    const c = cssValue("x");
    static assert(!__traits(compiles, htmlText(i`<p>$(j)</p>`)));
    static assert(!__traits(compiles, htmlText(i`<p>$(c)</p>`)));
    static assert(!__traits(compiles, htmlText(i`<p class="$(j)">y</p>`)));
    // …and a plain value is still refused inside <script>.
    const plain = "x";
    static assert(!__traits(compiles, htmlText(i`<script>var v = $(plain);</script>`)));
}

/// `<textarea>`/`<title>` are RCDATA, not raw text: character references work,
/// so a value escapes exactly as text does and cannot close the element.
@("html_template.rcdata.escapesLikeText")
@safe unittest
{
    const draft = "</textarea><script>alert(1)</script>";
    assert(htmlText(i`<textarea>$(draft)</textarea>`)
        == `<textarea>&lt;/textarea&gt;&lt;script&gt;alert(1)&lt;/script&gt;</textarea>`);

    const t = "R&D <notes>";
    assert(htmlText(i`<title>$(t)</title>`) == `<title>R&amp;D &lt;notes&gt;</title>`);
}

/// The hatches keep the `@nogc` promise too (`HTL15`): every one of them writes
/// straight through, so a `@nogc` writer stays `@safe pure nothrow @nogc`.
@("html_template.hatches.stayNogc")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.smallbuffer : SmallBuffer;

    SmallBuffer!(char, 512) buf;
    const Attr[2] pairs = [attr("id", "main"), attr("hidden", true)];
    const frag = raw("<b>ok</b>");
    writeHtml(buf, i`<div $(attrs(pairs[]))>$(frag)</div>`);
    writeHtml(buf, i`<style>.a { color: $(cssValue("red")); }</style>`);
    writeHtml(buf, i`<script>var n = $(json(7));</script>`);
    assert(buf[] == `<div id="main" hidden><b>ok</b></div>`
        ~ `<style>.a { color: red; }</style>`
        ~ `<script>var n = 7;</script>`, buf[]);
}
