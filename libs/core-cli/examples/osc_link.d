#!/usr/bin/env dub

/+ dub.sdl:
name "osc_link"
dependency "sparkles:core-cli" version="*"
targetPath "build"
+/

import std.stdio : writeln;

import sparkles.core_cli.ui.osc_link;
import sparkles.core_cli.term_style : Style;

void main()
{
    // Plain hyperlink
    writeln("Visit: ", oscLink(text: "Example", uri: "https://example.com"));

    // Styled hyperlink (blue text)
    writeln("Docs:  ", oscLink(text: "D Language", uri: "https://dlang.org", style: Style.blue));

    // Styled hyperlink (bold + underline)
    writeln("Repo:  ", oscLink(text: "GitHub", uri: "https://github.com", style: Style.underline));

    // With explicit id parameter
    writeln("Home:  ", oscLink(text: "Homepage", uri: "https://example.com",
        props: OscLinkProps(id: "home")));

    // Using low-level open/close sequences directly
    writeln(
        oscLinkOpenSeq(uri: "https://dlang.org"),
        "Click ",
        "here".stylize(Style.bold),
        oscLinkCloseSeq(),
    );

    // With ST terminator instead of BEL
    writeln("ST:    ", oscLink(text: "ST link", uri: "https://example.com",
        props: OscLinkProps(terminator: OscTerminator.st)));
}

private string stylize(string text, Style style)
{
    import sparkles.core_cli.term_style : stylize;
    return text.stylize(style);
}
