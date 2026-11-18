/**
An undo-history inspector (`TXB-HIS7`): the revisions of a branching
`sparkles.text_buffer.history.History` listed in creation order around the
current one, each naming its parent, its text length and whether it is a
branch point, indented by depth; and travel to a listed revision through
the editor's own `earlier`/`later`, so the move is one ordinary history
step. Revision `i`'s row carries hit id `hits[i]` from the caller's block (`INP27`),
and the host maps a press back with the block's `indexOf`.
*/
module sparkles.ui.components.history_view;

import core.time : MonoTime;
import sparkles.ui.geometry : Insets;
import sparkles.ui.hit_ids : HitBlock;
import sparkles.ui.style : Slot;
import sparkles.ui.widget : Builder, Widget, WidgetKind;

/// How the history is listed.
struct HistoryViewOptions
{
    /// The most revisions listed.
    size_t limit = 6;
    /// Revision `i`'s row has hit id `hits[i]`; the empty block gives rows none.
    /// Ask for as many ids as the history has revisions.
    HitBlock hits;
    /// Appended to the header, such as the keys that travel.
    string hint;
}

/**
The revisions `[first, last]` listed for `current` of `total` with at most
`limit` rows: up to half the window past the current one, the rest before
it, filled from the other side near either end.
*/
size_t[2] historyWindow(size_t current, size_t total, size_t limit) @safe pure nothrow @nogc
in (limit > 0 && current < total)
{
    size_t last = current + limit / 2 < total ? current + limit / 2 : total - 1;
    const first = last + 1 > limit ? last + 1 - limit : 0;
    if (last - first + 1 < limit && total > limit) last = first + limit - 1 < total ? first + limit - 1 : total - 1;
    return [first, last];
}

/**
The header row and one row per listed revision of `history` (a
`History!S`), in creation order: `● #4 from #3  12 B  ⑂ 2 branches`, the
current revision on the selection slot.
*/
uint[] viewHistory(H)(ref Builder b, ref const H history, HistoryViewOptions options = HistoryViewOptions.init)
{
    import std.conv : text;

    const current = history.currentIndex;
    const total = history.length;
    const window = historyWindow(current, total, options.limit);
    uint[] rows;
    rows ~= b.add(Widget(kind: WidgetKind.text, slot: Slot.info,
        text: text("Undo history: revision ", current, " of ", total - 1,
            options.hint.length ? "  (" ~ options.hint ~ ")" : "")));
    foreach (i; window[0] .. window[1] + 1)
    {
        const info = history.revision(i);
        const label = text(i == current ? "● " : "○ ", i == 0 ? "root" : text("#", i),
            i == 0 ? "" : text(" from ", info.parent == 0 ? "root" : text("#", info.parent)),
            "  ", info.length, " B", info.children > 1 ? text("  ⑂ ", info.children, " branches") : "");
        rows ~= b.add(Widget(kind: WidgetKind.text, text: label, hitId: options.hits[i],
            slot: i == current ? Slot.selection : Slot.docs, paintBackground: i == current,
            padding: Insets(0, 0, 0, 2 * (info.depth < 8 ? cast(int) info.depth : 8))));
    }
    return rows;
}

/**
Travel `field` (an `EditorFieldOf`) to revision `index` in creation order
through `earlier`/`later`. An index past the history changes nothing;
returns whether the field moved.
*/
bool travelTo(Field)(ref Field field, size_t index, MonoTime now = MonoTime.init)
{
    import sparkles.ui.editor.command : EditCommand;

    const history = &field.state.history;
    if (index >= history.length) return false;
    const current = history.currentIndex;
    if (index < current) field.run(EditCommand.earlier(current - index), now);
    else if (index > current) field.run(EditCommand.later(index - current), now);
    return index != current;
}

/// The window keeps the current revision in view, filled from either end.
@("ui.historyView.window")
@safe pure nothrow @nogc unittest
{
    assert(historyWindow(0, 1, 6) == [0, 0]);
    assert(historyWindow(9, 10, 6) == [4, 9]);
    assert(historyWindow(0, 10, 6) == [0, 5]);
    assert(historyWindow(5, 20, 6) == [3, 8]);
}

/// Rows name parents and branches, carry the caller's hits, and travel
/// reaches an abandoned branch.
@("ui.historyView.rowsAndTravel")
@safe unittest
{
    import core.time : seconds;
    import sparkles.ui.editor.command : EditCommand, EditKind;
    import sparkles.ui.editor.field : EditorField;

    auto field = EditorField.make("");
    const at = MonoTime.currTime;
    field.insert("a", false, at); // #1
    field.run(EditCommand.of(EditKind.undo), at + 2.seconds);
    field.insert("b", false, at + 4.seconds); // #2, a second branch of the root
    Builder b;
    const rows = viewHistory(b, field.state.history, HistoryViewOptions(hits: HitBlock(100, field.state.history.length), hint: "select one"));
    const(char)[][] texts;
    size_t[] hits;
    foreach (row; rows)
    {
        texts ~= b.nodes[row].text;
        hits ~= b.nodes[row].hitId;
    }
    assert(texts == ["Undo history: revision 2 of 2  (select one)", "○ root  0 B  ⑂ 2 branches",
        "○ #1 from root  1 B", "● #2 from root  1 B"], texts[1]);
    assert(hits == [0, 100, 101, 102]);
    size_t index;
    const block = HitBlock(100, field.state.history.length);
    assert(block.indexOf(101, index) && index == 1);
    size_t none;
    assert(!block.indexOf(103, none));
    assert(travelTo(field, index) && field.text == "a", "travel reaches the abandoned branch");
    assert(!travelTo(field, 1) && !travelTo(field, 9));
}
