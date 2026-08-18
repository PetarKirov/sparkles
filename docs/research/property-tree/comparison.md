# Comparison

The cross-subject synthesis: one scannable matrix, then what the field actually disagrees about, the architectural families the disagreements cluster into, the forks a Sparkles design will have to take, and the things that were not obvious before reading the source.

**Last reviewed:** August 18, 2026

> [!NOTE]
> Four subjects were read at pinned revisions ([Qt][qt], [Godot][godot], [WinForms][winforms],
> [bevy][bevy]). [Unreal][unreal] was read from archived API documentation only — its source
> requires an authenticated account — and every Unreal claim here inherits that weaker status.
> Statements that are analysis rather than observation are marked **INFERENCE**.

---

## Comparison matrix

|                              | [Qt Property Browser][qt]             | [Godot `EditorInspector`][godot]                    | [WinForms `PropertyGrid`][winforms]                                                       | [Unreal Details][unreal] (docs)                       | [`bevy-inspector-egui`][bevy]                           | [`sparkles:ui` today][baseline]                                    |
| ---------------------------- | ------------------------------------- | --------------------------------------------------- | ----------------------------------------------------------------------------------------- | ----------------------------------------------------- | ------------------------------------------------------- | ------------------------------------------------------------------ |
| **Where the tree lives**     | data model, browser-independent       | the widget tree itself                              | retained entry model                                                                      | node tree behind handles                              | nowhere — a stack frame                                 | widget tree rebuilt per frame + explicit state values              |
| **Node address**             | `QtProperty*`                         | `(object, "path/string")`                           | `GridEntry`, re-matched structurally                                                      | `IPropertyHandle` (+ `IsValidHandle`)                 | hashed structural path (`egui::Id`)                     | adapter-minted `Key`                                               |
| **Survives rebuild**         | no rebuild exists                     | selection/focus restored by hand; caret lost        | children diffed with `EqualsIgnoreParent`                                                 | yes, that is the handle's job                         | recomputed identically                                  | yes — `TreeViewState(Key)`                                         |
| **Metadata**                 | none (caller builds tree)             | runtime `PropertyInfo` stream                       | runtime `TypeDescriptor` attributes                                                       | `UPROPERTY` + `meta=` map, class **and** instance     | type registry of option objects                         | UDAs (compile-time) — unused for this                              |
| **Descent decision**         | `hasValue()` on the manager           | `Variant` type + hint                               | `TypeConverter.GetPropertiesSupported`                                                    | handle has children                                   | `ReflectMut` discriminant                               | —                                                                  |
| **Children come from**       | hand-written per composite manager    | a nested inspector, or a composite widget           | `TypeConverter.GetProperties`                                                             | child handles / `AddChildStructure`                   | the reflected value's fields                            | —                                                                  |
| **Materialisation**          | eager, whole subtree                  | lazy — sub-inspector built only when unfolded       | lazy on expand                                                                            | not determined                                        | per frame, only inside open regions                     | `flatten` descends only into open nodes                            |
| **Cycles**                   | **impossible** — checked on insert    | no guard; user-driven recursion                     | no guard; opt-in converters limit exposure                                                | not determined                                        | impossible via `&mut` aliasing                          | compile-time descent **fails to build** without a visited-type set |
| **Editor dispatch**          | factory per manager                   | plugin chain, last wins                             | `UITypeEditor` → standard values → converter                                              | customization by class and by type                    | registry by concrete type → short-circuit → structure   | none                                                               |
| **Mutation**                 | editor → manager setter, live         | `emit_changed` → undo transaction                   | setter inside a designer transaction                                                      | through the handle (transaction included)             | `&mut` in place                                         | —                                                                  |
| **Undo**                     | none                                  | `EditorUndoRedoManager`, `MERGE_ENDS`               | delegated to `IDesignerHost`                                                              | automatic via handle                                  | none                                                    | none                                                               |
| **Transient vs committed**   | none                                  | `changing` flag (suppresses rebuild, not the write) | commit on Enter/blur; conversion at commit                                                | `SetValue` flags + `NotifyFinishedChangingProperties` | none                                                    | none                                                               |
| **Validation**               | editor widget only                    | none                                                | converter throws → modal dialog, text kept                                                | `SetIgnoreValidation` per subtree                     | none                                                    | none                                                               |
| **Collections**              | none                                  | paged rows, add/remove/reorder                      | array index rows; richer → modal editor                                                   | `AsArray`/`AsMap`/`AsSet`                             | inline add/remove/move                                  | table core, read-only                                              |
| **Sum types / polymorphism** | enum + flags only                     | `EditorResourcePicker`; subtree replaced            | none                                                                                      | `GeneratePossibleValues` + restrictions               | variant combo, unconstructable entries disabled         | none                                                               |
| **Optional / unset**         | none                                  | null resource; checkable rows                       | `ResetValue` / `[DefaultValue]`                                                           | not determined                                        | `Option` is just an enum                                | none                                                               |
| **Multi-object**             | none                                  | intersection; **first object's value shown**        | merged descriptors; blank when `allEqual == false`                                        | per-object values, first-class                        | `ui_for_reflect_many` + projector                       | none                                                               |
| **Grouping**                 | insertion order + group properties    | category/group/subgroup pseudo-rows + name prefixes | `[Category]` + `PropertySort`                                                             | categories via customization                          | declaration order                                       | declaration order                                                  |
| **Filter**                   | none                                  | rebuild; **folding disabled while filtering**       | none                                                                                      | not determined                                        | none in `reflect_inspector`                             | filter owned by `TreeViewState`, rebuild reported                  |
| **Escape hatches**           | manager / factory / browser           | plugin at 4 granularities                           | `[Editor]` → `UITypeEditor` → `[TypeConverter]` → `ICustomTypeDescriptor` → `PropertyTab` | `IDetailCustomization` / `IPropertyTypeCustomization` | type impl → short-circuit → call the functions yourself | DbI capability-by-presence, adapters                               |
| **Row cost**                 | one item + one heap property per node | one `Control` per row                               | zero widgets per row (one shared editor)                                                  | not determined                                        | zero retained, re-walked per frame                      | zero retained; `viewSlice` windows rows                            |

