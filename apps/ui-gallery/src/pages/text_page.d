/**
The Text page: three wrap strategies at one width, and the width authority.

The three modes side by side is the only way `balanced` justifies itself — on a
paragraph whose greedy last line is a single orphan word, the minimum-squared-
slack pass visibly evens the block out, and on most paragraphs it does nothing.

The second half compares the owned terminalKitty `visibleWidth` cell profile
with byte counts. Extended graphemes stay whole; font appearance is a backend
property, not a second cell-width authority.
*/
module pages.text_page;

import std.conv : text;

import sparkles.input : Key, KeyEvent, PointerEvent, PointerAction, PointerButton;
import sparkles.base.text.grapheme : visibleWidth;
import sparkles.ui.geometry : SizeSpec;
import sparkles.ui.style : FontRole, Slot, TextStyle, TypeStep;
import sparkles.ui.layout : Frame;
import sparkles.ui.state : hoverTargets;
import sparkles.ui.widget : Builder, Widget, WidgetKind, WidgetTree;
import sparkles.ui.wrap : TextWrap;

import kit;
import keymap : GalleryCommand;
import state : GalleryState, TextDemo;

@safe:

/// ditto
// The page's keys are `galleryBindings` rows in `GalleryScope.pageText`.

/// The specimen paragraph. Chosen for a greedy break that leaves a short last
/// line at the page's default width, so `balanced` has something to do.
private enum sample =
    "A widget names a semantic slot, never a concrete colour, and the palette "
    ~ "resolves it while the display list is built.";

/// ditto
uint view(ref Builder b, in GalleryState s)
{
    const w = s.contentWidth;
    const d = s.textDemo;
    const col = clampWidth(d.width, w);

    uint[] body_;
    body_ ~= heading(b, "Text · wrapping and measurement");
    body_ ~= spacer(b);
    body_ ~= para(b,
        "Wrapping retains a source ledger and selected projection. Painting, "
        ~ "cell hits and copy consume that same plan; source bytes stay available.", w);
    body_ ~= spacer(b);
    body_ ~= row(b, [
        label(b, "column", Slot.muted),
        label(b, text(col, " cells"), Slot.chromeAccent),
        label(b, "hang", Slot.muted),
        label(b, d.hangIndent.text, Slot.chromeAccent),
    ]);
    body_ ~= spacer(b);

    body_ ~= section(b, "none — one line, clipped by whatever contains it", [
        wrapped(b, TextWrap.none, col, 0),
    ]);
    body_ ~= spacer(b);
    body_ ~= section(b, "greedy — break as late as possible", [
        wrapped(b, TextWrap.greedy, col, 0),
    ]);
    body_ ~= spacer(b);
    body_ ~= section(b, "balanced — minimum squared slack over all but the last line", [
        wrapped(b, TextWrap.balanced, col, 0),
    ]);
    body_ ~= spacer(b);
    body_ ~= section(b, "hang indent — continuation lines indent under the text", [
        wrapped(b, TextWrap.greedy, col, d.hangIndent, "• "),
    ]);
    body_ ~= spacer(b);

    body_ ~= section(b, "type scale — the interface face (GLY10)", [
        typed(b, "Settings", TypeStep.title, bold: true),
        typed(b, "Follow system light/dark", TypeStep.body),
        typed(b, "Switch colours with the system scheme", TypeStep.caption),
        typed(b, "✓ info · ⌕ source ▾ · ⚙ Settings", TypeStep.label),
    ]);
    body_ ~= spacer(b);
    body_ ~= para(b,
        "In a window these draw in the interface face — the system's sans, or "
        ~ "the bundled Roboto — at 17, 14, 12 and 13 density-independent "
        ~ "pixels; a title takes as many rows as its line needs. Icons the "
        ~ "face lacks come from the cell font at the same size. A terminal "
        ~ "keeps the cell font in the same rows and columns and reports "
        ~ "monospace-ui.", w);
    body_ ~= spacer(b);

    body_ ~= section(b, "visibleWidth — the one width authority", [
        measured(b, "ascii"),
        measured(b, "a — b"),
        measured(b, "→ ✓ ◆"),
        measured(b, "日本語"),
        measured(b, "👍🏽"),
        measured(b, "❤️ e\u0301"),
        measured(b, "👩‍💻 🇺🇸"),
    ]);
    body_ ~= spacer(b);
    body_ ~= para(b,
        "visibleWidth uses the shared terminalKitty cell profile: CJK occupies "
        ~ "two columns, accents remain attached, and flags and emoji sequences "
        ~ "advance as whole graphemes. Layout, clipping, and cell painting use "
        ~ "these same advances rather than counting UTF-8 bytes or scalars.", w);
    body_ ~= spacer(b);
    body_ ~= para(b,
        "The grid retains complete grapheme bytes and marks wide continuation "
        ~ "cells. These measurements describe terminalKitty revision 1; actual "
        ~ "terminal compatibility depends on the host's grapheme support and "
        ~ "negotiated capabilities, not on replacing an emoji with its leading "
        ~ "code point.", w);

    return column(b, body_);
}

