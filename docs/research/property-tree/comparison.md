# Comparison

The cross-subject synthesis over the whole corpus — the Tier-1 five and the Tier-2 four: two scannable matrices, what the field actually disagrees about, the architectural families the disagreements cluster into, the forks a Sparkles design will have to take, what Tier 2 **retracted** from the Tier-1 reading, and the things that were not obvious before reading the source.

**Last reviewed:** August 19, 2026

> [!NOTE]
> Eight subjects were read from source at pinned revisions ([Qt][qt], [Godot][godot],
> [WinForms][winforms], [bevy][bevy], [Unity][unity], the [derive-macro crates][derive],
> [VS Code][vscode], [rjsf][rjsf], [DevTools][devtools]). [Unreal][unreal] was read from
> archived API documentation only — its source requires an authenticated account — and every
> Unreal claim inherits that weaker status. Statements that are analysis rather than
> observation are marked **INFERENCE**.

---

## Matrix I — architecture

Subjects as rows. Tier-2 subjects are marked ★.

| Subject                                 | Where the tree lives                   | Node address                                  | Survives a rebuild by                                       | Metadata source                     | Descent decision                         |
| --------------------------------------- | -------------------------------------- | --------------------------------------------- | ----------------------------------------------------------- | ----------------------------------- | ---------------------------------------- |
| [Qt Property Browser][qt]               | independent data model                 | `QtProperty*`                                 | there being no rebuild                                      | none — caller builds the tree       | `hasValue()` on the manager              |
| [Godot `EditorInspector`][godot]        | the widget tree itself                 | `(object, "path/string")`                     | restoring selection/focus by hand; fold state on the object | flat `PropertyInfo` stream          | `Variant` type + hint                    |
| [WinForms `PropertyGrid`][winforms]     | retained entry model                   | `GridEntry`                                   | re-matching children structurally                           | `TypeDescriptor` attributes         | `TypeConverter.GetPropertiesSupported`   |
| [Unreal Details][unreal] _(docs)_       | node tree behind handles               | `IPropertyHandle`                             | the handle, with `IsValidHandle()`                          | `UPROPERTY` + `meta=` map           | handle has children                      |
| [`bevy-inspector-egui`][bevy]           | nowhere — a stack frame                | hashed structural path (`egui::Id`)           | recomputing the same id                                     | `bevy_reflect` + type registry      | `ReflectMut` discriminant                |
| ★ [Unity `SerializedProperty`][unity]   | serialized mirror + cursor             | mutable cursor **plus** `propertyPath` string | `isExpanded` living in the serialized data                  | serialization system + attributes   | the cursor's `enterChildren`             |
| ★ [Derive-macro crates][derive]         | the call graph of generated impls      | call-site id                                  | being the same call graph next frame                        | **attributes on the type**          | associated const / overridden visitor    |
| ★ [VS Code settings][vscode]            | settings tree model                    | `sanitizeId(parent + key)`                    | the model outliving the view                                | JSON-schema contributions           | none — two levels of grouping, flat rows |
| ★ [`react-jsonschema-form`][rjsf]       | nowhere — fields recurse per render    | field path **plus synthetic row keys**        | React reconciliation over those keys                        | a JSON Schema document + `uiSchema` | the schema's `type`                      |
| ★ [DevTools object inspector][devtools] | the other process                      | remote `objectId` (a lease) + `path()`        | refetching on expansion                                     | CDP property descriptors            | every value with children                |
| [`sparkles:ui` today][baseline]         | per-frame tree + explicit state values | adapter-minted `Key`                          | `TreeViewState(Key)`                                        | — (UDAs unused for this)            | —                                        |

## Matrix II — behaviour

