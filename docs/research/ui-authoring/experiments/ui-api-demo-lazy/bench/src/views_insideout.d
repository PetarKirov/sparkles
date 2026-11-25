/// The benchmark's views on the inside-out builder (`insideout.d`).
module views_insideout;

import model;
import insideout;

Node statsPane(ref Ui ui, in Stats s, in IdsView ids) @safe pure nothrow @nogc
    => ui.Column(gap: ui.env.density == Density.compact ? 0 : 1, children: [
        ui.Row(gap: 2, children: [
            ui.Label(slot: Slot.heading, text: "Stats"),
            ui.Toggle(on: s.hashOnEdit, label: "hash on edit",
                onPress: ui.on(StatsMsg(ToggleHash()))),
            ui.NumberField(value: s.debounceMs, unit: "ms",
                onChange: ui.on!((int v) => StatsMsg(SetDebounce(v)))),
        ]),
        ids.computing
            ? ui.Label(slot: Slot.dim, text: ui.text(i"computing… (query $(ids.query))"))
            : Node.none,
        ids.rows
            .toUi(ui)
            .mapKeyed!(
                r => r.name,
                r => ui.KeyValue(name: r.name, value: r.value,
                    onPress: ui.on(StatsMsg(CopyName(r.name)))),
            ),
        ui.env.density == Density.comfortable
            ? ui.Label(slot: Slot.dim, text: "click a name to copy it")
            : Node.none,
    ]);

Node panel(ref Ui ui, uint d) @safe pure nothrow @nogc
    => ui.Column(gap: 1, children: [
        ui.Label(slot: Slot.heading, text: "panel"),
        ui.Toggle(on: (d & 1) != 0, label: "open", onPress: ui.on(StatsMsg(ToggleHash()))),
        d ? ui.Row(gap: 1, children: [panel(ui, d - 1), panel(ui, d - 1)]) : Node.none,
    ]);
