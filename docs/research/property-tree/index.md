# Reflective property editors

A **property tree** is the component that takes a value of type `T`, produces one label/editor row per field, and lets a nested value be opened inline as a subtree. Five systems were read to answer one question — **what does a design commit to when it makes that tree?** — because `sparkles:ui` must answer it once, in integer cells, for a GPU window, a terminal grid, a script-free HTML page and an Android `NativeActivity`, and with compile-time reflection instead of the runtime reflection every surveyed subject relies on.

The corpus was picked so the answers would disagree. It spans a library with **no reflection at all** ([Qt's property browser][qt]), an editor panel whose tree **is** its widget hierarchy ([Godot][godot]), a grid that delegates the whole notion of nesting to the **model type's converter** ([WinForms][winforms]), a details panel built around a **property handle** that addresses N objects at once ([Unreal][unreal]), and an immediate-mode inspector that has **no model whatsoever** ([`bevy-inspector-egui`][bevy]). Where the field diverges, the divergence is reported as a fork rather than resolved by preference; the design itself is deliberately not proposed here.

## This survey answers ten questions

1. **[Where does the tree live?][q1]** — data model, widget hierarchy, or nowhere at all, and what each costs in rebuild, identity and testability.
2. **[What identifies a node, and how does it survive a rebuild?][q2]** — five different answers, from a raw pointer to a hashed structural path. Vocabulary in [`concepts.md`][concepts-addr].
3. **[Who decides that a value is a subtree?][q3]** — the converter, the discriminant, the manager, or the type — and why that choice determines the whole extension story.
4. **[How does anyone survive a cycle?][q4]** — the short answer is that nobody solves it; four different ways of arranging not to have one, and why a compile-time descent in D cannot use any of them ([`reflect-descent.d`](./examples/reflect-descent.d)).
5. **[When does typing become a value?][q5]** — commit points, the transient-vs-committed distinction, and the one subject that takes validation seriously.
6. **[How is a sum-typed field edited?][q6]** — variant pickers, constructability, and what happens to the subtree on a switch ([`sumtype-variants.d`](./examples/sumtype-variants.d)).
7. **[What does multi-object editing force into an architecture?][q7]** — cheap where the address is already an indirection, incomplete where it is not.
8. **[Which features actually require a retained tree?][q8]** — the cross-cutting frame-model question, answered as a table.
9. **[What of each design assumes pixels, hover, a modal window or a frame clock?][q9]** — the surface-independence question, for a toolkit whose targets have none of those in common.
10. **[What must a Sparkles design decide?][q10]** — eight explicit forks, each with what the options foreclose, against the [in-repo baseline][baseline].

**Last reviewed:** August 18, 2026

> [!IMPORTANT]
> Four subjects were read from source at a **pinned revision** recorded in the
> [revision ledger](#revision-ledger); every claim about them cites a file and line at
> that revision. The fifth ([Unreal][unreal]) could **not** be read from source — the
> repository requires an authenticated account — and is documented from archived API
> reference pages, marked as such on every page it appears. Statements that are analysis
> rather than observation are marked **INFERENCE**.

---

## Master catalog

| Subject                                | Ecosystem          | Tree lives in                          | Metadata                      | Multi-object                         | Undo                          | Deep-dive                              |
| -------------------------------------- | ------------------ | -------------------------------------- | ----------------------------- | ------------------------------------ | ----------------------------- | -------------------------------------- |
| **Qt Property Browser**                | C++ / Qt Widgets   | independent data model                 | none — caller builds it       | no                                   | no                            | [`qt-property-browser.md`][qt]         |
| **Godot `EditorInspector`**            | C++ / Godot editor | the widget tree                        | runtime `PropertyInfo` stream | intersection, no mixed marker        | yes (`EditorUndoRedoManager`) | [`godot-inspector.md`][godot]          |
| **WinForms `PropertyGrid`**            | C# / .NET          | retained entry model                   | runtime `TypeDescriptor`      | merged descriptors, blank when mixed | delegated to designer host    | [`winforms-propertygrid.md`][winforms] |
| **Unreal Details panel** _(docs only)_ | C++ / Slate        | node tree behind handles               | `UPROPERTY` + `meta=` map     | first-class, per-object values       | automatic via handle          | [`unreal-details-panel.md`][unreal]    |
| **`bevy-inspector-egui`**              | Rust / egui        | nowhere — a stack frame                | type registry of options      | `ui_for_reflect_many`                | no                            | [`bevy-inspector-egui.md`][bevy]       |
| **`sparkles:ui`** _(the baseline)_     | D                  | per-frame tree + explicit state values | UDAs, unused for this         | no                                   | no                            | [`sparkles-baseline.md`][baseline]     |

## Taxonomies

### By architectural family

| Family                             | Subjects                             | Commits a design to                                                                                         |
| ---------------------------------- | ------------------------------------ | ----------------------------------------------------------------------------------------------------------- |
| **Model-first**                    | [Qt][qt], [Unreal][unreal]           | a second structure and its lifetime, in exchange for several presentations and free multi-object addressing |
| **View-first with external state** | [Godot][godot], [WinForms][winforms] | naming every piece of state that must outlive a refresh — and losing whatever you failed to name            |
| **Function-first**                 | [bevy][bevy]                         | positional identity and a frame clock, in exchange for no rebuild, invalidation or notification at all      |

Detail and the placement of `sparkles:ui` in [`comparison.md` § families][families].

### By descent decision

| Owner of the decision            | Subject              | Consequence                                                                    |
| -------------------------------- | -------------------- | ------------------------------------------------------------------------------ |
| the model type's converter       | [WinForms][winforms] | any type becomes inspectable everywhere without touching the component         |
| the value's structural kind      | [bevy][bevy]         | uniform, with a leaf-editor registry consulted first so `Vec3` is not a struct |
| the value's runtime type + hint  | [Godot][godot]       | fully dynamic, re-derived every rebuild                                        |
| the property's manager           | [Qt][qt]             | total control, and a hand-written manager per composite type                   |
| the static type, at compile time | D / Sparkles         | a manifest constant — and a hard build error on a recursive type               |

### By materialisation

| Strategy                            | Subject                              | Failure mode it accepts                                |
| ----------------------------------- | ------------------------------------ | ------------------------------------------------------ |
| eager, whole subtree                | [Qt][qt]                             | a large collapsed model still costs its full item tree |
| lazy on expand                      | [WinForms][winforms], [Godot][godot] | unbounded manual descent into a self-referential value |
| per frame, only what is open        | [bevy][bevy]                         | everything visible is re-walked at frame rate          |
| per frame, windowed to the viewport | [`sparkles:ui`][baseline]            | (the current baseline: `flatten` + `viewSlice`)        |

---

## Revision ledger

| Subject               | Source                                                                                          | Revision                                                                                                                                                     | Date read  |
| --------------------- | ----------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------- |
| Qt Property Browser   | [`qtproject/qt-solutions`](https://github.com/qtproject/qt-solutions)                           | [`777e95ba69952f11eaec0adfb0cb987fabcdecb3`](https://github.com/qtproject/qt-solutions/tree/777e95ba69952f11eaec0adfb0cb987fabcdecb3)                        | 2026-08-18 |
| Godot                 | [`godotengine/godot`](https://github.com/godotengine/godot)                                     | [`944a3c6cbbbb88284feebcb0603464cb175fa18e`](https://github.com/godotengine/godot/tree/944a3c6cbbbb88284feebcb0603464cb175fa18e)                             | 2026-08-18 |
| WinForms              | [`dotnet/winforms`](https://github.com/dotnet/winforms)                                         | [`af0c793d58f30c92a3e42b5fabb8fee1ffe14796`](https://github.com/dotnet/winforms/tree/af0c793d58f30c92a3e42b5fabb8fee1ffe14796)                               | 2026-08-18 |
| `bevy-inspector-egui` | [`jakobhellermann/bevy-inspector-egui`](https://github.com/jakobhellermann/bevy-inspector-egui) | [`ac6729854a97a9abcd7657b29d7356bdea63c568`](https://github.com/jakobhellermann/bevy-inspector-egui/tree/ac6729854a97a9abcd7657b29d7356bdea63c568) (v0.37.0) | 2026-08-18 |
| Unreal Engine         | UE 5.1 API reference (**docs only**, source access gated)                                       | [archived 2023-02-04][ueiph] / 2023-04-01                                                                                                                    | 2026-08-18 |
| `sparkles:ui`         | this repository                                                                                 | working tree of `feat/ui/property-tree` (parent `77d0d547`)                                                                                                  | 2026-08-18 |

Compilers used for the runnable examples: **ldc2 1.41.0** (D 2.111) and **dmd 2.112.1**.

## Runnable examples

Three single-file `dub` programs, compiled and run by the repository's `ci` helper, each backing a claim the prose makes:

| Example                                                        | Backs                                                                                                                                        |
| -------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| [`examples/reflect-descent.d`](./examples/reflect-descent.d)   | compile-time descent yields a manifest row plan; a recursive type is a **build error** without a visited-type set                            |
| [`examples/sumtype-variants.d`](./examples/sumtype-variants.d) | variant switching in D: `.init` makes constructability nearly free, but `SumType.opAssign` is `@system` when another member has indirections |
| [`examples/uda-metadata.d`](./examples/uda-metadata.d)         | what a UDA channel answers at compile time, and why a value-dependent condition must be carried as data                                      |

## Suggested reading paths

- **"I want the map, not the details."** [`comparison.md` § matrix][matrix] → [§ families][families] → [§ surprises][surprises].
- **"I am about to write the spec."** [`sparkles-baseline.md`][baseline] (the delta table) → [`comparison.md` § decisions][decisions] → the three examples.
- **"I want to know how the field really does recursion and editing."** [`concepts.md`][concepts] → [WinForms][winforms] (converter-driven descent) → [bevy][bevy] (the immediate-mode contrast) → [Godot][godot] (the cost of a rebuild).
- **"I care about multi-object editing."** [Unreal][unreal] → [WinForms][winforms] § multi-object → [`comparison.md` § 7][q7].

## What this survey does not cover

Deliberate scope limits, stated so they are not mistaken for findings:

- **Tier-2 subjects were not deep-dived.** Xceed WPF Toolkit, ControlsFX `PropertySheet`, Unity's `SerializedProperty`/`PropertyDrawer`, the Delphi/Lazarus object inspector, NetBeans `PropertySheetView`, Chrome DevTools' object inspector, `react-json-tree`, `react-jsonschema-form` and `uniforms` were left unread once the four source-readable Tier-1 subjects already produced disagreeing answers on every spine dimension. Depth was preferred to breadth per the brief; **no claim in this tree rests on them**.
- **Schema-driven editors** (`react-jsonschema-form`, `uniforms`) are a distinct family — the tree comes from a document, not a type — and are not represented here at all.
- **Unreal was not read from source.** Laziness, cycle handling and optional/nullable treatment could not be determined and are recorded as unknown rather than guessed.
- **No behaviour was exercised at runtime** in any surveyed subject; every claim is a source or documentation reading. The only executed code in this tree is the D examples.

## Sources

Per-subject sources are listed in each deep-dive's `Sources` section; revisions are in the [ledger](#revision-ledger) above. In-repo context: [`docs/specs/ui/inspector.md`][inspector] (the inspector component this would feed), [`docs/specs/ui/editor.md`][editorspec] (the editable-text component, `not started`), and [`docs/research/anchored-overlays/`][overlays] for the surface-independence method this tree reuses.

<!-- References -->

[qt]: ./qt-property-browser.md
[godot]: ./godot-inspector.md
[winforms]: ./winforms-propertygrid.md
[unreal]: ./unreal-details-panel.md
[bevy]: ./bevy-inspector-egui.md
[baseline]: ./sparkles-baseline.md
[concepts]: ./concepts.md
[concepts-addr]: ./concepts.md#node-address
[matrix]: ./comparison.md#comparison-matrix
[families]: ./comparison.md#architectural-families
[decisions]: ./comparison.md#decisions-we-will-have-to-make
[surprises]: ./comparison.md#surprises
[q1]: ./comparison.md#1-where-the-tree-lives-and-what-it-costs
[q2]: ./comparison.md#1-where-the-tree-lives-and-what-it-costs
[q3]: ./comparison.md#3-descent-and-who-owns-it
[q4]: ./comparison.md#4-cycles
[q5]: ./comparison.md#5-editing-commitment-and-undo
[q6]: ./comparison.md#6-polymorphic-and-sum-typed-values
[q7]: ./comparison.md#7-multi-object-editing
[q8]: ./comparison.md#cross-cutting-the-frame-model
[q9]: ./comparison.md#cross-cutting-surface-independence
[q10]: ./comparison.md#decisions-we-will-have-to-make
[inspector]: ../../specs/ui/inspector.md
[editorspec]: ../../specs/ui/editor.md
[overlays]: ../anchored-overlays/index.md
[ueiph]: https://web.archive.org/web/20230204095057/https://docs.unrealengine.com/5.1/en-US/API/Editor/PropertyEditor/IPropertyHandle/