---

## Per-dimension synthesis

### 1. Where the tree lives, and what it costs

Three distinct approaches, and the cost is paid in exactly one place each.

**A model independent of any view** ([Qt][qt], [Unreal][unreal]). Buys presentation-independence outright: Qt drives a tree browser, a group-box browser and a button browser from the same properties, and the model never learns which. The cost is a second structure — Qt materialises a `QtBrowserItem` per _occurrence_ per browser and fans every change out over the occurrence list — and the discipline of keeping model and subject in sync, since the manager, not the application object, holds the value.

**The widget tree as the only tree** ([Godot][godot]). Buys directness: a plugin manipulates rows because rows are objects. The cost is that any structural change is a teardown, and the source says so — `update_tree()` saves selection and focus around `_clear()` and openly notes that the caret position is not saved ([`editor_inspector.cpp:4396`][godot-todo]). Godot then has to push the one piece of state it cannot afford to lose — expansion — **onto the edited object** (`editor_set_section_unfold`), which makes fold state part of the saved scene.

**No tree at all** ([bevy][bevy]). Buys the elimination of an entire class of problems: no rebuild, no invalidation, no change notification, no stale model. The cost is that everything persistent must be keyed by a structurally-derived id in the UI library's side table — and that identity is positional, so mutating a collection shuffles the state of everything after the mutation point.

[WinForms][winforms] sits between the first and second: a retained entry model, but one owned by the grid and rebuilt from the root, with identity reconstructed by structural equality (`EqualsIgnoreParent`) rather than preserved.

