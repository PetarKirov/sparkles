import markup : markupSource; pragma(msg, markupSource!q{
        column(gap: ui.env.density == Density.compact ? 0 : 1) {
            row(gap: 2) {
                label(slot: Slot.heading, text: "Stats 1");
                toggle(on: s.hashOnEdit, label: "hash on edit", onPress: ui.on(StatsMsg(ToggleHash())));
                numberField(value: s.debounceMs, unit: "ms", onChange: ui.on!((int v) => StatsMsg(SetDebounce(v))));
            }
            if (ids.computing) { label(slot: Slot.dim, text: i"computing… (query $(ids.query))"); }
            foreach (r; ids.rows; key: r.name) { keyValue(name: r.name, value: r.value, onPress: ui.on(StatsMsg(CopyName(r.name)))); }
            if (ui.env.density == Density.comfortable) { label(slot: Slot.dim, text: "click a name to copy it"); }
        }
});
