/** Shared `sparkles:ui` picker widget tree for GUI and terminal backends. */
module picker_view;

import std.conv : text;

import sparkles.fuzzy : CandidateSnapshot, RankedResult, TextRange;
import sparkles.ui.geometry : Insets, Rect, SizeSpec;
import sparkles.ui.layout : Frame;
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

/// The overlay geometry both hosts derive from their screen size (in cells)
/// alone — never from content, which is what keeps the frame stable.
PickerGeometry pickerGeometryFor(int screenCols, int screenRows)
    @safe pure nothrow @nogc
{
    int cols = (screenCols - 4) / 2;
    if (cols > 60)
        cols = 60;
    if (cols < 20)
        cols = screenCols / 2 > 10 ? screenCols / 2 : 10;
    int rows = screenRows - 3;
    if (rows > 30)
        rows = 30;
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
    scope const(GrepRowText)[] grepRows = null)
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
    body ~= promptRow;
    // The PAINTED window, not the whole ranking (`pickerTopK` is deeper
    // than the viewport). `highlights` is window-relative; `selection` is
    // ranking-relative, so the comparison adds the scroll offset back.
    foreach (i, ranked; state.visible)
    {
        TextSpan[] spans;
        if (i < grepRows.length)
            grepSpans(spans, grepRows[i]);
        else if (ranked.corpusIndex < snapshot.candidates.length)
        {
            const candidate = snapshot.candidates[ranked.corpusIndex];
            const icon = fsIcon(candidate.path[candidate.filenameOffset .. $]);
            spans ~= TextSpan(text: icon.glyph, fg: icon.fg, hasFg: true,
                noBreak: true);
            pathSpans(spans, candidate.path, candidate.filenameOffset,
                i < highlights.length ? highlights[i].ranges : null);
        }
        else
            spans ~= TextSpan(text: "(stale row)", slot: Slot.muted);
        // The selection bar's strength follows the focus — snacks dims its
        // cursorline the same way when focus leaves the list: bright while
        // the list owns the keyboard, a tint while the prompt types, at
        // rest while the preview reads.
        const selected = state.firstRow + i == state.selection;
        const rowSlot = !selected ? Slot.inherit
            : listFocused ? Slot.selection
                : inputFocused ? Slot.highlight : Slot.inherit;
        body ~= builder.add(Widget(kind: WidgetKind.rich,
            spans: spans,
            slot: rowSlot,
            paintBackground: rowSlot != Slot.inherit,
            hitId: ranked.corpusIndex + 1,
            width: SizeSpec.grow()));
    }
    if (state.rowCount == 0)
        body ~= builder.add(Widget(kind: WidgetKind.text,
            text: state.searching ? "searching…" : "no matches",
            slot: Slot.muted));

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
        const previewPanel = titledPanel(builder, previewBody, title,
            geometry, focused: previewFocused);
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
    const(char)[] title, in PickerGeometry geometry, bool focused = true)
    @safe
{
    const content = builder.add(Widget(kind: WidgetKind.column,
        children: body, width: SizeSpec.grow(), height: SizeSpec.grow(),
        clipX: true, clipY: true));
    const boxed = builder.add(Widget(kind: WidgetKind.panel,
        children: [content],
        padding: Insets(1, 2, 1, 2),
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
    // A definition is marked, not merely ranked: a nudge nobody can see is
    // indistinguishable from a ranking bug.
    spans ~= TextSpan(text: row.definition ? "▸ " : "  ",
        slot: row.definition ? Slot.chromeAccent : Slot.inherit,
        noBreak: true);

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

    const def = render(GrepRowText(label: "a.d", context: "struct Foo",
        line: 1, matchStart: 7, matchLen: 3, definition: true));
    assert(def.canFind("▸"), "a definition must be marked, not merely ranked");
}
