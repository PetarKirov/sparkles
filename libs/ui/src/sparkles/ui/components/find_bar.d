/**
The find and replace bar's view (`EDS7`): the query field with its
switches, the match summary and Previous/Next/Close, and, when replacing,
the replacement field with Replace and All. The state and its matching are
`sparkles.ui.editor.search.FindBar`; every control's hit identity is the
caller's, so the host maps a press to its own commands.

Specification: `docs/specs/ui/editor.md` §9.
*/
module sparkles.ui.components.find_bar;

import sparkles.ui.components.editor : editorView, EditorViewOptions;
import sparkles.ui.editor.search : FindBar, FindOption;
import sparkles.ui.editor.state : EditorState;
import sparkles.ui.geometry : Insets, SizeSpec;
import sparkles.ui.style : Slot;
import sparkles.ui.widget : Builder, Widget, WidgetKind;

/// The hit identity of each of the bar's controls; 0 leaves one without.
struct FindBarHits
{
    /// Previous and next match, and closing the bar.
    size_t previous, next, close;
    /// Replace the current match, and every match.
    size_t replaceOne, replaceAll;
    /// The first switch's identity: switch `o` is `optionBase + o` (`FindOption`).
    size_t optionBase;
    /// The query and replacement fields.
    size_t queryField, replacementField;
}

/// How the bar is drawn.
struct FindBarViewOptions
{
    /// The controls' hit identities.
    FindBarHits hits;
    /// Shown, muted, in an empty field.
    string queryPlaceholder = "Search…";
    /// ditto
    string replacementPlaceholder = "Replacement…";
    /**
    The fields leave their caret to the host (ui-app `HST20`); the focused
    one carries the host cursor's column.
    */
    bool hostCursor = true;
}

/**
The bar for `bar`, as one column node: a row for the query and, when
`bar.replacing`, a row for the replacement. `selectionStart` and
`selectionEnd` are the document's primary selection, which the summary
counts as the current match (`3 of 12`). The caller refreshes `bar` for the
document first (`FindBar.refresh`).
*/
uint viewFindBar(ref Builder b, ref const FindBar bar, size_t selectionStart, size_t selectionEnd,
    FindBarViewOptions options = FindBarViewOptions.init) @safe
{
    uint control(string label, size_t hit, bool on = false)
        => b.add(Widget(kind: WidgetKind.text, text: label, hitId: hit,
            slot: on ? Slot.selection : Slot.docs, paintBackground: on, padding: Insets(0, 1, 0, 1)));
    uint option(string label, FindOption which, bool on)
        => b.add(Widget(kind: WidgetKind.text, text: label, hitId: options.hits.optionBase + which,
            slot: on ? Slot.selection : Slot.muted, paintBackground: on, padding: Insets(0, 1, 0, 1)));
    uint field(in EditorState state, bool focused, string placeholder, size_t hit)
    {
        const node = editorView(b, state, EditorViewOptions(visibleLines: 1, placeholder: placeholder,
            caretVisible: focused, hostCursor: options.hostCursor));
        b.nodes[node].width = SizeSpec.grow();
        b.nodes[node].slot = Slot.surfaceSunken;
        b.nodes[node].paintBackground = true;
        b.nodes[node].hitId = hit;
        return node;
    }
    const summary = bar.summary(selectionStart, selectionEnd);
    const onReplacement = bar.onReplacement && bar.replacing;
    uint[] query = [b.add(Widget(kind: WidgetKind.text, text: "Find", slot: Slot.muted)),
        field(bar.query.state, !onReplacement, options.queryPlaceholder, options.hits.queryField),
        option(".*", FindOption.regex, bar.options.regex),
        option("Aa", FindOption.caseSensitive, bar.options.caseSensitive),
        option("W", FindOption.wholeWord, bar.options.wholeWord),
        b.add(Widget(kind: WidgetKind.text, text: summary,
            slot: bar.pattern.error.length ? Slot.error : Slot.muted)),
        control("↑", options.hits.previous), control("↓", options.hits.next), control("×", options.hits.close)];
    uint[] rows = [b.add(Widget(kind: WidgetKind.row, children: query, gap: 1, height: SizeSpec.fixed(1)))];
    if (bar.replacing)
        rows ~= b.add(Widget(kind: WidgetKind.row, gap: 1, height: SizeSpec.fixed(1), children: [
            b.add(Widget(kind: WidgetKind.text, text: "Into", slot: Slot.muted)),
            field(bar.replacement.state, onReplacement, options.replacementPlaceholder, options.hits.replacementField),
            control("Replace", options.hits.replaceOne), control("All", options.hits.replaceAll)]));
    return b.add(Widget(kind: WidgetKind.column, children: rows, width: SizeSpec.grow()));
}

/// The rows `viewFindBar` draws for `bar`: one, two when replacing.
int findBarRows(in FindBar bar) @safe pure nothrow @nogc => bar.replacing ? 2 : 1;


/// The controls carry the caller's identities; switches show their state
/// and the summary counts the current match.
@("ui.findBar.view")
@safe unittest
{
    import sparkles.text_buffer.text : Text;
    import sparkles.ui.editor.keys : EditorTarget;

    FindBar bar;
    bar.show(true, "ab", EditorTarget.window);
    bar.toggle(FindOption.caseSensitive);
    bar.refresh(Text("ab xx ab"), 1);
    Builder b;
    const hits = FindBarHits(previous: 10, next: 11, close: 12, replaceOne: 13, replaceAll: 14,
        optionBase: 20, queryField: 30, replacementField: 31);
    const tree = b.finish(viewFindBar(b, bar, 6, 8, FindBarViewOptions(hits: hits)));
    size_t[string] hitOf;
    bool[string] onOf;
    foreach (node; tree.nodes)
        if (node.kind == WidgetKind.text)
        {
            hitOf[node.text.idup] = node.hitId;
            onOf[node.text.idup] = node.paintBackground;
        }
    assert(hitOf["↑"] == 10 && hitOf["↓"] == 11 && hitOf["×"] == 12);
    assert(hitOf["Replace"] == 13 && hitOf["All"] == 14, "replacing shows its row");
    assert(hitOf[".*"] == 20 && hitOf["Aa"] == 21 && hitOf["W"] == 22);
    assert(onOf["Aa"] && !onOf[".*"], "a switch shows its state");
    assert("2 of 2" in hitOf, "the summary counts the selected match");
    size_t[] fields;
    foreach (node; tree.nodes)
        if (node.hitId == 30 || node.hitId == 31) fields ~= node.hitId;
    assert(fields == [30, 31]);
    assert(findBarRows(bar) == 2);
    bar.close();
    bar.show(false, null, EditorTarget.window);
    assert(findBarRows(bar) == 2, "the replacement row stays until the bar is reset");
}
