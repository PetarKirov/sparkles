/// The benchmark's views on the scoped `with` builder (`scoped.d`).
module views_scoped;

import model;
import scoped;

void statsPane(ref Ui!StatsMsg ui, in Stats s, in IdsView ids) @safe pure nothrow @nogc
{
    with (ui.column(gap: ui.env.density == Density.compact ? 0 : 1))
    {
        with (ui.row(gap: 2))
        {
            ui.label(slot: Slot.heading, text: "Stats");
            ui.toggle(on: s.hashOnEdit, label: "hash on edit",
                onPress: ui.on(StatsMsg(ToggleHash())));
            ui.numberField(value: s.debounceMs, unit: "ms",
                onChange: ui.on!((int v) => StatsMsg(SetDebounce(v))));
        }
        if (ids.computing)
            ui.label(slot: Slot.dim, text: ui.text(i"computing… (query $(ids.query))"));
        foreach (r; ids.rows)
            ui.keyValue(key: r.name, name: r.name, value: r.value,
                onPress: ui.on(StatsMsg(CopyName(r.name))));
        if (ui.env.density == Density.comfortable)
            ui.label(slot: Slot.dim, text: "click a name to copy it");
    }
}

void panel(ref Ui!StatsMsg ui, uint d) @safe pure nothrow @nogc
{
    with (ui.column(gap: 1))
    {
        ui.label(slot: Slot.heading, text: "panel");
        ui.toggle(on: (d & 1) != 0, label: "open", onPress: ui.on(StatsMsg(ToggleHash())));
        if (d)
            with (ui.row(gap: 1))
            {
                panel(ui, d - 1);
                panel(ui, d - 1);
            }
    }
}
