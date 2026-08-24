# `sparkles:ui` property tree — Feature Requirements (`PRT`)

_**Status:** in progress (P0/P1 core shipped) · **Date:** 2026-08-21 · **Scope:** `PropertyTree!T`, the
reflective `sparkles:ui` adapter that presents one D value as an interactive,
filterable tree of property rows, applies scalar edits, and owns a host-stored
undo/redo model. The read path serves raylib, the terminal cell grid,
script-free HTML and Android; script-free HTML is intentionally read-only._

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

### Filtering makes the tree a ranked search result

The filter editor already belongs to `TreeViewState!string`; property-tree uses
that shared state and its `TreeStep.rebuild` protocol. An empty query builds the
ordinary disclosure projection `(subject, opened paths, policy)`. A non-empty
query builds a distinct search-result projection `(subject, query, policy,
target rows)`. This is VS Code's clean model-swap semantics without retaining a
second copy of the subject: each rebuild produces one flat value snapshot, and
clearing the query simply selects the disclosure projection again.

Search discovery ignores the opened set and descends through every locally
enumerable, eligible composite within the automatic-walk budgets. The result
contains direct matches plus the minimum ancestor closure needed to explain
their paths, like broot's tree-as-search-result mode and hue's shipped `TRV5`
explorer filter. Search-result edges render open by default, but filtering
never calls `DisclosureState.opened` / `closed`. While a query is present,
folding commands act on a per-query **transient fold overlay** owned by the
filter portion of `TreeViewState!string`, so a reader can fold a noisy context
subtree mid-search; the overlay affects visibility only — never admission,
ranking or match counts — and is discarded with the query. Clearing a filter
therefore restores the exact manual disclosure intent rather than a
search-expanded approximation. A directly matching composite does not drag in
all its unmatched descendants; a named **reveal in base tree** command clears
the query, opens its ancestors and selects it when the reader wants to explore
it.

Every eligible row has one `PropertySearchRecord`: stable path, display label,
rendered scalar text when present, and `@Doc` text when present. `@hidden` rows
and rows rejected by `@ShowIf` never enter the search corpus. Unqualified query
parts use `sparkles:fuzzy`'s Unicode-aware `codePath` analysis, smart case,
typo-tolerant admission, deterministic integer scoring and canonical witness
positions. A one-analyzed-unit part uses exact smart-case unit admission rather
than fuzzy's dropped-short-part behavior, so typing one character narrows the
tree instead of matching everything. Every query part is required, but
different parts may land in different record fields (for example
`opacity 0.5` may match label plus value). A field longer than the fuzzy
candidate capacity (4,096 analyzed units / 4,096 source bytes — fuzzy refuses
such a candidate as `candidateTooLong` rather than truncating it) is analyzed
as source-offset-preserving Unicode-boundary chunks with a one-query-span
overlap; the chunking is this component's own layer over that refusal, not an
existing fuzzy facility, and a field is never truncated silently. The
aggregate score is the floor of the arithmetic mean of the part scores —
fuzzy's own intra-candidate rule. Ties prefer a label match, then path, value
and documentation; then shallower depth; then the canonical path's byte order.
This is property-tree's own total order layered over fuzzy's integer part
scores — it deliberately replaces fuzzy's default recency/id tie-breaking,
which has no meaning for property rows — and does not depend on walk, hash or
worker order.

The builder scores during discovery instead of materialising a full hidden
`TreeData` and filtering it afterward. It retains the best direct matches in a
`sparkles:fuzzy` `TopK` (defined in `sparkles.fuzzy.rank`, re-exported by the
package); the match target is ten times the requesting pane's viewport row
count, read from that pane's `TreeViewState` at rebuild — so the projection
stays a pure function of `(subject, query, policy, target rows)` and a resize
is simply another rebuild — bounded by `maxNodes`. It then reconstructs their ancestor
closure in declaration / collection order, dropping lowest-ranked matches and
now-unneeded ancestors until the flat result also fits `maxNodes`. Ranking
therefore decides admission and the initial best match, while visible siblings
retain the subject's meaningful order. Known rejected matches become a
non-selectable `⋯ N lower-ranked matches omitted` row. If `maxDepth` or the
candidate-walk `maxNodes` budget ends discovery before exhaustion, the result
instead says `⋯ search incomplete (capped)` and must not claim a complete match
count.