**The pattern:** every subject that rebuilds has to name the state that must survive, and each names a _different_ set. Godot names expansion (and loses the caret). WinForms names expansion (via child diffing) and nothing else. bevy names everything at once by making the id derivable. Nobody preserves in-progress text across a structural rebuild — [Godot][godot] avoids the question by suppressing rebuilds while `changing > 0`.

### 2. Metadata

Four runtime channels and one compile-time one, and the split that matters is not runtime-vs-compile-time but **type-scoped vs instance-scoped**. [Unreal][unreal] is alone in offering both (`GetMetaData` vs `GetInstanceMetaData`), which is what lets a customization attach information to one occurrence of a type. [Godot][godot] gets the same effect differently: the whole property list is regenerated per rebuild, and a script may rewrite it per object (`_get_property_list`) or per property (`_validate_property`), so metadata is inherently per-instance and inherently transient.

The deeper structural finding is Godot's: metadata arrives as a **flat ordered stream with pseudo-entries**, and the hierarchy is recovered by prefix matching on names ([`editor_inspector.cpp:4715`][godot-prefix]). Grouping is a naming convention, re-derived every rebuild. That is cheap and open — a script can produce any tree — and it means the panel can never trust its own structure.

### 3. Descent, and who owns it

The most consequential divergence in the corpus. [WinForms][winforms] puts the decision **on the model type**: `TypeConverter.GetPropertiesSupported` says whether a value expands, and `GetProperties` says into what. The grid contains no knowledge of nesting at all. That is the most extensible answer — any type becomes inspectable everywhere by shipping a converter — and the most obscure: three unrelated hooks (`GetPropertiesSupported`, `GetCreateInstanceSupported`, `[NotifyParentProperty]`) must agree or a nested edit silently does nothing.

[bevy][bevy] puts it in the **value's structural kind**, with a leaf-editor registry consulted _first_ so that `Vec3` renders as three drag boxes rather than a struct. Ordering matters: registry → short-circuit → structure. [Qt][qt] puts it in the manager and pays for it in code volume — every composite type is a hand-written manager, which is why one file runs to 6,611 lines.

**The pattern:** whoever owns the descent decision owns the extension story. Model-side ownership (WinForms) means new types work everywhere without touching the component; component-side ownership (Qt) means the component is in control and grows without bound.

### 4. Cycles

The finding here is that **nobody solves cycles; they arrange not to have them**.

- [Qt][qt] forbids them at the model boundary, with an explicit descendant walk on every insert ([`qtpropertybrowser.cpp:403`][qt-cycle]). It can afford the check because insertion is caller-driven and rare.
- [bevy][bevy] gets cycle-freedom from Rust's aliasing rules; the reference graph that _would_ cycle is pushed out of the walk entirely, into `RestrictedWorldView`.
- [Godot][godot] and [WinForms][winforms] have no guard at all. They survive because materialisation is lazy and recursion is driven by clicks — a self-referential value can be unfolded forever, one level per click, and no one has complained loudly enough for a guard to appear.
- A **compile-time** descent in D cannot take any of those positions: without a visited-type set the build fails outright at 500 levels of template recursion, verified in [`reflect-descent.d`](./examples/reflect-descent.d) on both compilers.

### 5. Editing, commitment and undo

Undo is present in exactly the two subjects embedded in an application that already had an undo stack ([Godot][godot]'s `EditorUndoRedoManager`, [WinForms][winforms]'s designer transaction) plus the one that made it the handle's job ([Unreal][unreal]). Both standalone libraries ([Qt][qt], [bevy][bevy]) have none. **INFERENCE:** undo is a host concern, and a property component that invents its own is likely to be fighting the host's.

The transient/committed distinction is where the corpus is most instructive and most misread. Godot's `changing` flag looks like "don't commit yet" and is not — the source comment says it exists for properties "that trigger events as typing occurs" ([`editor_inspector.cpp:5829`][godot-changing]), and its effect is to suppress the rebuild that would destroy the widget being typed into. The value is written on every keystroke; what is deferred is the _refresh_. Only [Unreal][unreal] separates the two at the API level, with set flags plus an explicit `NotifyFinishedChangingProperties`.

