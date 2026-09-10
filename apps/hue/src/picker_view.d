/** Shared `sparkles:ui` picker widget tree for GUI and terminal backends. */
module picker_view;

import std.conv : text;

import sparkles.fuzzy : CandidateSnapshot, RankedResult, TextRange;
import sparkles.ui.geometry : Insets, Rect, SizeSpec;
import sparkles.ui.layout : Frame;
import sparkles.ui.components.chrome : scrollbar, ScrollbarGlyphs,
    ScrollbarSpec;
import sparkles.ui.state : ScrollAxis;
import sparkles.ui.style : BorderStyle, Decoration, Slot, TextStyle;
import sparkles.ui.widget : Alignment, Builder, TextSpan, Widget, WidgetKind,
    WidgetTree;
import sparkles.ui.wrap : TextWrap;

import explorer : fsIcon;
import keymap : Scope_;
import picker : PickerState;

/// Supported picker presentation presets.
enum PickerLayout : ubyte
{
    default_, /// list and preview side by side
    vscode,   /// compact dropdown, no preview
    select,   /// small short-list panel
}

/**
One row's fuzzy-match byte ranges, derived at render time by the host — the
positions-on-demand doctrine: ranges are never stored on results, and `ranges`
borrows the host's fixed storage for exactly this build.
*/
struct RowHighlight
{
    const(TextRange)[] ranges;
}

/**
One content-search row, as the view needs it (`PKS2`/`PKC11`).

A plain data shape rather than the grep source's own types, so the view
stays ignorant of the scanner: the host fills these in from its hits, and
`picker_view` renders text. A row is rendered in grep form exactly when the
caller supplies one of these for it.

Offsets are into `context`, which is the stored window — already trimmed
and possibly elided — never into the source line.
*/
struct GrepRowText
{
    /// The document's display label: a repository-relative path, or a name
    /// for a document that has none (`PR #476 · src/app.d`).
    const(char)[] label;
    /// The stored window around the match.
    const(char)[] context;
    /// 1-based source position, rendered as the `:12:5` suffix a reader can
    /// paste back into the prompt (`PKQ4`).
    uint line;
    uint column;
    /// The match, as an offset into `context`.
    ushort matchStart;
    ushort matchLen;
    /// Whether the window dropped text on each side.
    bool elidedLeft, elidedRight;
    /// The line defines the matched name rather than mentioning it
    /// (`PKC14`). Rendered as a marker, because a ranking nudge nobody can
    /// SEE is indistinguishable from a ranking bug.
    bool definition;
}

/**
Frame-stable overlay geometry: both panels are exactly `panelCols` ×
`panelRows`, whatever the rows or the previewed file contain — so switching
files never moves a border and never re-splits the columns.
*/
struct PickerGeometry
{
    int panelCols = 48;
    int panelRows = 20;
}

/// The `key` marking the preview panel's content box, so a host can find its
/// laid-out rect and paint the document pane into it.
enum size_t pickerPreviewKey = 0x9c4b_9e77;

/// Identity for the list's horizontal bar (`WGT5`), so the host finds the
/// rect it was painted at rather than re-deriving one — `SCV7`'s rule that
/// paint geometry and hit geometry are the same derivation.
enum size_t pickerHBarHitId = 0x9c4b_9e78;

/// ditto, for the list's vertical bar.
enum size_t pickerVBarHitId = 0x9c4b_9e79;

/// The eased 0..100 the scrollbar op carries, clamped from a float.
private ubyte clampPercent(float v) @safe pure nothrow @nogc
    => v <= 0 ? 0 : v >= 100 ? 100 : cast(ubyte) v;

/// The overlay geometry both hosts derive from their screen size (in cells)
/// alone — never from content, which is what keeps the frame stable.
/// The list panel's inner content box, in cells (`SCV7`).
///
/// One derivation for both the rows the list can show and the columns a row
/// has. The panel's padding is `Insets(1, 2, 1, 2)`, so four columns and two
/// rows never belong to content — and the chrome inside it (the prompt, the
/// rule under it, the horizontal bar) takes three more rows.
///
/// Computing these separately is what left the list painting sixteen rows in
/// a forty-row panel and its horizontal scroll two columns short of the end.
struct PickerListBox
{
    int cols;
    int rows;
}

/// ditto
PickerListBox pickerListBox(in PickerGeometry geometry)
    @safe pure nothrow @nogc
{
    // padding (2 left + 2 right) and the vertical bar's reserved gutter.
    // The gutter is reserved whether or not the bar is live: a lane that
    // appears with the bar would reflow every row at the ranking depth
    // where it first overflows. Forgetting it here trimmed each row to one
    // cell WIDER than the column it is painted in, so the last character
    // clipped and the selection background stopped a cell short of it.
    const cols = geometry.panelCols - 4 - 1;
    const rows = geometry.panelRows - 2    // padding: 1 top + 1 bottom
        - 1                                // the prompt
        - 1                                // the rule under it
        - 1;                               // the horizontal bar's lane
    return PickerListBox(cols: cols > 1 ? cols : 1, rows: rows > 1 ? rows : 1);
}

