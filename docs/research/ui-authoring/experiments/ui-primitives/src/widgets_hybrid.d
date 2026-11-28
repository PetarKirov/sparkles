/**
The **hybrid** widget library: `box` + `text` plus four core primitives —
`toggle` (hot: one node instead of four, many per form), `textInput` (caret,
IME, selection and platform text-field semantics belong to the backend),
`scrollView` and `virtualList` (clip, offset, bar and the visible-range
arithmetic in the core, no spacers). Everything else is shared with the pure
library (`widgets_common`).
*/
module widgets_hybrid;

public import uicore;
public import widgets_common;

/// A switch: one `Kind.toggle` leaf; role, label and checked come from it.
Node toggle(ref Ui ui, NamedOnly _ = NamedOnly.init, bool on = false,
    scope const(char)[] label = null, MsgRef onPress = MsgRef.init) @safe pure nothrow @nogc
    => ui.toggleLeaf(on, label, onPress);

/// A single-line text field: one `Kind.textInput` leaf.
Node textInput(ref Ui ui, NamedOnly _ = NamedOnly.init, scope const(char)[] value = null,
    int width = 20, MsgRef onEdit = MsgRef.init) @safe pure nothrow @nogc
    => ui.textInputLeaf(value, width, onEdit);

/// A clipped, scrolled column with a bar the backend draws.
Node scrollView(ref Ui ui, NamedOnly _ = NamedOnly.init, Sizing h = Sizing.grow,
    NamedOnly _children = NamedOnly.init, scope ChildFn[] children...) @safe pure nothrow @nogc
    => ui.scrollViewBox(h, children);

/// A virtual list: the core positions the rows it is given at their index.
Node virtualList(alias key, alias row, R)(UiRange!R r, NamedOnly _ = NamedOnly.init,
    int rowHeight = 1, Sizing h = Sizing.grow, int fallbackRows = 20)
{
    ref ui = *r.ui;
    const s = ui.peekState;
    const n = cast(int) r.range.length;
    const view = s.lastH ? s.lastH : fallbackRows * rowHeight;
    int first = s.scrollY / rowHeight;
    if (first > n)
        first = n;
    int last = (s.scrollY + view + rowHeight - 1) / rowHeight;
    if (last > n)
        last = n;
    return ui.virtualListOpen(n, rowHeight, first, h,
        r.range[first .. last].toUi(ui).mapKeyed!(key, row));
}
