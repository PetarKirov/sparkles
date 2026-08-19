# Derive-macro inspectors (Rust / egui)

Four crates that build the same component **without reflection of any kind**: a proc macro emits a trait impl per type, and the tree is the resulting call graph. The only compile-time-dispatch family in the corpus, and the closest structural peer to what D's `__traits` would produce.

|                        |                                                                                                                                                                                |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Language / toolkit** | Rust / [`egui`][egui] (immediate mode)                                                                                                                                         |
| **Subjects**           | [`egui-probe`][probe] `5ce68de1` (0.12.0) · [`egui_struct`][struct] `b9549e51` (0.4.2) · [`egui_inspect`][inspect] `f37e05e0` (0.1.3) · [`enum2egui`][e2e] `02fa8255` (0.34.1) |
| **Licenses**           | MIT / Apache-2.0 (per crate)                                                                                                                                                   |
| **Category**           | Compile-time dispatch, per-frame recursive descent                                                                                                                             |
| **Metadata source**    | **attributes on the type**, consumed by the proc macro                                                                                                                         |
| **Undo**               | none, in any of the four                                                                                                                                                       |

> [!NOTE]
> Read as source only. No Rust toolchain is available in this repository's dev shell, so
> nothing here was compiled or executed; claims are readings of the crates' traits, impls
> and generated code. The one claim that would most benefit from execution — that a
> self-referential type compiles — is marked **INFERENCE** below and derived from the shape
> of the generated code, not observed.

## Overview

### What they solve

The same job as [`bevy-inspector-egui`][bevy] — render a value as editable rows — with the
reflection removed. `egui_inspect` states the goal in the terms this survey cares about:

> to provide as much compile-time generated code as possible, avoiding conditional branches at runtime
>
> — [`egui_inspect/README.md:11`][inspectreadme]

Each crate is a **trait plus a derive macro**:

| Crate          | Trait                           | Shape                                                                                                      |
| -------------- | ------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| `egui-probe`   | `EguiProbe`                     | `probe(&mut self, ui, style)` + `iterate_inner(&mut self, ui, f)` ([`lib.rs:187`][probetrait])             |
| `egui_struct`  | `EguiStruct` / `EguiStructImut` | split into `has_primitive` / `show_primitive` / `has_childs` / `show_childs` ([`lib.rs:277`][structtrait]) |
| `egui_inspect` | `EguiInspect`                   | `inspect(&self, label, ui)` + `inspect_mut` ([`lib.rs:60`][inspecttrait])                                  |
| `enum2egui`    | `Gui`                           | `ui` / `ui_mut`, with the enum case generated per variant                                                  |

## Model & addressing

There is no model and — unlike [bevy][bevy] — not even a uniform value representation. The
tree exists only as the **call graph of generated impls**, and identity is whatever `egui`
derives from the call site (`ui.next_auto_id()` in `enum2egui`'s combo box,
[`enums.rs:48`][e2ecombo]).

`egui-probe` is the one with an explicit child protocol, and it is a **visitor, not a tree**:

```rust
fn iterate_inner(
    &mut self,
    ui: &mut egui::Ui,
    f: &mut dyn FnMut(&str, &mut egui::Ui, &mut dyn EguiProbe),
);
```

— [`lib.rs:196`][probeiter]

Children are handed to the caller one at a time as `(name, &mut dyn EguiProbe)`. That
type-erasure is load-bearing: the walk is dynamically dispatched from the second level down,
so a container's impl does not have to be monomorphised against every depth of nesting.

## Metadata

**Attributes on the type**, read by the proc macro — the exact analogue of D UDAs, and the
richest metadata vocabulary in the corpus relative to its cost:

| Crate          | Vocabulary (samples from the crates' own doc examples)                                                                                             |
| -------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| `egui-probe`   | `#[egui_probe(range = 22..=55)]`, `toggle_switch`, `multiline`, `name = "…"`, `as angle` (delegate to a named widget fn) ([`lib.rs:41`][probedoc]) |
| `egui_inspect` | `#[inspect(no_edit)]`, `hide`, `multiline`, `min`/`max`, `slider`, `name = "…"`, `custom_func_mut = "fn_name"` ([`lib.rs:10`][inspectdoc])         |
| `egui_struct`  | `#[eguis(…)]` config objects per type (`ConfigNum::Slider(min, max)`, …) ([`lib.rs:289`][structcfg])                                               |
| `enum2egui`    | `#[gui(skip)]`, custom per-variant labels ([`enums.rs:14`][e2eskip])                                                                               |

Two consequences the runtime-reflection subjects do not have:

- **A misspelled attribute is a build error**, not an ignored table entry.
- **A per-field escape hatch is a function name resolved at compile time**
  (`custom_func_mut`, `as angle`), so the "custom drawer" seam costs no registry and no
  dynamic lookup — but it also cannot be changed at runtime.

## Recursion

**The descent decision is a compile-time capability on the trait.** `egui_struct` states it as
an associated const plus a runtime refinement — `const SIMPLE: bool`
([`lib.rs:483`][structsimple]) says "this type is a leaf"; `has_childs(&self)`
([`lib.rs:485`][structhaschilds]) refines it per value. `egui-probe` says it by whether an impl
overrides `iterate_inner` at all — the default is an empty body ([`lib.rs:195`][probeiter]),
i.e. leaf.

That is _the same mechanism_ `sparkles:ui` already uses for its inspector adapters — capability
by presence, checked at compile time ([baseline][baseline]) — arrived at independently.

**Recursion terminates for a different reason than in D.** The generated impl for a type calls
the _trait method_ of its field types; the call is resolved per type, once, and recursion
happens at **run time** through those calls. So a self-referential type (`Box<Node>` inside
`Node`) needs one impl for `Node` and one blanket impl for `Box<T>`, and nothing expands
forever at compile time. Contrast [`reflect-descent.d`](./examples/reflect-descent.d): a D CTFE
walk that inlines the descent into one template instantiation per path **fails to build** on a
recursive type. The lesson is not "Rust is better here" — it is that **the failure mode follows
the erasure boundary, not the language**: `egui-probe`'s `&mut dyn EguiProbe` is exactly the
boundary that makes the recursion a runtime call. _(INFERENCE — the generated code was read,
not compiled.)_

Cycles, as in [bevy][bevy], cannot occur in the value graph because the walk holds `&mut`
throughout; none of the four carries a visited set, and none needs one.

## Editing & mutation

- **Dispatch** — trait resolution. There is no registry, so there is also no way to add a
  rendering for a type you do not own: Rust's orphan rule requires a newtype wrapper (which is
  what `egui-probe`'s `DeleteMe` wrapper does incidentally, [`vec.rs:29`][probedelete]). This
  is the one place where the compile-time family is strictly less capable than a registry
  ([WinForms][winforms] can attach a `TypeConverter` to a third-party type; these crates
  cannot).
- **Mutation** — direct, through `&mut`, immediately; the same posture as [bevy][bevy].
  `egui_struct` additionally carries `EguiStructClone`/`EguiStructEq` supertraits
  ([`lib.rs:216`][structclone]) so it can offer a **reset-to-previous** affordance — the
  closest anything in this family gets to undo.
- **Commit / validation / notification** — per keystroke; none; none. Nothing to notify,
  because the next frame re-reads the value.

## Type coverage

- **Collections** — `egui-probe` renders per-element rows through `iterate_inner` with
  positional labels (`[{idx}]`) and implements deletion by wrapping each element in a
  `DeleteMe` marker inside `retain_mut` ([`vec.rs:22`][probevec]) — element identity is the
  index, so removing one shifts the UI state of all later elements, exactly as in [bevy][bevy].
- **Sum types** — the sharpest contrast in this survey. `enum2egui`'s derive **generates the
  construction**:

  ```rust
  #field_name: Default::default(),
  …
  *self = #name::#variant_name { #default_fields };
  ```

  — [`enums.rs:96`][e2edefault]

  So "can I switch to this variant?" is answered by **the compiler**: if a field is not
  `Default`, the derive's own output fails to compile. [bevy][bevy] answers the same question
  at runtime by consulting the type registry and greying out the entries it cannot build, with
  a hover explaining which field types blocked it. Same requirement, opposite failure surface:
  a build error for the _library author's type_ versus a disabled menu entry for the _user_.

- **Optional / nullable** — `impl<T> EguiProbe for Option<T> where T: EguiProbe + Default`
  ([`option.rs:3`][probeoption]): the `None → Some` transition needs a default, so the bound is
  checked at compile time and a non-`Default` `T` simply has no `Option` impl. `egui_struct`
  renders `Option` as a checkbox primitive plus a `[0]` child when `Some`
  ([`lib.rs:430`][structoption]).
- **Opaque types** — a type without an impl is a compile error at the use site. There is no
  "unsupported value" row anywhere in the family, because such a value cannot reach the UI.

## Presentation & control

- **Grouping / ordering** — declaration order; `egui_struct` adds indent levels and a
  collapsing header per non-simple field.
- **Conditional visibility** — attribute-level only (`skip`, `hide`, `no_edit`); nothing
  value-dependent.
- **Multi-object editing, search/filter** — absent from all four.
- **Escape hatches** — per-field function (`custom_func_mut`, `as widget`) → hand-written impl
  for the type → newtype wrapper for a foreign type.
- **Virtualization** — none; immediate mode means only open regions execute, as in [bevy][bevy].

## Strengths

- No registry, no type ids, no runtime reflection: the whole mechanism is trait resolution.
- Attribute vocabulary is checked at compile time, and a per-field custom renderer is just a
  function name.
- The descent decision is a compile-time capability (`SIMPLE`, or overriding `iterate_inner`) —
  the same idiom `sparkles:ui` already uses.
- Erasing children behind `&mut dyn` keeps recursion a runtime concern, so recursive types are
  ordinary.
- Smallest dependency surface of anything surveyed: no serialization system, no ECS, no host.

## Weaknesses

- The orphan rule blocks third-party types without a wrapper — the registry-based subjects have
  no equivalent limitation.
- No undo, no multi-object editing, no validation, no filtering, no conditional visibility.
- Element identity is positional.
- Four crates solving the same problem four incompatible ways is itself a finding: no shared
  trait means an application cannot mix them.

## Key design decisions and trade-offs

| Decision                                      | Rationale                                              | Trade-off                                                                   |
| --------------------------------------------- | ------------------------------------------------------ | --------------------------------------------------------------------------- |
| Derive macro instead of reflection            | No runtime type information, no registry, no type ids  | Only works for types you can annotate; foreign types need a newtype         |
| Trait method per type, recursion at run time  | Recursive types compile; monomorphisation stays finite | The child walk is a virtual call, not an inlinable static descent           |
| `iterate_inner` visitor with `&mut dyn`       | The parent never materialises a child list             | No random access to a child; the walk is the only way in                    |
| Descent decision as an associated const       | Free, and checkable at compile time                    | Cannot vary per instance except through a second runtime predicate          |
| Variant switch generates `Default::default()` | Type-correct by construction, no registry              | A non-`Default` field breaks the derive at build time                       |
| No undo, no multi-object                      | Keeps the crates small and host-agnostic               | Confirms the corpus rule: undo belongs to a host, and none of these has one |

## Sources

Per-crate revisions are in the table above and in the umbrella's [revision ledger][ledger].

- [`egui-probe/src/lib.rs`][probetrait], [`option.rs`][probeoption], [`vec.rs`][probevec] — the trait, the visitor, `Option`'s `Default` bound, element deletion
- [`egui_struct/src/lib.rs`][structtrait] — `EguiStruct`/`EguiStructImut`, `SIMPLE`, `has_childs`, `Option` rendering, the clone/eq supertraits
- [`egui_inspect/egui_inspect/src/lib.rs`][inspecttrait] + [`README.md`][inspectreadme] — the minimal trait and the crate's stated compile-time goal
- [`enum2egui/enum2egui-derive/src/enums.rs`][e2edefault] — generated variant construction and the variant combo box

<!-- References -->

[egui]: https://github.com/emilk/egui
[probe]: https://github.com/zakarumych/egui-probe
[struct]: https://github.com/pingpongun/egui_struct
[inspect]: https://github.com/Meisterlama/egui_inspect
[e2e]: https://github.com/matthewjberger/enum2egui
[probetrait]: https://github.com/zakarumych/egui-probe/blob/5ce68de11b9dcee3ff4f3d2d5f8492a39e1a79b4/src/lib.rs#L187
[probeiter]: https://github.com/zakarumych/egui-probe/blob/5ce68de11b9dcee3ff4f3d2d5f8492a39e1a79b4/src/lib.rs#L196
[probedoc]: https://github.com/zakarumych/egui-probe/blob/5ce68de11b9dcee3ff4f3d2d5f8492a39e1a79b4/src/lib.rs#L41
[probeoption]: https://github.com/zakarumych/egui-probe/blob/5ce68de11b9dcee3ff4f3d2d5f8492a39e1a79b4/src/option.rs#L3
[probevec]: https://github.com/zakarumych/egui-probe/blob/5ce68de11b9dcee3ff4f3d2d5f8492a39e1a79b4/src/vec.rs#L22
[probedelete]: https://github.com/zakarumych/egui-probe/blob/5ce68de11b9dcee3ff4f3d2d5f8492a39e1a79b4/src/vec.rs#L29
[structtrait]: https://github.com/pingpongun/egui_struct/blob/b9549e51491e02a6c471e1cf7a6bd4b77bd87203/src/lib.rs#L277
[structcfg]: https://github.com/pingpongun/egui_struct/blob/b9549e51491e02a6c471e1cf7a6bd4b77bd87203/src/lib.rs#L289
[structclone]: https://github.com/pingpongun/egui_struct/blob/b9549e51491e02a6c471e1cf7a6bd4b77bd87203/src/lib.rs#L216
[structoption]: https://github.com/pingpongun/egui_struct/blob/b9549e51491e02a6c471e1cf7a6bd4b77bd87203/src/lib.rs#L430
[structsimple]: https://github.com/pingpongun/egui_struct/blob/b9549e51491e02a6c471e1cf7a6bd4b77bd87203/src/lib.rs#L483
[structhaschilds]: https://github.com/pingpongun/egui_struct/blob/b9549e51491e02a6c471e1cf7a6bd4b77bd87203/src/lib.rs#L485
[inspecttrait]: https://github.com/Meisterlama/egui_inspect/blob/f37e05e0e1c71108d4faa7de884fdaa5ad91debb/egui_inspect/src/lib.rs#L60
[inspectdoc]: https://github.com/Meisterlama/egui_inspect/blob/f37e05e0e1c71108d4faa7de884fdaa5ad91debb/egui_inspect/src/lib.rs#L10
[inspectreadme]: https://github.com/Meisterlama/egui_inspect/blob/f37e05e0e1c71108d4faa7de884fdaa5ad91debb/README.md#L11
[e2ecombo]: https://github.com/matthewjberger/enum2egui/blob/02fa82557acffeb1c08c661f84fea48b4b3acc26/enum2egui-derive/src/enums.rs#L48
[e2eskip]: https://github.com/matthewjberger/enum2egui/blob/02fa82557acffeb1c08c661f84fea48b4b3acc26/enum2egui-derive/src/enums.rs#L14
[e2edefault]: https://github.com/matthewjberger/enum2egui/blob/02fa82557acffeb1c08c661f84fea48b4b3acc26/enum2egui-derive/src/enums.rs#L96
[bevy]: ./bevy-inspector-egui.md
[winforms]: ./winforms-propertygrid.md
[baseline]: ./sparkles-baseline.md
[ledger]: ./index.md#revision-ledger