/// The most a single panel grows to. Past this a row is wider than the eye
/// tracks in one sweep, and the pair of panels stops reading as a pair.
enum int pickerMaxPanelCols = 90;

/// The most rows a panel grows to. A list nobody scrolls is not more useful
/// for being longer, and the preview beside it has the same height.
enum int pickerMaxPanelRows = 45;

PickerGeometry pickerGeometryFor(int screenCols, int screenRows)
    @safe pure nothrow @nogc
{
    // Take a fixed SHARE of the screen rather than a fixed number of cells.
    // The previous caps (60 x 30) were sized for a terminal window and left
    // a 200-column screen showing a picker over a third of it — the panels
    // stayed put while everything around them grew.
    int cols = screenCols * 8 / 10 / 2; // ~80% of the width, split in two
    if (cols > pickerMaxPanelCols)
        cols = pickerMaxPanelCols;
    if (cols < 20)
        cols = screenCols / 2 > 10 ? screenCols / 2 : 10;

    int rows = screenRows * 85 / 100;
    if (rows > pickerMaxPanelRows)
        rows = pickerMaxPanelRows;
    if (rows > screenRows - 3)
        rows = screenRows - 3;
    if (rows < 6)
        rows = screenRows > 2 ? screenRows - 2 : screenRows;
    return PickerGeometry(panelCols: cols, panelRows: rows);
}

/// The preview panel's content rect after layout (`Rect.init` when the
/// preset has no preview panel).
Rect pickerPreviewRect(in WidgetTree tree, scope const(Frame)[] frames)
    @safe pure nothrow @nogc
{
    foreach (i, ref node; tree.nodes)
        if (node.key == pickerPreviewKey && i < frames.length)
            return frames[i].rect;
    return Rect.init;
}

