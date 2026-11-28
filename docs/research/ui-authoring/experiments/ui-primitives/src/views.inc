// The app's views, mixed into `views_pure` and `views_hybrid` verbatim: the
// app code is identical whichever widget library it is built on.

import model;

Node statsPane(ref Ui ui, in Stats s, in IdsView ids) @safe pure nothrow @nogc
    => ui.column(gap: ui.env.density == Density.compact ? 0 : 1, children:
        ui.row(gap: 2, children:
            ui.label(slot: Slot.heading, text: "Stats"),
            ui.toggle(on: s.hashOnEdit, label: "hash on edit",
                onPress: ui.on(StatsMsg(ToggleHash()))),
            ui.numberField(value: s.debounceMs, unit: "ms", label: "debounce",
                onChange: ui.on!((int v) => StatsMsg(SetDebounce(v)))),
        ),
        ids.computing
            ? ui.label(slot: Slot.dim, text: ui.fmt(i"computing… (query $(ids.query))"))
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

/// A settings page: 8 toggles and 8 number fields in a scroll view, a text
/// field, three buttons, and a virtual list of the member rows.
Node settingsPage(ref Ui ui, in Settings s, in IdsView ids) @safe pure nothrow @nogc
    => ui.column(gap: 0, w: Sizing.grow, h: Sizing.grow, children:
        ui.label(slot: Slot.heading, text: "Settings"),
        ui.scrollView(h: Sizing.fixed(12), children:
            ui.toggle(on: s.flags[0], label: "Autosave", onPress: ui.on(SettingsMsg(ToggleFlag(0)))),
            ui.toggle(on: s.flags[1], label: "Format on save", onPress: ui.on(SettingsMsg(ToggleFlag(1)))),
            ui.toggle(on: s.flags[2], label: "Word wrap", onPress: ui.on(SettingsMsg(ToggleFlag(2)))),
            ui.toggle(on: s.flags[3], label: "Line numbers", onPress: ui.on(SettingsMsg(ToggleFlag(3)))),
            ui.toggle(on: s.flags[4], label: "Minimap", onPress: ui.on(SettingsMsg(ToggleFlag(4)))),
            ui.toggle(on: s.flags[5], label: "Telemetry", onPress: ui.on(SettingsMsg(ToggleFlag(5)))),
            ui.toggle(on: s.flags[6], label: "Spell check", onPress: ui.on(SettingsMsg(ToggleFlag(6)))),
            ui.toggle(on: s.flags[7], label: "Hash on edit", onPress: ui.on(SettingsMsg(ToggleFlag(7)))),
            ui.formRow(label: "Tab width", children: ui.numberField(value: s.numbers[0], unit: "cols",
                label: "Tab width", onChange: ui.on!((int v) => SettingsMsg(SetNumber(0, v))))),
            ui.formRow(label: "Font size", children: ui.numberField(value: s.numbers[1], unit: "pt",
                label: "Font size", onChange: ui.on!((int v) => SettingsMsg(SetNumber(1, v))))),
            ui.formRow(label: "Line height", children: ui.numberField(value: s.numbers[2], unit: "%",
                label: "Line height", onChange: ui.on!((int v) => SettingsMsg(SetNumber(2, v))))),
            ui.formRow(label: "Debounce", children: ui.numberField(value: s.numbers[3], unit: "ms",
                label: "Debounce", onChange: ui.on!((int v) => SettingsMsg(SetNumber(3, v))))),
            ui.formRow(label: "History", children: ui.numberField(value: s.numbers[4], unit: "entries",
                label: "History", onChange: ui.on!((int v) => SettingsMsg(SetNumber(4, v))))),
            ui.formRow(label: "Ruler", children: ui.numberField(value: s.numbers[5], unit: "cols",
                label: "Ruler", onChange: ui.on!((int v) => SettingsMsg(SetNumber(5, v))))),
            ui.formRow(label: "Autosave delay", children: ui.numberField(value: s.numbers[6], unit: "s",
                label: "Autosave delay", onChange: ui.on!((int v) => SettingsMsg(SetNumber(6, v))))),
            ui.formRow(label: "Workers", children: ui.numberField(value: s.numbers[7],
                label: "Workers", onChange: ui.on!((int v) => SettingsMsg(SetNumber(7, v))))),
        ),
        ui.formRow(label: "Name", children:
            ui.textInput(value: s.name, width: 24, onEdit: ui.on(SettingsMsg(EditName())))),
        ui.row(gap: 2, children:
            ui.button(label: "Apply", onPress: ui.on(SettingsMsg(Press(0)))),
            ui.button(label: "Reset", onPress: ui.on(SettingsMsg(Press(1)))),
            ui.button(label: "Cancel", onPress: ui.on(SettingsMsg(Press(2)))),
        ),
        ids.rows
            .toUi(ui)
            .virtualList!(
                r => r.name,
                r => ui.keyValue(name: r.name, value: r.value,
                    onPress: ui.on(SettingsMsg(CopyName(r.name)))),
            )(rowHeight: 1, h: Sizing.fixed(12), fallbackRows: 12),
    );