`PropertyNode` carries whether it is a direct match, an ancestor context row or
a synthetic status row, plus its score, matched fields and exact UTF-8 byte
ranges. Renderers emphasize the canonical witness in labels and values. A
path-only or documentation-only hit shows one bounded secondary snippet so the
reason for inclusion is visible. Context and selection use independent styles;
plain text includes semantic match/status markers, and accessibility text says
which field matched rather than relying on color. A malformed or over-capacity
query keeps the last complete result and reports the fuzzy error in filter
chrome; zero matches renders one non-selectable `No properties match` row.

On the first empty-to-non-empty query transition, the filter portion of
`TreeViewState!string` captures the selected stable path and its viewport row
(`sel - top`). Each later query rebuild preserves the current selection when
that path remains, otherwise selects the highest-ranked direct match. Named
next/previous-match commands cycle through direct matches in visible tree
order, skipping ancestors, synthetic rows and rows hidden by a transient fold.
Accepting the editor keeps the query, result and captured base anchor.
Clearing it restores the captured path at the same viewport row, falling back
to its nearest visible ancestor and the ordinary clamp; only then is the
anchor discarded. **Reveal in base tree** is the exception: it clears the
query, discards the anchor, and selects its own target instead.

Every query mutation advances a monotonically increasing generation. The
locally enumerable v1 walk may complete synchronously under the hard budgets;
an implementation that chunks or parallelises discovery/scoring must use
`sparkles.fuzzy.searchChunk`-style caller-owned cursors and publish only the
current generation. A new keystroke makes earlier work stale immediately. No
search job may retain `T*`; it either receives `ref T` for its bounded step or
works from an owned, generation-bound search-record snapshot.

Filtering must not break an edit transaction. A path with a pending preview is
pinned into every pane's result with its ancestors even if the previewed value
stops matching; it remains selected — in the pane that owns the interaction —
until commit, cancellation or stale-interaction refusal ends the group. The next rebuild then applies the query normally. Undo,
redo and an ordinary committed edit likewise rebuild the result because the
rendered value and `@ShowIf` eligibility may have changed.

Raylib, TUI and Android expose the same live-query transitions through their
input surfaces. Script-free HTML does not render an inert filter box; it renders
the ordinary tree, or the same precomputed ranked projection and `<mark>`
spans when the host supplies a query. Thus filtering changes the set of rows,
never the meaning of a row or the edit dispatch behind it.

### Paths are addresses; element keys are identity

Every row has one readable, persistable path conforming to the [`sparkles:dql`](../dql/SPEC.md)
path addressing grammar. The base grammar is `name ( "." name | "[" digits "]" )*`:
members use `style.opacity`, array elements use `stops[2]`. Erased child names
are not restricted to D identifiers — a `JsonValue`-shaped subject may hold
keys containing `.`, `[`, spaces or leading digits — so the grammar adds a
quoted segment: `["…"]` addresses a child by arbitrary name, with `\"` and
`\\` escapes. The path emitter uses the bare form exactly when the name is
identifier-shaped and the quoted form otherwise, so every emitted path
re-parses to the same segments. `at!"style.opacity"(subject)` is a
compile-time-checked, `ref`-returning direct access; a typo is a build error.
`resolve` parses the same grammar at run time and returns a refusal for a bad
member, bad index or null pointer rather than faulting. The two forms are
differentially equal over all base-grammar paths the planner emits, and the
quoted round-trip is proved in the same spike, by
[`path-addressing.d`](../../research/property-tree/examples/path-addressing.d);
quoted segments, like keyed ones below, are runtime-resolved only.

Index paths are deliberately positional in v1. This is simple and useful for
fixed collections, but deleting element zero re-points every later opened row,
selection, pending drag and history entry. A collection whose element type
exposes `ulong propElementKey() const` opts into stable identity: the component
renders `items[#7]`, resolves it by the key rather than the current index, and
requires keys to be unique within that collection. A duplicate key produces a
visible diagnostic row and refuses addressing; it never falls back to an index.
The keyed extension is runtime-resolved because `[#7]` is not a D field-access
expression; the compile-time direct-access guarantee remains exact for the
base positional grammar. The element-provided key is a deliberate departure
from the survey spike's first fix, which minted the id in an adapter-owned
table: identity belongs beside the element, not in an ambient side table
([`PRN1`, `PRN2`](./principles.md)), and the extended spike proves the
intrusive form, duplicate refusal included (C25).

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