/**
Build one backend-neutral picker frame.

Rows borrow candidate paths from `snapshot`; the snapshot must be the same
immutable corpus generation used by the scheduler. `highlights` runs parallel
to `state.rows` (missing tail entries mean "no highlight").
*/
WidgetTree pickerView(size_t Capacity, size_t PromptCapacity)(
    in PickerState!(Capacity, PromptCapacity) state,
    in CandidateSnapshot snapshot,
    scope const(RowHighlight)[] highlights = null,
    const(char)[] previewTitle = null,
    PickerGeometry geometry = PickerGeometry.init,
    PickerLayout preset = PickerLayout.default_,
    Scope_ focus = Scope_.pickerInput,
    scope const(GrepRowText)[] grepRows = null,
    const(char)[] modeLabel = null)
{
    auto builder = Builder();
    // The focused pane's panel carries the accent chrome, and INSIDE the
    // files panel the backgrounds say which half owns the keyboard (`PKL7`
    // — the reader must see where keys go): the prompt row lights its band
    // while the input is focused (the `DockHeader` `chromeFocused`
    // convention), the selection bar brightens while the list is, dims to
    // a tint while the prompt types, and rests while the preview reads.
    const previewFocused = focus == Scope_.pickerPreview;
    const inputFocused = focus == Scope_.pickerInput;
    const listFocused = focus == Scope_.pickerList;

    // ── the prompt row: `› query▏` left, `matched/total` right ────────────
    TextSpan[] promptSpans;
    promptSpans ~= TextSpan(text: "› ", slot: Slot.chromeAccent,
        textStyle: TextStyle(bold: true));
    // Copied, not borrowed: the prompt accessor is `return scope` into the
    // caller's state, which the tree must not capture.
    promptSpans ~= TextSpan(text: state.prompt.text.idup);
    // The caret lives where the keys go: only the prompt pane shows it.
    if (focus == Scope_.pickerInput)
        promptSpans ~= TextSpan(text: "▏", slot: Slot.caret);
    if (state.searching)
        promptSpans ~= TextSpan(text: " …", slot: Slot.muted);
    const promptText = builder.add(Widget(kind: WidgetKind.rich,
        spans: promptSpans, width: SizeSpec.grow()));
    uint[] promptChildren = [promptText];
    // `PKL5`: the active search mode, shown because `PKC9` classifies the
    // query ONCE and falls back at most once — a reader who cannot see
    // which question was asked cannot explain the result list. A
    // single-mode configuration passes none and the indicator disappears.
    if (modeLabel.length)
        promptChildren ~= builder.add(Widget(kind: WidgetKind.text,
            text: text("[", modeLabel, "]"), slot: Slot.chromeAccent));
    if (state.corpusTotal != 0)
        promptChildren ~= builder.add(Widget(kind: WidgetKind.text,
            text: text(state.matchedTotal, "/", state.corpusTotal),
            slot: Slot.muted));
    const promptRow = builder.add(Widget(kind: WidgetKind.row,
        children: promptChildren, width: SizeSpec.grow(),
        slot: inputFocused ? Slot.chromeFocused : Slot.inherit,
        paintBackground: inputFocused));

    // ── the ranked rows: icon · dimmed directory · filename · match marks ─
    uint[] body;
    uint[] rowNodes;
    size_t widest;
    body ~= promptRow;
    // A rule between the query and its answers. Without it the prompt reads
    // as the list's first row — which it is not, and which matters most
    // exactly when the top pick is selected and two adjacent lines are both
    // highlighted.
    {
        // Drawn as glyphs rather than a bordered box: a box's border is a
        // px stroke the cell backend renders on its EDGE, which lands on
        // the row above or below rather than in the row itself, and shows
        // as a blank line.
        const ruleCols = geometry.panelCols > 2 ? geometry.panelCols - 2 : 1;
        char[] rule;
        foreach (_; 0 .. ruleCols)
            rule ~= "─";
        body ~= builder.add(Widget(kind: WidgetKind.text,
            text: rule.idup, slot: Slot.border));
    }
    // The PAINTED window, not the whole ranking (`pickerTopK` is deeper
    // than the viewport). `highlights` is window-relative; `selection` is
    // ranking-relative, so the comparison adds the scroll offset back.
    foreach (i, ranked; state.visible)
    {
        TextSpan[] spans;
        // How many leading spans identify the ROW rather than describe it,
        // and so must survive a sideways scroll: a files row leads with its
        // icon, a grep row with its icon and its definition marker.
        size_t pinnedSpans;
        bool definitionRow;
        if (i < grepRows.length)
        {
            grepSpans(spans, grepRows[i]);
            pinnedSpans = 1; // the file icon; the marker is a tint now
            definitionRow = grepRows[i].definition;
        }
        else if (ranked.corpusIndex < snapshot.candidates.length)
        {
            pinnedSpans = 1;
            const candidate = snapshot.candidates[ranked.corpusIndex];
            const icon = fsIcon(candidate.path[candidate.filenameOffset .. $]);
            spans ~= TextSpan(text: icon.glyph, fg: icon.fg, hasFg: true,
                noBreak: true);
            pathSpans(spans, candidate.path, candidate.filenameOffset,
                i < highlights.length ? highlights[i].ranges : null);
        }
        else
            spans ~= TextSpan(text: "(stale row)", slot: Slot.muted);

        // Measure BEFORE trimming: the bar describes the whole row, and the
        // widest row is what the offset clamps against.
        {
            import sparkles.source_view.search : columnWidth;

            size_t w;
            foreach (ref const sp; spans)
                w += columnWidth(sp.text);
            if (w > widest)
                widest = w;
        }
        // The file-type icon is PINNED: it identifies the row and costs two
        // cells, so scrolling it away trades the row's only at-a-glance
        // marker for two more columns of path. The viewer pins its gutter
        // strips the same way (`pinnedCols`), and for the same reason.
        if (state.hOffset)
        {
            if (spans.length > pinnedSpans && pinnedSpans > 0)
            {
                auto rest = spans[pinnedSpans .. $];
                trimLeading(rest, state.hOffset);
                spans = spans[0 .. pinnedSpans] ~ rest;
            }
            else
                trimLeading(spans, state.hOffset);
        }
        // The selection bar's strength follows the focus — snacks dims its
        // cursorline the same way when focus leaves the list: bright while
        // the list owns the keyboard, a tint while the prompt types, at
        // rest while the preview reads.
        const selected = state.firstRow + i == state.selection;
        // A visible selection outranks the definition tint — the cursor must
        // stay findable, and a row can be both. But when the selection
        // paints NOTHING (the preview holds the focus, so the bar is at
        // rest), the definition tint is what that row still has to say.
        Slot rowSlot = Slot.inherit;
        if (selected)
            rowSlot = listFocused ? Slot.selection
                : inputFocused ? Slot.highlight : Slot.inherit;
        if (rowSlot == Slot.inherit && definitionRow)
            rowSlot = Slot.highlight;
        rowNodes ~= builder.add(Widget(kind: WidgetKind.rich,
            spans: spans,
            slot: rowSlot,
            paintBackground: rowSlot != Slot.inherit,
            hitId: ranked.corpusIndex + 1,
            width: SizeSpec.grow()));
    }
    if (state.rowCount == 0)
        rowNodes ~= builder.add(Widget(kind: WidgetKind.text,
            text: state.searching ? "searching…" : "no matches",
            slot: Slot.muted));

    // The rows and their vertical bar share a row, so the bar spans exactly
    // the rows' height and the list keeps a reserved gutter whether or not
    // the bar is live (`SCV`: a lane that appears and disappears makes the
    // list reflow at the width where content just fits).
    {
        // Clipped on BOTH axes. Without `clipX` a row's text painted past
        // its own frame — the panel's outer column clipped it a cell later,
        // so the last character showed while the row's background, which
        // covers the frame, stopped before it. The reported symptom was a
        // selected row whose final letter looked unselected.
        const rowsColumn = builder.add(Widget(kind: WidgetKind.column,
            children: rowNodes, width: SizeSpec.grow(),
            height: SizeSpec.grow(), clipX: true, clipY: true));
        uint[] listChildren = [rowsColumn];
        if (state.rowCount > state.viewRows)
            listChildren ~= scrollbar(builder, ScrollbarSpec(
                content: cast(long) state.rowCount,
                viewport: cast(long) state.viewRows,
                offset: cast(long) state.firstRow,
                axis: ScrollAxis.vertical,
                expandPercent: clampPercent(state.scroll.vAnim.percent),
                hitId: pickerVBarHitId,
                glyphs: ScrollbarGlyphs('█', '░')),
                cast(int) state.viewRows);
        else
            listChildren ~= builder.add(Widget(kind: WidgetKind.box,
                width: SizeSpec.fixed(1), height: SizeSpec.grow()));
        body ~= builder.add(Widget(kind: WidgetKind.row,
            children: listChildren, width: SizeSpec.grow(),
            height: SizeSpec.grow()));
    }

    // `PKL8`: the list's horizontal bar — the toolkit's `WidgetKind.scrollbar`
    // node (`SCV1`), not a string of glyphs. The first version of this drew
    // its own track and thumb, which made it the seventh site to assemble a
    // scrollbar by convention in a codebase that had just collapsed six into
    // one component. Emitting the node means the px backend animates and
    // hover-expands it, the cell backend degrades it, and its geometry is
    // the one both paint and hit-testing read.
    // The list row above grows, so the bar already sits at the panel's
    // bottom edge; a grower here would claim height the rows need and push
    // the bar out of a short panel entirely — which is what hid it whenever
    // the panel was shorter than the ranking.
    if (widest > state.viewCols)
    {
        const track = geometry.panelCols > 2 ? geometry.panelCols - 2 : 1;
        body ~= scrollbar(builder, ScrollbarSpec(
            content: cast(long) widest,
            viewport: cast(long) state.viewCols,
            offset: cast(long) state.hOffset,
            axis: ScrollAxis.horizontal,
            // The eased expansion, as the semantic 0..100 the op carries —
            // never a pixel width, which is the bargain that let the five
            // rail-width copies be deleted.
            expandPercent: clampPercent(state.scroll.hAnim.percent),
            hitId: pickerHBarHitId,
            glyphs: ScrollbarGlyphs('━', '─')), track);
    }

    const inspection = state.debugScore;
    if (inspection.present)
    {
        const score = inspection.result.score;
        body ~= builder.add(Widget(kind: WidgetKind.text,
            text: text("score ", score.total,
                " = fuzzy ", score.base,
                " + frecency ", score.frecency,
                " + git ", score.gitModified,
                " + distance ", score.directoryDistance,
                " + filename ", score.filename,
                " + current ", score.currentFilePenalty,
                " + combo ", score.combo,
                " + path ", score.pathAlignment),
            slot: Slot.info, wrap: TextWrap.greedy));
    }
    if (state.error.code)
        body ~= builder.add(Widget(kind: WidgetKind.text,
            text: text("picker error: ", state.error.code),
            slot: Slot.error));

    const filesPanel = titledPanel(builder, body, " Files ", geometry,
        focused: !previewFocused);
    uint root;
    final switch (preset)
    {
    case PickerLayout.vscode:
    case PickerLayout.select:
        root = filesPanel;
        break;
    case PickerLayout.default_:
        // The preview panel is a fixed-size framed hole: the host paints its
        // own document pane (`picker_preview`) into the content rect this
        // keyed box lays out to — the pane is a live `PreviewTui`, not
        // widget rows, so the view only reserves and frames its space.
        uint[] previewBody = [builder.add(Widget(kind: WidgetKind.box,
            key: pickerPreviewKey,
            width: SizeSpec.grow(), height: SizeSpec.grow()))];
        const title = previewTitle.length
            ? text(" ", previewTitle, " ") : " preview ";
        // The border and nothing more. A panel's padding is measured from
        // its edge, so 1 clears the border stroke and 0 would paint the
        // document OVER it; the default 2 columns then spend a cell a side
        // on air. The files panel keeps the default — its rows are chrome
        // and want the breathing room; a document wants the columns.
        const previewPanel = titledPanel(builder, previewBody, title,
            geometry, focused: previewFocused, padding: Insets.all(1));
        root = builder.add(Widget(kind: WidgetKind.row,
            children: [filesPanel, previewPanel]));
        break;
    }
    return builder.finish(root);
}

