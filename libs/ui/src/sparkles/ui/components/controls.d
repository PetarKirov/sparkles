/**
Form controls — a chip, a toggle switch, a segmented control, a stepper and a
dropdown chip — drawn compact inside a full touch target (`WGT26`).

A phone needs every control to be at least 48 dp tall to tap reliably, yet a
48 dp chip or switch looks like a slab. Each control here therefore keeps a
target `rows` cells tall (what 48 dp takes at the host's cell height) and draws
its box at a compact height centred in it (design-system `TOK11`): 32 dp for a
chip, 28 dp for a switch's track. A control shows a value, so its text stays in
the cell font, where a value is read and compared character by character; the
name and description beside it use the interface face (`GLY10`). A cell target
draws each box over its whole target: a tinted chip, a switch whose knob sits
at the start or the end of its track, a group of segments.
*/
module sparkles.ui.components.controls;

import sparkles.ui.geometry : cellsOf, Insets, SizeSpec;
import sparkles.ui.style : BorderStyle, Decoration, FontRole, Slot, TextStyle, TypeStep;
import sparkles.ui.widget : Alignment, Builder, Widget, WidgetKind;

@safe:

/// The size every control shares: the rows its touch target takes and the
/// height, in CSS px, its box is drawn at (`TOK11`).
struct ControlSize
{
    int rows = 1;     /// the touch target's height, in cells (48 dp on a phone)
    int drawDp = 32;  /// the drawn box's height, in CSS px
}

/// The slots the controls reference (design-system `TOK6`).
enum Slot[] controlSlots = [Slot.surfaceRaised, Slot.surfaceSunken, Slot.chromeAccent, Slot.controlOn,
    Slot.textPrimary, Slot.textSecondary, Slot.border, Slot.code];

/// A value: the cell font at the body step (`uiMono`), bold when selected.
private TextStyle valueStyle(bool bold = false) pure nothrow @nogc
    => TextStyle(bold: bold, fontRole: FontRole.uiMono, typeStep: TypeStep.body);

/// A box `rows` tall drawn `drawDp` tall: the shared shape of every control.
private Widget controlBox(uint[] children, ControlSize sz, size_t hitId, Slot slot,
    int radius, bool bordered = false) pure nothrow
    => Widget(kind: WidgetKind.panel, children: children, padding: Insets(0, 1, 0, 1),
        height: sz.rows > 1 ? SizeSpec.fixed(sz.rows) : SizeSpec.fit_,
        alignX: Alignment.center, alignY: Alignment.center, hitId: hitId,
        slot: slot, paintBackground: true,
        decoration: Decoration(borderRadius: radius, drawHeight: sz.drawDp,
            borderStyle: bordered ? BorderStyle.solid : BorderStyle.none,
            borderWidth: bordered ? Insets.all(1) : Insets.init, borderSlot: Slot.border));

/**
A chip: a short label in a pill — a filter, a choice, a compact button.
`selected` tints it in the accent and bolds the label.
*/
uint chip(ref Builder b, string label, size_t hitId, bool selected = false,
    ControlSize sz = ControlSize.init)
{
    const t = b.add(Widget(kind: WidgetKind.text, text: label,
        slot: selected ? Slot.chromeAccent : Slot.textPrimary,
        textStyle: valueStyle(selected)));
    return b.add(controlBox([t], sz, hitId,
        selected ? Slot.chromeAccent : Slot.surfaceRaised, sz.drawDp / 2));
}

/**
A toggle switch: a track with its knob at the start (off) or the end (on). On
fills the track with the accent (`control.on`); off is the sunken surface with
a border.
*/
uint toggleSwitch(ref Builder b, bool on, size_t hitId, ControlSize sz = ControlSize.init)
{
    const knob = b.add(Widget(kind: WidgetKind.text, text: "●",
        slot: on ? Slot.controlOn : Slot.textSecondary,
        textStyle: TextStyle(fontRole: FontRole.ui, typeStep: TypeStep.title)));
    auto track = controlBox([knob], ControlSize(sz.rows, 28), hitId,
        on ? Slot.controlOn : Slot.surfaceSunken, 14, bordered: !on);
    track.width = SizeSpec.fixed(5);
    track.alignX = on ? Alignment.end : Alignment.start;
    return b.add(track);
}

/**
A segmented control: one segment per label in a bordered group, the
`selected` one tinted. `hitIds[i]` is segment `i`'s target.
*/
uint segmented(ref Builder b, in string[] labels, size_t selected, in size_t[] hitIds,
    ControlSize sz = ControlSize.init)
