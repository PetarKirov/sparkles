/** Shared `sparkles:ui` picker widget tree for GUI and terminal backends. */
module picker_view;

import std.conv : text;

import sparkles.fuzzy : CandidateSnapshot;
import sparkles.ui.geometry : Insets, SizeSpec;
import sparkles.ui.style : Slot, TextStyle;
import sparkles.ui.widget : Builder, Widget, WidgetKind, WidgetTree;

import picker : PickerState;

/// Supported picker presentation presets.
enum PickerLayout : ubyte
{
    default_, /// list and preview side by side
    vscode,   /// compact dropdown, no preview
    select,   /// small short-list panel
}

/**
Build one backend-neutral picker frame.

Rows borrow candidate paths from `snapshot`; the snapshot must be the same
immutable corpus generation used by the scheduler.
*/
WidgetTree pickerView(size_t Capacity, size_t PromptCapacity)(
    in PickerState!(Capacity, PromptCapacity) state,
    in CandidateSnapshot snapshot,
    PickerLayout preset = PickerLayout.default_)
{
    auto builder = Builder();
    const prompt = builder.add(Widget(kind: WidgetKind.text,
        text: text("› ", state.prompt.text, state.searching ? " …" : ""),
        slot: Slot.chromeAccent,
        textStyle: TextStyle(bold: true),
        width: SizeSpec.grow()));

    uint[] rows;
    foreach (i, ranked; state.rows)
    {
        const label = ranked.corpusIndex < snapshot.candidates.length
            ? snapshot.candidates[ranked.corpusIndex].path : "(stale row)";
        rows ~= builder.add(Widget(kind: WidgetKind.text,
            text: label,
            slot: i == state.selection ? Slot.selection : Slot.inherit,
            hitId: ranked.corpusIndex + 1,
            width: SizeSpec.grow()));
    }
    if (rows.length == 0)
        rows ~= builder.add(Widget(kind: WidgetKind.text,
            text: state.searching ? "searching…" : "no matches",
            slot: Slot.muted));

    const list = builder.add(Widget(kind: WidgetKind.column,
        children: rows, width: SizeSpec.grow(), clipY: true));
    uint[] body;
    body ~= prompt;
    body ~= list;

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
            slot: Slot.info));
    }
    if (state.error.code)
        body ~= builder.add(Widget(kind: WidgetKind.text,
            text: text("picker error: ", state.error.code),
            slot: Slot.error));

    // A panel is a stack — children share its content origin (the lantern's
    // `popup` finding) — so the prompt/list/footer rows need an explicit
    // column or they paint over one another.
    const bodyColumn = builder.add(Widget(kind: WidgetKind.column,
        children: body, width: SizeSpec.grow()));
    Widget listPanel = Widget(kind: WidgetKind.panel,
        children: [bodyColumn], padding: Insets.all(1),
        slot: Slot.surface, paintBackground: true, width: SizeSpec.grow());
    const panel = builder.add(listPanel);
    uint root;
    final switch (preset)
    {
    case PickerLayout.vscode:
    case PickerLayout.select:
        root = panel;
        break;
    case PickerLayout.default_:
        const selected = state.selectedCorpusIndex;
        const previewLabel = selected < snapshot.candidates.length
            ? snapshot.candidates[selected].path : "preview";
        const preview = builder.add(Widget(kind: WidgetKind.panel,
            children: [builder.add(Widget(kind: WidgetKind.text,
                text: previewLabel, slot: Slot.muted))],
            padding: Insets.all(1), slot: Slot.surface,
            paintBackground: true, width: SizeSpec.grow()));
        root = builder.add(Widget(kind: WidgetKind.row,
            children: [panel, preview], gap: 1, width: SizeSpec.grow()));
        break;
    }
    return builder.finish(root);
}

@("picker.view.rowsAndScoreBreakdownShareOneTree")
@safe
unittest
{
    import std.algorithm.searching : canFind;
    import sparkles.fuzzy : CandidateView, RankedResult;

    CandidateView[1] candidates;
    candidates[0].path = "src/app.d";
    CandidateSnapshot snapshot;
    snapshot.candidates = candidates[];
    PickerState!4 state;
    state.open();
    RankedResult[1] rows;
    rows[0].score.total = 42;
    rows[0].score.base = 30;
    state.publish(rows[], 1, false);
    state.toggleScoreDebug();
    const tree = pickerView(state, snapshot);
    bool sawPath;
    bool sawScore;
    foreach (node; tree.nodes)
    {
        sawPath |= node.text == "src/app.d";
        sawScore |= node.text.canFind("score 42");
    }
    assert(sawPath && sawScore);
}
