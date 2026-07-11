/**
HTML/XML text escaping for output-range writers.

One primitive: $(LREF writeHtmlEscaped) — the five-entity escape every
HTML-emitting writer needs (markup renderers, SVG text, report generators).
Follows the `writers.d` conventions: a template over any `char` output
range, attributes inferred, `@safe pure nothrow @nogc` with a `@nogc`
writer, unescaped stretches flushed as whole slices.
*/
module sparkles.base.text.html;

import std.range.primitives : put;

/**
Writes `s` to `w`, escaping the five HTML/XML special characters
(`&` `<` `>` `"` `'` → `&amp;` `&lt;` `&gt;` `&quot;` `&#39;`).

The output is safe for element content and for single- or double-quoted
attribute values. `&#39;` is used over `&apos;` for HTML4 compatibility.
*/
void writeHtmlEscaped(Writer)(ref Writer w, scope const(char)[] s)
{
    size_t flushed = 0;
    foreach (i, char c; s)
    {
        string entity;
        switch (c)
        {
            case '&': entity = "&amp;"; break;
            case '<': entity = "&lt;"; break;
            case '>': entity = "&gt;"; break;
            case '"': entity = "&quot;"; break;
            case '\'': entity = "&#39;"; break;
            default: continue;
        }
        if (flushed < i)
            put(w, s[flushed .. i]);
        put(w, entity);
        flushed = i + 1;
    }
    if (flushed < s.length)
        put(w, s[flushed .. $]);
}

///
@("text.html.writeHtmlEscaped")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.smallbuffer : checkWriter;

    checkWriter!((ref w) => writeHtmlEscaped(w, `if (a < b && c > 'x') "quote"`))(
        "if (a &lt; b &amp;&amp; c &gt; &#39;x&#39;) &quot;quote&quot;");
}

@("text.html.writeHtmlEscaped.passthrough")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.smallbuffer : checkWriter;

    // nothing to escape: the input is flushed as one slice
    checkWriter!((ref w) => writeHtmlEscaped(w, "plain text 123"))("plain text 123");
    checkWriter!((ref w) => writeHtmlEscaped(w, ""))("");
}

@("text.html.writeHtmlEscaped.edges")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.smallbuffer : checkWriter;

    checkWriter!((ref w) => writeHtmlEscaped(w, "&"))("&amp;");
    checkWriter!((ref w) => writeHtmlEscaped(w, "&&"))("&amp;&amp;");
    checkWriter!((ref w) => writeHtmlEscaped(w, "a&"))("a&amp;");
    checkWriter!((ref w) => writeHtmlEscaped(w, "&a"))("&amp;a");
    // UTF-8 multibyte content passes through untouched
    checkWriter!((ref w) => writeHtmlEscaped(w, "héllo <wörld>"))("héllo &lt;wörld&gt;");
}