The compile-time metadata vocabulary is `@Label`, `@Doc`, `@Range`, `@hidden`,
`@readOnly`, `@Editor` and `@ShowIf`. (`@Group` exists in the research spike's
vocabulary but is deferred until its semantics are defined — see Deferred.)
`@Editor` names a symbol that must compile for the concrete supported leaf
type and emit a compatible `EditValue`; it is not a registry key and cannot
make an arbitrary opaque value assignable.
`@ShowIf("kind == FillKind.gradient")` is compiled into a typed `@safe`
[`sparkles:dql`](../dql/SPEC.md) predicate over the enclosing value and
evaluated on every rebuild. Bad member names or incompatible custom editors
are build errors, shown by the spike's negative-compile probes (C27). The
complete dispatch, including the opaque escape and value-dependent predicate,
is proved by [`leaf-dispatch.d`](../../research/property-tree/examples/leaf-dispatch.d).

All surfaces ask one shared `nodeExpandable` projection. It reads a node's
optional `expandable` capability and falls back to structural
`TreeData.hasChildren`. `activate` already has this rule; `treeView`,
`writeTreeText` and `collapseOrUp` must use it too. Today `treeView` paints a
closed lazy composite as a leaf, `collapseOrUp` climbs instead of closing it,
and `writeTreeText` publishes no open/closed/leaf distinction at all; after
the fix the text target includes the same open/closed/leaf/capped meaning
rather than publishing a different tree.

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
oldest undo entries are evicted whole until both limits hold. The
just-committed entry is always retained, even when it alone exceeds the byte
bound: eviction removes older entries and stops, so the entry bound stays
hard, the byte bound is a target the newest entry may exceed, and undo of the
latest commit always remains possible. Moving entries between undo and redo
does not change the combined budget.

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

String fields remain read-only with a visible `needs EDT` marker until the
editor spec ships — the `EDT` state machine, the `EDI` backend text-input/IME
tier and the `EDR` widget of [`editor.md`](./editor.md); `EDI3` (raylib has no
IME composition) and `EDI4` (the Android soft keyboard) are the hard half of
that gate for this component's targets. Property-tree does not invent a second
text editor. The later string control composes that component and keeps
property history as the outer value-level transaction rather than creating
competing undo stacks.

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

