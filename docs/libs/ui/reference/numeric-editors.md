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
policy. Pass frames in layout cells and supply `cellPixels` when pointer
positions are pixels; the default is the identity conversion. Hit-testing
accounts for fractional scrolling and viewport clipping. A touch press waits
for horizontal intent before capturing; vertical movement remains available
to the containing scroll view.

Slider thumbs paint between text columns on pixel backends. A zero range step
allows continuous values; a positive step still snaps values to the declared
domain. Cell backends retain whole-cell rendering.

`sparkles.ui.components.scroll_body.ScrollBody` shares the terminal's page
scrolling with other applications. Set `content` and `viewport` in content
units, route wheel events to `scroll`, and call `animate(frameSeconds)` each
frame, requesting another frame while it returns true. Lay out with
`motion.whole` and paint with `motion.frac` as `childOffsetFracY` on the clipped
viewport. Set `motion.instant` for cell targets or reduced motion.

For direct touch input, call `beginDrag`, `dragTo`, and `endDrag` with positions
in the same content units and monotonic timestamps in seconds. A release
continues with decaying momentum; holding before release suppresses stale
momentum. Call `cancelDrag` when another control captures the contact, and
`motion.stop` when the surface closes. Hosts that already generate momentum
wheel events should route those events through `scroll` without also starting
a direct-touch fling. The shared `bar` retains scrollbar capture and touch
fade state; placement remains the application's choice.

The controller retains up to 128 scalar row subtrees. Their keys include the
projected value and metadata, runtime bounds/defaults, choices, focus, editor
and refusal state, target geometry, and hit identifiers. Changed rows rebuild;
unchanged rows reuse their presentation with child indices rebased into the
current tree. Aggregate rows remain live because they can inspect children.
This reuse is shared by the terminal and text lab.

Layout also retains unmeasured plain-text wrap results, including Unicode
slider tracks. The thread-local cache owns input keys and projected text,
keeps at most 512 entries and 2 MiB of text/header payload, and returns fresh
line headers. Width, first-line geometry, algorithm, and complete text are
part of the key. Target-measured wraps remain live because their results can
depend on font settings.

Press captures the original track geometry. Moves apply preview edits through
the generated dispatch, release commits one history entry, and cancellation
restores the exact pre-drag value. Call `cancel` before closing a surface,
changing its logical subject, or relinquishing capture. Runtime bounds also
apply during undo and redo; changing a subject's domain can therefore refuse a
previously valid history entry.