| Subject                   | Materialisation                                         | Cycles                                                          | Mutation                                     | Transient vs committed                                | Collections                                    | Sum types                                                                | Multi-object                                               | Filter                              | Row cost                           |
| ------------------------- | ------------------------------------------------------- | --------------------------------------------------------------- | -------------------------------------------- | ----------------------------------------------------- | ---------------------------------------------- | ------------------------------------------------------------------------ | ---------------------------------------------------------- | ----------------------------------- | ---------------------------------- |
| [Qt][qt]                  | eager, whole subtree                                    | **forbidden at insert**                                         | editor → manager setter, live                | none                                                  | none                                           | enum/flags only                                                          | none                                                       | none                                | item + heap property per node      |
| [Godot][godot]            | lazy — sub-inspector on unfold                          | no guard                                                        | undo transaction (`MERGE_ENDS`)              | `changing` suppresses the _rebuild_                   | paged rows, add/remove/reorder                 | resource picker; subtree replaced                                        | intersection, **first object's value**                     | rebuild; folding disabled           | one `Control` per row              |
| [WinForms][winforms]      | lazy on expand                                          | no guard                                                        | designer transaction                         | commit on Enter/blur; modal error keeps text          | array index rows; modal editor                 | none                                                                     | merged descriptors, **blank when mixed**                   | none                                | zero widgets (one shared editor)   |
| [Unreal][unreal] _(docs)_ | not determined                                          | not determined                                                  | through the handle (transaction included)    | `SetValue` flags + `NotifyFinishedChangingProperties` | `AsArray`/`AsMap`/`AsSet`                      | `GeneratePossibleValues` + restrictions                                  | per-object values, first-class                             | not determined                      | not determined                     |
| [bevy][bevy]              | per frame, only inside open regions                     | impossible (`&mut` aliasing)                                    | `&mut` in place                              | none                                                  | inline add/remove/move                         | variant combo; unconstructable entries disabled                          | `ui_for_reflect_many`                                      | none                                | zero retained; re-walked per frame |
| ★ [Unity][unity]          | traversal skips collapsed subtrees                      | **visited set — in expand-all only**                            | mirror + `ApplyModifiedProperties` (undo)    | none at the C# layer                                  | reorderable list, keyed by path                | `[SerializeReference]`; subtree rebuilt on type change                   | `hasMultipleDifferentValues` (+ per-bit), `showMixedValue` | table views only                    | IMGUI, per-visible-row             |
| ★ [derive crates][derive] | per frame, open regions                                 | impossible (`&mut`)                                             | `&mut` in place                              | none                                                  | positional rows, add/remove/move               | derive **generates** construction — non-`Default` field is a build error | none                                                       | none                                | zero retained                      |
| ★ [VS Code][vscode]       | model built once, tree virtualizes                      | n/a (flat key space)                                            | configuration service writes `settings.json` | per control                                           | inline widgets for arrays/maps; else `Complex` | none — `Complex`                                                         | n/a (scope selector instead)                               | **model swap**, expansion untouched | virtualized, recycled templates    |
| ★ [rjsf][rjsf]            | per render                                              | **tagged, rendered as Expand**                                  | immutable `onChange`; host owns data         | per keystroke into `formData`                         | add/remove/reorder, **stable row keys**        | `oneOf` picker; **data survives via name+type match**                    | none                                                       | none                                | whole DOM                          |
| ★ [DevTools][devtools]    | per expansion — a network fetch                         | none needed (no automatic walk)                                 | remote evaluation                            | none                                                  | recursive `[from … to]` buckets; 200-row limit | read-only                                                                | none                                                       | over materialised rows only         | fetched rows only                  |
| [`sparkles:ui`][baseline] | `flatten` descends into open nodes; `viewSlice` windows | compile-time walk **fails to build** without a visited-type set | —                                            | —                                                     | table core, read-only                          | —                                                                        | none                                                       | filter owned by `TreeViewState`     | zero retained                      |

---

## Per-dimension synthesis

### 1. Where the tree lives, and what it costs

Four approaches now, not three.

**A model independent of any view** ([Qt][qt], [Unreal][unreal], ★[VS Code][vscode]). Buys
presentation-independence: Qt drives three browsers from one model; VS Code renders its model
through a virtualized tree and swaps the whole model for search. The cost is a second structure
to maintain — Qt materialises an item per _occurrence_ and fans changes out over the list.

**The widget tree as the only tree** ([Godot][godot]). Buys directness, costs a teardown per
structural change, and forces the state that must survive onto the edited object
([`editor_inspector.cpp:4396`][godot-todo] admits the caret is lost).

**No tree at all** ([bevy][bevy], ★[derive crates][derive], ★[rjsf][rjsf]). Buys the
elimination of rebuild, invalidation and change notification. Costs positional identity — except
in rjsf, which pays one synthetic key per array row to get identity back ([`ArrayField.tsx:44`][rjsf-rowid]).

**A mirror of the subject** (★[Unity][unity]). The inspector edits a serialized copy, pulled by
`Update()` and pushed by `ApplyModifiedProperties()` — which is also where undo is registered
([`SerializedObject.bindings.cs:122`][unity-apply]). This is the only subject that decouples
editing from the object _without_ building a node model: the mirror is the model.