| ID    | Requirement                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 | Status          | Traces to                                                                  |
| ----- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------- | -------------------------------------------------------------------------- |
| PRT1  | `PropertyTree!T` must be an **adapter over the existing tree**: one per-rebuild `TreeData!PropertyNode`, host-owned `TreeViewState!string`, and the existing flatten/interaction/view functions. It must not add another retained or recursive node model.                                                                                                                                                                                                                                                                  | full (14a19837) | `WGT12`, `VMD1`–`VMD7`; `tree-adapter.d`                                   |
| PRT2  | Every persistent concern must be a **named host-owned value**. The adapter must receive `ref T` for each rebuild/edit and must not retain `T*`; expansion/view state and edit history remain separately ownable and shareable.                                                                                                                                                                                                                                                                                              | full (14a19837) | `PRN1`, `PRN2`, `PRN7`; `tree-adapter.d` C24; `run_app.d` frame model      |
| PRT3  | Reflection must use one **type-only** template walk. Path, depth, opened state and budgets are values, so the one walk over a self-referential type builds, and runs at runtime and at CTFE, without a visited-type set, delegate-per-node erasure, registry or caller branch.                                                                                                                                                                                                                                              | full (14a19837) | `type-only-instantiation.d`; `open-set-descent.d` C1–C2                    |
| PRT4  | Descent must materialise only opened children. Automatic descent, including `allOpen`, must terminate under `PropertyTreePolicy(maxDepth: 16, maxNodes: 5_000)` defaults and emit a visible, non-editable `⋯ (capped)` row at either cut; limits must be host-configurable positive values.                                                                                                                                                                                                                                 | full (14a19837) | `open-set-descent.d` C2–C3; `STM5`; DevTools fetch policy                  |
| PRT5  | A statically typed erased subject may provide `propChildren`, `propExpandable` and `propText`; the same walk must cross between static and erased children by capability presence. The v1 erased seam is read-only unless a future typed edit capability is present.                                                                                                                                                                                                                                                        | full (14a19837) | `erased-subject.d` C16–C19; `VMD6`                                         |
| PRT6  | Row addresses must use `name(.name\|[index])*`, plus a quoted segment `["name"]` (backslash escapes) for erased child names outside the identifier subset; the emitter must pick bare exactly when the name is identifier-shaped so every emitted path re-parses. `at!P(ref subject)` must be a compile-time-checked direct `ref` access for the base grammar; runtime `resolve` must implement all segment forms and refuse malformed paths, missing members, out-of-range indices and null pointer hops without faulting. | full (14a19837) | `path-addressing.d` C8–C10, C26                                            |
| PRT7  | Collection indices are positional by default. An element exposing unique `ulong propElementKey() const` must instead use `[#key]` for disclosure, selection, pending edits and runtime resolution; duplicate keys must produce a visible diagnostic and no positional fallback.                                                                                                                                                                                                                                             | full (14a19837) | `path-addressing.d` C11/C25; rjsf synthetic row keys                       |
| PRT8  | Rebuild must restore selection by the prior row path, falling back to its nearest visible ancestor and then the normal clamp. Thus stable element keys preserve selection through reorder, while a removed selection degrades predictably.                                                                                                                                                                                                                                                                                  | full (14a19837) | `VMD2`, `VMD7`; `path-addressing.d` C11                                    |
| PRT9  | The metadata vocabulary must be `@Label`, `@Doc`, `@Range`, `@hidden`, `@readOnly`, `@Editor`, `@ShowIf` and type-level `@opaqueValue` (`@Group` is deferred); invalid metadata/editor combinations must fail compilation.                                                                                                                                                                                                                                                                                                  | full (14a19837) | `leaf-dispatch.d` C5–C7, C27                                               |
| PRT10 | `@ShowIf` must compile its expression into a typed `@safe` predicate over the enclosing value and evaluate it per rebuild; there must be no `void*`, untyped callback or runtime script evaluation.                                                                                                                                                                                                                                                                                                                         | full (14a19837) | `leaf-dispatch.d` C6; `PRN8`                                               |
| PRT11 | Leaf dispatch must be a closed `static if` mapping to boolean, integral, floating, text, enumeration or opaque. `@opaqueValue` uses the type's `toString` and remains read-only in v1; `@Editor` may override only a supported leaf with a type-correct editor that emits compatible `EditValue`s.                                                                                                                                                                                                                          | full (14a19837) | `leaf-dispatch.d` C4/C7/C27; VS Code `Complex`; `PRN5`, `PRN12`            |
| PRT12 | One shared `nodeExpandable` projection (optional node `expandable`, structural fallback) must drive `activate`, `treeView`, `writeTreeText` and `collapseOrUp`, including the same leaf/open/closed/capped meaning on the plain-text target.                                                                                                                                                                                                                                                                                | full (b409c408) | `tree-adapter.d` C22; `INS5`; `VMD6`–`VMD7`                                |
| PRT13 | V1 editing must cover bool, enum, integral and floating leaves through pointer/key controls. Strings must render read-only with `needs EDT` until `EDT`/`EDR` ship; script-free HTML must apply the read-only policy as its complete, intentional mode.                                                                                                                                                                                                                                                                     | partial         | `EDT`/`EDI`/`EDR`; `WGT14`; DevTools read-only inspector                   |
| PRT14 | `Edit(path, EditValue, phase)` and `Applied(inverse \| Refusal)` must be owned Regular values. Runtime user/input failures must be refusal values, not exceptions, and an `in Edit` string must be copied before it can enter the subject or history.                                                                                                                                                                                                                                                                       | full (66326827) | `edit-commands.d` C12; `PRN6`; `dip1000` evidence                          |
| PRT15 | Generated assignment must be lossless and total over supported leaves: check signedness/width, enum membership, floating representation and `@Range` before mutation. `EditValue` equality must be total, including NaN payloads, so history preconditions are coherent.                                                                                                                                                                                                                                                    | full (66326827) | `PRN5`, `PRN6`, `PRN11`; `leaf-dispatch.d` range metadata                  |
| PRT16 | `@readOnly` and `PropertyTreePolicy(readOnly: true)` must refuse inside the generated mutation dispatch. A view may omit or disable an affordance, but no alternate view may bypass the policy.                                                                                                                                                                                                                                                                                                                             | full (66326827) | `edit-commands.d` C13; script-free HTML doctrine                           |
| PRT17 | `PropertyEditState` must own undo, redo, the pending preview group and path-addressed refusal display as one serialisable value stored per logical subject. Multiple panes over one subject share it; replacing the logical subject clears it.                                                                                                                                                                                                                                                                              | full (66326827) | `PRN1`, `PRN6`; frame-model table in `comparison.md`                       |
| PRT18 | A successful commit must store a `HistoryEntry(path, before, after)`. Undo may apply only when the current value equals `after`; redo only when it equals `before`. A stale/missing path must refuse and leave the subject and both stacks unchanged.                                                                                                                                                                                                                                                                       | full (66326827) | `edit-commands.d` C12; local-reasoning contracts; external-mutation hazard |
| PRT19 | Preview grouping must span exactly the first successful preview through the next commit on the same path, preserving the pre-preview value. Later previews add no entry; commit without preview adds one; other-path/history operations refuse while pending; each step checks the last emitted value; release/cancel/focus loss commits; completed groups never merge.                                                                                                                                                     | full (66326827) | `edit-commands.d` C14; Godot `MERGE_ENDS`                                  |
| PRT20 | The first successful edit of a new interaction must clear redo; refusals must not. Combined undo/redo history must default to at most 256 entries and 1,048,576 logical payload bytes, evicting oldest undo entries whole after commit until both bounds hold; the just-committed entry is always retained even when it alone exceeds the byte bound.                                                                                                                                                                       | full (66326827) | value-semantic undo; `PRN1`, `PRN6`                                        |
| PRT21 | Edit refusals and validation failures must render **inline at the addressed row**, survive rebuilding as part of `PropertyEditState`, clear on that path's next success, and never require a modal surface.                                                                                                                                                                                                                                                                                                                 | full (66326827) | VS Code inline validation; WinForms modal contrast; `PRN8`, `PRN9`         |
| PRT22 | Collection add/remove/reorder and variant replacement must not be exposed in v1. They may ship only with a reversible value-semantic structural `Edit` case and the same staleness contract; variant replacement must isolate the directional `SumType` hazard in exactly one documented `@trusted` seam.                                                                                                                                                                                                                   | full (66326827) | `edit-commands.d` C15; `PRN5`; rjsf variant migration                      |
| PRT23 | Undo and redo must be named component commands with availability queries for the host's binding table and exhaustive dispatch. The component must not hard-code keys, chords or platform affordances.                                                                                                                                                                                                                                                                                                                       | full (66326827) | `KEY1`, `KEY11`; Android input surface                                     |
| PRT24 | Templates must infer attributes; non-templates must be explicitly `@safe`. The only planned `@trusted` operation is structural variant overwrite with the precondition that no reference into the old payload survives the call.                                                                                                                                                                                                                                                                                            | partial         | `edit-commands.d` C15; project safety rules                                |
| PRT25 | A successful edit followed by rebuild must refresh values and conditional visibility while preserving opened paths, restored selection, viewport bounds, history and any pending same-path preview.                                                                                                                                                                                                                                                                                                                         | full (66326827) | `tree-adapter.d` C21/C23; `TreeStep.rebuild`; `VMD2`, `VMD7`               |
| PRT26 | The read model and all semantic edit transitions must be backend-independent. Raylib, TUI and Android may realise controls differently; HTML must render the same rows/readouts/cuts/refusals without an inert editing affordance.                                                                                                                                                                                                                                                                                          | partial         | `PRN8`, `PRN9`; four-target constraint; `INS5`                             |
| PRT27 | Implementation must live in `sparkles.ui.property_tree` (metadata, walk, paths, edits, adapter) and `sparkles.ui.components.property_view` (presentation), with the expandability fix kept in the existing tree/inspector modules rather than copied into the adapter.                                                                                                                                                                                                                                                      | full (c2ef3d45) | `PRN8`, `PRN10`; `tree_widget.d`, `tree_view.d`, `inspector.d`             |
| PRT28 | Read-path tests must include CTFE/runtime path differential cases, quoted-segment round-trips, cyclic/open/all-open cuts, null/bad paths, UDA compile failures, stable-key reorder and duplicate cases, all four target renderings, and the read-side filtering matrix in `PRT29`–`PRT33`. (`PRT35` is the write-path matrix.)                                                                                                                                                                                              | partial         | seven property-tree design spikes; `PRN11`; `INS5`                         |
| PRT29 | A non-empty shared-tree query must rebuild a distinct **search-result projection** from the subject: direct matches plus their minimum ancestor closure, independent of the opened set. Filtering must neither read disclosure to limit discovery nor mutate it; folding while filtered must act on a per-query transient overlay (visibility only, discarded with the query); clearing must restore the prior disclosure projection exactly.                                                                               | full (0eea890c) | `VMD7`; `TRV5`; broot dual-tree/search-result model; VS Code model swap    |
| PRT30 | Search records must cover stable path, display label, rendered scalar value and `@Doc`, excluding `@hidden`/false-`@ShowIf` rows. All query parts must match across those fields through `sparkles:fuzzy` `codePath` semantics, with exact one-unit matching and lossless chunking for over-capacity fields; ranking must be total and canonical witness ranges retained.                                                                                                                                                   | partial         | `sparkles:fuzzy` §§2–6; broot fuzzy scoring/highlighting                   |
| PRT31 | Filtering must score during bounded discovery, retain up to ten times the requesting pane's viewport row target — read from its `TreeViewState` at rebuild — in best direct matches (bounded by `maxNodes`), reconstruct their ancestor closure in source order, and emit honest non-selectable omitted/incomplete rows. Query generations must cancel stale chunked/parallel work, which may retain owned records but never `T*`.                                                                                          | full (0eea890c) | broot BFS/Top-K/pruning/cancellation; `sparkles:fuzzy` §§6/9; `PRN1`       |
| PRT32 | Filter state must capture the pre-filter selection path and viewport row, preserve a still-visible selection across query edits, otherwise choose the best direct match, and restore the base anchor on clear. Next/previous-match must skip context/status rows and rows hidden by a transient fold; reveal-in-base must clear the query, discard the captured anchor, open ancestors and select the result without hard-coded keys.                                                                                       | full (0eea890c) | broot selection restoration; `TRV3`, `TRV7`; `VMD2`, `VMD7`; `KEY1`        |
| PRT33 | Nodes must distinguish direct match, ancestor context and synthetic status, retain field-specific highlight spans, and expose why a row matched in color-independent text. Invalid queries keep the last complete result with an explicit error; zero results are explicit; HTML supports precomputed results/`<mark>` but no inert live-search control.                                                                                                                                                                    | full (0eea890c) | broot direct-match/pruning rendering; `PRN8`–`PRN9`; `TRB3`                |
| PRT34 | A path with a pending edit preview must remain pinned with its ancestors in every pane's projection — selected in the interaction's own pane — until that interaction ends. Commit/cancel/refusal, undo, redo and committed edits must then re-evaluate filtering so value matches and conditional visibility cannot strand an editor or pointer capture.                                                                                                                                                                   | full (0eea890c) | `PRT19`, `PRT25`; `SCV8` precedent; frame-model local reasoning            |
| PRT35 | Write-path tests must include policy bypass attempts, preview grouping, stale undo/redo, history eviction including the oversized-newest-entry rule, floating-equality totality, the one trusted seam's precondition, and the filter/edit interplay in `PRT34`.                                                                                                                                                                                                                                                             | partial         | `edit-commands.d` C12–C15; `PRN11`                                         |

