/**
The Text page: three wrap strategies at one width, and the width authority.

The three modes side by side is the only way `balanced` justifies itself — on a
paragraph whose greedy last line is a single orphan word, the minimum-squared-
slack pass visibly evens the block out, and on most paragraphs it does nothing.

The second half is `cellsOf`, and it is the page most likely to look $(B
different) in the terminal and in the window. That is a real open item, not a
bug in the page: the cell grid measures with `codepointWidth` (a wide glyph is
two columns) while the GPU canvas advances one column per codepoint. The page
says so where a reader will see it.
*/
module pages.text_page;

import std.conv : text;

import sparkles.input : Key, KeyEvent;
import sparkles.ui.geometry : cellsOf, SizeSpec;
import sparkles.ui.style : Slot;
import sparkles.ui.widget : Builder, Widget, WidgetKind;
import sparkles.ui.wrap : TextWrap;

import kit;
import state : GalleryState, TextDemo;

@safe:

/// ditto
static immutable string[] keys = ["+/- width", "h hang indent"];

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
        "Wrapped lines are slices of the input, never copies — the layout pass "
        ~ "reports where the breaks go and the painter draws the same bytes.", w);
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

    body_ ~= section(b, "cellsOf — the one width authority", [
        measured(b, "ascii"),
        measured(b, "a — b"),
        measured(b, "→ ✓ ◆"),
        measured(b, "日本語"),
        measured(b, "👍🏽"),
    ]);
    body_ ~= spacer(b);
    body_ ~= para(b,
        "cellsOf counts one column per codepoint, which is what the GPU "
        ~ "painter advances by. The terminal's cell grid measures a wide glyph "
        ~ "as two. The last two rows above therefore lay out differently in a "
        ~ "window and in a terminal — a known gap (LAY5/MIG5), shown here "
        ~ "rather than hidden, since this is the page where a reader would "
        ~ "otherwise conclude the toolkit is simply wrong.", w);

    return column(b, body_);
}

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

/// A string beside its two measurements: what `cellsOf` says, and how many
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
            label(b, text("cellsOf ", cellsOf(sample_)), Slot.chromeAccent),
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
bool handleKey(ref GalleryState s, in KeyEvent k)
{
    switch (k.ch)
    {
        case '+': case '=': s.textDemo.width += 2; return true;
        case '-': s.textDemo.width = s.textDemo.width > 12 ? s.textDemo.width - 2 : 12; return true;
        case 'h': s.textDemo.hangIndent = (s.textDemo.hangIndent + 1) % 5; return true;
        default: return false;
    }
}

@("ui_gallery.pages.textEveryWrapModeIsShown")
@safe unittest
{
    auto b = Builder();
    auto tree = b.finish(view(b, GalleryState.init));

    bool[TextWrap.max + 1] seen;
    foreach (ref n; tree.nodes)
        if (n.kind == WidgetKind.text && n.text == sample)
            seen[n.wrap] = true;

    static foreach (m; __traits(allMembers, TextWrap))
        assert(seen[__traits(getMember, TextWrap, m)],
            "the page never shows TextWrap." ~ m);
}

@("ui_gallery.pages.textGreedyAndBalancedProduceTheSameLineCount")
@safe unittest
{
    import sparkles.ui.geometry : Constraints;
    import sparkles.ui.layout : layout;

    // What `balanced` actually promises: it evens the lines out, it does not
    // use fewer of them. A page claiming otherwise would be teaching the wrong
    // thing, and this is cheaper than a screenshot to check.
    int lines(TextWrap mode)
    {
        auto b = Builder();
        const t = wrapped(b, mode, 40, 0);
        auto tree = b.finish(t);
        return layout(tree, Constraints(maxW: 40))[t].rect.height;
    }

    assert(lines(TextWrap.greedy) == lines(TextWrap.balanced));
    assert(lines(TextWrap.none) == 1, "none stays a single line");
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
