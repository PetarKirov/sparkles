# `sparkles:ui` — Open implementation issues

_Companion to the [architectural principles](./principles.md) and the UI
requirement tree. The normative decisions remain in those specs; this page
records concrete implementation gaps that the requirements already expose but
this docs-only consistency pass does not fix. Close an entry only after the
implementation lands, affected requirement statuses are reconciled, and the
closing commit is recorded._

## UI-O1 — Mutable-slice-backed Wholes lack an enforced copy policy {#ui-o1}

**Status:** open. **Requirements:** `PRN1`, `PRN6`, `WGT4`, `VMD1`.

`WidgetTree.nodes`, `Widget.children`, `Widget.spans`, `TreeData.nodes` and
`DisclosureState.exceptions` are prominent D-slice payloads in types that claim
value semantics. Copying their containing structs copies the slice descriptor,
so the copies alias mutable storage. Mutable builder/store types and the unified
`Theme.rules` channel require the same ownership audit even where they do not
claim to be Regular. The current types therefore do not satisfy the
copy-independence axiom required of the value-like Wholes and props described by
the specs. Borrowed text introduces a separate, legitimate lifetime relationship
that also needs to stay explicit.

The implementation must select and encode an honest policy for each type:
independent owning copy, exclusive/move-only ownership, or immutable/borrowed
sharing with an explicit lifetime. Close this issue when default or named copy
operations cannot silently create mutable aliases and property tests demonstrate
equality preservation plus independence for every type that claims Regular value
semantics. The audit must cover all mutable slice-bearing UI structs, not only
the examples named above.

## UI-O2 — The widget payload is still a tagged record {#ui-o2}

**Status:** open. **Requirements:** `PRN5`, `PRN6`, `PRN12`, `WGT3`.

`Widget.kind` currently selects which fields of one broad record carry meaning;
inactive fields still exist. `final switch` sites provide some exhaustiveness,
but the representation does not make invalid kind/payload combinations
unrepresentable and its structural equality includes fields outside the semantic
payload.

The implementation must replace the kind-dependent fields with the finite closed
sum required by `WGT3`, keep common layout/identity props outside that sum, and
make every alternative satisfy `PRN6`. Close this issue when every interpreter is
exhaustive over the sum and property tests cover equality laws, copy independence
and one representative value of every alternative.

## UI-O3 — Native pointer grab is missing {#ui-o3}

**Status:** open. **Requirements:** `INP9`, `TGT5`.
**Consumers:** [`hue` (`HUE-O3`)](../hue/open-issues.md#hue-o3) and
`apps/terminal`.

The raylib/window backend does **not** hold a native pointer grab during a mouse
drag. On GNOME/Wayland the apps run through XWayland, whose compositor routes
pointer events over window decoration—or outside the window—away from the app.
Two symptoms follow:

1. A drag released on a close/minimize/maximize button can activate that button.
2. A drag that leaves the content loses motion and release, so selection can stay
   active and scrollbar dragging cannot continue outside the window.

App-level mitigations were tried and reverted: vetoing close cannot cover
minimize/maximize, ending a drag on cursor exit breaks valid outside-window
dragging, and `GLFW_CURSOR_CAPTURED` was ignored on the tested XWayland/mutter
setup. The decisive events happen in the window manager, so semantic state checks
cannot reconstruct them.

The required implementation is a real active grab owned by the window/input
adapter for the duration of a drag:

- X11/XWayland: `XGrabPointer` on press and `XUngrabPointer` on release, using
  GLFW native display/window handles and requesting release plus motion events.
- Native Wayland, when supported: compositor pointer constraints together with
  the compositor's implicit grab.

This remains unverified on the target compositor. Close the issue only after the
[end-to-end windowing harness](../../research/window-system-integration/e2e-testing.md)
reproduces and then passes drag-over-decoration, outside-window motion and
outside-window release under a real headless window manager. In-process unit
tests are insufficient.