★[DevTools][devtools] is the limiting case of all four: the tree is in another process, so the
inspector holds leases and refetches.

### 2. Metadata

Five channels: none ([Qt][qt]), runtime attribute tables ([WinForms][winforms], ★[Unity][unity]),
a runtime stream ([Godot][godot]), a type registry ([bevy][bevy]), a document
(★[VS Code][vscode], ★[rjsf][rjsf]) — and, new in Tier 2, **attributes consumed at compile
time** (★[derive crates][derive]).

The compile-time channel changes the failure mode rather than the expressiveness: a misspelled
attribute is a build error, and a per-field custom renderer is a function name resolved at
compile time. What it cannot express is a condition over the _value_ — which the document-driven
subjects get for free (`if`/`then`/`else`, `dependencies` in JSON Schema) and which
[`uda-metadata.d`](./examples/uda-metadata.d) shows a D UDA channel must carry as data and
evaluate per frame.

★[Unity][unity] adds one distinction nobody else has at the API level: metadata is readable at
**class scope and instance scope** (`GetMetaData` vs `GetInstanceMetaData` in [Unreal][unreal];
`SerializedProperty` + drawer attributes in Unity), so per-occurrence metadata is possible.

★[VS Code][vscode] adds **provenance**: a row carries `scopeValue`, `defaultValue`,
`defaultValueSource`, `isConfigured`, `hasPolicyValue`, per-language overrides
([`settingsTreeModels.ts:113`][vscode-element]). No other subject models _why_ a value is what
it is.

### 3. Descent, and who owns it

Unchanged in shape — model type ([WinForms][winforms]), value kind ([bevy][bevy]), manager
([Qt][qt]), runtime type+hint ([Godot][godot]) — with two Tier-2 additions.

★[Derive crates][derive] put it on the **trait, at compile time**: an associated const
(`SIMPLE`) or simply whether the impl overrides the child visitor. That is the same
capability-by-presence idiom `sparkles:ui` already uses for inspector adapters.

★[VS Code][vscode] declines the question: nested values are typed `Complex` and handed to the
text editor ("Edit in settings.json", [`settingsTree.ts:1203`][vscode-json]). A GUI that refuses
to descend, and offers the serialization format instead, is a legitimate answer nobody in Tier 1
considered.

### 4. Cycles — the rule the corpus was missing

Tier 1 concluded that nobody solves cycles; they arrange not to have them. Tier 2 supplies the
**rule** two independent subjects state in opposite directions:

> ★ Managed reference objects can form a cyclical graph, so need to track visited objects
>
> — [Unity][unity], inside `SetExpandedRecurse` ([`EditorGUI.cs:7841`][unity-visited])

> ★ Should only be `true` when called from an **object-property** context, because object
> properties are always rendered (creating an infinite loop), whereas array items and
> anyOf/oneOf branches are data-driven.
>
> — [rjsf][rjsf] on when to tag a `$ref` cycle ([`retrieveSchema.ts:366`][rjsf-cyclecomment])

**Guard the walk that is neither user-driven nor data-driven.** Unity's visited set is in
expand-all, not in painting. rjsf's cycle tag is for object properties, which are always
rendered, and not for array items or `oneOf` branches, which the data terminates. [DevTools][devtools]
needs no guard because it has no automatic walk at all. [Qt][qt] forbids cycles at the model
boundary; [bevy][bevy] and the ★[derive crates][derive] get freedom from `&mut` aliasing;
[Godot][godot] and [WinForms][winforms] rely on the reader stopping.

rjsf also contributes the best _presentation_ of a cut: `CyclicSchemaField` renders a
placeholder with an **Expand** button that opens exactly one more level
([`CyclicSchemaField.tsx:25`][rjsf-cyclic]) — the cut is visible and actionable rather than
silent. [`erased-descent.d`](./examples/erased-descent.d) reproduces that shape in D.

For Sparkles the constraint is sharper than for anyone surveyed: a CTFE walk **fails to build**
on a recursive type ([`reflect-descent.d`](./examples/reflect-descent.d)), and the escape is to
put an **erasure boundary** in the child walk — which is precisely what the ★[derive crates][derive]
do with `&mut dyn`, and what [`erased-descent.d`](./examples/erased-descent.d) measures the cost
of (one delegate per open node, one virtual call per descent).

### 5. Editing, commitment and undo

