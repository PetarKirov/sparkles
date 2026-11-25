/// The benchmark's views on the lazy-variadic builder with a children stack (`lazystack.d`).
module views_lazysoa;

import model;
import lazysoa;

Node statsPane(ref Ui ui, in Stats s, in IdsView ids) @safe pure nothrow @nogc
    => ui.column(gap: ui.env.density == Density.compact ? 0 : 1, children:
        ui.row(gap: 2, children:
            ui.label(slot: Slot.heading, text: "Stats"),
            ui.toggle(on: s.hashOnEdit, label: "hash on edit",
                onPress: ui.on(StatsMsg(ToggleHash()))),
            ui.numberField(value: s.debounceMs, unit: "ms",
                onChange: ui.on!((int v) => StatsMsg(SetDebounce(v)))),
        ),
        ids.computing
            ? ui.label(slot: Slot.dim, text: ui.text(i"computing… (query $(ids.query))"))
            : Node.none,
        ids.rows
            .toUi(ui)
            .mapKeyed!(
                r => r.name,
                r => ui.keyValue(name: r.name, value: r.value,
                    onPress: ui.on(StatsMsg(CopyName(r.name)))),
            ),
        ui.env.density == Density.comfortable
            ? ui.label(slot: Slot.dim, text: "click a name to copy it")
            : Node.none,
    );

/// A binary tree of nested panels, `d` levels below this one.
Node panel(ref Ui ui, uint d) @safe pure nothrow @nogc
    => ui.column(gap: 1, children:
        ui.label(slot: Slot.heading, text: "panel"),
        ui.toggle(on: (d & 1) != 0, label: "open", onPress: ui.on(StatsMsg(ToggleHash()))),
        d ? ui.row(gap: 1, children: panel(ui, d - 1), panel(ui, d - 1)) : Node.none,
    );

/// One small view, for reading the generated code.
Node tiny(ref Ui ui, bool flag) @safe pure nothrow @nogc
    => ui.column(gap: 1, children:
        ui.label(text: "a"),
        flag ? ui.label(text: "b") : Node.none,
    );
