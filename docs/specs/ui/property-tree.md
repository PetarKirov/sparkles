# `sparkles:ui` property tree — Feature Requirements (`PRT`)

_**Status:** planned · **Date:** 2026-08-20 · **Scope:** `PropertyTree!T`, the
reflective `sparkles:ui` adapter that presents one D value as an interactive
tree of property rows, applies scalar edits, and owns a host-stored undo/redo
model. The read path serves raylib, the terminal cell grid, script-free HTML
and Android; script-free HTML is intentionally read-only._

## Design & rationale

### A typed adapter over the existing tree

`PropertyTree!T` is an adapter, not another tree widget. It rebuilds one
`TreeData!PropertyNode` from `ref T`, lets `TreeViewState!string` retain the
opened set, cursor and viewport, and presents the result through the existing
`treeView` / `viewSlice` / `writeTreeText` surfaces. `TreeStep.rebuild` already
means exactly what the adapter needs: the opened set or filter changed, so walk
the subject again. The
[`tree-adapter.d`](../../research/property-tree/examples/tree-adapter.d) spike
proves that composition against the shipped components.

This keeps the three layers from [`VMD1`–`VMD7`](./widgets.md) intact:

| Layer       | Property-tree responsibility                                                                |
| ----------- | ------------------------------------------------------------------------------------------- |
| data        | `PropertyTree!T.data`, a per-rebuild flat `TreeData!PropertyNode` snapshot                  |
| interaction | host-owned `TreeViewState!string` and `PropertyEditState`, both named values                |
| view        | `components/property_view.d`, borrowing the data and state and emitting ordinary UI widgets |

The adapter never retains a pointer to the subject. Under `dip1000`, an adapter
containing a `T*` borrowed from its caller becomes `scope` and cannot safely
call its own ordinary methods. Receiving `ref T` at each rebuild and edit is
both the safe API and the honest expression of the frame model: the subject is
whatever the host owns this frame. It also preserves local reasoning
([`PRN1`, `PRN2`, `PRN7`](./principles.md)): the tree snapshot, interaction
state, edit history and subject relationship are explicit rather than an
ambient id-keyed side table.

The planned module split is:

- `sparkles.ui.property_tree` in `libs/ui` — metadata UDAs, path parsing and
  resolution, the type-only walk, `PropertyNode`, edit values, refusal values,
  `PropertyEditState`, and the `PropertyTree!T` adapter;
- `sparkles.ui.components.property_view` — checkbox, picker and numeric
  presentation over that model, composed with the shared tree view.

The reflection and mutation rules belong together because only the generated
dispatch can enforce `@readOnly` and type/range checks so no presentation can
route around them. Painting stays separate because the same model must serve
all four targets ([`PRN8`, `PRN9`](./principles.md)).

### One type-only walk, driven by disclosure

The public API is static introspection: `PropertyTree!T` reflects `T` at compile
time, with no registry and no dynamic-dispatch surface. The walk is
parameterised by **type only**; path, depth and budget are ordinary values.
That distinction is load-bearing. A path-parameterised template recursively
instantiates a fresh walk and hits the compiler limit, while
[`type-only-instantiation.d`](../../research/property-tree/examples/type-only-instantiation.d)
produces a 22-row CTFE manifest for a cyclic type. Runtime recursion through
the one type instance is therefore not an erasure boundary and needs no
delegate per node.

Children are materialised only when their path is open. A user-driven walk
therefore needs no visited set: each click admits one more finite level, as
proved by
[`open-set-descent.d`](../../research/property-tree/examples/open-set-descent.d).
`DisclosureState.allOpen()`, however, changes that walk from driven to
automatic. `PropertyTreePolicy` consequently defaults to `maxDepth = 16` and
`maxNodes = 5_000`. Reaching either cut emits a non-editable
`⋯ (capped)` row; it never truncates silently. A host may choose different
positive limits as data, including a larger limit after an explicit reader
action.

Runtime-shaped subjects use the same walk through a statically typed erased
value, such as a `JsonValue`-shaped sum. The optional `propChildren`,
`propExpandable` and `propText` capabilities are detected by presence. Static
fields can contain erased values and erased children can contain statically
typed values without a caller branch or registry; this is the seam proved by
[`erased-subject.d`](../../research/property-tree/examples/erased-subject.d).
The v1 erased seam is a read seam. A future writable erased type must expose a
typed edit capability; it may not introduce `void*` or an untyped callback.

### Paths are addresses; element keys are identity

