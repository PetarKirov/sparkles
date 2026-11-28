/**
The **pure** widget library: every widget is a composite of `box` and
`text`. Interaction state (scroll offset, caret) is read from the element
store by the id the composite's outer box is about to get (`peekState`).
*/
module widgets_pure;

public import uicore;
public import widgets_common;

/// A switch: a track box with a knob box, then the caption. The outer box
/// carries the semantics (role, checked, focusable; label merged from the
/// caption) and the message; a press anywhere inside bubbles to it.
Node toggle(ref Ui ui, NamedOnly _ = NamedOnly.init, bool on = false,
    scope const(char)[] label = null, MsgRef onPress = MsgRef.init) @safe pure nothrow @nogc
    => ui.box(layout: Lay(dir: Dir.row, gap: 1),
        sem: Sem(role: Role.switch_, checked: on ? Checked.on : Checked.off, focusable: true, merge: true),
        onPress: onPress, children:
        ui.box(layout: Lay(dir: Dir.row, w: Sizing.fixed(4), h: Sizing.fixed(ui.env.controlRows),
                alignX: on ? Align.end : Align.start),
            bg: on ? Slot.controlOn : Slot.sunken, children:
            ui.box(layout: Lay(w: Sizing.fixed(2), h: Sizing.grow), bg: Slot.knob)),
        ui.text(text: label));

/// A single-line text field: a bordered box with the value and the caret
/// (from the element store) as a caret column on the text.
Node textInput(ref Ui ui, NamedOnly _ = NamedOnly.init, scope const(char)[] value = null,
    int width = 20, MsgRef onEdit = MsgRef.init) @safe pure nothrow @nogc
    => ui.box(layout: Lay(pad: Pad.xy(1, 0), w: Sizing.fixed(width)), border: 0, bg: Slot.sunken,
        sem: Sem(role: Role.textField, focusable: true), onPress: onEdit, children:
        ui.text(text: value, wrap: Wrap.none, caret: ui.peekState.caret));

/// A clipped, scrolled column with a thumb floated at its right edge, sized
/// from last frame's extent (the element store).
Node scrollView(ref Ui ui, NamedOnly _ = NamedOnly.init, Sizing h = Sizing.grow,
    NamedOnly _children = NamedOnly.init, scope ChildFn[] children...) @safe pure nothrow @nogc
    => scrollViewAt(ui, ui.peekState, h, children);

private Node scrollViewAt(ref Ui ui, in ElemState s, Sizing h, scope ChildFn[] children) @safe pure nothrow @nogc
    => ui.box(layout: Lay(dir: Dir.column, pad: Pad(0, 0, 1, 0), w: Sizing.grow, h: h),
        scroll: Scroll(y: true), sem: Sem(role: Role.scrollArea), children:
        ui.box(layout: Lay(dir: Dir.column, w: Sizing.grow), children: children),
        // the bar: out of flow (not scrolled), at the right edge
        ui.box(layout: Lay(w: Sizing.fixed(1), h: Sizing.fixed(thumb(s))), bg: Slot.thumb,
            floating: Floating(active: true, attachX: Align.end,
                y: cast(short) (s.contentH ? s.scrollY * s.lastH / s.contentH : 0))));

private int thumb(in ElemState s) @safe pure nothrow @nogc
    => s.contentH > s.lastH && s.lastH ? (s.lastH * s.lastH / s.contentH > 0 ? s.lastH * s.lastH / s.contentH : 1) : s.lastH;

/**
A virtual list: a scrolled column that builds only the rows in view, between
two spacers standing for the rows above and below. The viewport is last
frame's height (Clay-style), `fallbackRows` on the first frame.
*/
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
    return ui.box(layout: Lay(dir: Dir.column, w: Sizing.grow, h: h), scroll: Scroll(y: true),
        sem: Sem(role: Role.list), children:
        ui.box(layout: Lay(h: Sizing.fixed(first * rowHeight))),
        r.range[first .. last].toUi(ui).mapKeyed!(key, row),
        ui.box(layout: Lay(h: Sizing.fixed((n - last) * rowHeight))));
}
