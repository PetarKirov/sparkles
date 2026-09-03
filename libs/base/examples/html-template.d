#!/usr/bin/env dub
/+ dub.sdl:
    name "html-template"
    dependency "sparkles:base" path="../../.."
    targetPath "build"
    // Optimised, assertions live, `debug {}` blocks out — the build every nix
    // artifact uses. Neither `debug` (which compiles those blocks in) nor
    // `release` (which deletes assert *expressions*, side effects included).
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/

// `sparkles.base.html_template`: the escape an interpolated value gets is
// decided by where the literal puts it — text, attribute, or a position inside
// a URL — and the decision is made at compile time
// (docs/specs/base/html-template.md).
//
// Every value below is hostile; none of them escapes its slot, and no call
// site names an escape.

module html_template_example;

import std.stdio : writeln;

import sparkles.base.html_template : attr, attrs, Attr, cssValue, htmlText,
    HtmlErrorCode, json, raw, writeHtml, writeHtmlChecked;
import sparkles.base.smallbuffer : SmallBuffer;

void main()
{
    const user = `Ada "Countess" Lovelace <ada@example.com>`;
    const cssClass = `row" onmouseover="steal()`;
    const avatar = "../../etc/passwd";
    const query = "notes & drafts=all";
    const id = 1815;

    // Text and attributes: entity-escaped, and an unquoted attribute value is
    // quoted by the emitter, so a value with a space cannot become a second
    // attribute.
    writeln(htmlText(i`<li class=$(cssClass)>$(user)</li>`));

    // Inside a URL: a path segment escapes `/`, so an interpolated segment
    // stays one segment; a query component escapes `&` and `=`, so a value
    // cannot append parameters.
    writeln(htmlText(i`<a href="/users/$(id)/avatars/$(avatar)?q=$(query)">avatar</a>`));

    // A value that *is* the whole URL keeps its scheme (it could not survive
    // percent-encoding) and is checked instead — scripting schemes are replaced
    // by an inert URL rather than emitted or silently dropped.
    const safe = "https://example.com/a?b=1&c=2";
    const hostile = "javascript:steal(document.cookie)";
    writeln(htmlText(i`<a href=$(safe)>ok</a> <a href=$(hostile)>blocked</a>`));

    // Escape hatches, each unlocking exactly one position: `raw` for markup
    // that is already correct (so templates compose), `attr`/`attrs` for a
    // dynamic attribute NAME, `json`/`cssValue` for the two elements no escape
    // can reach into.
    const cell = htmlText(i`<td>$(user)</td>`);
    writeln(htmlText(i`<tr>$(raw(cell))</tr>`));

    const Attr[3] pairs = [attr("class", cssClass), attr("hidden", false),
        attr("data-role", "row")];
    writeln(htmlText(i`<div $(attrs(pairs[]))>spread</div>`));

    const payload = `</script><img src=x onerror=alert(1)>`;
    writeln(htmlText(i`<script>const p = $(json(payload));</script>`));
    writeln(htmlText(i`<style>.a { content: $(cssValue("</style><script>")); }</style>`));

    // `writeHtmlChecked` reports what the plain form silently made safe.
    reportUnsafe();

    // The primitive writes into any output range and allocates nothing: with a
    // `@nogc` writer the whole path is `@safe pure nothrow @nogc`.
    nogcRender();
}

void reportUnsafe()
{
    import std.array : appender;

    auto w = appender!string;
    const link = "javascript:steal(document.cookie)";
    const r = writeHtmlChecked(w, i`<a href="$(link)">report</a>`);
    writeln(w[], "   (", r.hasError ? r.error.code : HtmlErrorCode.none,
        " on `", r.hasError ? r.error.expression : "", "`)");
}

void nogcRender() @safe pure nothrow @nogc
{
    SmallBuffer!(char, 128) page;
    const label = "R&D";
    const slug = "r&d/2026";
    writeHtml(page, i`<a href="/teams/$(slug)">$(label)</a>`);
    // `/` is escaped (a segment stays a segment) while `&` is `pchar`, so it
    // survives percent-encoding and the attribute escape handles it.
    assert(page[] == `<a href="/teams/r&amp;d%2F2026">R&amp;D</a>`);
}