Undo is present in exactly the subjects embedded in a host that already had an undo stack
([Godot][godot], [WinForms][winforms], [Unreal][unreal], ★[Unity][unity] — where
`ApplyModifiedProperties()` _is_ the undo boundary). Every standalone library has none:
[Qt][qt], [bevy][bevy], all four ★[derive crates][derive], ★[rjsf][rjsf] (which hands
`formData` to the host), ★[DevTools][devtools]. **Nine subjects, no counterexample: undo
belongs to the host.**

The transient/committed distinction remains rare and remains misread. [Godot's][godot]
`changing` flag suppresses the rebuild, not the write ([`editor_inspector.cpp:5829`][godot-changing]).
Only [Unreal][unreal] separates the two at the API. ★[Unity][unity] has no equivalent at the C#
layer — its merge happens in the native undo system.

Validation gained a second data point: [WinForms][winforms] blocks navigation with a modal and
keeps the reader's text; ★[VS Code][vscode] renders the message **inline in the row**
([`settingsTree.ts:1215`][vscode-validation]); ★[rjsf][rjsf] makes validation a designed stage
whose `errorSchema` is addressed by the same path as the data.

### 6. Polymorphic and sum-typed values

The corpus now shows the full spread of "what happens on a variant switch":

| Approach                                                                       | Subject                  | On switch                                                                                                                        |
| ------------------------------------------------------------------------------ | ------------------------ | -------------------------------------------------------------------------------------------------------------------------------- |
| Runtime constructability check, unconstructable variants disabled with reasons | [bevy][bevy]             | old data discarded                                                                                                               |
| Derive **generates** the construction                                          | ★[derive crates][derive] | old data discarded; a non-`Default` field is a **build error**                                                                   |
| Concrete type name is part of the value                                        | ★[Unity][unity]          | subtree torn down when `managedReferenceFullTypename` changes ([`PropertyField.cs:249`][unity-pf])                               |
| Picker over allowed classes                                                    | [Godot][godot]           | value replaced; subtree is whatever the new object reports                                                                       |
| Metadata-driven options with restrictions                                      | [Unreal][unreal]         | not determined                                                                                                                   |
| **Schema `oneOf` with data migration**                                         | ★[rjsf][rjsf]            | **data survives**: keys whose name and resolved type match are carried over ([`sanitizeDataForNewSchema.ts:117`][rjsf-sanitize]) |

The last row is a Tier-1 retraction (see [Retractions](#retractions-what-tier-2-changed)). For D
specifically the obstacle is neither construction nor migration: it is `@safe`
([`sumtype-variants.d`](./examples/sumtype-variants.d)).

### 7. Multi-object editing

Four positions, and the Tier-2 addition is the cheapest one for the view:

- **Designed in** ([Unreal][unreal]): the handle addresses N objects; every read returns a result code.
- **Merged descriptors** ([WinForms][winforms]): `allEqual` out-parameter; a mixed row renders blank.
- **★ Ambient flag** ([Unity][unity]): `hasMultipleDifferentValues` per property — including a
  **per-bit** variant for masks — and a global `EditorGUI.showMixedValue` that every control
  consults, drawing an em-dash ([`EditorGUI.cs:273`][unity-showmixed]). Cheapest for the view,
  most demanding of the model, which must maintain an invalidatable comparison cache.
- **Incomplete** ([Godot][godot]): intersect the property lists, then show the first object's value.

★[VS Code][vscode] shows the adjacent problem — one row, several underlying values — solved by a
**scope selector** instead of a merge: pick which one you are editing.

### 8. Presentation, filtering, performance

Filtering has three answers now. [Godot][godot] rebuilds and disables folding while a filter is
active; `sparkles:ui`'s tree asks its adapter to rebuild; ★[VS Code][vscode] **swaps in a
different model** ([`settingsEditor2.ts:453`][vscode-model]), so filtering and expansion never
interact at all. The last is the cleanest and costs a second model to keep behaviourally
consistent.

On scale the corpus splits by what a row costs. [WinForms][winforms] and ★[VS Code][vscode]
virtualize (zero widgets per unrendered row). [Godot][godot] pays a `Control` per row and answers
size with **pagination**. ★[DevTools][devtools] answers it with **fetch policy** — 200 visible
children, then a "show all"; arrays above 100 elements become recursive `[from … to]` buckets
([`ObjectPropertiesSection.ts:2528`][devtools-thresholds]) — which is cheaper than virtualization
because unfetched rows do not exist. `sparkles:ui` already windows rows with `viewSlice`.

---

## Cross-cutting: the frame model

| Feature                       | Survives per-frame rebuild?                                  | Evidence                                                                                                                               |
| ----------------------------- | ------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------- |
| Expansion                     | **yes**, if identity is derivable or stored outside the view | [Godot][godot] on the object; ★[Unity][unity] in the serialized data; [bevy][bevy] from the id; `sparkles:ui`'s `DisclosureState(Key)` |
| Selection / focus             | **yes**, with explicit save-restore                          | [Godot][godot] around `_clear()`                                                                                                       |
| In-progress text              | **no** in practice                                           | [Godot][godot] loses the caret; [bevy][bevy] keeps it only via a stable id                                                             |
| Element state in a collection | **only with a synthetic key**                                | ★[rjsf][rjsf] alone; everyone else keys by index                                                                                       |
| Drag-transient edits          | yes, if the write is per-frame anyway                        | [bevy][bevy]; [Unreal][unreal] flags them instead                                                                                      |
| Virtualization                | yes — orthogonal                                             | [WinForms][winforms], ★[VS Code][vscode], `sparkles:ui`                                                                                |
| Undo grouping                 | **no** — needs "the same interaction"                        | [Godot][godot]'s `MERGE_ENDS`, [Unreal][unreal]'s set flags                                                                            |

**INFERENCE:** the features that genuinely force retention are those tied to an interaction that
spans frames — in-progress text and undo grouping — plus collection element state, which needs a
key that is not the index.

## Cross-cutting: surface independence

Tier 2 adds two data points to the same reasoning:

- **A GUI may legitimately refuse.** ★[VS Code's][vscode] `Complex` → "edit the JSON" says a
  property editor need not be total over its value space, provided the escape lands somewhere
  real. For the script-free HTML target that is the whole design: render what the row model can
  express, and let the underlying format be edited elsewhere.
- **Fetch policy is a portable substitute for virtualization.** ★[DevTools'][devtools] limits are
  policy, not layout — they work identically in a cell grid, and they bound work before it
  reaches the renderer.

Unchanged: pointer/hover affordances ([Godot's][godot] hover-only row icons), sub-cell geometry
([WinForms'][winforms] draggable splitter), modal escapes ([WinForms'][winforms] collection
editor), and a live runtime ([bevy][bevy], ★[derive crates][derive]) all assume things a
terminal or a static page does not have.

---

## Architectural families

Three families in Tier 1; Tier 2 adds a fourth and populates the others.

### Family A — Model-first ([Qt][qt], [Unreal][unreal], ★[VS Code][vscode])

A presentation-free model outlives any view; the view subscribes.
**Commits you to:** a second structure and its lifetime. **Buys you:** several presentations,
model-level search (VS Code swaps models), multi-object addressing as an indirection you already
have.

### Family B — View-first with external state ([Godot][godot], [WinForms][winforms], ★[Unity][unity])

The presented rows are the structure; what must survive lives elsewhere — on the object
([Godot][godot]), in the serialized data (★[Unity][unity]), or reconstructed by matching
([WinForms][winforms]).
**Commits you to:** naming every piece of surviving state, and losing what you fail to name.
**Buys you:** directness and no synchronisation problem.

### Family C — Function-first ([bevy][bevy], ★[derive crates][derive], ★[rjsf][rjsf])

The tree is a recursive function; persistence is a side table keyed by a derived id.
**Commits you to:** positional identity (unless you mint keys, as rjsf does) and a frame clock.
**Buys you:** no rebuild, no invalidation, no notification.

### ★ Family D — Handle-first over a foreign graph (★[DevTools][devtools])

The value is not yours: you hold leases, fetch on expansion, and bound by policy.
**Commits you to:** asynchrony everywhere, staleness, and never knowing the row count.
**Buys you:** the ability to inspect something unbounded, live and hostile — and a clean split
between _displaying_ and _evaluating_ (getters stay uninvoked).

`sparkles:ui` remains **Family C's frame model with Family B's state discipline**: rebuilt per
frame, but with no ambient id-keyed memory, so every persistent thing is a named value the host
owns ([baseline][baseline]).

---

## Decisions we will have to make

Eight forks, re-run against the Tier-2 evidence. Options and what each forecloses; no
recommendation.

### D1. Is there a node model at all, or is the tree a function of `T`?

- **A row model built per rebuild** — inspectable, testable, paintable read-only on the HTML target.
- **A pure function walked per frame** — smallest, matches the frame model; forecloses asking
  "how many rows does `T` have?" without painting.

_Tier-2 evidence:_ ★[VS Code][vscode] shows a model buys **search as a model swap**, which is
the cleanest filter/expansion story in the corpus. ★[DevTools][devtools] shows that when the row
count is unknowable, a model is impossible — irrelevant for a typed subject, decisive for a live
foreign one.

### D2. Where does the descent decision live?

- **On the type, at compile time** — total, checkable, no registry; forecloses per-instance decisions.
- **On an adapter the host supplies** — per-use flexibility; forecloses "any `T` just works".

_Tier-2 evidence:_ the ★[derive crates][derive] prove the compile-time option works at scale
(associated const / overridden visitor), and prove its cost: **the orphan rule**. A type you do
not own cannot be given a rendering without a wrapper. A registry ([WinForms][winforms]) has no
such limit.

### D3. What is a node's address?

- **A dotted path string** — readable, persistable, stable; allocates.
- **A compile-time row index** — free and exact; breaks on variant switches and collection edits.
- **An adapter-minted `Key`** — consistent with `TreeViewState(Key)`; defers the question.

_Tier-2 evidence:_ ★[Unity][unity] runs **cursor + path string** and keeps per-row side tables
keyed by the path — the pattern works, at the cost of stringly-typed lookups. ★[rjsf][rjsf]
demonstrates the one case an index cannot serve: **collection element state needs a synthetic
key**, or deleting element 0 shifts every later row's state.

### D4. How does a leaf editor get chosen?

- **Compile-time dispatch** (`static if` ladder + per-field UDA overrides) — no registry, `@nogc`-compatible.
- **A runtime registry** — open extension; would be `sparkles:ui`'s first dynamic dispatch surface.

_Tier-2 evidence:_ the ★[derive crates][derive] show compile-time dispatch is viable _and_ that
its escape hatch is cheap — a per-field function name (`custom_func_mut`, `as angle`) resolved at
compile time. ★[VS Code][vscode] shows the opposite pole working too: a **closed** renderer set
where extensions contribute data, not presentation.

### D5. What is the mutation contract?

- **Write through a reference, immediately** — simplest; forecloses undo, transient edits and
  multi-object editing, and inherits the `@system` `SumType` assignment problem.
- **Emit an edit command the host applies** — undo and multi-object become the host's; costs a
  command vocabulary and a way to name the target field.

_Tier-2 evidence:_ ★[Unity's][unity] mirror is a third option — edit a copy, commit at a
boundary (`ApplyModifiedProperties`) — and that boundary is exactly where undo attaches.
★[rjsf][rjsf] is a fourth: the component owns nothing and the host holds the data. Across nine
subjects, **every standalone library delegates undo to a host**; none invents its own.

### D6. Does the component support editing at all in v1?

- **Read-only inspection first** — deliverable now, serves the [inspector spec's][inspector]
  details pane and the HTML target, does not block on the unstarted [editor component][editorspec].
- **Editable from the start** — blocks on that component for every string field.

_Tier-2 evidence:_ ★[DevTools][devtools] is a fully useful, widely used property tree that is
**almost entirely read-only**, and its most interesting decisions (fetch bounds, buckets,
uninvoked getters) are all on the read path.

### D7. Which "unset" does D's Optional row mean?

`Nullable!T`, `T*`, `Expected!(T, E)`, a `SumType` with a unit variant.

_Tier-2 evidence:_ this is the axis Tier 2 changed most. ★[rjsf][rjsf] has explicit
present-vs-absent controls ([`OptionalDataControlsField.tsx:46`][rjsf-optional]); ★[VS Code][vscode]
distinguishes **not-set-here-but-inherited** from set-here (`isConfigured`) and shows the
provenance of the inherited value. Both are _user-facing states_, not type distinctions — so the
fork is really "how many kinds of unset does the row model name?", independently of how D spells
them.

### D8. Multi-subject editing: now, later, or never?

_Tier-2 evidence:_ ★[Unity][unity] shows the cheapest known implementation — one ambient
`showMixedValue` flag plus a per-property "do they differ?" predicate — but it is cheap only
because the _model_ maintains the comparison. Deciding "never" is still a decision about D3.

---

## Retractions: what Tier 2 changed

Claims from the Tier-1 pass that did not survive, and their narrowed replacements.

| Tier-1 claim                                                         | Status                   | Replacement                                                                                                                                                                                  |
| -------------------------------------------------------------------- | ------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| "Nobody attempts to carry per-field state across a variant switch."  | **Retracted**            | ★[rjsf][rjsf] migrates data on `oneOf` change, keeping keys whose name and resolved type match ([`sanitizeDataForNewSchema.ts:117`][rjsf-sanitize]). The type-driven subjects still discard. |
| "The only cycle check in the entire corpus is Qt's."                 | **Retracted**            | ★[Unity][unity] has a runtime visited set in `SetExpandedRecurse`, and ★[rjsf][rjsf] tags `$ref` cycles during schema resolution. Qt's remains the only _insert-time structural_ one.        |
| "Nobody in the corpus uses a visited set over values."               | **Retracted**            | ★[Unity][unity] keys one by `managedReferenceId`.                                                                                                                                            |
| "Element identity is positional everywhere."                         | **Retracted**            | ★[rjsf][rjsf] mints a synthetic row key per element and keeps it beside the data.                                                                                                            |
| "Recursion is user-driven, so no guard is needed."                   | **Narrowed**             | True only for walks the user or the data drives. An automatic walk (expand-all, schema resolution) needs a guard — stated independently by ★[Unity][unity] and ★[rjsf][rjsf].                |
| "Validation is a modal, or absent."                                  | **Narrowed**             | ★[VS Code][vscode] renders it inline per row; ★[rjsf][rjsf] makes it a stage with path-addressed errors.                                                                                     |
| "Undo belongs to a host."                                            | **Upheld, strengthened** | Nine subjects, no counterexample.                                                                                                                                                            |
| "No subject preserves in-progress text across a structural rebuild." | **Upheld**               | Unity avoids the question the same way as the rest: nothing is rebuilt while typing.                                                                                                         |

---

## Surprises

1. **Qt's model is a DAG, and the browser knows it** — `items(property)` returns a list of occurrences.
2. **Nesting in WinForms is not implemented by the grid** — the converter decides and supplies children; without `[NotifyParentProperty]` a nested edit silently does nothing.
3. **Godot's `changing` flag does not defer the commit** — it defers the rebuild.
4. **Godot's fold state lives on the edited object**, so it is serialized with the scene.
5. **Godot's multi-selection shows the first node's value** with no mixed marker.
6. **Godot's answer to big collections is pagination, not virtualization.**
7. **Qt is the only subject that forbids cycles structurally**, at insert time.
8. **bevy's cycle-freedom is a borrow-checker artifact**, and the price is that cross-object references leave the walk entirely.
9. **bevy disables variant entries it cannot construct, and says which field types blocked it.**
10. **A compile-time descent in D turns the cycle problem into a build failure** — verified on both compilers.
11. **In D the variant-switch obstacle is `@safe`, not constructability.**
12. **Not one subject preserves in-progress text across a structural rebuild.**
13. ★ **Unity's expansion state lives in the serialized data**, not in the window — one step beyond Godot: it survives selection changes and domain reloads because it is part of the object's serialized form.
14. ★ **Unity caps custom-drawer recursion with a nesting-indexed drawer list** — a drawer cannot draw its own type forever; past the list's end the default field takes over.
15. ★ **The corpus's two visited sets are both in walks nobody clicked** — expand-all and schema resolution. That, not "reflective editors need visited sets", is the rule.
16. ★ **rjsf renders a cycle as an Expand button**, making an infinite structure finite and legible instead of silently cut.
17. ★ **rjsf migrates data across a variant switch** by name-and-type matching — the only subject that tries, and it is a heuristic that can carry a same-named field into a different meaning.
18. ★ **A settings row is not (label, value)** — VS Code's carries scope, default, default _source_, policy lock and per-language overrides, i.e. why the value is what it is.
19. ★ **VS Code answers search by swapping the model**, so filtering never touches expansion.
20. ★ **DevTools refuses to invoke getters** — the only subject that treats displaying and evaluating as different acts.
21. ★ **DevTools bounds by fetch policy, not rendering policy** (200 children, 100-element buckets, recursive ranges), which is cheaper than virtualization because unfetched rows do not exist.
22. ★ **The derive family's recursion terminates because of an erasure boundary**, not because of Rust — the same boundary in D turns our build error into a runtime walk, at the price of a delegate per open node ([`erased-descent.d`](./examples/erased-descent.d)).

---

## Sources

Per-subject sources are in each deep-dive: [Qt][qt], [Godot][godot], [WinForms][winforms],
[Unreal][unreal], [bevy][bevy], ★[Unity][unity], ★[derive crates][derive], ★[VS Code][vscode],
★[rjsf][rjsf], ★[DevTools][devtools], [Sparkles baseline][baseline]. Revisions are recorded in
the [revision ledger][ledger].

<!-- References -->

[qt]: ./qt-property-browser.md
[godot]: ./godot-inspector.md
[winforms]: ./winforms-propertygrid.md
[bevy]: ./bevy-inspector-egui.md
[unreal]: ./unreal-details-panel.md
[unity]: ./unity-serializedproperty.md
[derive]: ./derive-macro-inspectors.md
[vscode]: ./vscode-settings-ui.md
[rjsf]: ./react-jsonschema-form.md
[devtools]: ./devtools-object-inspector.md
[baseline]: ./sparkles-baseline.md
[ledger]: ./index.md#revision-ledger
[inspector]: ../../specs/ui/inspector.md
[editorspec]: ../../specs/ui/editor.md
[godot-todo]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/editor/inspector/editor_inspector.cpp#L4396
[godot-changing]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/editor/inspector/editor_inspector.cpp#L5829
[unity-visited]: https://github.com/Unity-Technologies/UnityCsReference/blob/225b0fbdb57cc17d094e8056b71f8314aba56f73/Editor/Mono/EditorGUI.cs#L7841
[unity-showmixed]: https://github.com/Unity-Technologies/UnityCsReference/blob/225b0fbdb57cc17d094e8056b71f8314aba56f73/Editor/Mono/EditorGUI.cs#L273
[unity-apply]: https://github.com/Unity-Technologies/UnityCsReference/blob/225b0fbdb57cc17d094e8056b71f8314aba56f73/Editor/Mono/SerializedObject.bindings.cs#L122
[unity-pf]: https://github.com/Unity-Technologies/UnityCsReference/blob/225b0fbdb57cc17d094e8056b71f8314aba56f73/Editor/Mono/UIElements/Controls/PropertyField.cs#L249
[rjsf-rowid]: https://github.com/rjsf-team/react-jsonschema-form/blob/c8723f5f39d030776909667e74d217572757483c/packages/core/src/components/fields/ArrayField.tsx#L44
[rjsf-sanitize]: https://github.com/rjsf-team/react-jsonschema-form/blob/c8723f5f39d030776909667e74d217572757483c/packages/utils/src/schema/sanitizeDataForNewSchema.ts#L117
[rjsf-cyclic]: https://github.com/rjsf-team/react-jsonschema-form/blob/c8723f5f39d030776909667e74d217572757483c/packages/core/src/components/fields/CyclicSchemaField.tsx#L25
[rjsf-cyclecomment]: https://github.com/rjsf-team/react-jsonschema-form/blob/c8723f5f39d030776909667e74d217572757483c/packages/utils/src/schema/retrieveSchema.ts#L366
[rjsf-optional]: https://github.com/rjsf-team/react-jsonschema-form/blob/c8723f5f39d030776909667e74d217572757483c/packages/core/src/components/fields/OptionalDataControlsField.tsx#L46
[vscode-element]: https://github.com/microsoft/vscode/blob/474a349ad5b745e512ef86b864d1c74f7264dd7a/src/vs/workbench/contrib/preferences/browser/settingsTreeModels.ts#L113
[vscode-json]: https://github.com/microsoft/vscode/blob/474a349ad5b745e512ef86b864d1c74f7264dd7a/src/vs/workbench/contrib/preferences/browser/settingsTree.ts#L1203
[vscode-validation]: https://github.com/microsoft/vscode/blob/474a349ad5b745e512ef86b864d1c74f7264dd7a/src/vs/workbench/contrib/preferences/browser/settingsTree.ts#L1215
[vscode-model]: https://github.com/microsoft/vscode/blob/474a349ad5b745e512ef86b864d1c74f7264dd7a/src/vs/workbench/contrib/preferences/browser/settingsEditor2.ts#L453
[devtools-thresholds]: https://github.com/ChromeDevTools/devtools-frontend/blob/788f6469296bf2420bd95bb6d73d28a21439f345/front_end/ui/legacy/components/object_ui/ObjectPropertiesSection.ts#L2528
