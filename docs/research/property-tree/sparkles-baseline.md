# Sparkles baseline (`sparkles:ui`)

What the toolkit already answers on each spine dimension, read from the working tree, and the delta between that and what a reflective property editor needs.

|                    |                                                                                                               |
| ------------------ | ------------------------------------------------------------------------------------------------------------- |
| **Subject**        | `libs/ui` (`sparkles:ui`), `libs/ui-app`, with `libs/input`                                                   |
| **Read at**        | working tree of branch `feat/ui/property-tree`, parent commit `77d0d547`                                      |
| **Frame model**    | `view → layout → buildDisplayList → paint`, rebuilt per frame                                                 |
| **Retained state** | explicit value types the host owns (`TreeViewState`, `DisclosureState`, `LineEditState`, `ScrollbarState`, …) |
| **Reflection**     | compile-time only (`__traits`, `std.traits`, UDAs)                                                            |
| **Targets**        | raylib GPU, terminal cell grid, script-free HTML, Android                                                     |

## The frame model, stated precisely

`presentApp` rebuilds the widget tree every frame and lays it out from scratch:

```d
snap = FrameSnapshot.init;
snap.tree = app.view(h);
…
snap.frames = layout(snap.tree, Constraints(sz.width, sz.height));
buildDisplayListInto(snap.tree, snap.frames, …, h.ops());
```

— `libs/ui-app/src/sparkles/ui_app/run_app.d:160`

So on the [comparison][cmp]'s frame-model axis, Sparkles is **already on the immediate-mode side of the corpus** — closer to [`bevy-inspector-egui`][bevy] than to any of the retained subjects. It differs in one decisive respect: the toolkit does not have an id-keyed side table like egui's. Everything that must persist is a **named value the host stores**, which is why `sparkles:ui` has an explicit vocabulary of interaction-state structs instead of an implicit memory.

That is the single most important baseline fact for the design: **a property tree here cannot "just work" the way an egui inspector does, because there is no ambient place to put a row's expansion or a field's in-progress text.** Either the component names that state as a value, or it does not have it.

## Model & addressing

The tree component is already split three ways, and the split is documented as the design insight it came from:

> - **data** — `TreeData`, the flat arena. Owned by the adapter, rebuilt at will.
> - **interaction** (`TreeViewState`) — the opened set, the cursor, the viewport and both scrollbars, and the live filter's editor: every piece of state a tree pane keeps between frames, as **one value**.
> - **view** — `treeView` over the `viewSlice` window this state selects.
>
> — `libs/ui/src/sparkles/ui/components/tree_view.d:1`

- **`TreeData(T)`** (`components/tree_widget.d:40`) is a flat arena of `(value, parent, firstChild, nextSibling)` — indices, not pointers.
- **`TreeViewState(Key)`** (`components/tree_view.d:79`) is generic over the **adapter's node identity**, "so the opened set survives rebuilds" — the corpus's rebuild-survival problem, already solved once, by making identity the adapter's choice rather than the component's.
- **`DisclosureState(Key)`** (`state.d:1171`) stores expansion as `defaultOpen` plus a sorted exception set, so "expand all" is a polarity flip rather than an O(n) walk.
- **`TreeStep`** (`components/tree_view.d:62`) is how interaction reports structural invalidation: `rebuild` means "the opened set or filter changed — rebuild rows", and the adapter does it. The component never rebuilds anything itself.