Every row has one readable, persistable path. The base grammar is
`name ( "." name | "[" digits "]" )*`: members use `style.opacity`, array
elements use `stops[2]`. `at!"style.opacity"(subject)` is a compile-time-checked,
`ref`-returning direct access; a typo is a build error. `resolve` parses the
same grammar at run time and returns a refusal for a bad member, bad index or
null pointer rather than faulting. The two forms are differentially equal over
all paths the planner emits, as proved by
[`path-addressing.d`](../../research/property-tree/examples/path-addressing.d).

Index paths are deliberately positional in v1. This is simple and useful for
fixed collections, but deleting element zero re-points every later opened row,
selection, pending drag and history entry. A collection whose element type
exposes `ulong propElementKey() const` opts into stable identity: the component
renders `items[#7]`, resolves it by the key rather than the current index, and
requires keys to be unique within that collection. A duplicate key produces a
visible diagnostic row and refuses addressing; it never falls back to an index.
The keyed extension is runtime-resolved because `[#7]` is not a D field-access
expression; the compile-time direct-access guarantee remains exact for the
base positional grammar.

Before rebuilding, the adapter remembers the selected row's path and restores
that path in the new rows. If it no longer exists, it selects the nearest
visible ancestor, then clamps normally. Stable element keys therefore preserve
selection as well as disclosure and an in-progress edit across reorderings.

### Closed dispatch and metadata

Leaf choice is a closed `static if` ladder to `LeafKind`: boolean, integral,
floating, text, enumeration or opaque. Aggregates and collections descend;
strings remain leaves. `@opaqueValue` makes any type a leaf rendered through
its own `toString`, the script-free equivalent of VS Code's `Complex` escape.
An opaque value is never editable merely because it has text.

The compile-time metadata vocabulary is `@Label`, `@Group`, `@Doc`, `@Range`,
`@hidden`, `@readOnly`, `@Editor` and `@ShowIf`. `@Editor` names a symbol that
must compile for the concrete supported leaf type and emit a compatible
`EditValue`; it is not a registry key and cannot make an arbitrary opaque value
assignable.
`@ShowIf("kind == FillKind.gradient")` is compiled into a typed `@safe`
predicate over the enclosing value and evaluated on every rebuild. Bad member
names or incompatible custom editors are build errors. The complete dispatch,
including the opaque escape and value-dependent predicate, is proved by
[`leaf-dispatch.d`](../../research/property-tree/examples/leaf-dispatch.d).

All surfaces ask one shared `nodeExpandable` projection. It reads a node's
optional `expandable` capability and falls back to structural
`TreeData.hasChildren`. `activate` already has this rule; `treeView`,
`writeTreeText` and `collapseOrUp` must use it too. Otherwise a closed composite
whose lazy children do not exist yet is painted as a leaf, and Left climbs
instead of closing it. The text target includes the same open/closed/leaf/capped
meaning rather than publishing a different tree.

### Edits and refusals are values

An `Edit` is an owned value `(path, EditValue, phase)`, where phase is
`preview` or `commit`. Applying it through the generated dispatch returns an
`Applied` value containing either its inverse or a `Refusal`; it never throws
for user input. `EditValue` is a closed tagged value and assignments are
lossless: signedness and target width are checked, enum names must exist,
floating payloads round-trip exactly, and `@Range` is enforced before mutation.
Text copied from an `in Edit` is duplicated before storage, as `dip1000`
requires.

`EditValue`, `Edit`, `HistoryEntry` and `PropertyEditState` are Regular values
([`PRN6`](./principles.md)). In particular, floating edit equality is defined
by the stored representation rather than D's partial `NaN == NaN` relation, so
a value cannot be stale relative to itself.

Read-only is enforced inside the same generated dispatch: `@readOnly` refuses
one field, while `PropertyTreePolicy(readOnly: true)` refuses the entire
component before descent. Hiding or disabling a widget is not the security
boundary. `Refusal` includes at least no-such-path, null traversal, read-only
field, read-only policy, type mismatch, out of range, stale history and
stale interaction, edit in progress and duplicate element key. The view renders
the current path-addressed refusal inline below its row, following VS Code
rather than WinForms' modal error. A successful edit of that path clears it.

### Undo/redo belongs to the component, but the state belongs to the host

The survey found nine subjects and no standalone library that owns undo. This
component deliberately departs from that result because the edit protocol has
already paid the cost: applying an edit returns its inverse. The departure does
not create ambient memory. `PropertyEditState` is a named, serialisable value
the host stores **per logical subject**, beside the subject and independently of
each pane's `TreeViewState`. Two panes editing one subject share it; two panes
that need independent histories are, by definition, editing different logical
subjects. Rebinding the state to a replacement subject clears it.