in (labels.length == hitIds.length)
{
    uint[] segs;
    foreach (i, l; labels)
    {
        const on = i == selected;
        const t = b.add(Widget(kind: WidgetKind.text, text: l,
            slot: on ? Slot.chromeAccent : Slot.textPrimary, textStyle: valueStyle(on)));
        segs ~= b.add(controlBox([t], sz, hitIds[i],
            on ? Slot.chromeAccent : Slot.surfaceRaised, 6));
    }
    return b.add(Widget(kind: WidgetKind.row, children: segs,
        alignY: Alignment.center,
        decoration: Decoration(borderStyle: BorderStyle.solid, borderWidth: Insets.all(1),
            borderSlot: Slot.border, borderRadius: 6, drawHeight: sz.drawDp)));
}

/// A stepper: round `−` and `+` buttons around `value`.
uint stepper(ref Builder b, string value, size_t decHit, size_t incHit,
    ControlSize sz = ControlSize.init)
{
    const round = ControlSize(sz.rows, 36);
    const dec = chip(b, "−", decHit, false, round);
    const val = b.add(Widget(kind: WidgetKind.text, text: value, slot: Slot.code,
        textStyle: valueStyle(),
        width: SizeSpec.fixed(cast(int) cellsOf(value) + 1), alignX: Alignment.center));
    const inc = chip(b, "+", incHit, false, round);
    return b.add(Widget(kind: WidgetKind.row, children: [dec, val, inc], gap: 1,
        alignY: Alignment.center));
}

/// A dropdown chip: the current `value` and a caret in a bordered box.
uint dropdownChip(ref Builder b, string value, bool open, size_t hitId,
    ControlSize sz = ControlSize.init)
{
    const t = b.add(Widget(kind: WidgetKind.text, text: value ~ (open ? " ▴" : " ▾"),
        slot: Slot.textPrimary, textStyle: valueStyle()));
    return b.add(controlBox([t], sz, hitId, Slot.surfaceRaised, 6, bordered: true));
}

@("ui.controls.chipKeepsItsTargetAndDrawsCompact")
@safe unittest
{
    auto b = Builder();
    const c = chip(b, "info", 7, selected: true, ControlSize(rows: 3));
    const w = b.nodes[c];
    assert(w.hitId == 7, "the whole target is the chip's");
    assert(w.height == SizeSpec.fixed(3), "three rows: 48 dp on a phone");
    assert(w.decoration.drawHeight == 32 && w.decoration.borderRadius == 16,
        "drawn as a 32 dp pill");
    assert(w.slot == Slot.chromeAccent, "selected: tinted");
    const t = b.nodes[w.children[0]];
    assert(t.textStyle.fontRole == FontRole.uiMono && t.textStyle.bold, "a value: the cell font");
}

@("ui.controls.toggleKnobFollowsTheState")
@safe unittest
{
    auto b = Builder();
    const on = toggleSwitch(b, true, 1, ControlSize(rows: 3));
    const off = toggleSwitch(b, false, 2, ControlSize(rows: 3));
    assert(b.nodes[on].alignX == Alignment.end && b.nodes[off].alignX == Alignment.start);
    assert(b.nodes[on].slot == Slot.controlOn && b.nodes[off].slot == Slot.surfaceSunken);
    assert(b.nodes[on].decoration.drawHeight == 28);
    assert(b.nodes[off].decoration.borderStyle == BorderStyle.solid, "off is outlined");
}

@("ui.controls.segmentedTintsOnlyTheSelectedSegment")
@safe unittest
{
    auto b = Builder();
    const s = segmented(b, ["auto", "on", "off"], 0, [10, 11, 12], ControlSize(rows: 2));
    const segs = b.nodes[s].children;
    assert(segs.length == 3);
    assert(b.nodes[segs[0]].slot == Slot.chromeAccent);
    assert(b.nodes[segs[1]].slot == Slot.surfaceRaised && b.nodes[segs[1]].hitId == 11);
    assert(b.nodes[s].decoration.borderStyle == BorderStyle.solid, "one bordered group");
}

@("ui.controls.stepperAndDropdown")
@safe unittest
{
    auto b = Builder();
    const st = stepper(b, "16", 3, 4, ControlSize(rows: 3));
    const parts = b.nodes[st].children;
    assert(b.nodes[parts[0]].hitId == 3 && b.nodes[parts[2]].hitId == 4);
    assert(b.nodes[parts[0]].decoration.drawHeight == 36, "round 36 dp buttons");
    const d = dropdownChip(b, "confirm", false, 5);
    assert(b.nodes[b.nodes[d].children[0]].text == "confirm ▾");
    assert(b.nodes[d].decoration.borderStyle == BorderStyle.solid);
}
