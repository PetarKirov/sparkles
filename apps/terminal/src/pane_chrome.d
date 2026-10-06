/**
How panes are marked and labelled (`TSS11`, `ui.paneChrome`, mockup E), and
where each pane's content goes once its chrome has taken its share:

$(LIST
    * `reveal` (default) — no chrome; the focused pane wears an accent
        corner, and a pane's toolbar — title, directory, split, zoom, close —
        shows while the pointer is at its top (desktop) or after a tap on it
        (touch), until the next tap elsewhere;
    * `header` — a one-line header on every pane, bold with a bar on the
        focused one;
    * `framed` — a rounded frame with the title set in its top border,
        heavier and accented on the focused one.
)

Each mark is visible without colour (`ACC4`): the corner, the bold and the
bar, the heavier frame.
*/
module pane_chrome;

import sparkles.ui.components.dock : DockFrames, PaneId;
import sparkles.ui.geometry : Insets, Rect, SizeSpec;
import sparkles.ui.style : BorderStyle, Decoration, Slot, TextStyle;
import sparkles.ui.widget : Alignment, Builder, Widget, WidgetKind, WidgetTree;

import chrome : button, label, row, uiLabel;
import settings : ButtonLabels, PaneChrome;

/// One pane's place on screen, in pixels: all of it, and its content.
struct PaneBox
{
    PaneId id;
    /// The pane's whole rect, chrome included.
    Rect outer;
    /// Where the terminal is painted.
    Rect content;
    /// The content in cells.
    int cols, rows;
    bool focused;
}

/**
The boxes of the panes in `f` (cells within `area`, a pixel rect) under
`mode`: `header` and `framed` take the top row; `framed` also keeps its
lines clear of the text.
*/
PaneBox[] paneBoxes(in DockFrames f, in Rect area, int cw, int ch, PaneChrome mode,
    PaneId focused, int padX = 0, int padTop = 0) @safe pure nothrow
{
    PaneBox[] boxes;
    foreach (ref p; f.panes)
    {
        PaneBox b;
        b.id = p.pane;
        b.focused = p.pane == focused;
        b.outer = Rect(area.x + p.rect.x * cw, area.y + p.rect.y * ch,
            p.rect.width * cw, p.rect.height * ch);
        b.content = b.outer;
        final switch (mode)
        {
            case PaneChrome.reveal:
                b.content = Rect(b.outer.x + padX, b.outer.y + padTop,
                    b.outer.width - 2 * padX, b.outer.height - padTop);
                break;
            case PaneChrome.header:
                b.content = Rect(b.outer.x + padX, b.outer.y + ch,
                    b.outer.width - 2 * padX, b.outer.height - ch);
                break;
            case PaneChrome.framed:
                const pad = cw / 2 > 3 ? cw / 2 : 4;
                b.content = Rect(b.outer.x + pad, b.outer.y + ch, b.outer.width - 2 * pad,
                    b.outer.height - ch - pad);
                break;
        }
        b.cols = b.content.width / cw > 0 ? b.content.width / cw : 1;
        b.rows = b.content.height / ch > 0 ? b.content.height / ch : 1;
        // The part of a cell left over across goes half to each side.
        const spare = b.content.width - b.cols * cw;
        if (spare > 0)
            b.content = Rect(b.content.x + spare / 2, b.content.y, b.cols * cw, b.content.height);
        boxes ~= b;
    }
    return boxes;
}

/// The toolbar's targets: `toolHit + 4 * pane + k`.
enum size_t toolHit = 0x7A00_0000;
/// ditto
enum ToolAction : size_t
{
    split,
    zoom,
    close,
}

/// The header of `header` mode: one row, `▍title  directory`.
WidgetTree paneHeader(string title, string detail, bool focused, int cols) @safe
{
    Builder b;
    uint[] parts = [label(b, focused ? "▍" : "│", Slot.accentPrimary),
        keepTitle(b, uiLabel(b, title, focused ? Slot.textPrimary : Slot.muted, bold: focused))];
    if (detail.length)
        parts ~= label(b, detail, Slot.muted);
    return b.finish(b.add(Widget(kind: WidgetKind.row, children: parts, gap: 1,
        width: SizeSpec.fixed(cols), height: SizeSpec.fixed(1),
        slot: focused ? Slot.chromeFocused : Slot.chrome, paintBackground: true)));
}