/**
A fixed-size bordered surface with its heading embedded in the top border.

The panel is a stack, and a stack's children share its origin — so a
full-width centered row drawn second lands its title text ON the border row,
interrupting the line exactly the way fzf-lua/telescope draw theirs. The
fixed `geometry` is what keeps the overlay frame-stable: content never
resizes a panel, it clips inside one (`clipX`/`clipY`).

`focused` is the chrome half of `PKL7`: the pane that owns the keyboard gets
the highlight border and the accent title, its sibling the muted ones.
*/
private uint titledPanel(ref Builder builder, uint[] body,
    const(char)[] title, in PickerGeometry geometry, bool focused = true,
    Insets padding = Insets(1, 2, 1, 2))
    @safe
{
    const content = builder.add(Widget(kind: WidgetKind.column,
        children: body, width: SizeSpec.grow(), height: SizeSpec.grow(),
        clipX: true, clipY: true));
    const boxed = builder.add(Widget(kind: WidgetKind.panel,
        children: [content],
        padding: padding,
        slot: Slot.surface, paintBackground: true,
        // `borderRadius` doubles as the rounded-corner flag: the window
        // rounds the stroke, the cell canvas picks `╭╮╰╯`.
        decoration: Decoration(borderWidth: Insets.all(2),
            borderStyle: BorderStyle.solid, borderRadius: 6,
            borderSlot: focused ? Slot.highlightBorder : Slot.border),
        width: SizeSpec.fixed(geometry.panelCols),
        height: SizeSpec.fixed(geometry.panelRows)));
    const titleText = builder.add(Widget(kind: WidgetKind.text,
        text: title, slot: focused ? Slot.chromeAccent : Slot.muted,
        textStyle: TextStyle(bold: focused)));
    const titleRow = builder.add(Widget(kind: WidgetKind.row,
        children: [titleText],
        width: SizeSpec.fixed(geometry.panelCols),
        alignX: Alignment.center));
    return builder.add(Widget(kind: WidgetKind.stack,
        children: [boxed, titleRow],
        width: SizeSpec.fixed(geometry.panelCols),
        height: SizeSpec.fixed(geometry.panelRows)));
}