Each `HistoryEntry` owns the path and exact before/after values. Undo requires
the addressed value to equal `after`; redo requires it to equal `before`. A
failed precondition returns `Refusal.staleHistory` and leaves the subject and
both stacks unchanged. This catches host writes, another pane, reloads and
positional collection movement instead of replaying an obsolete inverse
silently.

Grouping is interaction-scoped, not time-scoped:

1. The first successful `preview` for a path stores the value before the
   interaction and starts one pending group.
2. Further previews for that path mutate the subject but add no history.
3. The next `commit` for that path records one entry from the first value to
   the final value, even when the commit itself writes the already-previewed
   value.
4. A commit without a pending preview is one entry. A different path cannot
   join the pending group, and two completed commits never merge merely because
   they are adjacent.
5. While a group is pending, a different-path edit and undo/redo refuse without
   mutation. Each later preview/commit also requires the current value to equal
   the last value the group wrote; an external change makes the interaction
   stale and discards the pending group without overwriting that change.

Pointer release, pointer cancellation and focus loss are commit boundaries: the
input owner must finish the group with its last previewed value before routing
the event onward. Thus no pending drag is silently abandoned in retained state.

That is Godot's `MERGE_ENDS` rule stated without an ambient clock, and fixes the
no-op inverse demonstrated by
[`edit-commands.d`](../../research/property-tree/examples/edit-commands.d).
The first successful edit of a new interaction clears redo. Refused edits do
not change history. History is bounded by both `maxHistoryEntries = 256` and
`maxHistoryBytes = 1_048_576` logical payload bytes by default; after a commit,
oldest undo entries are evicted whole until both limits hold. Moving entries
between undo and redo does not change the combined budget.

Collection add/remove/reorder and sum-variant replacement are structural
edits. They are not exposed in v1, and therefore cannot bypass history as
"non-undoable" mutations. A later milestone must add a value-semantic `Edit`
case that owns a reversible structural payload and the same preconditions
before enabling its control. A sum switch will then use exactly one narrow
`@trusted` seam whose precondition is that no reference into the overwritten
payload outlives the call; the directional `SumType.opAssign` result is proved
in `edit-commands.d`.

Undo and redo are named commands exposed to the application's keymap layer.
The component supplies verbs and availability queries; it does not choose
Ctrl-Z, terminal chords or Android affordances. This keeps one binding table
and exhaustive host dispatch under [`KEY1` and `KEY11`](./keymap.md).

### Honest v1 target and editing scope

The read path ships first and is the same model on all four targets. In the
read-write milestone, bool uses a checkbox, enum a picker, and integral /
floating values a stepper or `@Range` slider. Those controls need only shared
key and pointer events, so raylib, TUI and Android can implement them without
the text editor. Script-free HTML always applies
`PropertyTreePolicy(readOnly: true)` and renders real values, documentation,
refusals and cuts without dead controls.

String fields remain read-only with a visible `needs EDT` marker until
[`EDT1`–`EDR5`](./editor.md) ship; property-tree does not invent a second text
editor. The later string control composes that component and keeps property
history as the outer value-level transaction rather than creating competing
undo stacks.

### Corrections to the survey snapshot

[`comparison.md`](../../research/property-tree/comparison.md) and
[`sparkles-baseline.md`](../../research/property-tree/sparkles-baseline.md) are
the historical Tier-2 reading. Their claims that recursive static reflection
requires a visited-type set or delegate erasure boundary, and their blanket
description of `SumType` assignment, are superseded here by the later design
spikes: `type-only-instantiation.d`, `open-set-descent.d` and
`edit-commands.d`. The normative rules are type-only instantiation, disclosure-
driven descent with explicit automatic-walk caps, and one directional trusted
variant-switch seam. The older prose remains useful evidence of the failed
approaches, not a competing requirement.

## Requirements (`PRT`)