The `partial` rows, precisely: `PRT13` ships bool/enum/numeric controls, the
`needs EDT` string marker and the read-only policy, but the script-free HTML
posture has no dedicated rendering test yet. `PRT24` deviates knowingly — the
walk and `resolve` are explicitly `@safe` rather than inferred, because the
erased seam's enumeration closes an attribute-inference cycle the compiler
cannot settle (documented at the declaration); the seam's capabilities are
`@safe` by contract either way. `PRT26`/`PRT28` lack an HTML-target test and
the CTFE half of the path differential. `PRT30`'s exact one-unit override uses
ASCII smart-case folding (not full Unicode simple folding) and the
over-capacity chunking is implemented but not yet exercised by a test.
`PRT35` is complete except the trusted-seam precondition test, which is
`P3`'s.

## Milestones

| Milestone | Independently shippable scope                                                                                                                                                                             | Status   | Requirements                                                                    |
| --------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------- | ------------------------------------------------------------------------------- |
| P0        | Read path on all four targets: type-only disclosure/search projections, ranked fuzzy filtering, metadata, paths, dynamic read seam, stable keys, caps, shared expandability and plain-text/HTML rendering | partial  | `PRT1`–`PRT12`, `PRT24`, `PRT26` (read model), `PRT27`–`PRT33`                  |
| P1        | Scalar write path on raylib/TUI/Android: bool/enum/numeric controls, generated refusal/validation, read-only policy, per-subject bounded undo/redo and keymap commands                                    | partial  | `PRT13`–`PRT21`, `PRT23`, `PRT25`, `PRT26` (edit transitions), `PRT34`, `PRT35` |
| P2        | String leaves by composition after the shared editor lands; property-level commit/history remains outside the editor's internal text operation log                                                        | deferred | `PRT13`; gated by `EDT`/`EDI`/`EDR`                                             |
| P3        | Structural editing only after reversible collection/variant edit cases and the trusted variant seam are separately designed, implemented and property-tested                                              | deferred | `PRT22`, `PRT24`, `PRT35`                                                       |