/**
Split one path into styled spans: the directory prefix muted, the filename
plain, and every fuzzy-matched byte range bright + bold (`Slot.matched`) —
crossing either boundary splits the span, never the color.
*/
private void pathSpans(ref TextSpan[] spans, const(char)[] path,
    size_t filenameOffset, scope const(TextRange)[] ranges) @safe
{
    size_t at;
    while (at < path.length)
    {
        const matched = inRange(ranges, at);
        size_t end = path.length;
        // The next boundary: a range edge or the directory/filename split.
        foreach (r; ranges)
        {
            if (r.start > at && r.start < end)
                end = r.start;
            if (r.end > at && r.end < end)
                end = r.end;
        }
        if (filenameOffset > at && filenameOffset < end)
            end = filenameOffset;
        spans ~= TextSpan(text: path[at .. end],
            slot: matched ? Slot.matched
                : at < filenameOffset ? Slot.muted : Slot.inherit,
            textStyle: matched ? TextStyle(bold: true) : TextStyle.init);
        at = end;
    }
}

/**
Render one content-search row: marker · label · `:line:col` · the window.

The match inside the window carries `Slot.matched` exactly as a fuzzy path
match does, so the two row kinds highlight the same way and a reader learns
one convention. Elision is spelled with `…` on the side that was cut —
ripgrep's `--max-columns-preview` behaviour — because a silently truncated
line reads as a complete one.
*/
private void grepSpans(ref TextSpan[] spans, GrepRowText row) @safe
{
    // The same file-type icon a files row leads with. A grep row names a
    // document too, and reading a list of them without the type marker the
    // rest of the app uses is a gratuitous difference.
    const icon = fsIcon(baseNameOf(row.label));
    spans ~= TextSpan(text: icon.glyph, fg: icon.fg, hasFg: true,
        noBreak: true);

    // A definition is marked, not merely ranked — a nudge nobody can see is
    // indistinguishable from a ranking bug (`PKC14`) — but it is marked with
    // a BACKGROUND TINT rather than a leading glyph. An arrow in the text
    // reads as punctuation the reader has to decode, and it costs two
    // columns on every row to say something about a minority of them.
    spans ~= TextSpan(text: row.label, slot: Slot.muted, noBreak: true);

    spans ~= TextSpan(text: row.column != 0
            ? text(":", row.line, ":", row.column)
            : text(":", row.line),
        slot: Slot.muted, noBreak: true);
    spans ~= TextSpan(text: "  ", noBreak: true);

    if (row.elidedLeft)
        spans ~= TextSpan(text: "…", slot: Slot.muted, noBreak: true);

    const ctx = row.context;
    const from = row.matchStart <= ctx.length ? row.matchStart : ctx.length;
    const to = from + row.matchLen <= ctx.length
        ? from + row.matchLen : ctx.length;
    if (from)
        spans ~= TextSpan(text: ctx[0 .. from]);
    if (to > from)
        spans ~= TextSpan(text: ctx[from .. to], slot: Slot.matched,
            textStyle: TextStyle(bold: true));
    if (to < ctx.length)
        spans ~= TextSpan(text: ctx[to .. $]);

    if (row.elidedRight)
        spans ~= TextSpan(text: "…", slot: Slot.muted, noBreak: true);
}

