// Ghostty-free presentation types shared by the markdown-preview model and
// the ANSI decoder. Split out of `gui_ansi.d` so the preview model
// (`gui_preview.d`) compiles into the raylib-/ghostty-free `no-gui` build:
// only `decodeAnsi` (the off-screen libghostty-vt bridge) still lives in
// `gui_ansi.d` and is pulled in solely by the GUI build.
module ansi_model;

import sparkles.base.term_color : RgbColor;
import sparkles.syntax : AnsiOptions, ColorDepth;
import sparkles.ui.widget : TextSpan;

/// How the theme background is applied in terminal rendering (`--background`,
/// hue spec `BGM`) — shared by the whole-file ANSI emit, the markdown-preview
/// painter and the TUI. (Moved here from the retired `previewer.d`.)
enum BackgroundMode
{
    /// `no-background`: foreground only; the terminal's own background shows
    /// through (`BGM1`).
    noBackground,
    /// `spans`: emit a background only where a theme rule sets one, stopping at
    /// each line's last glyph (`BGM2`).
    spans,
    /// `full`: fill every line edge-to-edge with the theme's page background
    /// (`BGM3`, the default), matching a back-color-erase look.
    full,
}

/// The `AnsiOptions` background flags for whole-file rendering under `mode`.
AnsiOptions backgroundOptions(BackgroundMode mode, ColorDepth depth, bool italics)
    @safe pure nothrow @nogc
{
    return AnsiOptions(
        depth: depth,
        italics: italics,
        emitBackground: mode != BackgroundMode.noBackground,
        fillLine: mode == BackgroundMode.full,
    );
}

/// Neutral text-attribute bits shared by the ANSI decoder (`gui_ansi`) and
/// the views that consume decoded spans (`gui.d`/`document.d` map them onto
/// the toolkit's `TextStyle`).
enum Attr : ubyte
{
    bold          = 1 << 0,
    italic        = 1 << 1,
    underline     = 1 << 2,
    strikethrough = 1 << 3,
}

/// A maximal run of same-styled cells on one line. `fgDefault`/`bgDefault` mark
/// a cell that used the terminal *default* color (SGR 39/49 or never set): the
/// layout substitutes the theme's page fg/bg so ` ```ansi ` blocks stay
/// theme-consistent. `text` is owned (GC) UTF-8.
struct AnsiSpan
{
    string text;
    RgbColor fg;
    RgbColor bg;
    bool fgDefault;
    bool bgDefault;
    ubyte attrs;
}

/// One decoded line: its styled spans, left to right.
struct AnsiLine
{
    AnsiSpan[] spans;
}