Against the corpus, this is [Unreal's][unreal] "identity survives the rebuild" property obtained without a handle object: the key is a value the adapter mints.

## Metadata

Nothing exists for property metadata. The toolkit's DbI convention is capability-by-presence on the adapter's node type — the inspector view reads a node's `label`/`badge` only if they compile:

```d
static if (__traits(compiles, { const(char)[] s = v.label; }))
```

— `libs/ui/src/sparkles/ui/components/inspector.d:323`

The in-repo precedents for a **UDA metadata vocabulary** are `sparkles:core-cli`'s `@CliOption` and `sparkles:wired`'s compile-time-reflected wire format. [`uda-metadata.d`](./examples/uda-metadata.d) measures what that channel can answer: label/group/range/hidden are compile-time constants, but any condition over the _value_ has to be carried as data (a function pointer in the UDA) and evaluated per frame — which is the compile-time analogue of Godot's `_validate_property` rebuild.

## Recursion

`flatten` already materialises only what is open, and only in pre-order:

```d
if (data.hasChildren(at) && isOpen(at))
    walk(data.nodes[at].firstChild, depth + 1);
```

— `libs/ui/src/sparkles/ui/components/tree_widget.d:115`

So the visible-row discipline the corpus reaches for is in place. What is absent is everything upstream of it: nothing decides that a _type_ has children, nothing builds `TreeData` from a `T`, and nothing knows what a value's editor is.

The D-specific finding is that **the descent decision moves to compile time and takes the cycle problem with it**. [`reflect-descent.d`](./examples/reflect-descent.d) demonstrates a `static if (isAggregateType!Target)` walk that yields a manifest constant — and shows that the visited-_type_ set is not optional: without it, `struct Node { Node* parent; }` does not compile, with

```
Error: template instance ... recursive expansion exceeded allowed nesting limit
```

on both ldc2 1.41 (D 2.111) and dmd 2.112. Where [Godot][godot] and [WinForms][winforms] let a reader unfold a self-referential value forever, and [`bevy-inspector-egui`][bevy] gets cycle-freedom from Rust's aliasing rules, a compile-time descent in D gets a **hard build error** — a stronger guarantee, and a constraint the design cannot ignore. Note also what the example's output shows: a type-visited cut still expands the recursive type **once** (a full duplicate subtree under `parent.`) before cutting, so "cut on second occurrence" is a policy choice with a visible row-count cost.

## Editing & mutation

Nothing to build on yet, and the gap is bigger than it looks:

- **There is no text editor.** `LineEditState` (`state.d:990`) is a single-line, append/backspace machine used for the incremental-search field. The real editable-text component is specified but **not started** — `docs/specs/ui/editor.md` is entirely `not started`, and its scope note says hue's "only text input today is the single-line incremental-search field, hand-rolled per backend".
- **There is no command, transaction or undo vocabulary** anywhere in `sparkles:ui`.
- **There is no change-notification mechanism**, and per the frame model none is needed: the next frame re-reads the subject.
- **Mutation would be direct**, in-place, through whatever reference the view holds — the [`bevy-inspector-egui`][bevy] posture, with `@safe` consequences the corpus never had to think about. [`sumtype-variants.d`](./examples/sumtype-variants.d) measures one: Phobos' `SumType.opAssign` is `@system` whenever another member type has indirections, so a variant picker over an arbitrary `SumType` needs a `@trusted` seam whose precondition is that nothing holds a pointer into the old payload.

## Type coverage

| Kind              | Baseline                                                                                                                               |
| ----------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| Structs / classes | `TreeData` can express the shape; nothing produces it from a type                                                                      |
| Collections       | `sparkles:ui`'s table core exists (`components/table/`) with freeze panes and overflow policy, but no add/remove/reorder editing model |
| Sum types         | none; D offers `SumType`, class hierarchies and hand-rolled tagged unions, all with different variant-switch semantics                 |
| Optional          | none; `Nullable`, `Expected!(T, E)` and pointers are three different "unset"s                                                          |
| Opaque            | none                                                                                                                                   |

## Presentation & control

- **Grouping/ordering** — declaration order is what `__traits(allMembers)` gives; there is no category vocabulary.
- **Filter** — `TreeViewState` already owns a live filter whose every edit asks the adapter to rebuild, which is the same "filter changes the tree" model [Godot][godot] uses (and Godot additionally disables folding while filtering, `editor_inspector.cpp:4464`).
- **Virtualization** — `viewSlice` windows the visible rows and the display list carries only those; the table core does the same for columns. This is [WinForms][winforms]-grade row virtualization, already present.
- **Multi-object editing** — nothing.
- **Escape hatches** — the toolkit's convention is DbI capability-by-presence plus adapters, not a registry. There is no dynamic dispatch surface to register an editor into, and adding one would be the first of its kind in `sparkles:ui`.

## Delta table

Each row: the capability, where the corpus's answer comes from, and what Sparkles has today.

| Capability                            | Corpus answer                                                                                         | Sparkles today                                               | Delta                                                            |
| ------------------------------------- | ----------------------------------------------------------------------------------------------------- | ------------------------------------------------------------ | ---------------------------------------------------------------- |
| Presentation-free node model          | [Qt][qt] `QtProperty`; [Unreal][unreal] `FPropertyNode`                                               | `TreeData(T)` flat arena                                     | **have**                                                         |
| Node identity that survives a rebuild | [Unreal][unreal] handles; [WinForms][winforms] entry diffing; [Godot][godot] fold-state on the object | `TreeViewState(Key)` keyed by adapter identity               | **have** (identity is the adapter's to mint)                     |
| Expansion as a value                  | [Godot][godot] stores it on the edited object                                                         | `DisclosureState(Key)` with polarity + exceptions            | **have**, and better                                             |
| Visible-row materialisation           | all four retained subjects                                                                            | `flatten` descends only into open nodes; `viewSlice` windows | **have**                                                         |
| Row virtualization                    | [WinForms][winforms] `_visibleRows`                                                                   | `viewSlice` + display list                                   | **have**                                                         |
| Type → rows (reflection)              | runtime in all five subjects                                                                          | nothing                                                      | **missing** — and compile-time here, with a hard recursion limit |
| Descent decision                      | converter ([WinForms][winforms]) / discriminant ([bevy][bevy]) / hint ([Godot][godot])                | nothing                                                      | **missing**                                                      |
| Metadata channel                      | attributes / `PropertyInfo` / registry                                                                | UDAs exist as a mechanism (`@CliOption` precedent)           | **missing** as a vocabulary                                      |
| Leaf editor dispatch                  | factory ([Qt][qt]) / registry ([bevy][bevy]) / converter+editor ([WinForms][winforms])                | nothing; no dynamic dispatch surface in the toolkit          | **missing**                                                      |
| Text editing                          | every subject                                                                                         | `LineEditState` only; the editor component is `not started`  | **missing** — blocking for any string field                      |
| Transient vs committed edits          | [Godot][godot] `changing`; [Unreal][unreal] `SetValue` flags                                          | nothing                                                      | **missing**                                                      |
| Undo / transactions                   | [Godot][godot] `EditorUndoRedoManager`; [WinForms][winforms] designer transaction                     | nothing                                                      | **missing**                                                      |
| Validation + error display            | [WinForms][winforms] converter + modal dialog                                                         | nothing                                                      | **missing**                                                      |
| Collections editing                   | [Unreal][unreal] `AsArray`; [bevy][bevy] list ops; [Godot][godot] paged                               | table core, read-only                                        | **missing**                                                      |
| Variant / type picker                 | [bevy][bevy] constructable check; [Unreal][unreal] `GeneratePossibleValues`                           | nothing; `SumType` assignment is `@system`                   | **missing**, with a D-specific safety wrinkle                    |
| Multi-object editing                  | [WinForms][winforms] merged descriptors; [Unreal][unreal] per-object values                           | nothing                                                      | **missing**                                                      |
| Conditional visibility                | attributes ([WinForms][winforms]) / usage flags ([Godot][godot]) / restrictions ([Unreal][unreal])    | nothing                                                      | **missing**                                                      |

Two rows deserve emphasis because they are the ones that cross a target boundary rather than merely being unbuilt:

- **Text editing is the gating dependency.** Three of the four targets can host an editable field; the script-free HTML target is read-only by doctrine (`docs/specs/ui/editor.md`), so a property tree that assumes an editor everywhere cannot serve it. A read-only presentation is not a degraded mode there — it is the only mode.
- **Editor dispatch has no existing shape in this toolkit.** Every corpus answer is a runtime registry; `sparkles:ui`'s entire idiom is compile-time capability detection. Whatever the design picks will be either the toolkit's first registry or the corpus's first compile-time dispatch — see [`comparison.md` § decisions][decisions].

## Sources

In-tree, at the working tree of `feat/ui/property-tree` (parent `77d0d547`):

- `libs/ui/src/sparkles/ui/components/tree_view.d` — the three-layer split, `TreeViewState`, `TreeStep`
- `libs/ui/src/sparkles/ui/components/tree_widget.d` — `TreeData`, `flatten`, `treeView`
- `libs/ui/src/sparkles/ui/components/tree_model.d` — the pure flatten-to-rows function
- `libs/ui/src/sparkles/ui/components/inspector.d` — the adapter contract and capability-by-presence
- `libs/ui/src/sparkles/ui/state.d` — `DisclosureState`, `LineEditState`, `ScrollbarState`, `CaptureState`
- `libs/ui-app/src/sparkles/ui_app/run_app.d` — the per-frame `view → layout → display list` pipeline
- `docs/specs/ui/editor.md`, `docs/specs/ui/inspector.md` — the editable-text component (`not started`) and the inspector requirements
- Runnable: [`examples/reflect-descent.d`](./examples/reflect-descent.d), [`examples/sumtype-variants.d`](./examples/sumtype-variants.d), [`examples/uda-metadata.d`](./examples/uda-metadata.d)

<!-- References -->

[qt]: ./qt-property-browser.md
[godot]: ./godot-inspector.md
[winforms]: ./winforms-propertygrid.md
[bevy]: ./bevy-inspector-egui.md
[unreal]: ./unreal-details-panel.md
[cmp]: ./comparison.md
[decisions]: ./comparison.md#decisions-we-will-have-to-make
