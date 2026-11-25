/// The benchmark's views on Clay (`clayui.d`), declared top-down as Clay
/// intends: an element opens, its children are declared, it closes.
module views_clay;

import model;
import clayui;

void statsPane(U)(ref U ui, in Stats s, in IdsView ids)
{
    with (ui.column(gap: ui.density == Density.compact ? 0 : 1))
    {
        with (ui.row(gap: 2))
        {
            ui.label("Stats");
            ui.toggle(on: s.hashOnEdit, label: "hash on edit",
                onPress: ui.on(StatsMsg(ToggleHash())));
            ui.numberField(value: s.debounceMs, unit: "ms",
                onChange: ui.on(StatsMsg(SetDebounce(0))));
        }
        if (ids.computing)
            ui.label(ui.text(i"computing… (query $(ids.query))"));
        foreach (ref r; ids.rows)
            ui.keyValue(key: r.name, name: r.name, value: r.value,
                onPress: ui.on(StatsMsg(CopyName(r.name))));
        if (ui.density == Density.comfortable)
            ui.label("click a name to copy it");
    }
}

/// A binary tree of nested panels, `d` levels below this one.
void panel(U)(ref U ui, uint d)
{
    with (ui.column(gap: 1))
    {
        ui.label("panel");
        ui.toggle(on: (d & 1) != 0, label: "open", onPress: ui.on(StatsMsg(ToggleHash())));
        if (d)
            with (ui.row(gap: 1))
            {
                panel(ui, d - 1);
                panel(ui, d - 1);
            }
    }
}