[WinForms][winforms] is alone in taking validation seriously, and its answer is worth stating as a pattern: convert at commit, show the exception, **block the navigation that triggered the commit**, and let the reader choose between reverting and continuing to edit their text ([`PropertyGridView.cs:5046`][wf-revert]).

### 6. Polymorphic and sum-typed values

The axis the brief flagged, and the corpus's answers are unusually far apart.

[bevy][bevy] is the only subject that treats a variant switch as a **construction problem**: the picker enables a variant only if every field type has a registered default, and a disabled entry explains which types blocked it ([`mod.rs:1889`][bevy-constructable]). Switching builds a `DynamicEnum` of defaults and applies it — the old variant's data is gone.

[Unreal][unreal] generalises the same shape to classes and enums (`GeneratePossibleValues` returning values, tooltips **and** a restricted flag per entry), and adds reasons a value is unavailable.

[Godot][godot] has a picker for `Resource` subclasses and simply replaces the value; the subtree becomes whatever the new object reports. [WinForms][winforms] has no type picker at all — a polymorphic field is whatever its converter says. [Qt][qt] has none.

**Nobody attempts to carry per-field state across a variant switch.** The subtree is discarded and rebuilt in all three subjects that support switching. For D that is a stronger statement than it looks: [`sumtype-variants.d`](./examples/sumtype-variants.d) shows that constructability is nearly free (every type has `.init`), so the picker's hard question is not "can I build it?" but "may I assign it?" — Phobos' `SumType.opAssign` is `@system` whenever another member has indirections.

### 7. Multi-object editing

Three positions, and the architecture consequences are visible in each.

- **Designed in from the start** ([Unreal][unreal]): a handle addresses N objects, every read returns a result code beside the value, and "they disagree" is a normal answer. The whole API is shaped by it.
- **Bolted on cleanly** ([WinForms][winforms]): merge N `PropertyDescriptor`s into one `MergePropertyDescriptor` whose `GetValue` reports `allEqual`, and the rest of the grid never learns that N > 1. The cost is a parallel entry class, a merged-collection type, and event lookups that have to unpack the array.
- **Bolted on and left incomplete** ([Godot][godot]): `MultiNodeEdit` intersects the property lists and then returns **the first node's value**, with no mixed-value indication ([`multi_node_edit.cpp:144`][godot-mne]).

**The pattern:** multi-object editing is cheap to add to a design where the address is already an indirection (a handle, a descriptor) and expensive where the address is "this object, this field".

### 8. Presentation, filtering, performance

Filtering interacts with expansion in exactly one interesting way, and [Godot][godot] is the only subject that has it: while a filter is active, folding is **disabled entirely** so every match is visible ([`editor_inspector.cpp:4464`][godot-filter]), and the reader's fold state is untouched because it lives on the object rather than in the panel.

On performance the corpus splits by widget cost, not by row count. [WinForms][winforms] paints rows itself and keeps one shared edit box, so rows are nearly free. [Godot][godot] spends a `Control` per row and, having no virtualization, answers large collections with **pagination**. [bevy][bevy] pays per visible row per frame and nothing when closed. [Qt][qt] retains an item per node but only one editor widget at a time.

---

## Cross-cutting: the frame model

Which of these designs survives a per-frame rebuild of the presented tree?

| Feature              | Survives per-frame rebuild?                                  | Evidence                                                                                                                                                                              |
| -------------------- | ------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Expansion            | **yes**, if identity is derivable or stored outside the view | [Godot][godot] stores it on the object; [bevy][bevy] derives it from the id; `sparkles:ui` has `DisclosureState(Key)`                                                                 |
| Selection / focus    | **yes**, with explicit save-restore                          | [Godot][godot] does exactly this around `_clear()`                                                                                                                                    |
| In-progress text     | **no** in practice                                           | [Godot][godot] loses the caret ([`editor_inspector.cpp:4396`][godot-todo]) and suppresses rebuilds while typing; [bevy][bevy] keeps it only because egui holds it against a stable id |
| Drag-transient edits | **yes**, if the write is per-frame anyway                    | [bevy][bevy] drags write continuously; [Unreal][unreal] flags them instead                                                                                                            |
| Virtualization       | **yes** — orthogonal                                         | [WinForms][winforms] and `sparkles:ui` both window rows without retaining them                                                                                                        |
| Undo grouping        | **no** — needs a notion of "the same interaction"            | [Godot][godot]'s `MERGE_ENDS`, [Unreal][unreal]'s set flags                                                                                                                           |

