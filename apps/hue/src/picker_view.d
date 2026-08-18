/** Shared `sparkles:ui` picker widget tree for GUI and terminal backends. */
module picker_view;

import std.conv : text;

import sparkles.fuzzy : CandidateSnapshot, TextRange;
import sparkles.ui.geometry : Insets, SizeSpec;
import sparkles.ui.style : BorderStyle, Decoration, Slot, TextStyle;
import sparkles.ui.widget : Alignment, Builder, TextSpan, Widget, WidgetKind,
    WidgetTree;
import sparkles.ui.wrap : TextWrap;

import explorer : fsIcon;
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

/// The preview pane's content: the selected file's head, host-loaded.
struct PickerPreview
{
    const(char)[] title;
    const(string)[] lines;
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
    in PickerPreview preview = PickerPreview.init,
    PickerLayout preset = PickerLayout.default_)
{
    auto builder = Builder();

    // ── the prompt row: `› query▏` left, `matched/total` right ────────────
    TextSpan[] promptSpans;
    promptSpans ~= TextSpan(text: "› ", slot: Slot.chromeAccent,
        textStyle: TextStyle(bold: true));
    // Copied, not borrowed: the prompt accessor is `return scope` into the
    // caller's state, which the tree must not capture.
    promptSpans ~= TextSpan(text: state.prompt.text.idup);
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
        children: promptChildren, width: SizeSpec.grow()));

    // ── the ranked rows: icon · dimmed directory · filename · match marks ─
    uint[] body;
    body ~= promptRow;
    foreach (i, ranked; state.rows)
    {
        TextSpan[] spans;
        if (ranked.corpusIndex < snapshot.candidates.length)
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
        const selected = i == state.selection;
        body ~= builder.add(Widget(kind: WidgetKind.rich,
            spans: spans,
            slot: selected ? Slot.selection : Slot.inherit,
            paintBackground: selected,
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

    const filesPanel = titledPanel(builder, body, " Files ");
    uint root;
    final switch (preset)
    {
    case PickerLayout.vscode:
    case PickerLayout.select:
        root = filesPanel;
        break;
    case PickerLayout.default_:
        // The preview never grows the overlay taller than the list panel:
        // its lines are capped to the files body so the two borders align.
        uint[] previewBody;
        const previewCap = body.length;
        const numberWidth = digitCount(preview.lines.length);
        foreach (i, line; preview.lines)
        {
            if (i == previewCap)
                break;
            TextSpan[] spans;
            spans ~= TextSpan(text: paddedNumber(i + 1, numberWidth),
                slot: Slot.gutter, noBreak: true);
            spans ~= TextSpan(text: " ", noBreak: true);
            spans ~= TextSpan(text: line);
            previewBody ~= builder.add(Widget(kind: WidgetKind.rich,
                spans: spans, width: SizeSpec.grow()));
        }
        if (previewBody.length == 0)
            previewBody ~= builder.add(Widget(kind: WidgetKind.text,
                text: "", slot: Slot.muted));
        const title = preview.title.length
            ? text(" ", preview.title, " ") : " preview ";
        const previewPanel = titledPanel(builder, previewBody, title);
        root = builder.add(Widget(kind: WidgetKind.row,
            children: [filesPanel, previewPanel],
            width: SizeSpec.grow()));
        break;
    }
    return builder.finish(root);
}

/**
A bordered surface with its heading embedded in the top border.

The panel is a stack, and a stack's children share its origin — so a
full-width centered row drawn second lands its title text ON the border row,
interrupting the line exactly the way fzf-lua/telescope draw theirs.
*/
private uint titledPanel(ref Builder builder, uint[] body,
    const(char)[] title) @safe
{
    const content = builder.add(Widget(kind: WidgetKind.column,
        children: body, width: SizeSpec.grow(), clipX: true));
    const boxed = builder.add(Widget(kind: WidgetKind.panel,
        children: [content],
        padding: Insets(1, 2, 1, 2),
        slot: Slot.surface, paintBackground: true,
        decoration: Decoration(borderWidth: Insets.all(2),
            borderStyle: BorderStyle.solid),
        width: SizeSpec.grow()));
    const titleText = builder.add(Widget(kind: WidgetKind.text,
        text: title, slot: Slot.chromeAccent,
        textStyle: TextStyle(bold: true)));
    const titleRow = builder.add(Widget(kind: WidgetKind.row,
        children: [titleText], width: SizeSpec.grow(),
        alignX: Alignment.center));
    return builder.add(Widget(kind: WidgetKind.stack,
        children: [boxed, titleRow], width: SizeSpec.grow()));
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

private bool inRange(scope const(TextRange)[] ranges, size_t at)
    @safe pure nothrow @nogc
{
    foreach (r; ranges)
        if (at >= r.start && at < r.end)
            return true;
    return false;
}

private size_t digitCount(size_t value) @safe pure nothrow @nogc
{
    size_t digits = 1;
    while (value >= 10)
    {
        value /= 10;
        ++digits;
    }
    return digits;
}

private string paddedNumber(size_t value, size_t width) @safe
{
    auto digits = text(value);
    while (digits.length < width)
        digits = " " ~ digits;
    return digits;
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
    PickerPreview preview;
    preview.title = "app.d";
    static immutable string[2] lines = ["void main()", "{}"];
    preview.lines = lines[];

    const tree = pickerView(state, snapshot, highlights[], preview);
    bool sawDir, sawMatch, sawTail, sawIcon;
    bool sawScore, sawTitle, sawPreviewTitle, sawCount, sawLine;
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
            sawLine |= span.text == "void main()";
        }
    }
    assert(sawDir && sawMatch && sawTail, "the path splits at every boundary");
    assert(sawIcon, "the row leads with a file-type icon");
    assert(sawScore && sawTitle && sawPreviewTitle && sawCount && sawLine);
}
