# `bevy-inspector-egui` (Rust / egui)

The immediate-mode contrast: **no node model, no rows, no entries** — the tree is a recursive function over a reflected value, run every frame, with all persistent state living in the UI library's id-keyed side table.

|                        |                                                                     |
| ---------------------- | ------------------------------------------------------------------- |
| **Language / toolkit** | Rust / [`egui`][egui] (immediate mode), Bevy ECS                    |
| **License**            | MIT / Apache-2.0                                                    |
| **Repository**         | [`jakobhellermann/bevy-inspector-egui`][repo]                       |
| **Revision read**      | [`ac672985`][rev] (2026-06-20), crate version 0.37.0                |
| **Category**           | Immediate mode, per-frame recursive descent                         |
| **Metadata source**    | runtime — `bevy_reflect` `TypeInfo` + a `TypeRegistry` of type data |
| **Undo**               | none                                                                |

## Overview

### What it solves

The crate states its own decomposition:

> This crate contains
>
> - general purpose machinery for displaying `Reflect` values in `reflect_inspector`,
> - a way of associating arbitrary options with fields and enum variants in `inspector_options`
> - utility functions for displaying bevy resource, entities and assets in `bevy_inspector`
>
> — [`lib.rs:13`][libdoc]

The split matters for this survey: [`reflect_inspector`][mod] is a **toolkit-agnostic value inspector** that knows nothing about Bevy, and the Bevy-specific behaviour (following an asset handle, showing an entity) is injected as a _short-circuit function_.

## How it works

`InspectorUi` ([`reflect_inspector/mod.rs:175`][iui]) carries the type registry, a context, and three function pointers — `short_circuit`, `short_circuit_readonly`, `short_circuit_many`. The whole descent is one method:

```rust
match value.reflect_mut() {
    ReflectMut::Struct(value) => self.ui_for_struct(value, ui, id, options),
    ReflectMut::List(value) => self.ui_for_list(value, ui, id, options),
    ReflectMut::Enum(value) => self.ui_for_enum(value, ui, id, options),
    ReflectMut::Opaque(value) => { errors::reflect_value_no_impl(…); false }
    …
}
```

— [`reflect_inspector/mod.rs:260`][dispatch]

Each arm recurses into its fields, and every function returns `bool` — "did this subtree change?" — which is the entire change-propagation mechanism.

## Model & addressing

**There is no model.** Nothing is retained between frames except:

- the **id**: `egui::Id`, derived structurally as `id.with(i)` per field index ([`reflect_inspector/mod.rs:533`][idwith]) — a hashed path from the root id;
- whatever **egui** stores against that id: collapsing-header open state, drag state, text-edit cursor, and the crate's own scratch flags (`ui.data_mut(… get_temp_mut_or_default::<bool>(error_id))`, [`reflect_inspector/mod.rs:886`][temp]).

Consequences, in both directions:

- **Nothing has to survive a rebuild, because everything _is_ a rebuild.** No selection restoration, no focus restoration, no entry-diffing: the id is stable as long as the structural path is, so state re-attaches by construction.
- **Identity is positional.** A list element's id is its index ([`reflect_inspector/mod.rs:860`][listid]), so removing element 0 shifts every later element's expansion, drag and text state up by one. This is the immediate-mode analogue of Godot's paging problem, and it is not addressed in the surveyed code. _(INFERENCE from the id derivation; not exercised at runtime.)_

## Metadata

Two channels, both runtime:

- **`TypeInfo`** — field names, and (behind the `documentation` feature) doc comments, shown as hover text ([`reflect_inspector/mod.rs:527`][docs]).
- **`InspectorOptions`** in the `TypeRegistry` — arbitrary per-field/per-variant option objects, fetched by type id and threaded down the recursion as `&dyn Any`:

  ```rust
  if options.is::<()>() && let Some(data) = value.try_as_reflect().and_then(|val| {
      self.type_registry.get_type_data::<ReflectInspectorOptions>(val.type_id()) })
  ```

  — [`reflect_inspector/mod.rs:238`][optlookup]

  The leaf impls interpret them (`NumberOptions` for `f32`, and so on), so the option vocabulary is open-ended rather than a fixed attribute set. The `#[derive(InspectorOptions)]` macro in `bevy-inspector-egui-derive` is the authoring surface.