/**
Drop the first `cells` display columns from a rendered row (`PKL8`).

The list scrolls sideways by trimming TEXT rather than by translating the
widget subtree: a row is spans, the panel clips at its border, and shifting
the layout would push the row under the border instead of past it. Trimming
also keeps every span's style intact — the match stays `Slot.matched` even
when its first half scrolls away.

Spans are dropped whole while they fit entirely before the cut, then the
straddling one is sliced at a character boundary.
*/
private void trimLeading(ref TextSpan[] spans, size_t cells) @safe
{
    import sparkles.source_view.search : columnWidth;

    if (cells == 0)
        return;
    size_t dropped;
    size_t i;
    while (i < spans.length)
    {
        const w = columnWidth(spans[i].text);
        if (dropped + w <= cells)
        {
            dropped += w;
            ++i;
            continue;
        }
        // Slice this span at the cut. Advance by whole characters so a
        // multi-byte glyph is never halved.
        auto t = spans[i].text;
        size_t at;
        while (at < t.length && dropped < cells)
        {
            size_t step = 1;
            while (at + step < t.length
                && (cast(ubyte) t[at + step] & 0xC0) == 0x80)
                ++step;
            dropped += columnWidth(t[at .. at + step]);
            at += step;
        }
        spans[i].text = t[at .. $];
        break;
    }
    spans = spans[i .. $];
}

/// The last path segment of `p` — the part `fsIcon` reads an extension from.
private const(char)[] baseNameOf(return scope const(char)[] p)
    @safe pure nothrow @nogc
{
    foreach_reverse (i, c; p)
        if (c == '/')
            return p[i + 1 .. $];
    return p;
}

private bool inRange(scope const(TextRange)[] ranges, size_t at)
    @safe pure nothrow @nogc
{
    foreach (r; ranges)
        if (at >= r.start && at < r.end)
            return true;
    return false;
}

@("picker.view.rowsIconsHighlightsAndTitledPanelsShareOneTree")
@safe
unittest
{
    import std.algorithm.searching : canFind;
    import sparkles.fuzzy : CandidateView, RankedResult;

    CandidateView[1] candidates;
    candidates[0].path = "src/app.d";
    candidates[0].filenameOffset = 4;
    CandidateSnapshot snapshot;
    snapshot.candidates = candidates[];
    PickerState!4 state;
    state.open();
    RankedResult[1] rows;
    rows[0].score.total = 42;
    rows[0].score.base = 30;
    state.publish(rows[], 1, false);
    state.matchedTotal = 1;
    state.corpusTotal = 9;
    state.toggleScoreDebug();

    static immutable TextRange[1] matchRanges = [TextRange(4, 7)]; // "app"
    static immutable RowHighlight[1] highlights
        = [RowHighlight(matchRanges[])];

    const geometry = PickerGeometry(panelCols: 40, panelRows: 12);
    const tree = pickerView(state, snapshot, highlights[], "app.d", geometry);
    bool sawDir, sawMatch, sawTail, sawIcon;
    bool sawScore, sawTitle, sawPreviewTitle, sawCount;
    foreach (node; tree.nodes)
    {
        sawScore |= node.text.canFind("score 42");
        sawTitle |= node.text == " Files ";
        sawPreviewTitle |= node.text.canFind("app.d");
        sawCount |= node.text == "1/9";
        foreach (span; node.spans)
        {
            sawDir |= span.text == "src/" && span.slot == Slot.muted;
            sawMatch |= span.text == "app" && span.slot == Slot.matched;
            sawTail |= span.text == ".d" && span.slot == Slot.inherit;
            sawIcon |= span.hasFg && span.text.length && span.text[0] > 0x7F;
        }
    }
    assert(sawDir && sawMatch && sawTail, "the path splits at every boundary");
    assert(sawIcon, "the row leads with a file-type icon");
    assert(sawScore && sawTitle && sawPreviewTitle && sawCount);

    // Fixed geometry: the panels lay out to exactly the asked size wherever
    // the content lands, and the preview hole is findable and inside the
    // right-hand panel.
    import sparkles.ui.geometry : Constraints;
    import sparkles.ui.layout : layout;

    auto frames = layout(tree, Constraints(maxW: 2 * geometry.panelCols));
    const whole = frames[tree.root].rect;
    assert(whole.width == 2 * geometry.panelCols
        && whole.height == geometry.panelRows, "the overlay is frame-stable");
    const hole = pickerPreviewRect(tree, frames);
    assert(hole.width > 0 && hole.height > 0);
    assert(hole.x >= geometry.panelCols, "the hole is in the preview panel");
    assert(hole.width <= geometry.panelCols - 2
        && hole.height <= geometry.panelRows - 2,
        "the hole sits inside the preview panel's frame");
}