/// The frame of `framed` mode, `cols` × `rows`, with `title` in its top
/// border.
WidgetTree paneFrame(string title, bool focused, int cols, int rows) @safe
{
    Builder b;
    const box = b.add(Widget(kind: WidgetKind.panel,
        width: SizeSpec.fixed(cols), height: SizeSpec.fixed(rows),
        decoration: Decoration(
            borderStyle: BorderStyle.solid,
            borderWidth: focused ? Insets(2, 2, 2, 2) : Insets(1, 1, 1, 1),
            borderSlot: focused ? Slot.accentPrimary : Slot.border, borderRadius: 6)));
    const name = b.add(Widget(kind: WidgetKind.row,
        children: [uiLabel(b, " " ~ title ~ " ", focused ? Slot.accentPrimary : Slot.muted,
            bold: focused)],
        padding: Insets(0, 0, 0, 1), slot: Slot.surfaceBase, paintBackground: true));
    const nameRow = b.add(Widget(kind: WidgetKind.row, children: [name],
        padding: Insets(0, 0, 0, 1)));
    return b.finish(b.add(Widget(kind: WidgetKind.stack, children: [box, nameRow],
        width: SizeSpec.fixed(cols), height: SizeSpec.fixed(rows))));
}

/// A pane's title gives way after its directory does: it keeps up to 16
/// cells when the row overflows (the tablet showed "b" for bash beside the
/// whole `/data/user/0/…` path).
private uint keepTitle(ref Builder b, uint title) @safe
{
    import sparkles.ui.geometry : cellsOf;

    const cells = cast(int) cellsOf(b.nodes[title].text);
    b.nodes[title].width.min = cells < 16 ? cells : 16;
    return title;
}