| ID    | Requirement                                                                                                                                                                                                                                                                                                                                                             | Status      | Traces to                                                                  |
| ----- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | -------------------------------------------------------------------------- |
| PRT1  | `PropertyTree!T` must be an **adapter over the existing tree**: one per-rebuild `TreeData!PropertyNode`, host-owned `TreeViewState!string`, and the existing flatten/interaction/view functions. It must not add another retained or recursive node model.                                                                                                              | not started | `WGT12`, `VMD1`–`VMD7`; `tree-adapter.d`                                   |
| PRT2  | Every persistent concern must be a **named host-owned value**. The adapter must receive `ref T` for each rebuild/edit and must not retain `T*`; expansion/view state and edit history remain separately ownable and shareable.                                                                                                                                          | not started | `PRN1`, `PRN2`, `PRN7`; `tree-adapter.d` C24; `run_app.d` frame model      |
| PRT3  | Reflection must use one **type-only** template walk. Path, depth, opened state and budgets are values, so a self-referential type compiles at runtime and at CTFE without a visited-type set, delegate-per-node erasure, registry or caller branch.                                                                                                                     | not started | `type-only-instantiation.d`; `open-set-descent.d` C1–C2                    |
| PRT4  | Descent must materialise only opened children. Automatic descent, including `allOpen`, must terminate under `PropertyTreePolicy(maxDepth: 16, maxNodes: 5_000)` defaults and emit a visible, non-editable `⋯ (capped)` row at either cut; limits must be host-configurable positive values.                                                                             | not started | `open-set-descent.d` C2–C3; `STM5`; DevTools fetch policy                  |
| PRT5  | A statically typed erased subject may provide `propChildren`, `propExpandable` and `propText`; the same walk must cross between static and erased children by capability presence. The v1 erased seam is read-only unless a future typed edit capability is present.                                                                                                    | not started | `erased-subject.d` C16–C19; `VMD6`                                         |
| PRT6  | Row addresses must use `name(.name\|[index])*`. `at!P(ref subject)` must be a compile-time-checked direct `ref` access for that grammar; runtime `resolve` must implement the same segments and refuse malformed paths, missing members, out-of-range indices and null pointer hops without faulting.                                                                   | not started | `path-addressing.d` C8–C10                                                 |
| PRT7  | Collection indices are positional by default. An element exposing unique `ulong propElementKey() const` must instead use `[#key]` for disclosure, selection, pending edits and runtime resolution; duplicate keys must produce a visible diagnostic and no positional fallback.                                                                                         | not started | `path-addressing.d` C11; rjsf synthetic row keys                           |
| PRT8  | Rebuild must restore selection by the prior row path, falling back to its nearest visible ancestor and then the normal clamp. Thus stable element keys preserve selection through reorder, while a removed selection degrades predictably.                                                                                                                              | not started | `VMD2`, `VMD7`; `path-addressing.d` C11                                    |
| PRT9  | The metadata vocabulary must be `@Label`, `@Group`, `@Doc`, `@Range`, `@hidden`, `@readOnly`, `@Editor`, `@ShowIf` and type-level `@opaqueValue`; invalid metadata/editor combinations must fail compilation.                                                                                                                                                           | not started | `leaf-dispatch.d` C5–C7                                                    |
| PRT10 | `@ShowIf` must compile its expression into a typed `@safe` predicate over the enclosing value and evaluate it per rebuild; there must be no `void*`, untyped callback or runtime script evaluation.                                                                                                                                                                     | not started | `leaf-dispatch.d` C6; `PRN8`                                               |
| PRT11 | Leaf dispatch must be a closed `static if` mapping to boolean, integral, floating, text, enumeration or opaque. `@opaqueValue` uses the type's `toString` and remains read-only in v1; `@Editor` may override only a supported leaf with a type-correct editor that emits compatible `EditValue`s.                                                                      | not started | `leaf-dispatch.d` C4/C7; VS Code `Complex`; `PRN5`, `PRN12`                |
| PRT12 | One shared `nodeExpandable` projection (optional node `expandable`, structural fallback) must drive `activate`, `treeView`, `writeTreeText` and `collapseOrUp`, including the same leaf/open/closed/capped meaning on the plain-text target.                                                                                                                            | not started | `tree-adapter.d` C22; `INS5`; `VMD6`–`VMD7`                                |
| PRT13 | V1 editing must cover bool, enum, integral and floating leaves through pointer/key controls. Strings must render read-only with `needs EDT` until `EDT`/`EDR` ship; script-free HTML must apply the read-only policy as its complete, intentional mode.                                                                                                                 | not started | `EDT1`–`EDR5`; `WGT14`; DevTools read-only inspector                       |
| PRT14 | `Edit(path, EditValue, phase)` and `Applied(inverse \| Refusal)` must be owned Regular values. Runtime user/input failures must be refusal values, not exceptions, and an `in Edit` string must be copied before it can enter the subject or history.                                                                                                                   | not started | `edit-commands.d` C12; `PRN6`; `dip1000` evidence                          |
| PRT15 | Generated assignment must be lossless and total over supported leaves: check signedness/width, enum membership, floating representation and `@Range` before mutation. `EditValue` equality must be total, including NaN payloads, so history preconditions are coherent.                                                                                                | not started | `PRN5`, `PRN6`, `PRN11`; `leaf-dispatch.d` range metadata                  |
| PRT16 | `@readOnly` and `PropertyTreePolicy(readOnly: true)` must refuse inside the generated mutation dispatch. A view may omit or disable an affordance, but no alternate view may bypass the policy.                                                                                                                                                                         | not started | `edit-commands.d` C13; script-free HTML doctrine                           |
| PRT17 | `PropertyEditState` must own undo, redo, the pending preview group and path-addressed refusal display as one serialisable value stored per logical subject. Multiple panes over one subject share it; replacing the logical subject clears it.                                                                                                                          | not started | `PRN1`, `PRN6`; frame-model table in `comparison.md`                       |
| PRT18 | A successful commit must store a `HistoryEntry(path, before, after)`. Undo may apply only when the current value equals `after`; redo only when it equals `before`. A stale/missing path must refuse and leave the subject and both stacks unchanged.                                                                                                                   | not started | `edit-commands.d` C12; local-reasoning contracts; external-mutation hazard |
| PRT19 | Preview grouping must span exactly the first successful preview through the next commit on the same path, preserving the pre-preview value. Later previews add no entry; commit without preview adds one; other-path/history operations refuse while pending; each step checks the last emitted value; release/cancel/focus loss commits; completed groups never merge. | not started | `edit-commands.d` C14; Godot `MERGE_ENDS`                                  |
| PRT20 | The first successful edit of a new interaction must clear redo; refusals must not. Combined undo/redo history must default to at most 256 entries and 1,048,576 logical payload bytes, evicting oldest undo entries whole after commit until both bounds hold.                                                                                                          | not started | value-semantic undo; `PRN1`, `PRN6`                                        |
| PRT21 | Edit refusals and validation failures must render **inline at the addressed row**, survive rebuilding as part of `PropertyEditState`, clear on that path's next success, and never require a modal surface.                                                                                                                                                             | not started | VS Code inline validation; WinForms modal contrast; `PRN8`, `PRN9`         |
| PRT22 | Collection add/remove/reorder and variant replacement must not be exposed in v1. They may ship only with a reversible value-semantic structural `Edit` case and the same staleness contract; variant replacement must isolate the directional `SumType` hazard in exactly one documented `@trusted` seam.                                                               | not started | `edit-commands.d` C15; `PRN5`; rjsf variant migration                      |
| PRT23 | Undo and redo must be named component commands with availability queries for the host's binding table and exhaustive dispatch. The component must not hard-code keys, chords or platform affordances.                                                                                                                                                                   | not started | `KEY1`, `KEY11`; Android input surface                                     |
| PRT24 | Templates must infer attributes; non-templates must be explicitly `@safe`. The only planned `@trusted` operation is structural variant overwrite with the precondition that no reference into the old payload survives the call.                                                                                                                                        | not started | `edit-commands.d` C15; project safety rules                                |
| PRT25 | A successful edit followed by rebuild must refresh values and conditional visibility while preserving opened paths, restored selection, viewport bounds, history and any pending same-path preview.                                                                                                                                                                     | not started | `tree-adapter.d` C21/C23; `TreeStep.rebuild`; `VMD2`, `VMD7`               |
| PRT26 | The read model and all semantic edit transitions must be backend-independent. Raylib, TUI and Android may realise controls differently; HTML must render the same rows/readouts/cuts/refusals without an inert editing affordance.                                                                                                                                      | not started | `PRN8`, `PRN9`; four-target constraint; `INS5`                             |
| PRT27 | Implementation must live in `sparkles.ui.property_tree` (metadata, walk, paths, edits, adapter) and `sparkles.ui.components.property_view` (presentation), with the expandability fix kept in the existing tree/inspector modules rather than copied into the adapter.                                                                                                  | not started | `PRN8`, `PRN10`; `tree_widget.d`, `tree_view.d`, `inspector.d`             |
| PRT28 | Tests must include CTFE/runtime path differential cases, cyclic/open/all-open cuts, null/bad paths, UDA compile failures, stable-key reorder and duplicate cases, policy bypass attempts, preview grouping, stale undo/redo, history eviction, floating totality, all four target renderings, and the one trusted seam's precondition.                                  | not started | seven property-tree design spikes; `PRN11`; `INS5`                         |

