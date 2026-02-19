/++
OSC 8 terminal hyperlink rendering.

Provides functions to wrap text in OSC 8 escape sequences, making it
clickable in terminal emulators that support hyperlinks.
+/
module sparkles.core_cli.ui.osc_link;

import sparkles.core_cli.term_style : Style;

@safe:

/// OSC 8 sequence terminator style.
enum OscTerminator
{
    bel, /// BEL character (`\x07`) — widely supported default.
    st,  /// String Terminator (`\x1b\\`) — standard but less common.
}

/// Configuration for OSC 8 hyperlink rendering.
struct OscLinkProps
{
    OscTerminator terminator = OscTerminator.bel;
    string id = null; /// Optional link id parameter.
}

/// Returns the OSC 8 opening escape sequence for `uri`.
pure nothrow
string oscLinkOpenSeq(const(char)[] uri, OscLinkProps props = OscLinkProps.init)
{
    const params = props.id !is null ? "id=" ~ props.id : "";
    const term = props.terminator == OscTerminator.st ? "\x1b\\" : "\x07";
    return "\x1b]8;" ~ params ~ ";" ~ uri ~ term;
}

/// Opening sequence uses BEL terminator by default.
@("oscLink.oscLinkOpenSeq.bel")
@safe pure nothrow unittest
{
    assert(oscLinkOpenSeq(uri: "https://example.com") == "\x1b]8;;https://example.com\x07");
}

/// Opening sequence with ST terminator.
@("oscLink.oscLinkOpenSeq.st")
@safe pure nothrow unittest
{
    assert(oscLinkOpenSeq(uri: "https://example.com", props: OscLinkProps(terminator: OscTerminator.st))
        == "\x1b]8;;https://example.com\x1b\\");
}

/// Opening sequence with id parameter.
@("oscLink.oscLinkOpenSeq.withId")
@safe pure nothrow unittest
{
    assert(oscLinkOpenSeq(uri: "https://example.com", props: OscLinkProps(id: "link1"))
        == "\x1b]8;id=link1;https://example.com\x07");
}

/// Returns the OSC 8 closing escape sequence.
pure nothrow
string oscLinkCloseSeq(OscLinkProps props = OscLinkProps.init)
{
    const term = props.terminator == OscTerminator.st ? "\x1b\\" : "\x07";
    return "\x1b]8;;" ~ term;
}

/// Closing sequence uses BEL terminator by default.
@("oscLink.oscLinkCloseSeq.bel")
@safe pure nothrow unittest
{
    assert(oscLinkCloseSeq() == "\x1b]8;;\x07");
}

/// Closing sequence with ST terminator.
@("oscLink.oscLinkCloseSeq.st")
@safe pure nothrow unittest
{
    assert(oscLinkCloseSeq(props: OscLinkProps(terminator: OscTerminator.st)) == "\x1b]8;;\x1b\\");
}

/// Wraps `text` in an OSC 8 hyperlink to `uri`.
pure nothrow
string oscLink(in char[] text, in char[] uri, OscLinkProps props = OscLinkProps.init)
{
    return oscLinkOpenSeq(uri: uri, props: props) ~ text ~ oscLinkCloseSeq(props: props);
}

/// Plain hyperlink with BEL terminator.
@("oscLink.oscLink.basic")
@safe pure nothrow unittest
{
    assert(oscLink(text: "Click", uri: "https://example.com")
        == "\x1b]8;;https://example.com\x07Click\x1b]8;;\x07");
}

/// Hyperlink with ST terminator.
@("oscLink.oscLink.st")
@safe pure nothrow unittest
{
    assert(oscLink(text: "Click", uri: "https://example.com", props: OscLinkProps(terminator: OscTerminator.st))
        == "\x1b]8;;https://example.com\x1b\\Click\x1b]8;;\x1b\\");
}

/// Hyperlink with id parameter.
@("oscLink.oscLink.withId")
@safe pure nothrow unittest
{
    assert(oscLink(text: "Click", uri: "https://example.com", props: OscLinkProps(id: "foo"))
        == "\x1b]8;id=foo;https://example.com\x07Click\x1b]8;;\x07");
}

/// Wraps styled `text` in an OSC 8 hyperlink to `uri`.
///
/// The SGR styling is applied inside the link, so terminal emulators
/// render the styled text as a clickable hyperlink.
pure nothrow
string oscLink(string text, in char[] uri, Style style, OscLinkProps props = OscLinkProps.init)
{
    import sparkles.core_cli.term_style : stylize;
    return oscLinkOpenSeq(uri: uri, props: props) ~ text.stylize(style) ~ oscLinkCloseSeq(props: props);
}

/// Styled hyperlink with blue.
@("oscLink.oscLink.styled")
@safe pure nothrow unittest
{
    import sparkles.core_cli.term_style : stylize;

    const result = oscLink(text: "Click", uri: "https://example.com", style: Style.blue);
    assert(result == "\x1b]8;;https://example.com\x07" ~ "Click".stylize(Style.blue) ~ "\x1b]8;;\x07");
}

/// Styled hyperlink with id and ST terminator.
@("oscLink.oscLink.styledWithProps")
@safe pure nothrow unittest
{
    import sparkles.core_cli.term_style : stylize;

    const result = oscLink(text: "Link", uri: "https://d-lang.org", style: Style.underline,
        props: OscLinkProps(terminator: OscTerminator.st, id: "dlang"));
    assert(result == "\x1b]8;id=dlang;https://d-lang.org\x1b\\" ~ "Link".stylize(Style.underline) ~ "\x1b]8;;\x1b\\");
}

/// `unstyledLength` works correctly with OSC links.
@("oscLink.unstyledLength")
@safe unittest
{
    import sparkles.core_cli.term_unstyle : unstyledLength;

    assert(oscLink(text: "Click here", uri: "https://example.com").unstyledLength == 10);
}

/// Styled OSC link unstyled length counts only the visible text.
@("oscLink.unstyledLength.styled")
@safe unittest
{
    import sparkles.core_cli.term_unstyle : unstyledLength;

    assert(oscLink(text: "Hello", uri: "https://example.com", style: Style.blue).unstyledLength == 5);
}

// Legacy test using test files
@system unittest
{
    import sparkles.core_cli.test_utils : readFromTestDir;

    // out0.txt: plain OSC 8 link with BEL terminator
    assert(oscLink(text: "example", uri: "https://example.com") == readFromTestDir("out0.txt"));

    // out1.txt: OSC 8 link with blue styling
    assert(oscLink(text: "example", uri: "https://example.com", style: Style.blue) == readFromTestDir("out1.txt"));
}