/++
Gives the spans of a decoded ` ```ansi ` fence their place in the source
(`SEL6`), so selecting inside the fence is as precise as in a terminal.

Each line of `lines` is the decoding of the same line of `body_`. A
decoded span's text is the source text between escapes, so the spans are
matched against the source in order, skipping every escape sequence. A span
that an escape interrupts (the decoder merges runs whose style the escape
did not change) is split there. Every resulting piece is a contiguous slice
of the source, which is what a pointer's column → byte mapping needs:
`srcStart + byte index`.

Offsets are relative to `body_`, as a fence renderer's are. Where the
decoded text stops matching the source (a cursor movement, a tab the
terminal expanded), the rest of that line keeps no identity rather than a
wrong one.
+/
TextSpan[][] anchorAnsiLines(TextSpan[][] lines, scope const(char)[] body_)
    @safe pure
{
    TextSpan[][] anchored;
    anchored.reserve(lines.length);
    size_t lineStart = 0;
    foreach (line; lines)
    {
        size_t lineEnd = lineStart;
        while (lineEnd < body_.length && body_[lineEnd] != '\n')
            ++lineEnd;

        TextSpan[] out_;
        size_t at = lineStart;
        bool lost = lineStart > body_.length;
        foreach (sp; line)
        {
            size_t i = 0;
            while (i < sp.text.length)
            {
                if (!lost)
                    at = skipEscapes(body_, at, lineEnd);
                size_t j = i, k = at;
                if (!lost)
                    while (j < sp.text.length && k < lineEnd
                        && body_[k] != '\x1b' && body_[k] == sp.text[j])
                    {
                        ++j;
                        ++k;
                    }
                TextSpan piece = sp;
                if (j == i) // no longer the source: no identity from here on
                {
                    lost = true;
                    piece.text = sp.text[i .. $];
                    piece.srcStart = piece.srcEnd = size_t.max;
                    out_ ~= piece;
                    break;
                }
                piece.text = sp.text[i .. j];
                piece.srcStart = at;
                piece.srcEnd = k;
                out_ ~= piece;
                i = j;
                at = k;
            }
        }
        anchored ~= out_;
        lineStart = lineEnd + 1;
    }
    return anchored;
}

/// The first byte at or after `at` that is not inside an escape sequence:
/// CSI (`ESC [ … final`), OSC (`ESC ] … BEL` or `ESC \`), or a two-byte
/// `ESC x`.
private size_t skipEscapes(scope const(char)[] s, size_t at, size_t end)
    @safe pure nothrow @nogc
{
    while (at < end && s[at] == '\x1b')
    {
        if (at + 1 >= end)
            return end;
        const kind = s[at + 1];
        at += 2;
        if (kind == '[')
        {
            while (at < end && !(s[at] >= 0x40 && s[at] <= 0x7E))
                ++at;
            if (at < end)
                ++at; // the final byte
        }
        else if (kind == ']')
        {
            while (at < end && s[at] != '\x07'
                && !(s[at] == '\x1b' && at + 1 < end && s[at + 1] == '\\'))
                ++at;
            if (at < end)
                at += s[at] == '\x07' ? 1 : 2;
        }
    }
    return at;
}

@("ansi_model.anchorAnsiLines.eachPieceIsTheSourceItCameFrom")
@safe pure
unittest
{
    //            0         1         2
    //            0123456789012345678901234
    const body_ = "\x1b[31mred\x1b[0m plain\nnext\n";
    auto decoded = [
        [TextSpan("red"), TextSpan(" plain")],
        [TextSpan("next")],
    ];
    const a = anchorAnsiLines(decoded, body_);
    assert(a.length == 2);
    assert(a[0][0].text == "red" && a[0][0].srcStart == 5 && a[0][0].srcEnd == 8);
    assert(body_[a[0][1].srcStart .. a[0][1].srcEnd] == " plain");
    assert(body_[a[1][0].srcStart .. a[1][0].srcEnd] == "next");
}

@("ansi_model.anchorAnsiLines.aSpanAnEscapeInterruptsIsSplitThere")
@safe pure
unittest
{
    // A reset that changes nothing visible: the decoder reports one run "ab",
    // but its bytes are not contiguous in the source.
    const body_ = "a\x1b[0mb";
    const a = anchorAnsiLines([[TextSpan("ab")]], body_);
    assert(a[0].length == 2, "split at the escape");
    assert(a[0][0].text == "a" && a[0][0].srcStart == 0 && a[0][0].srcEnd == 1);
    assert(a[0][1].text == "b" && a[0][1].srcStart == 5 && a[0][1].srcEnd == 6);

    // An OSC hyperlink around text is skipped the same way.
    const link = "\x1b]8;;https://x\x07go\x1b]8;;\x1b\\";
    const b = anchorAnsiLines([[TextSpan("go")]], link);
    assert(link[b[0][0].srcStart .. b[0][0].srcEnd] == "go");
}

@("ansi_model.anchorAnsiLines.textThatIsNotTheSourceKeepsNoIdentity")
@safe pure
unittest
{
    // A terminal-expanded tab: the decoded spaces are not in the source.
    const a = anchorAnsiLines([[TextSpan("x"), TextSpan("    y")]], "x\ty");
    assert(a[0][0].srcStart == 0 && a[0][0].srcEnd == 1, "the match holds");
    assert(a[0][1].srcStart == size_t.max, "and stops where the text diverges");
    assert(a[0][1].text == "    y", "the text itself is kept");
}