@("picker.view.focusSelectsTheChrome")
@safe
unittest
{
    import std.algorithm.searching : canFind;
    import sparkles.fuzzy : CandidateView, RankedResult;
    import sparkles.ui.style : Decoration;

    CandidateView[1] candidates;
    candidates[0].path = "src/app.d";
    candidates[0].filenameOffset = 4;
    CandidateSnapshot snapshot;
    snapshot.candidates = candidates[];
    PickerState!4 state;
    state.open();
    RankedResult[1] rows;
    state.publish(rows[], 1, false);

    // Panel chrome, caret, and the in-panel backgrounds per focused pane
    // (`PKL7`): the pane that owns the keyboard gets the highlight border
    // and the accent title; INSIDE the files panel the prompt's band lights
    // while the input is focused and the selection bar brightens while the
    // list is — the flip that shows which half `Tab` landed on.
    static struct Seen
    {
        Slot filesTitle, previewTitle, filesBorder, previewBorder;
        bool caret, promptBand, brightBar, dimBar;
    }

    static Seen scan(in WidgetTree tree) @safe
    {
        Seen s;
        int panels;
        foreach (node; tree.nodes)
        {
            if (node.text == " Files ")
                s.filesTitle = node.slot;
            if (node.kind == WidgetKind.text && node.text.canFind("app.d"))
                s.previewTitle = node.slot;
            if (node.decoration.borderWidth.left > 0)
            {
                // The panels appear in build order: files first, preview
                // second (`titledPanel` call order in `pickerView`).
                if (panels == 0)
                    s.filesBorder = node.decoration.borderSlot;
                else
                    s.previewBorder = node.decoration.borderSlot;
                ++panels;
            }
            if (node.kind == WidgetKind.row
                && node.slot == Slot.chromeFocused && node.paintBackground)
                s.promptBand = true;
            if (node.slot == Slot.selection && node.paintBackground)
                s.brightBar = true;
            if (node.slot == Slot.highlight && node.paintBackground)
                s.dimBar = true;
            foreach (span; node.spans)
                s.caret |= span.text == "▏";
        }
        return s;
    }

    const geometry = PickerGeometry(panelCols: 40, panelRows: 12);

    const inp = scan(pickerView(state, snapshot, null, "app.d", geometry,
        PickerLayout.default_, Scope_.pickerInput));
    assert(inp.filesTitle == Slot.chromeAccent && inp.previewTitle == Slot.muted);
    assert(inp.filesBorder == Slot.highlightBorder
        && inp.previewBorder == Slot.border);
    assert(inp.caret, "the prompt pane shows its caret");
    assert(inp.promptBand, "…and its band lights");
    assert(inp.dimBar && !inp.brightBar,
        "the selection is a tint while the prompt types");

    const lst = scan(pickerView(state, snapshot, null, "app.d", geometry,
        PickerLayout.default_, Scope_.pickerList));
    assert(!lst.promptBand, "the band follows the focus to the list");
    assert(lst.brightBar && !lst.dimBar, "…where the selection brightens");
    assert(!lst.caret, "no caret while the list owns the keys");
    assert(lst.filesBorder == Slot.highlightBorder,
        "the files panel stays the focused one");

    const pv = scan(pickerView(state, snapshot, null, "app.d", geometry,
        PickerLayout.default_, Scope_.pickerPreview));
    assert(pv.filesTitle == Slot.muted && pv.previewTitle == Slot.chromeAccent,
        "focus swaps the titles");
    assert(pv.filesBorder == Slot.border
        && pv.previewBorder == Slot.highlightBorder, "…and the borders");
    assert(!pv.caret, "no caret while the keys go to the preview");
    assert(!pv.promptBand && !pv.brightBar && !pv.dimBar,
        "every band rests while the preview reads");
}

