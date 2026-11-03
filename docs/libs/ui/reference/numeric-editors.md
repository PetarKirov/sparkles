# Numeric property editors

Numeric properties share one value domain across presentation, edits, reset,
and undo. `@Range(lo, hi, step)` declares a static domain. A parent subject
may supply `propRange(field)` and `propDefault(field)` for domains determined
at runtime, such as a variable font's declared axes. `propLabel(field)` supplies
a runtime label. An invalid runtime range leaves the static domain in place.
`propReadOnly(field)` makes a runtime-owned value visible without permitting
manual edits, such as optical size while its automatic mode is active.

`@PreferredInput(NumericInput.slider)` suggests a slider;
`NumericInput.stepper` suggests a counter, and `NumericInput.number` suggests
numeric text input. Without a preference, numeric section rows remain steppers.
The preference does not bypass validation. A slider also exposes its number as
an editable field; keyboard stepping uses the same domain.

<<< @/../libs/ui/examples/runtime-numeric-property.d{d}

Run `dub run --single libs/ui/examples/runtime-numeric-property.d` from the
repository root. It prints `value: 100..700`.

`SettingsSections` owns section navigation, inline editor routing, and numeric
pointer capture beside a `SettingsPane!T`. Both the terminal and text lab use
it. Applications retain placement, persistence, custom rows, and live-apply
policy. Pass pointer positions and laid-out frames in the same coordinate
space. A touch press waits for horizontal intent before capturing; vertical
movement remains available to the containing scroll view.

Press captures the original track geometry. Moves apply preview edits through
the generated dispatch, release commits one history entry, and cancellation
restores the exact pre-drag value. Call `cancel` before closing a surface,
changing its logical subject, or relinquishing capture. Runtime bounds also
apply during undo and redo; changing a subject's domain can therefore refuse a
previously valid history entry.