## Milestones

| Milestone | Independently shippable scope                                                                                                                                          | Status      | Requirements                     |
| --------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | -------------------------------- |
| P0        | Read path on all four targets: type-only open-set walk, metadata, paths, dynamic read seam, stable keys, caps, shared expandability and plain-text/HTML rendering      | not started | `PRT1`–`PRT12`, `PRT24`–`PRT28`  |
| P1        | Scalar write path on raylib/TUI/Android: bool/enum/numeric controls, generated refusal/validation, read-only policy, per-subject bounded undo/redo and keymap commands | not started | `PRT13`–`PRT21`, `PRT23`–`PRT28` |
| P2        | String leaves by composition after the shared editor lands; property-level commit/history remains outside the editor's internal text operation log                     | deferred    | `PRT13`; gated by `EDT1`–`EDR5`  |
| P3        | Structural editing only after reversible collection/variant edit cases and the trusted variant seam are separately designed, implemented and property-tested           | deferred    | `PRT22`, `PRT24`, `PRT28`        |

## Deferred by decision

- **Multi-subject editing (`D8`)** — v1 edits one logical subject. Unity's
  ambient mixed-value flag is cheap only because its model owns an invalidated
  comparison cache; adding that model and per-subject preconditions is a
  separate design.
- **Provenance rows (`D7`)** — v1 edits a value, not configuration. VS Code's
  `isConfigured`, default source, scope and policy lock become necessary when a
  subject represents layered configuration and must arrive as an explicit
  capability, not be guessed from equality.