/// The toolbar `reveal` shows over a pane's top: its title and directory,
/// then split, zoom and close.
WidgetTree paneToolbar(PaneId pane, string title, string detail, ButtonLabels labels,
    int targetRows, int cols) @safe
{
    Builder b;
    const base = toolHit + 4 * pane;
    // Three captioned buttons need about 32 columns; a narrower pane (half a
    // phone) shows their icons, so Close stays on screen.
    if (labels != ButtonLabels.icon && cols < 40)
        labels = ButtonLabels.icon;
    uint[] name = [keepTitle(b, uiLabel(b, title, Slot.textPrimary, bold: true))];
    if (detail.length)
        name ~= label(b, detail, Slot.muted);
    const titleRow = b.add(Widget(kind: WidgetKind.row, children: name, gap: 1,
        width: SizeSpec.grow(), alignY: Alignment.center));
    uint[] parts = [titleRow,
        button(b, "◫", "Split", labels, base + ToolAction.split, minRows: targetRows),
        button(b, "⤢", "Zoom", labels, base + ToolAction.zoom, minRows: targetRows),
        button(b, "×", "Close", labels, base + ToolAction.close, minRows: targetRows)];
    return b.finish(b.add(Widget(kind: WidgetKind.row, children: parts, gap: 1,
        padding: Insets(0, 1, 0, 1), width: SizeSpec.fixed(cols), alignY: Alignment.center,
        slot: Slot.surfaceRaised, paintBackground: true,
        decoration: Decoration(borderStyle: BorderStyle.solid, borderWidth: Insets(1, 1, 1, 1), borderRadius: 16))));
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests.
// ─────────────────────────────────────────────────────────────────────────────

@("pane_chrome.paneBoxes.eachModeKeepsItsShare")
@safe unittest
{
    import sparkles.ui.components.dock : PaneFrame;

    DockFrames f;
    f.panes = [PaneFrame(1, Rect(0, 0, 40, 20)), PaneFrame(2, Rect(41, 0, 39, 20))];
    const area = Rect(48, 0, 800, 400);

    const reveal = paneBoxes(f, area, 10, 20, PaneChrome.reveal, 2);
    assert(reveal[0].outer == Rect(48, 0, 400, 400) && reveal[0].content == reveal[0].outer);
    assert(reveal[0].cols == 40 && reveal[0].rows == 20 && reveal[1].focused);

    const header = paneBoxes(f, area, 10, 20, PaneChrome.header, 2);
    assert(header[0].rows == 19, "the header takes a row");

    const framed = paneBoxes(f, area, 10, 20, PaneChrome.framed, 2);
    assert(framed[0].content.x == 48 + 5 && framed[0].cols == 39 && framed[0].rows == 18);
}

@("pane_chrome.paneBoxes.paddingKeepsTextOffTheEdges")
@safe pure nothrow unittest
{
    import sparkles.ui.components.dock : PaneFrame;

    // Two panes edge to edge (no divider cells); 10 × 20 px cells; 8 px
    // across and 4 px at the top. 40 cells are 400 px; less 16 px of padding
    // that is 38 whole cells and 4 px over, 2 px of it on each side.
    DockFrames f;
    f.panes = [PaneFrame(1, Rect(0, 0, 40, 20)), PaneFrame(2, Rect(40, 0, 40, 20))];
    const b = paneBoxes(f, Rect(0, 0, 800, 400), 10, 20, PaneChrome.reveal, 1, 8, 4);
    assert(b[0].content == Rect(10, 4, 380, 396) && b[0].cols == 38 && b[0].rows == 19);
    assert(b[1].content.x == 410, "the second pane pads from the shared boundary too");
}

@("pane_chrome.paneToolbar.hitsNameThePaneAndAction")
@safe unittest
{
    import chrome : place, Place;

    const l = place(paneToolbar(7, "zsh", "~/sparkles", ButtonLabels.icon, 1, 40), 40, 3,
        0, 0, 1, 1, Place.top);
    size_t[] ids;
    foreach (ref t; l.hits)
        ids ~= t.hitId;
    assert(ids == [toolHit + 28 + ToolAction.split, toolHit + 28 + ToolAction.zoom,
        toolHit + 28 + ToolAction.close]);
}

@("pane_chrome.paneToolbar.aLongTitleNeverCutsAButton")
@safe unittest
{
    import chrome : place, Place;

    // A directory far wider than the pane: the title gives way, the three
    // captions stay whole (they were cut to "S", "Zo", "Cl").
    const l = place(paneToolbar(1, "sh", "/tmp/a/very/long/working/directory/that/goes/on",
        ButtonLabels.iconText, 1, 40), 40, 3, 0, 0, 1, 1, Place.top);
    import sparkles.ui.geometry : cellsOf;

    // Each hit is a button: its rect holds its whole caption plus padding.
    const captions = ["◫ Split", "⤢ Zoom", "× Close"];
    assert(l.hits.length == 3);
    foreach (i, ref t; l.hits)
        assert(t.rect.width >= cellsOf(captions[i]) + 2, captions[i]);
}

@("pane_chrome.paneToolbar.aNarrowPaneShowsIcons")
@safe unittest
{
    import chrome : place, Place;

    // Half a phone: captions would run past the edge; icons keep all three
    // buttons inside the pane.
    const l = place(paneToolbar(1, "bash", "~", ButtonLabels.iconText, 1, 20), 20, 3,
        0, 0, 1, 1, Place.top);
    assert(l.hits.length == 3);
    foreach (ref t; l.hits)
        assert(t.rect.x + t.rect.width <= 20);
}

@("pane_chrome.paneToolbar.theTitleOutlastsTheDirectory")
@safe unittest
{
    import chrome : place, Place;

    // A pane of 50 columns in a long directory: "bash" stays whole, the
    // directory takes the cut.
    enum dir = "/data/user/0/dev.petar_kirov.sparkles.terminal.nix/files/home";
    const l = place(paneToolbar(1, "bash", dir, ButtonLabels.iconText, 1, 50), 50, 3,
        0, 0, 1, 1, Place.top);
    foreach (i, ref n; l.tree.nodes)
        if (n.text == "bash")
            assert(l.frames[i].rect.width == 4, "the title is cut");
}
