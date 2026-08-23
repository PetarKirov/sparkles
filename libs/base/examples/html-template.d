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

import sparkles.base.html_template : htmlText, writeHtml;
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

    // The primitive writes into any output range and allocates nothing: with a
    // `@nogc` writer the whole path is `@safe pure nothrow @nogc`.
    nogcRender();
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