## Recursion

**The descent decision is the `ReflectRef`/`ReflectMut` discriminant** — a structural kind, not a type registry lookup. Ordering of the three dispatch layers is the design's real content ([`reflect_inspector/mod.rs:246`][order]):

1. a registered **`InspectorEguiImpl`** for the concrete type (the leaf-editor registry) — checked first, so `Vec3` renders as three drag values rather than a struct;
2. the **short-circuit** function (Bevy's: follow a `Handle<T>` into its asset, render an `Entity`, …);
3. the structural fallback above.

Materialisation is neither lazy nor eager in the usual sense: the recursion runs every frame for everything **inside an open region**, because a closed `CollapsingHeader` does not execute its body. Cost is therefore proportional to what is visible, with no retained cost at all — the one architecture in the corpus where a thousand-row object costs nothing when collapsed and nothing when closed again.

### Cycles

**Structurally impossible for the value graph, and delegated for the reference graph.** The recursion holds `&mut dyn PartialReflect` down the whole path; Rust's aliasing rules mean a value cannot contain a mutable path back to itself, so `ui_for_struct` cannot re-enter the same value. Anything that _would_ be a cycle — an entity referring to another entity, an asset handle pointing at an asset that holds the same handle — is not a value edge at all; it is resolved by the short-circuit against `RestrictedWorldView`, which is explicitly a "view into the world which may only access certain resources and components" ([`restricted_world_view.rs:27`][rwv]) and hands out disjoint borrows.

This is the corpus's most instructive cycle answer: **cycle-freedom was bought by the ownership model, not by a visited set** — and the price is that every cross-object reference has to leave the reflection walk and go through a mediated world view.

## Editing & mutation

- **Dispatch** — `InspectorEguiImpl` registry (per concrete type) → short-circuit → structural fallback. The fallback for an unrepresentable leaf is an inline error message naming the missing impl (`ReflectMut::Opaque` → `errors::reflect_value_no_impl`, [`reflect_inspector/mod.rs:269`][opaque]).
- **Mutation** — direct, through `&mut`, in place, immediately. There is no command, no transaction and **no undo**; the return value `bool` only tells the caller something changed (Bevy uses it to mark change detection).
- **Commit semantics** — whatever the egui widget does: a `DragValue` writes on every pixel of a drag, a text field on every keystroke. There is no transient/committed distinction anywhere in the crate.
- **Change notification** — moot. The next frame re-reads the value, so an external write appears immediately with no plumbing at all. This is the single largest simplification the immediate-mode model buys.
- **Validation** — none; a leaf impl may clamp, and structural failures render as error text.

## Type coverage

- **Collections** — `ui_for_list` renders per-element controls (add, remove, move up, move down — [`reflect_inspector/mod.rs:457`][listctrl]) and applies the resulting `ListOp`. Adding an element needs a default value for the element type; if the registry has none, the crate stashes an error flag in egui temp data and renders `no_default_value` ([`reflect_inspector/mod.rs:886`][temp]).
- **Polymorphic / sum-typed values** — the most thorough treatment in the corpus. `ui_for_enum` ([`reflect_inspector/mod.rs:1470`][enum]) draws a `ComboBox` of variant names; each entry is **enabled only if the variant is constructable**, where constructable means every field type has `ReflectDefault` in the registry:

  ```rust
  let type_id_is_constructable = |type_id: TypeId| {
      type_registry.get_type_data::<ReflectDefault>(type_id).is_some()
  };
  ```

  — [`reflect_inspector/mod.rs:1889`][constructable]

  A disabled entry explains itself on hover, listing the field types that blocked it. Choosing a variant builds a `DynamicEnum` from those defaults and `apply`s it ([`reflect_inspector/mod.rs:1786`][construct]) — so a switch **discards the old variant's data entirely**, and the subtree that follows is the new variant's fields.

- **Optional / nullable** — `Option<T>` is a Rust enum, so it goes through exactly the same variant picker; "unset" is `None` and the transition is a variant switch with a constructed default.
- **Opaque types** — a leaf with neither an `InspectorEguiImpl` nor structural reflection renders an error line naming the type and the reason (`TypeDataError::NotFullyReflected` and friends).
- **Multi-object editing** — supported through a parallel `*_many` API: `ui_for_reflect_many` takes `values: &mut [&mut dyn PartialReflect]` plus a `ProjectorReflect` closure ([`reflect_inspector/mod.rs:344`][many]), and `ui_for_enum_many` first checks whether every value is on the same variant before descending.

## Presentation & control

- **Grouping / ordering** — declaration order; a `Grid` per struct. No categories.
- **Conditional visibility** — none built in; a caller composes its own `ui_for_*` calls.
- **Search / filter** — none in `reflect_inspector`; the world inspector filters entities, not fields.
- **Escape hatches**, in the order they are consulted: register an `InspectorEguiImpl` for a type → supply a short-circuit for a whole family of values → call the `ui_for_*` functions directly and write the layout yourself. There is no "customize this one field of this one type" seam short of the type-level impl.
- **Virtualization** — unnecessary in the usual sense: closed regions execute no code. But every visible row is laid out from scratch each frame, so a very large open list is re-walked at frame rate.

## Strengths

- The smallest architecture in the corpus by a wide margin: one recursive function, one id, one `bool`.
- No rebuild problem, no stale model, no change-notification plumbing — external mutation is free.
- Cycles are excluded by the borrow checker rather than by a runtime guard.
- The variant picker is honest about what it cannot construct, and says why.
- The short-circuit hook cleanly separates "how do I render a value" from "how do I reach a value that lives elsewhere".

## Weaknesses

- No undo, no transactions, no transient edits — every keystroke is a committed mutation.
- Node identity is positional, so mutating a collection shuffles per-element UI state.
- No conditional visibility, categories, filtering or per-field customization seam.
- Requires `&mut` access to the whole value for the duration of the frame, which is why Bevy needs `RestrictedWorldView` machinery to hand out disjoint borrows.
- Everything visible is re-walked every frame; there is no way to cache a subtree's layout.

## Key design decisions and trade-offs

| Decision                                        | Rationale                                              | Trade-off                                                                 |
| ----------------------------------------------- | ------------------------------------------------------ | ------------------------------------------------------------------------- |
| No node model; recurse per frame                | Nothing to invalidate, nothing to synchronise          | No place to hang per-node state that is not id-keyed                      |
| `egui::Id` derived from the structural path     | State re-attaches automatically across frames          | Positional identity: collection edits shift state                         |
| Leaf-editor registry consulted before structure | `Vec3`, `Color`, `Handle` render as units, not structs | The registry is global; two crates cannot disagree per site               |
| Short-circuit function pointer                  | Keeps `reflect_inspector` free of Bevy                 | Cross-object navigation is invisible to the descent's own rules           |
| Variant switch = construct a default            | Type-correct by construction                           | Old variant's data is discarded; unconstructable variants are unofferable |
| `&mut` all the way down                         | No copies, immediate writes, no notification           | Cannot show two views of the same value simultaneously                    |

## Sources

All line numbers are at [`ac672985`][rev].

- [`crates/bevy-inspector-egui/src/reflect_inspector/mod.rs`][mod] — `InspectorUi`, dispatch order, struct/list/map/enum descent, variant construction
- [`crates/bevy-inspector-egui/src/lib.rs`][libdoc] — the crate's own decomposition
- [`crates/bevy-inspector-egui/src/restricted_world_view.rs`][rwv] — the mediated world access the short-circuit uses
- [`crates/bevy-inspector-egui/src/inspector_options/`][opts] — the options vocabulary threaded through the recursion

<!-- References -->

[repo]: https://github.com/jakobhellermann/bevy-inspector-egui
[rev]: https://github.com/jakobhellermann/bevy-inspector-egui/tree/ac6729854a97a9abcd7657b29d7356bdea63c568
[mod]: https://github.com/jakobhellermann/bevy-inspector-egui/blob/ac6729854a97a9abcd7657b29d7356bdea63c568/crates/bevy-inspector-egui/src/reflect_inspector/mod.rs
[iui]: https://github.com/jakobhellermann/bevy-inspector-egui/blob/ac6729854a97a9abcd7657b29d7356bdea63c568/crates/bevy-inspector-egui/src/reflect_inspector/mod.rs#L175
[dispatch]: https://github.com/jakobhellermann/bevy-inspector-egui/blob/ac6729854a97a9abcd7657b29d7356bdea63c568/crates/bevy-inspector-egui/src/reflect_inspector/mod.rs#L260
[order]: https://github.com/jakobhellermann/bevy-inspector-egui/blob/ac6729854a97a9abcd7657b29d7356bdea63c568/crates/bevy-inspector-egui/src/reflect_inspector/mod.rs#L246
[optlookup]: https://github.com/jakobhellermann/bevy-inspector-egui/blob/ac6729854a97a9abcd7657b29d7356bdea63c568/crates/bevy-inspector-egui/src/reflect_inspector/mod.rs#L238
[opaque]: https://github.com/jakobhellermann/bevy-inspector-egui/blob/ac6729854a97a9abcd7657b29d7356bdea63c568/crates/bevy-inspector-egui/src/reflect_inspector/mod.rs#L269
[idwith]: https://github.com/jakobhellermann/bevy-inspector-egui/blob/ac6729854a97a9abcd7657b29d7356bdea63c568/crates/bevy-inspector-egui/src/reflect_inspector/mod.rs#L533
[docs]: https://github.com/jakobhellermann/bevy-inspector-egui/blob/ac6729854a97a9abcd7657b29d7356bdea63c568/crates/bevy-inspector-egui/src/reflect_inspector/mod.rs#L527
[listid]: https://github.com/jakobhellermann/bevy-inspector-egui/blob/ac6729854a97a9abcd7657b29d7356bdea63c568/crates/bevy-inspector-egui/src/reflect_inspector/mod.rs#L860
[listctrl]: https://github.com/jakobhellermann/bevy-inspector-egui/blob/ac6729854a97a9abcd7657b29d7356bdea63c568/crates/bevy-inspector-egui/src/reflect_inspector/mod.rs#L457
[temp]: https://github.com/jakobhellermann/bevy-inspector-egui/blob/ac6729854a97a9abcd7657b29d7356bdea63c568/crates/bevy-inspector-egui/src/reflect_inspector/mod.rs#L886
[enum]: https://github.com/jakobhellermann/bevy-inspector-egui/blob/ac6729854a97a9abcd7657b29d7356bdea63c568/crates/bevy-inspector-egui/src/reflect_inspector/mod.rs#L1470
[construct]: https://github.com/jakobhellermann/bevy-inspector-egui/blob/ac6729854a97a9abcd7657b29d7356bdea63c568/crates/bevy-inspector-egui/src/reflect_inspector/mod.rs#L1786
[constructable]: https://github.com/jakobhellermann/bevy-inspector-egui/blob/ac6729854a97a9abcd7657b29d7356bdea63c568/crates/bevy-inspector-egui/src/reflect_inspector/mod.rs#L1889
[many]: https://github.com/jakobhellermann/bevy-inspector-egui/blob/ac6729854a97a9abcd7657b29d7356bdea63c568/crates/bevy-inspector-egui/src/reflect_inspector/mod.rs#L344
[libdoc]: https://github.com/jakobhellermann/bevy-inspector-egui/blob/ac6729854a97a9abcd7657b29d7356bdea63c568/crates/bevy-inspector-egui/src/lib.rs#L13
[rwv]: https://github.com/jakobhellermann/bevy-inspector-egui/blob/ac6729854a97a9abcd7657b29d7356bdea63c568/crates/bevy-inspector-egui/src/restricted_world_view.rs#L27
[opts]: https://github.com/jakobhellermann/bevy-inspector-egui/blob/ac6729854a97a9abcd7657b29d7356bdea63c568/crates/bevy-inspector-egui/src/inspector_options/mod.rs
[egui]: https://github.com/emilk/egui