- **General validation models** — v1 specifies display and assignment refusal.
  Cross-field/domain validation may later provide several path-addressed
  messages through a typed capability; it keeps the inline presentation.
- **Family-D remote subjects** — asynchronous leases, fetch policy and stale
  remote handles remain the extension point named by [`INS8`](./inspector.md),
  not a hidden promise of the synchronous `ref T` API.
- **Structural edits and variant migration** — unavailable in v1. A future
  design must choose operation-specific inverse payloads versus owned subtree
  snapshots and must decide whether rjsf-style name/type migration is honest
  enough for statically typed D values.

## Open questions

No open question blocks P0 or P1. P2 is gated by the existing `EDT` spec. P3
must answer the structural-payload and variant-migration questions above before
any structural control is enabled. Writable erased subjects likewise need a
separate typed edit capability; the v1 `propChildren` seam intentionally
promises inspection only.

## Module coverage

| Planned source file                                  | Requirements                                       |
| ---------------------------------------------------- | -------------------------------------------------- |
| `libs/ui/src/sparkles/ui/property_tree.d`            | `PRT1`–`PRT11`, `PRT14`–`PRT25`, `PRT27`–`PRT28`   |
| `libs/ui/src/sparkles/ui/components/property_view.d` | `PRT12`–`PRT13`, `PRT21`, `PRT23`, `PRT25`–`PRT28` |
| `libs/ui/src/sparkles/ui/components/tree_widget.d`   | `PRT12`                                            |
| `libs/ui/src/sparkles/ui/components/tree_view.d`     | `PRT12`                                            |
| `libs/ui/src/sparkles/ui/components/inspector.d`     | `PRT12`, `PRT26`                                   |

## Relationship to existing specs

| Piece                                                   | Role                                                                                    |
| ------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| [Widgets](./widgets.md) `WGT12`, `VMD1`–`VMD7`          | the flat tree, external interaction state, lazy intent and shared interaction verbs     |
| [Inspector](./inspector.md) `INS5`, `INS8`              | the plain-text surface and future async/remote-provider seam                            |
| [State machines](./state-machines.md) `STM5`            | disclosure as a value, including the `allOpen` polarity whose automatic walk needs caps |
| [Editor](./editor.md) `EDT`, `EDR`                      | the deliberately unimplemented dependency for editable string leaves                    |
| [Keymap](./keymap.md) `KEY1`, `KEY11`                   | named undo/redo commands, host-selected bindings and exhaustive dispatch                |
| [Principles](./principles.md) `PRN1`–`PRN12`            | explicit relationships, Regular values, local transitions and one semantic definition   |
| [Property-tree research](../../research/property-tree/) | corpus, comparison, vocabulary, baseline and executable design-spike evidence           |

→ [Overview](./index.md) · [Widgets](./widgets.md) · [Inspector](./inspector.md) · [Editor](./editor.md)
