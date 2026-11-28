/**
Widgets both libraries share, written over `box` + `text` only: layout sugar
(`column`, `row`, `label`, `formRow`) and the composites neither library
makes primitive (`numberField`, `keyValue`, `button`).
*/
module widgets_common;

import uicore;

/// A vertical stack: `box` with `Dir.column`.
Node column(ref Ui ui, NamedOnly _ = NamedOnly.init, int gap = 0, Sizing w = Sizing.fit,
    Sizing h = Sizing.fit, EnvOverride env = EnvOverride.init,
    NamedOnly _children = NamedOnly.init, scope ChildFn[] children...) @safe pure nothrow @nogc
    => ui.box(layout: Lay(dir: Dir.column, gap: cast(ushort) gap, w: w, h: h), env: env, children: children);

/// A horizontal stack.
Node row(ref Ui ui, NamedOnly _ = NamedOnly.init, int gap = 0, Sizing w = Sizing.fit,
    NamedOnly _children = NamedOnly.init, scope ChildFn[] children...) @safe pure nothrow @nogc
    => ui.box(layout: Lay(dir: Dir.row, gap: cast(ushort) gap, w: w), children: children);

/// One run of text in a slot.
Node label(ref Ui ui, NamedOnly _ = NamedOnly.init, Slot slot = Slot.body,
    scope const(char)[] text = null) @safe pure nothrow @nogc
    => ui.text(text: text, slot: slot, role: slot == Slot.heading ? Role.heading : Role.none);

/// A caption in a fixed-width column, then the control.
Node formRow(ref Ui ui, NamedOnly _ = NamedOnly.init, scope const(char)[] label = null,
    NamedOnly _children = NamedOnly.init, scope ChildFn[] children...) @safe pure nothrow @nogc
    => ui.box(layout: Lay(dir: Dir.row, gap: 1), children:
        ui.text(text: label, slot: Slot.dim, w: Sizing.fixed(16), wrap: Wrap.none),
        ui.box(children: children));

/// A number with its unit; `onChange` carries the new value as an `int`
/// payload. Its accessible name is `label` (not shown: the form row shows it).
Node numberField(ref Ui ui, NamedOnly _ = NamedOnly.init, int value = 0,
    scope const(char)[] unit = null, scope const(char)[] label = null,
    MsgRef onChange = MsgRef.init) @safe pure nothrow @nogc
    => ui.box(layout: Lay(dir: Dir.row, gap: 1),
        sem: Sem(role: Role.spinButton, focusable: true, hasValue: true, value: value),
        label: label, onPress: onChange, children:
        ui.text(text: ui.fmt(i"$(value)"), slot: Slot.code),
        unit.length ? ui.text(text: unit, slot: Slot.dim) : Node.none);

/// A name and its value; pressing it sends `onPress`.
Node keyValue(ref Ui ui, NamedOnly _ = NamedOnly.init, scope const(char)[] name = null,
    scope const(char)[] value = null, MsgRef onPress = MsgRef.init) @safe pure nothrow @nogc
    => ui.box(layout: Lay(dir: Dir.row, gap: 1), sem: Sem(role: Role.button, merge: true),
        onPress: onPress, children:
        ui.text(text: name),
        ui.text(text: value, slot: Slot.dim));

/// A labelled push button.
Node button(ref Ui ui, NamedOnly _ = NamedOnly.init, scope const(char)[] label = null,
    MsgRef onPress = MsgRef.init) @safe pure nothrow @nogc
    => ui.box(layout: Lay(pad: Pad.xy(1, 0)), bg: Slot.surface,
        sem: Sem(role: Role.button, focusable: true, merge: true), onPress: onPress, children:
        ui.text(text: label));