## Deferred by decision

- **Property grouping (`@Group`)** — the UDA exists in the research spike's
  vocabulary, but its semantics are undecided: synthetic header rows versus
  visual labels, ordering, path neutrality, and how headers behave under
  filtering. It ships only with a defined model; v1 presents siblings in
  declaration order, ungrouped.
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

No open question blocks P0 or P1. P2 is gated by the existing `EDT`/`EDI`/`EDR`
spec. P3
must answer the structural-payload and variant-migration questions above before
any structural control is enabled. Writable erased subjects likewise need a
separate typed edit capability; the v1 `propChildren` seam intentionally
promises inspection only.

## Module coverage

| Planned source file                                  | Requirements                                                        |
| ---------------------------------------------------- | ------------------------------------------------------------------- |
| `libs/ui/src/sparkles/ui/property_tree.d`            | `PRT1`–`PRT11`, `PRT14`–`PRT35`                                     |
| `libs/ui/src/sparkles/ui/property_tree_showif.d`     | `PRT10` (the condition resolves in the subject's module scope)      |
| `libs/ui/src/sparkles/ui/components/property_view.d` | `PRT12`–`PRT13`, `PRT21`, `PRT23`, `PRT25`–`PRT28`, `PRT32`–`PRT35` |
| `libs/ui/src/sparkles/ui/components/tree_widget.d`   | `PRT12`, `PRT33`                                                    |
| `libs/ui/src/sparkles/ui/components/tree_view.d`     | `PRT12`, `PRT29`, `PRT31`–`PRT32`                                   |
| `libs/ui/src/sparkles/ui/components/inspector.d`     | `PRT12`, `PRT26`, `PRT33`                                           |

## Relationship to existing specs

| Piece                                                              | Role                                                                                                                                                      |
| ------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [Widgets](./widgets.md) `WGT12`, `VMD1`–`VMD7`                     | the flat tree, external interaction state, lazy intent and shared interaction verbs                                                                       |
| [Hue tree view](../hue/tree-view.md) `TRV3`–`TRV5`, `TRV7`, `TRB3` | the shipped live-filter protocol, navigation, stable selection — and the script-free HTML tree doctrine (`TRB3`) behind `PRT33`                           |
| [Broot research](../../research/tui-libraries/broot.md)            | ranked tree-as-search-result, ancestor closure, honest pruning and cancellation                                                                           |
| [`sparkles:fuzzy`](../fuzzy/SPEC.md) §§2–6, §9                     | Unicode/smart-case admission, canonical highlight positions, Top-K and query generations                                                                  |
| [Inspector](./inspector.md) `INS5`, `INS8`                         | the plain-text surface and future async/remote-provider seam                                                                                              |
| [Containers](./containers.md) `SCV8`                               | precedent, not an inherited contract: a live pointer capture keeps being served across a view change — the shape `PRT34` restates for rebuild-during-edit |
| [State machines](./state-machines.md) `STM5`                       | disclosure as a value, including the `allOpen` polarity whose automatic walk needs caps                                                                   |
| [Editor](./editor.md) `EDT`, `EDI`, `EDR`                          | the deliberately unimplemented dependency for editable string leaves (`EDI3`/`EDI4` carry the raylib-IME and Android soft-keyboard risk)                  |
| [Keymap](./keymap.md) `KEY1`, `KEY11`                              | named undo/redo commands, host-selected bindings and exhaustive dispatch                                                                                  |
| [Principles](./principles.md) `PRN1`–`PRN12`                       | explicit relationships, Regular values, local transitions and one semantic definition                                                                     |
| [Property-tree research](../../research/property-tree/)            | corpus, comparison, vocabulary, baseline and executable design-spike evidence                                                                             |

→ [Overview](./index.md) · [Widgets](./widgets.md) · [Inspector](./inspector.md) · [Editor](./editor.md)