/// One line in the interface face at `step`.
private uint typed(ref Builder b, string text_, TypeStep step, bool bold = false)
    => b.add(Widget(kind: WidgetKind.text, text: text_,
        textStyle: TextStyle(fontRole: FontRole.ui, typeStep: step, bold: bold)));

/// The sample, wrapped one way.
private uint wrapped(ref Builder b, TextWrap mode, int col, int hang,
    string leader = "")
{
    const run = b.add(Widget(
        kind: WidgetKind.text,
        text: leader.length ? leader ~ sample : sample,
        slot: Slot.code,
        width: SizeSpec.fixed(col),
        wrap: mode,
        hangIndent: hang,
    ));
    // `clipX` clips a node's CHILDREN, and a text node has none — so an
    // unwrapped run needs a clipping container around it or it draws straight
    // through the panel border beside it. Which is precisely the specimen: a
    // `none` run is clipped by whatever contains it, and here that is this.
    return b.add(Widget(
        kind: WidgetKind.column,
        children: [run],
        width: SizeSpec.fixed(col),
        clipX: true,
    ));
}

/// A string beside its two measurements: what `visibleWidth` says, and how many
/// bytes it is. The gap between them is why `.length` is never the answer.
private uint measured(ref Builder b, string sample_)
{
    const specimen_ = b.add(Widget(
        kind: WidgetKind.text,
        text: sample_,
        slot: Slot.code,
        width: SizeSpec.fixed(10),
    ));
    return b.add(Widget(
        kind: WidgetKind.row,
        children: [
            specimen_,
            label(b, text("visibleWidth ", visibleWidth(sample_)), Slot.chromeAccent),
            label(b, text("bytes ", sample_.length), Slot.muted),
        ],
        gap: 2,
    ));
}

/// The wrap column, kept inside the pane and wide enough to break at all.
int clampWidth(int want, int pane) pure nothrow @nogc
{
    const hi = pane - 6 > 12 ? pane - 6 : 12;
    return want < 12 ? 12 : (want > hi ? hi : want);
}

/// ditto
bool handleCommand(ref GalleryState s, GalleryCommand cmd, ubyte arg)
{
    switch (cmd)
    {
        case GalleryCommand.textGrow:
            s.textDemo.width += 2;
            return true;
        case GalleryCommand.textShrink:
            s.textDemo.width = s.textDemo.width > 12 ? s.textDemo.width - 2 : 12;
            return true;
        case GalleryCommand.textHang:
            s.textDemo.hangIndent = (s.textDemo.hangIndent + 1) % 5;
            return true;
        default: return false;
    }
}


@("ui_gallery.pages.textWidthKnobStaysInsideThePane")
@safe unittest
{
    // The column can never exceed the pane it is drawn in — a wrap width wider
    // than the surface is a paragraph clipped rather than wrapped.
    foreach (pane; [20, 57, 120])
        foreach (want; [-5, 0, 12, 40, 400])
        {
            const c = clampWidth(want, pane);
            assert(c >= 12);
            assert(c <= pane || c == 12, "wider than the pane only when the pane is tiny");
        }
}