@("picker.view.grepRowShowsLocationContextAndTheMatch")
@safe
unittest
{
    // A grep row is not a path row: it has to say WHERE in the document, and
    // show the line so the reader can judge the hit without opening it.
    import std.algorithm.searching : canFind;

    PickerState!8 state;
    state.viewRows = 8;
    state.open();
    RankedResult[1] ranked;
    ranked[0].corpusIndex = 0;
    state.publish(ranked[], 1, false);

    const GrepRowText[1] rows = [GrepRowText(
        label: "src/app.d", context: "auto x = parse(input);",
        line: 12, column: 10, matchStart: 9, matchLen: 5)];

    auto tree = pickerView(state, CandidateSnapshot.init, null, null,
        PickerGeometry.init, PickerLayout.default_, Scope_.pickerInput,
        rows[]);

    // Gather the row's spans.
    TextSpan[] found;
    foreach (ref const node; tree.nodes)
        if (node.kind == WidgetKind.rich && node.spans.length
            && node.spans[$ - 1].text.canFind(";"))
            found = node.spans.dup;
    assert(found.length, "the grep row was not rendered");

    string all;
    foreach (ref const sp; found)
        all ~= sp.text;
    assert(all.canFind("src/app.d"), "the document must be named");
    assert(all.canFind(":12:10"),
        "the position must be shown, and in the form `PKQ4` accepts back");
    assert(all.canFind("parse"), "the line must be shown");

    // The match carries `Slot.matched`, exactly as a fuzzy path match does,
    // so a reader learns one highlight convention rather than two.
    bool matchedSpan;
    foreach (ref const sp; found)
        if (sp.slot == Slot.matched)
        {
            assert(sp.text == "parse", "the highlight must be the match");
            matchedSpan = true;
        }
    assert(matchedSpan, "the match must be highlighted");
}

@("picker.view.grepRowMarksElisionAndDefinitions")
@safe
unittest
{
    // Two cues a ranking cannot supply on its own: a truncated line must say
    // it was truncated (else it reads as complete), and a definition must be
    // VISIBLE — a nudge nobody can see is indistinguishable from a ranking
    // bug (`PKC14`).
    import std.algorithm.searching : canFind;

    static string render(GrepRowText row) @safe
    {
        PickerState!8 state;
        state.viewRows = 8;
        state.open();
        RankedResult[1] ranked;
        state.publish(ranked[], 1, false);
        auto tree = pickerView(state, CandidateSnapshot.init, null, null,
            PickerGeometry.init, PickerLayout.default_, Scope_.pickerInput,
            [row]);
        string all;
        foreach (ref const node; tree.nodes)
            if (node.kind == WidgetKind.rich)
                foreach (ref const sp; node.spans)
                    all ~= sp.text;
        return all;
    }

    const plain = render(GrepRowText(label: "a.d", context: "x",
        line: 1, matchStart: 0, matchLen: 1));
    assert(!plain.canFind("…"), "a complete line claims no elision");
    assert(!plain.canFind("▸"), "and a mention carries no marker");

    const cut = render(GrepRowText(label: "a.d", context: "x",
        line: 1, matchStart: 0, matchLen: 1,
        elidedLeft: true, elidedRight: true));
    assert(cut.canFind("…"), "a truncated line must say so");

    // A definition is marked by a background TINT on its row, not by a
    // glyph in its text: an arrow reads as punctuation to decode, and costs
    // two columns on every row to say something about a minority of them.
    static bool tinted(GrepRowText row) @safe
    {
        PickerState!8 state;
        state.viewRows = 8;
        state.open();
        RankedResult[1] ranked;
        state.publish(ranked[], 1, false);
        auto tree = pickerView(state, CandidateSnapshot.init, null, null,
            PickerGeometry.init, PickerLayout.default_, Scope_.pickerPreview,
            [row]);
        foreach (ref const node; tree.nodes)
            if (node.kind == WidgetKind.rich && node.hitId != 0)
                return node.paintBackground && node.slot == Slot.highlight;
        return false;
    }

    assert(tinted(GrepRowText(label: "a.d", context: "struct Foo",
        line: 1, matchStart: 7, matchLen: 3, definition: true)),
        "a definition must be marked, not merely ranked");
    assert(!tinted(GrepRowText(label: "a.d", context: "  Foo f;",
        line: 9, matchStart: 2, matchLen: 3)),
        "…and a mention must not be");
}

@("picker.view.geometryGrowsWithTheScreen")
@safe pure nothrow @nogc
unittest
{
    // The panels used to cap at 60x30 — sized for a terminal window. On a
    // maximised GUI window that left the picker occupying about a third of
    // the screen while everything around it grew, which is the shape the
    // screenshot showed.
    const small = pickerGeometryFor(80, 24);
    const large = pickerGeometryFor(200, 40);
    const huge = pickerGeometryFor(400, 120);

    assert(large.panelCols > small.panelCols, "a wider screen widens the panels");
    assert(large.panelRows > small.panelRows, "and a taller one lengthens them");

    // ~80% of the width, split between the two panels.
    assert(large.panelCols * 2 >= 200 * 7 / 10, "the pair uses most of the width");
    assert(large.panelCols * 2 <= 200, "but never more than there is");

    // Growth stops somewhere: past the cap a row is wider than the eye
    // tracks in one sweep.
    assert(huge.panelCols == pickerMaxPanelCols);
    assert(huge.panelRows == pickerMaxPanelRows);

    // And it still fits the smallest sane terminal.
    const tiny = pickerGeometryFor(40, 10);
    assert(tiny.panelCols >= 10 && tiny.panelCols * 2 <= 40);
    assert(tiny.panelRows >= 1 && tiny.panelRows <= 10);
}