**INFERENCE:** the only features that genuinely _force_ retention are the ones tied to an interaction that spans frames — in-progress text and undo grouping. Everything else survives a rebuild provided node identity is either derivable from the path or stored as a value outside the view. That is precisely the position `sparkles:ui` is already in ([baseline][baseline]).

## Cross-cutting: surface independence

What each design assumes about its surface, and what the cell grid / HTML / terminal targets would cost:

- **A pointer and hover.** [WinForms][winforms]' expansion glyph, drop-down buttons and `…` modal buttons are all pointer affordances; [Godot's][godot] rows carry hover-only revert/keying/pin/favourite icons. A terminal has no hover, so any affordance that only appears on hover has to become always-visible or keyboard-reachable — the same conclusion the [anchored-overlays][overlays] survey reached for tooltips.
- **Pixels.** [Godot's][godot] split-ratio label/value divider and [WinForms'][winforms] draggable column splitter are sub-cell geometry. In integer cells the split is a column count, which also means the label column is a layout decision rather than a drag.
- **A modal window.** [WinForms][winforms] pushes collection editing and validation errors into modal dialogs; [Qt][qt] uses a colour/font dialog for two of its editor factories. On a terminal or a script-free HTML page there is no modal to push to, so those cases must be inline (an expandable subtree) or absent.
- **A frame clock and a live runtime.** [bevy's][bevy] entire model assumes both. The script-free HTML target has neither — it has no runtime at all — so a property tree that is only defined as "a function run every frame" has no meaning there. What it can express is the **read-only presentation** of the same row model, which is what makes a presentation-free row model (as opposed to a per-frame function) load-bearing for this repo rather than a matter of taste.
- **One editor widget at a time.** [Qt][qt]'s delegate and [WinForms][winforms]' shared text box both assume exactly one row is being edited. That assumption is target-independent and cheap, and it is the one performance trick in the corpus that transfers unchanged.

---

## Architectural families

The corpus falls into three coherent families. Adopting one commits a design to its consequences as a package.

### Family A — Model-first (Qt, Unreal)

A presentation-free node model that outlives any view, addressed by a stable handle, with the view as a subscriber.

**Commits you to:** a second structure to maintain and fan changes out over; a node lifetime question; mirroring or mediating access to the real subject. **Buys you:** several simultaneous presentations, multi-object addressing as an indirection you already have, undo attached to the mediating layer, and node identity that needs no derivation.

### Family B — View-first with external state (Godot, WinForms)

The presented rows are the structure; whatever must survive a refresh is either stored outside the view (Godot: on the object) or reconstructed by matching (WinForms: entry diffing).

**Commits you to:** naming, one by one, every piece of state that must survive — and accepting that anything you fail to name is lost, in-progress text first. **Buys you:** directness (rows are objects a plugin can manipulate), and no synchronisation problem, because there is nothing to keep in sync.

### Family C — Function-first (bevy)

The tree is a recursive function over the value; identity is a hash of the structural path; persistence is a side table keyed by that hash.

**Commits you to:** positional identity (collection edits shuffle state); no place for state that is not id-keyed; a surface that has a frame clock. **Buys you:** the elimination of rebuild, invalidation and change-notification entirely — measurably the smallest implementation in the corpus.

`sparkles:ui` today is **Family C's frame model with Family B's state discipline**: the tree is rebuilt per frame like bevy's, but there is no ambient id-keyed memory, so every persistent thing is a named value the host owns ([baseline][baseline]). The design question is not which family to join — the toolkit has already chosen — but whether the property tree needs a Family A model _on top of_ that, and for which capabilities.

---

## Decisions we will have to make

Each fork, with what each option forecloses. No recommendation is offered.

### D1. Is there a node model at all, or is the tree a function of `T`?

- **A row model built per rebuild** (a `TreeData` of reflected rows) — makes the row set inspectable, testable and paintable read-only on the HTML target; forecloses nothing structurally, but costs a build step that must be invalidated by something.
- **A pure function walked per frame** — smallest, matches the frame model exactly; forecloses a read-only HTML rendering that is not "run the function", and forecloses any consumer that wants to ask "how many rows does `T` have?" without painting.

### D2. Where does the descent decision live?

- **On the type, at compile time** (`static if` over `isAggregateType` + opt-out UDAs) — total, checkable, no registry; forecloses per-instance decisions ("this `Config` expands, that one does not") and makes every consumer of a type agree.
- **On an adapter the host supplies** — per-use flexibility, matches `sparkles:ui`'s existing adapter idiom; forecloses "any `T` just works" and pushes the work onto every host.

### D3. What is a node's address?

- **A dotted path string** ([Godot's][godot] answer) — human-readable, easy to persist, trivially stable across rebuilds; forecloses cheap comparison and allocates.
- **A compile-time row index into the flattened plan** — free, exact; forecloses variant switches and collection edits changing the row set, unless the index is recomputed and remapped.
- **An adapter-minted `Key`, as `TreeViewState(Key)` already expects** — consistent with the toolkit; forecloses nothing, but defers the question to whoever writes the adapter.

### D4. How does a leaf editor get chosen?

- **Compile-time dispatch** (a `static if` ladder, plus per-field UDA overrides) — no registry, `@nogc`-compatible, everything is known at build time; forecloses a host adding an editor for a type it does not own, and forecloses runtime-chosen editors.
- **A runtime registry** (the corpus's universal answer) — open extension; would be `sparkles:ui`'s **first** dynamic dispatch surface, against the toolkit's whole DbI idiom.

### D5. What is the mutation contract?

- **Write through a reference, immediately** ([bevy's][bevy] position) — simplest; forecloses undo, transient edits and multi-object editing, and inherits the `@system` `SumType` assignment problem for variant switches.
- **Emit an edit command the host applies** — undo and multi-object become the host's, and the component stays `@safe pure`; costs a command vocabulary and a way to name the target field generically (which is D3 again).

### D6. Does the component support editing at all in v1?

- **Read-only inspection first** — deliverable now, serves the [inspector spec's][inspector] details pane and the HTML target, and does not block on the unstarted [editor component][editorspec].
- **Editable from the start** — blocks on that component for every string field; every other target-specific decision (commit point, validation display) then has to be made without an existing text-editing machine to make it against.

### D7. Which "unset" does D's Optional row mean?

`Nullable!T`, `T*`, `Expected!(T, E)` and a `SumType` with a unit variant are four different representations with four different transitions. Handling one forecloses nothing; handling all four means a vocabulary for "the unset transition" that none of the corpus has.

### D8. Multi-subject editing: now, later, or never?

The corpus says this is cheap when the address is already an indirection and expensive otherwise ([§7](#7-multi-object-editing)). Deciding "never" is a decision about D3, not a feature cut.

---

## Surprises

Things that were not obvious before reading the source.

1. **Qt's model is a DAG, and the browser knows it.** `items(property)` returns a _list_ because one property can be presented in several places at once; every change notification fans out over that list. The "one value shown twice" case is designed for, not a bug — and it is the only subject that does so.
2. **Nesting in WinForms is not implemented by the grid.** `TypeConverter.GetPropertiesSupported` decides expandability and `GetProperties` supplies the children, so the whole recursion lives on the model types. The corollary is a silent failure mode: without `[NotifyParentProperty]`, editing a child of a value type appears to work and never reaches the object.
3. **Godot's `changing` flag does not defer the commit.** It suppresses the _rebuild_. The value is written on every keystroke; the source comment says as much ([`editor_inspector.cpp:5829`][godot-changing]).
4. **Godot's fold state lives on the edited object, not the panel** — which is what makes its full-rebuild architecture viable, and also means expansion is serialized with the scene.
5. **Godot's multi-selection shows the first node's value** with no mixed-value marker, despite intersecting the property lists carefully ([`multi_node_edit.cpp:144`][godot-mne]). The careful part and the sloppy part are three files apart.
6. **Godot's answer to big collections is pagination, not virtualization** — a direct consequence of one widget per row.
7. **The only cycle check in the entire corpus is Qt's, and it runs on insert** ([`qtpropertybrowser.cpp:403`][qt-cycle]). Everyone else relies on laziness plus a human getting bored.
8. **bevy's cycle-freedom is a borrow-checker artifact**, not a design decision — and the cost is that every cross-object reference has to exit the reflection walk through `RestrictedWorldView`.
9. **bevy disables variant entries it cannot construct, and says which field types blocked it.** It is the only subject that treats "you may not switch to this variant" as information rather than as an error after the fact.
10. **A compile-time descent in D turns the cycle problem into a build failure.** Verified on both compilers at 500 levels of template recursion ([`reflect-descent.d`](./examples/reflect-descent.d)) — the field's "we just let the user stop clicking" answer is unavailable here.
11. **In D the variant-switch obstacle is `@safe`, not constructability.** Every type has `.init`, but `SumType.opAssign` is `@system` whenever another member type has indirections ([`sumtype-variants.d`](./examples/sumtype-variants.d)) — an obstacle no surveyed subject has an analogue for.
12. **Not one subject preserves in-progress text across a structural rebuild.** They avoid the question instead: Godot suppresses rebuilds while typing, WinForms blocks the navigation that would commit, bevy has no rebuild. If a design wants that guarantee, it will be the first.

---

## Sources

The per-subject sources are in each deep-dive: [Qt][qt], [Godot][godot], [WinForms][winforms], [Unreal][unreal], [bevy][bevy], [Sparkles baseline][baseline]. Revisions are recorded in the [revision ledger][ledger].

<!-- References -->

[qt]: ./qt-property-browser.md
[godot]: ./godot-inspector.md
[winforms]: ./winforms-propertygrid.md
[bevy]: ./bevy-inspector-egui.md
[unreal]: ./unreal-details-panel.md
[baseline]: ./sparkles-baseline.md
[ledger]: ./index.md#revision-ledger
[overlays]: ../anchored-overlays/index.md
[inspector]: ../../specs/ui/inspector.md
[editorspec]: ../../specs/ui/editor.md
[godot-todo]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/editor/inspector/editor_inspector.cpp#L4396
[godot-prefix]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/editor/inspector/editor_inspector.cpp#L4715
[godot-changing]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/editor/inspector/editor_inspector.cpp#L5829
[godot-filter]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/editor/inspector/editor_inspector.cpp#L4464
[godot-mne]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/editor/inspector/multi_node_edit.cpp#L144
[qt-cycle]: https://github.com/qtproject/qt-solutions/blob/777e95ba69952f11eaec0adfb0cb987fabcdecb3/qtpropertybrowser/src/qtpropertybrowser.cpp#L403
[wf-revert]: https://github.com/dotnet/winforms/blob/af0c793d58f30c92a3e42b5fabb8fee1ffe14796/src/System.Windows.Forms/System/Windows/Forms/Controls/PropertyGrid/PropertyGridInternal/PropertyGridView.cs#L5046
[bevy-constructable]: https://github.com/jakobhellermann/bevy-inspector-egui/blob/ac6729854a97a9abcd7657b29d7356bdea63c568/crates/bevy-inspector-egui/src/reflect_inspector/mod.rs#L1889
