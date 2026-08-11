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
the examples named above — `DockContainer.paneFrames`/`.dividers` are in scope
as derived per-frame caches (rebuilt by `arrange`, and so a candidate for the
"borrowed/derived, not owned" policy rather than for copying).

`DockLayout` ([`DCK1`](./containers.md)) is the first type to discharge this
requirement and is the worked example: its arena is deep-copied by an explicit
copy constructor, because a layout that aliases the arrangement it snapshotted
cannot serve [`DCK2`](./containers.md) persistence. The test asserting
copy-then-mutate independence is what exposed the aliasing — which is the
property test this issue asks for, generalized to every claimant.

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

`SCV8` now removes the common selection failure while the pointer is still in
the window: parking in the pane's edge band autoscrolls and re-delivers a drag
without further motion. It cannot recover a release captured by the window
manager, so this native-grab issue remains open.

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

[Anchored overlays](./popup.md) newly constrains this issue without closing it:
`MDL11` forbids specifying modality or dismissal in terms of an OS grab or a
nested event loop, so the overlay primitive must work without one and acquiring
a grab later is an improvement rather than a precondition. The issue stays open,
and its fix stays owned by the input adapter.

## UI-O4 — An allocation-free display list is borrowed, not owned {#ui-o4}

**Status:** open. **Requirements:** `NFR2`, `PRN1`, `UI-O1`.

`buildDisplayList` returns a GC array today, so every consumer's slice stays alive
for as long as it is referenced and no lifetime question arises. `NFR2` replaces
that with a `SmallBuffer` the caller supplies — which turns the returned operations
into a **borrow**: the buffer must outlive every painter that walks it, and a slice
that currently outlives its producer does so only because the collector kept it
alive.

**The `sparkles:base` prerequisite is met** (`350ba75d`): `SmallBuffer` registers
its heap block as a GC root and initializes its inline slots for an element type
carrying references, so a `DrawOp` buffer is safe to hold.

**The path exists** (`eea336c3`): `buildDisplayListInto` walks into any sink taking
`~= DrawOp`, and with a `SmallBuffer` the walk is `@nogc` — asserted at compile
time. `buildDisplayList` is unchanged and now wraps it.

What is left is the ownership, and the audit is what showed it is not mechanical:

1. **Retained consumers store the list, not a scope-local copy.** `ViewerModel`
   holds `DrawOp[] ops` as a member and rebuilds it on demand; `explorer.d`,
   `tui.d`, `twoslash_tui.d` and `gui.d` do likewise. Each must own the _sink_
   rather than a slice of one — a change to what the type owns, not to a call.
2. **The widget arena is the same change, wider.** `WidgetTree.nodes` is a slice
   consumers hold, so moving the `Builder` arena onto a buffer makes every holder
   of a tree a holder of its storage. That is [`UI-O1`](#ui-o1)'s question, not a
   separate one, and it should be answered there first.
3. **A stated policy**, in the same terms [`UI-O1`](#ui-o1) demands: the operations
   are derived, borrowed per-frame data, and the type should say so rather than
   leaving it to a comment.

Most of this converges on `gui.d`, which is excluded from hue's test build — so
the conversion wants doing one consumer at a time against a green build, not as a
sweep. The `@nogc` path being additive is what makes that possible: a new consumer
(the application host, the diagram app) takes it immediately, while a retained one
moves when its ownership is settled.

Close this issue when the widget arena and every retained display list are
allocation-free in steady state, the ownership policy is written on the types, and
no consumer holds operations past their buffer.
