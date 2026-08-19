# Reflective property editors

A **property tree** is the component that takes a value of type `T`, produces one label/editor row per field, and lets a nested value be opened inline as a subtree. **Ten systems** were read to answer one question — **what does a design commit to when it makes that tree?** — because `sparkles:ui` must answer it once, in integer cells, for a GPU window, a terminal grid, a script-free HTML page and an Android `NativeActivity`, and with compile-time reflection instead of the runtime reflection most surveyed subjects rely on.

The corpus was picked so the answers would disagree, in two passes. **Tier 1** took the four closest analogues that could be read from source plus the field's reference design: a library with **no reflection at all** ([Qt's property browser][qt]), an editor panel whose tree **is** its widget hierarchy ([Godot][godot]), a grid that delegates nesting to the **model type's converter** ([WinForms][winforms]), a details panel built around a **property handle** ([Unreal][unreal], documentation only), and an immediate-mode inspector with **no model whatsoever** ([`bevy-inspector-egui`][bevy]).

**Tier 2** was then chosen against the gaps that pass exposed rather than from the original shortlist: [Unity][unity] to get the handle and multi-object axes from **source** where Unreal could not be read; the Rust **[derive-macro crates][derive]**, the only compile-time-dispatch family and the closest peer to a D `__traits` descent; [VS Code's settings editor][vscode], because every Tier-1 subject was a developer inspector and none was an **end-user settings** surface; [`react-jsonschema-form`][rjsf] for the **schema-driven** family; and the [DevTools object inspector][devtools] for a **live, foreign, cyclic** graph. Four Tier-1 conclusions did not survive that second pass; they are listed as [retractions][retractions] rather than quietly amended.

## This survey answers twelve questions

1. **[Where does the tree live?][q1]** — data model, widget hierarchy, serialized mirror, another process, or nowhere at all.
2. **[What identifies a node, and how does it survive a rebuild?][q2]** — seven answers, from a raw pointer to a remote lease. Vocabulary in [`concepts.md`][concepts-addr].
3. **[Who decides that a value is a subtree?][q3]** — converter, discriminant, manager, trait const, schema `type` — or a refusal to descend at all.
4. **[How does anyone survive a cycle?][q4]** — and the rule Tier 2 supplied: **guard the walk that is neither user- nor data-driven**.
5. **[When does typing become a value?][q5]** — commit points, transient vs committed, and where validation is shown.
6. **[How is a sum-typed field edited?][q6]** — pickers, constructability, and the one subject that **migrates data** across a switch.
7. **[What does multi-object editing force into an architecture?][q7]** — four positions, from designed-in to incomplete.
8. **[Which features actually require a retained tree?][q8]** — the frame-model question, as a table.
9. **[What does a design assume about its surface?][q9]** — pixels, hover, modals, a frame clock, a live runtime.
10. **[What must a Sparkles design decide?][q10]** — eight forks, each re-run against the Tier-2 evidence.
11. **[What did Tier 2 retract?][retractions]** — four Tier-1 claims withdrawn, two narrowed, two upheld.
12. **[How should a property tree behave at scale?][q11]** — virtualization, pagination, fetch policy, and recursive bucketing.

**Last reviewed:** August 19, 2026

> [!IMPORTANT]
> Nine subjects were read from source at a **pinned revision** recorded in the
> [revision ledger](#revision-ledger); every claim about them cites a file and line at that
> revision. [Unreal][unreal] could **not** be read from source — the repository requires an
> authenticated account — and is documented from archived API reference pages, marked as such
> on every page it appears. [Unity][unity] is source-readable only at its **managed** layer;
> native internals are marked **INFERENCE**. Statements that are analysis rather than
> observation are marked **INFERENCE** throughout.

---

## Master catalog

Tier-2 subjects are marked ★.

| Subject                                | Ecosystem             | Tree lives in                          | Metadata                        | Multi-object                                           | Undo                          | Deep-dive                                  |
| -------------------------------------- | --------------------- | -------------------------------------- | ------------------------------- | ------------------------------------------------------ | ----------------------------- | ------------------------------------------ |
| **Qt Property Browser**                | C++ / Qt Widgets      | independent data model                 | none — caller builds it         | no                                                     | no                            | [`qt-property-browser.md`][qt]             |
| **Godot `EditorInspector`**            | C++ / Godot editor    | the widget tree                        | runtime `PropertyInfo` stream   | intersection, no mixed marker                          | yes (`EditorUndoRedoManager`) | [`godot-inspector.md`][godot]              |
| **WinForms `PropertyGrid`**            | C# / .NET             | retained entry model                   | runtime `TypeDescriptor`        | merged descriptors, blank when mixed                   | delegated to designer host    | [`winforms-propertygrid.md`][winforms]     |
| **Unreal Details panel** _(docs only)_ | C++ / Slate           | node tree behind handles               | `UPROPERTY` + `meta=` map       | first-class, per-object values                         | automatic via handle          | [`unreal-details-panel.md`][unreal]        |
| **`bevy-inspector-egui`**              | Rust / egui           | nowhere — a stack frame                | type registry of options        | `ui_for_reflect_many`                                  | no                            | [`bevy-inspector-egui.md`][bevy]           |
| ★ **Unity `SerializedProperty`**       | C# / Unity Editor     | serialized mirror + cursor             | serialization + attributes      | `hasMultipleDifferentValues`, ambient `showMixedValue` | on `ApplyModifiedProperties`  | [`unity-serializedproperty.md`][unity]     |
| ★ **Derive-macro inspectors**          | Rust / egui           | the generated call graph               | **attributes, at compile time** | no                                                     | no                            | [`derive-macro-inspectors.md`][derive]     |
| ★ **VS Code settings editor**          | TypeScript / DOM      | settings tree model                    | JSON-schema contributions       | scope selector instead                                 | no (the text editor's)        | [`vscode-settings-ui.md`][vscode]          |
| ★ **`react-jsonschema-form`**          | TypeScript / React    | nowhere — per render                   | a schema + a `uiSchema`         | no                                                     | host's                        | [`react-jsonschema-form.md`][rjsf]         |
| ★ **DevTools object inspector**        | TypeScript / DevTools | the other process                      | CDP descriptors                 | no                                                     | no                            | [`devtools-object-inspector.md`][devtools] |
| **`sparkles:ui`** _(the baseline)_     | D                     | per-frame tree + explicit state values | UDAs, unused for this           | no                                                     | no                            | [`sparkles-baseline.md`][baseline]         |

## Taxonomies

### By architectural family

| Family                                  | Subjects                                              | Commits a design to                                                                                                                           |
| --------------------------------------- | ----------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| **Model-first**                         | [Qt][qt], [Unreal][unreal], ★[VS Code][vscode]        | a second structure and its lifetime — in exchange for several presentations, model-level search, and multi-object addressing you already have |
| **View-first with external state**      | [Godot][godot], [WinForms][winforms], ★[Unity][unity] | naming every piece of state that must outlive a refresh — and losing whatever you failed to name                                              |
| **Function-first**                      | [bevy][bevy], ★[derive crates][derive], ★[rjsf][rjsf] | positional identity (unless you mint keys) and a frame clock — in exchange for no rebuild, invalidation or notification                       |
| ★ **Handle-first over a foreign graph** | ★[DevTools][devtools]                                 | asynchrony, staleness and never knowing the row count — in exchange for inspecting something unbounded and live                               |

Detail, and the placement of `sparkles:ui`, in [`comparison.md` § families][families].

### By descent decision

| Owner of the decision                | Subject                  | Consequence                                                            |
| ------------------------------------ | ------------------------ | ---------------------------------------------------------------------- |
| the model type's converter           | [WinForms][winforms]     | any type becomes inspectable everywhere without touching the component |
| the value's structural kind          | [bevy][bevy]             | uniform, with a leaf-editor registry consulted first                   |
| the value's runtime type + hint      | [Godot][godot]           | fully dynamic, re-derived every rebuild                                |
| the property's manager               | [Qt][qt]                 | total control, and a hand-written manager per composite type           |
| ★ a trait const / overridden visitor | ★[derive crates][derive] | compile-time, no registry — and the orphan rule blocks foreign types   |
| ★ the schema's `type`                | ★[rjsf][rjsf]            | conditions and cycles are expressible _in the data_                    |
| ★ nobody — the GUI declines          | ★[VS Code][vscode]       | `Complex` values are handed to the text editor over the real format    |
| the static type, at compile time     | D / Sparkles             | a manifest constant — and a hard build error on a recursive type       |

### By how the walk is bounded

| Strategy                                       | Subject                                               | What it accepts                                                        |
| ---------------------------------------------- | ----------------------------------------------------- | ---------------------------------------------------------------------- |
| eager, whole subtree                           | [Qt][qt]                                              | a large collapsed model still costs its full item tree                 |
| lazy on expand                                 | [WinForms][winforms], [Godot][godot], ★[Unity][unity] | unbounded manual descent into a self-referential value                 |
| per frame, only what is open                   | [bevy][bevy], ★[derive crates][derive], ★[rjsf][rjsf] | everything visible is re-walked at frame rate                          |
| ★ visited set — but only in automatic walks    | ★[Unity][unity], ★[rjsf][rjsf]                        | the guard's cost, paid exactly where a human is not driving            |
| ★ fetch policy (200 rows, 100-element buckets) | ★[DevTools][devtools]                                 | the reader sees a truncated truth and must ask for more                |
| ★ refuse to descend                            | ★[VS Code][vscode]                                    | a visible capability cliff, with an escape to the serialization format |
| per frame, windowed to the viewport            | [`sparkles:ui`][baseline]                             | (the current baseline: `flatten` + `viewSlice`)                        |

---

## Revision ledger

| Subject                   | Source                                                                                                                  | Revision                                                                                                                                                        | Date read  |
| ------------------------- | ----------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------- |
| Qt Property Browser       | [`qtproject/qt-solutions`](https://github.com/qtproject/qt-solutions)                                                   | [`777e95ba69952f11eaec0adfb0cb987fabcdecb3`](https://github.com/qtproject/qt-solutions/tree/777e95ba69952f11eaec0adfb0cb987fabcdecb3)                           | 2026-08-18 |
| Godot                     | [`godotengine/godot`](https://github.com/godotengine/godot)                                                             | [`944a3c6cbbbb88284feebcb0603464cb175fa18e`](https://github.com/godotengine/godot/tree/944a3c6cbbbb88284feebcb0603464cb175fa18e)                                | 2026-08-18 |
| WinForms                  | [`dotnet/winforms`](https://github.com/dotnet/winforms)                                                                 | [`af0c793d58f30c92a3e42b5fabb8fee1ffe14796`](https://github.com/dotnet/winforms/tree/af0c793d58f30c92a3e42b5fabb8fee1ffe14796)                                  | 2026-08-18 |
| `bevy-inspector-egui`     | [`jakobhellermann/bevy-inspector-egui`](https://github.com/jakobhellermann/bevy-inspector-egui)                         | [`ac6729854a97a9abcd7657b29d7356bdea63c568`](https://github.com/jakobhellermann/bevy-inspector-egui/tree/ac6729854a97a9abcd7657b29d7356bdea63c568) (v0.37.0)    | 2026-08-18 |
| Unreal Engine             | UE 5.1 API reference (**docs only**, source access gated)                                                               | [archived 2023-02-04][ueiph] / 2023-04-01                                                                                                                       | 2026-08-18 |
| ★ Unity                   | [`Unity-Technologies/UnityCsReference`](https://github.com/Unity-Technologies/UnityCsReference) (**C# reference only**) | [`225b0fbdb57cc17d094e8056b71f8314aba56f73`](https://github.com/Unity-Technologies/UnityCsReference/tree/225b0fbdb57cc17d094e8056b71f8314aba56f73) (6000.7.0a4) | 2026-08-19 |
| ★ `egui-probe`            | [`zakarumych/egui-probe`](https://github.com/zakarumych/egui-probe)                                                     | [`5ce68de11b9dcee3ff4f3d2d5f8492a39e1a79b4`](https://github.com/zakarumych/egui-probe/tree/5ce68de11b9dcee3ff4f3d2d5f8492a39e1a79b4) (0.12.0)                   | 2026-08-19 |
| ★ `egui_struct`           | [`pingpongun/egui_struct`](https://github.com/pingpongun/egui_struct)                                                   | [`b9549e51491e02a6c471e1cf7a6bd4b77bd87203`](https://github.com/pingpongun/egui_struct/tree/b9549e51491e02a6c471e1cf7a6bd4b77bd87203) (0.4.2)                   | 2026-08-19 |
| ★ `egui_inspect`          | [`Meisterlama/egui_inspect`](https://github.com/Meisterlama/egui_inspect)                                               | [`f37e05e0e1c71108d4faa7de884fdaa5ad91debb`](https://github.com/Meisterlama/egui_inspect/tree/f37e05e0e1c71108d4faa7de884fdaa5ad91debb) (0.1.3)                 | 2026-08-19 |
| ★ `enum2egui`             | [`matthewjberger/enum2egui`](https://github.com/matthewjberger/enum2egui)                                               | [`02fa82557acffeb1c08c661f84fea48b4b3acc26`](https://github.com/matthewjberger/enum2egui/tree/02fa82557acffeb1c08c661f84fea48b4b3acc26) (0.34.1)                | 2026-08-19 |
| ★ VS Code                 | [`microsoft/vscode`](https://github.com/microsoft/vscode)                                                               | [`474a349ad5b745e512ef86b864d1c74f7264dd7a`](https://github.com/microsoft/vscode/tree/474a349ad5b745e512ef86b864d1c74f7264dd7a)                                 | 2026-08-19 |
| ★ `react-jsonschema-form` | [`rjsf-team/react-jsonschema-form`](https://github.com/rjsf-team/react-jsonschema-form)                                 | [`c8723f5f39d030776909667e74d217572757483c`](https://github.com/rjsf-team/react-jsonschema-form/tree/c8723f5f39d030776909667e74d217572757483c)                  | 2026-08-19 |
| ★ DevTools front end      | [`ChromeDevTools/devtools-frontend`](https://github.com/ChromeDevTools/devtools-frontend)                               | [`788f6469296bf2420bd95bb6d73d28a21439f345`](https://github.com/ChromeDevTools/devtools-frontend/tree/788f6469296bf2420bd95bb6d73d28a21439f345)                 | 2026-08-19 |
| `sparkles:ui`             | this repository                                                                                                         | `feat/ui/property-tree` (parent `77d0d547`)                                                                                                                     | 2026-08-18 |

Compilers used for the runnable examples: **ldc2 1.41.0** (D 2.111) and **dmd 2.112.1**. No Rust
toolchain is available in this repository's dev shell, so the Rust subjects were read but not
compiled.

## Runnable examples

Four single-file `dub` programs, compiled and run by the repository's `ci` helper, each backing a
claim the prose makes:

| Example                                                        | Backs                                                                                                                                                                                             |
| -------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`examples/reflect-descent.d`](./examples/reflect-descent.d)   | compile-time descent yields a manifest row plan; a recursive type is a **build error** without a visited-type set                                                                                 |
| [`examples/sumtype-variants.d`](./examples/sumtype-variants.d) | variant switching in D: `.init` makes constructability nearly free, but `SumType.opAssign` is `@system` when another member has indirections                                                      |
| [`examples/uda-metadata.d`](./examples/uda-metadata.d)         | what a UDA channel answers at compile time, and why a value-dependent condition must be carried as data                                                                                           |
| ★ [`examples/erased-descent.d`](./examples/erased-descent.d)   | the Tier-2 escape: put an **erasure boundary** in the child walk and a self-referential type compiles, descends by **budget**, and cuts with an Expand affordance — at one delegate per open node |

## Suggested reading paths

- **"I want the map, not the details."** [`comparison.md` § matrices][matrix] → [§ families][families] → [§ retractions][retractions] → [§ surprises][surprises].
- **"I am about to write the spec."** [`sparkles-baseline.md`][baseline] (the delta table) → [`comparison.md` § decisions][decisions] → the four examples.
- **"I care about compile-time reflection specifically."** ★[derive crates][derive] → [`reflect-descent.d`](./examples/reflect-descent.d) → [`erased-descent.d`](./examples/erased-descent.d) → [`uda-metadata.d`](./examples/uda-metadata.d).
- **"I care about cycles and big graphs."** [`comparison.md` § 4][q4] → ★[DevTools][devtools] → ★[rjsf][rjsf] → ★[Unity][unity].
- **"I care about multi-object editing."** [Unreal][unreal] → ★[Unity][unity] → [WinForms][winforms] § multi-object.
- **"I care about settings, not inspection."** ★[VS Code][vscode] → ★[rjsf][rjsf].

## What this survey does not cover

Deliberate scope limits, stated so they are not mistaken for findings:

- **Demoted to matrix-row status, unread.** Xceed WPF Toolkit `PropertyGrid` (a WPF restatement
  of the [WinForms][winforms] design), ControlsFX `PropertySheet` (a thin bean-over-`Item`
  layer), NetBeans `Node.Property` (structurally [Qt's][qt] manager), and `react-json-tree`
  (subsumed by ★[DevTools][devtools]). No claim in this tree rests on them.
- **Dropped from the original Tier-2 shortlist.** `NSOutlineView`, `GtkTreeView` and JavaFX
  `TreeTableView` — tree-table mechanics are already covered in-repo by the
  [tree-view case study](../tui-libraries/tree-view-case-study.md) and the shipped tree
  component. Generic Dear ImGui/`egui` idioms — superseded by the ★[derive crates][derive].
- **Parked.** Delphi/Lazarus `TOIPropertyGrid` (the oldest RTTI-driven inspector) and Blender's
  RNA-driven buttons — both interesting, neither answering a question the ten subjects left open.
- **Unreal was not read from source**; laziness, cycle handling and optional/nullable treatment
  could not be determined and are recorded as unknown rather than guessed.
- **Unity's native layer was not read**, only its published C# reference.
- **No behaviour was exercised at runtime** in any surveyed subject; every claim is a source or
  documentation reading. The only executed code in this tree is the D examples.

## Sources

Per-subject sources are listed in each deep-dive's `Sources` section; revisions are in the
[ledger](#revision-ledger) above. In-repo context: [`docs/specs/ui/inspector.md`][inspector] (the
inspector component this would feed), [`docs/specs/ui/editor.md`][editorspec] (the editable-text
component, `not started`), and [`docs/research/anchored-overlays/`][overlays] for the
surface-independence method this tree reuses.

<!-- References -->

[qt]: ./qt-property-browser.md
[godot]: ./godot-inspector.md
[winforms]: ./winforms-propertygrid.md
[unreal]: ./unreal-details-panel.md
[bevy]: ./bevy-inspector-egui.md
[unity]: ./unity-serializedproperty.md
[derive]: ./derive-macro-inspectors.md
[vscode]: ./vscode-settings-ui.md
[rjsf]: ./react-jsonschema-form.md
[devtools]: ./devtools-object-inspector.md
[baseline]: ./sparkles-baseline.md
[concepts-addr]: ./concepts.md#node-address
[matrix]: ./comparison.md#matrix-i--architecture
[families]: ./comparison.md#architectural-families
[decisions]: ./comparison.md#decisions-we-will-have-to-make
[retractions]: ./comparison.md#retractions-what-tier-2-changed
[surprises]: ./comparison.md#surprises
[q1]: ./comparison.md#1-where-the-tree-lives-and-what-it-costs
[q2]: ./comparison.md#matrix-i--architecture
[q3]: ./comparison.md#3-descent-and-who-owns-it
[q4]: ./comparison.md#4-cycles--the-rule-the-corpus-was-missing
[q5]: ./comparison.md#5-editing-commitment-and-undo
[q6]: ./comparison.md#6-polymorphic-and-sum-typed-values
[q7]: ./comparison.md#7-multi-object-editing
[q8]: ./comparison.md#cross-cutting-the-frame-model
[q9]: ./comparison.md#cross-cutting-surface-independence
[q10]: ./comparison.md#decisions-we-will-have-to-make
[q11]: ./comparison.md#8-presentation-filtering-performance
[inspector]: ../../specs/ui/inspector.md
[editorspec]: ../../specs/ui/editor.md
[overlays]: ../anchored-overlays/index.md
[ueiph]: https://web.archive.org/web/20230204095057/https://docs.unrealengine.com/5.1/en-US/API/Editor/PropertyEditor/IPropertyHandle/
