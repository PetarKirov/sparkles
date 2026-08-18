# Godot `EditorInspector` (C++ / Godot editor)

A widget-per-property inspector with **no node model at all**: the tree is the scene graph of the panel, rebuilt wholesale whenever anything structural changes, and every piece of state that must outlive a rebuild is pushed onto the edited object.

|                        |                                                                       |
| ---------------------- | --------------------------------------------------------------------- |
| **Language / toolkit** | C++ / Godot's own `Control` toolkit                                   |
| **License**            | MIT                                                                   |
| **Repository**         | [`godotengine/godot`][repo], `editor/inspector/`                      |
| **Revision read**      | [`944a3c6c`][rev] (2026-08-18, `master`)                              |
| **Category**           | Retained widget tree, full rebuild on change                          |
| **Metadata source**    | runtime — `Object::get_property_list()` → a flat `List<PropertyInfo>` |
| **Undo**               | `EditorUndoRedoManager` transactions, with merge                      |

## Overview

### What it solves

The editor's object inspector: one panel that edits any `Object` — a `Node`, a `Resource`, a project setting, a remote debugger stand-in — plus the plugin surface (`EditorInspectorPlugin`) that lets any editor plugin insert or replace rows.

### Design philosophy

The design is visible in `update_tree()`'s first act, which is to save what it is about to destroy:

> ```cpp
> // Store currently selected and focused elements to restore after the update.
> // TODO: Can be useful to store more context for the focusable, such as the caret position in LineEdit.
> ```
>
> — [`editor_inspector.cpp:4396`][todo]

That comment is the whole architecture in two lines: because the presented tree is the widget tree and there is no model behind it, a refresh is a **teardown** (`_clear(false)`, [`editor_inspector.cpp:4424`][clear]) and everything the reader was in the middle of has to be reconstructed by hand — with the caret position acknowledged as not reconstructed at all.

## How it works

- **`EditorProperty`** ([`editor_inspector.h:70`][ep]) is a `Container` widget bound to an `(Object *object, StringName property)` pair. It is the row: label, value editor, and the revert/keying/pin/favourite affordances.
- **`EditorInspectorSection`** ([`editor_inspector.h:462`][sec]) is a foldable group header — also a widget, also rebuilt.
- **`EditorInspector`** owns `update_tree()` ([`editor_inspector.cpp:4380`][ut]), which reads the object's property list and instantiates one widget per row.
- **`EditorInspectorPlugin`** hooks the walk: `parse_begin`, `parse_category`, `parse_group`, `parse_property` (returning `true` to **replace** the default editor), `parse_end` ([`editor_inspector.cpp:1848`][plugin]).

## Model & addressing

There is no node model. The address of a row is the pair **(edited `Object`, property path string)**, held on the `EditorProperty` widget; nested rows use `/`-separated paths (`material/albedo_color`). Two consequences:

- **Rows are found by string.** `editor_property_map` maps a property path to the list of live `EditorProperty` widgets for it, which is how a value change reaches its editors ([`editor_inspector.cpp:5821`][map]).
- **Nothing survives a rebuild automatically.** Selection and focus are saved and restored explicitly around `_clear()`; expansion is not saved at all in the panel — it is read back from the **object** (below).

## Metadata

Runtime, and stringly-typed: `Object::get_property_list(&plist, true)` ([`editor_inspector.cpp:4477`][plist]) yields a flat, ordered `List<PropertyInfo>` where each entry carries `name`, `type`, `hint`, `hint_string` and a `usage` bitfield.

The **grouping is inline in that stream**, not a tree: entries whose usage has `PROPERTY_USAGE_CATEGORY`, `PROPERTY_USAGE_GROUP` or `PROPERTY_USAGE_SUBGROUP` are pseudo-rows that set the current group and a **name prefix** ([`editor_inspector.cpp:4506`][group]); subsequent properties join the group if their name `begins_with(group_base)` ([`editor_inspector.cpp:4715`][prefix]), and remaining `/`-separated path components create nested `VBoxContainer`s ([`editor_inspector.cpp:4814`][split]). The presented hierarchy is thus **reconstructed from a flat list by string prefix matching**, every rebuild.

A script can rewrite this stream per object (`_get_property_list`) and per property (`_validate_property`), so metadata is fully dynamic — the price is that it must be re-derived on every `update_tree()`.

## Recursion

**The descent decision is by `Variant` type and hint**, resolved when the row's editor is chosen. Two mechanisms produce subtrees:

1. **A nested inspector.** `EditorPropertyResource` instantiates an entire child `EditorInspector` as its "bottom editor" when the value is a valid `Resource` **and the section is unfolded**:

   ```cpp
   if (res.is_valid() && get_edited_object()->editor_is_section_unfolded(get_edited_property())) {
       if (!sub_inspector) {
           sub_inspector = memnew(EditorInspector);
   ```

   — [`editor_properties.cpp:3684`][subinsp]

   So materialization **is** lazy, and it is lazy precisely because the fold state is consulted first.

2. **A composite editor.** Vectors, transforms, arrays and dictionaries are single `EditorProperty` widgets that lay out their own sub-rows (`editor_properties_vector.cpp`, `editor_properties_array_dict.cpp`) — they are not inspector nodes at all.

**Expansion state lives on the edited object**, not the panel: `Object::editor_set_section_unfold(section, unfolded)` / `editor_is_section_unfolded(section)` ([`core/object/object.h:825`][unfold]), keyed by the section's path string. This is the load-bearing trick that makes the full-rebuild architecture survivable — and it also means fold state is serialized with the scene rather than being view state.

### Cycles

**No visited set, and no depth cap.** A self-referencing `Resource` can be unfolded as deep as the reader keeps clicking; each level is a fresh nested `EditorInspector`. The only depth-aware code is cosmetic: the sub-inspector background colour level saturates at 16 ([`editor_inspector.cpp:936`][level]). The lazy materialization is what makes this survivable — the recursion is driven by clicks, so it terminates when the reader stops.

## Editing & mutation

- **Dispatch** — plugins first (last registered wins, `can_handle(object)`, then `parse_property` may claim the row), otherwise the built-in `EditorInspectorDefaultPlugin` maps `(type, hint, hint_string)` to a concrete `EditorProperty` subclass.
- **Mutation** — a row calls `emit_changed(property, value, field, changing)` ([`editor_inspector.cpp:305`][emit]), which lands in `EditorInspector::_edit_set` ([`editor_inspector.cpp:5694`][editset]). That method creates an **undo/redo action** rather than writing the object directly:

  ```cpp
  undo_redo->create_action(vformat(TTR("Set %s"), p_name), UndoRedo::MERGE_ENDS, …);
  undo_redo->add_do_property(object, p_name, p_value);
  undo_redo->add_undo_property(object, p_name, value);
  ```

  — [`editor_inspector.cpp:5722`][undo]

  `MERGE_ENDS` is the drag story: successive sets to the same property collapse into one undo entry. Objects that opt out (`_dont_undo_redo`), multi-node edits and remote debugger objects bypass the transaction and set directly.

- **Commit semantics** — the `changing` flag is the transient/committed distinction, and its documentation states the rule:

  > The "changing" variable must be true for properties that trigger events as typing occurs, like "text_changed" signal.
  >
  > — [`editor_inspector.cpp:5829`][changing]

  While `changing > 0`, `_edit_request_change` drops incoming refresh requests ([`editor_inspector.cpp:5683`][reqchange]) — i.e. a live edit still writes through, but it suppresses the rebuild that would otherwise destroy the widget the reader is typing into. The distinction is not "don't commit yet"; it is "don't rebuild yet".

- **Change notification** — external changes mark `pending` property names or `update_tree_pending`, applied on the next process tick. There is no observer per row; the panel re-reads.
- **Validation** — none in the inspector. `Object::set` either takes the value or does not; the row shows what the object reports afterwards.

## Type coverage

- **Collections** — `EditorPropertyArray` / `EditorPropertyDictionary` provide add, remove, drag-reorder and a resize field, plus **pagination**: `page_length` comes from `interface/inspector/max_array_dictionary_items_per_page` ([`editor_properties_array_dict.cpp:1019`][page]) and rows are addressed as `index % page_length` within the current page. Element identity is positional; reordering across a page boundary flips the page ([`editor_properties_array_dict.cpp:960`][reorder]).
- **Polymorphic values** — `EditorResourcePicker` is the type picker: it offers the concrete `Resource` subclasses allowed by the property's `hint_string`, and choosing one replaces the value, after which the row's subtree is whatever the new object's property list says. There is no attempt to carry state across the change.
- **Optional / nullable** — a null `Resource` renders as an empty picker; `checkable`/`checked` rows (mostly theme overrides) are the explicit "unset vs set" case, with `autoclear` marking a property checked as soon as it is edited ([`editor_inspector.cpp:5695`][autoclear]).
- **Opaque types** — a property whose type has no editor simply gets no row; `PROPERTY_USAGE_EDITOR` gates visibility, and the walk `continue`s on anything without it.

## Presentation & control

- **Grouping / ordering** — declaration order of the property list, with category/group/subgroup pseudo-entries and `/`-path nesting, as above. Favourites can hoist rows into a pinned box.
- **Conditional visibility** — usage flags per rebuild (`_validate_property` in script), plus `_is_property_disabled_by_feature_profile` and a read-only propagation from `_is_read_only`.
- **Multi-object editing** — `MultiNodeEdit` ([`multi_node_edit.cpp`][mne]) is an `Object` façade over N nodes. Its `_get_property_list` intersects the nodes' lists, keeping only entries whose `name`, `type`, `class_name`, `hint` and `hint_string` all agree **and** that appear in every node (`nc == E->uses`, [`multi_node_edit.cpp:221`][mneisect]). Its `_get` returns **the first node's value** ([`multi_node_edit.cpp:144`][mneget]) — Godot shows no mixed-value indication at all, which is the sharpest divergence from [WinForms][winforms] and [Unreal][unreal] on this axis.
- **Search / filter** — a filter box re-runs `update_tree`, and while the filter is non-empty **folding is disabled entirely** (`use_folding = false`, [`editor_inspector.cpp:4464`][filterunfold]), so matches are always visible. Expansion state is untouched because it lives on the object.
- **Escape hatches** — `EditorInspectorPlugin` at four granularities (whole object, category, group, single property) plus `add_custom_control` for arbitrary widgets.
- **Virtualization** — none. Every visible row is a real widget; large collections are handled by paging rather than recycling.

## Strengths

- Plugin surface is genuinely open: any editor plugin can replace any row, or add rows the object never declared.
- Fold state on the object makes the full-rebuild model workable and gives "unfolded" free persistence.
- Transactional mutation with `MERGE_ENDS` gives correct undo for drags without a separate transient-edit concept.
- Lazy sub-inspectors keep deep resource graphs cheap until opened.

## Weaknesses

- A refresh destroys and rebuilds the widget tree; selection and focus are restored by hand and caret position is knowingly lost ([`editor_inspector.cpp:4396`][todo]).
- Hierarchy is recovered from a flat list by string-prefix matching, so grouping is a naming convention.
- Row addressing is by string path; nothing prevents two plugins from claiming the same path.
- No mixed-value representation in multi-object editing.
- No virtualization: a thousand-row object is a thousand `Control`s.

## Key design decisions and trade-offs

| Decision                                       | Rationale                                                      | Trade-off                                                                         |
| ---------------------------------------------- | -------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| The widget tree _is_ the tree                  | No model to keep in sync; plugins manipulate widgets directly  | Any structural change is a full rebuild; in-progress state must be saved by hand  |
| Metadata as a flat `List<PropertyInfo>` stream | One reflection call serves every object kind, scripts included | Grouping is encoded as pseudo-rows and name prefixes rather than structure        |
| Fold state stored on the edited object         | Survives the rebuild for free, persists with the scene         | View state is now object state; two panels over one object share folds            |
| Mutation via `EditorUndoRedoManager`           | Uniform undo, merging for drags                                | Every set allocates an action; objects that must bypass it need special cases     |
| `changing` counter instead of transient edits  | Live typing does not fight the rebuild                         | The value _is_ written on every keystroke; there is no rollback point             |
| Pagination instead of virtualization           | Bounded widget count with no recycling machinery               | Reordering and selection interact with pages; "the list" is never fully on screen |

## Sources

All line numbers are at [`944a3c6c`][rev].

- [`editor/inspector/editor_inspector.h`][ep], [`editor/inspector/editor_inspector.cpp`][ut] — `EditorProperty`, `EditorInspectorSection`, `update_tree`, `_edit_set`, `_property_changed`, plugin dispatch
- [`editor/inspector/editor_properties.cpp`][subinsp] — `EditorPropertyResource` and the nested inspector
- [`editor/inspector/editor_properties_array_dict.cpp`][page] — array/dictionary editing and paging
- [`editor/inspector/multi_node_edit.cpp`][mne] — the multi-selection façade
- [`core/object/object.h`][unfold] — `editor_set_section_unfold` / `editor_is_section_unfolded`

<!-- References -->

[repo]: https://github.com/godotengine/godot
[rev]: https://github.com/godotengine/godot/tree/944a3c6cbbbb88284feebcb0603464cb175fa18e
[ep]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/editor/inspector/editor_inspector.h#L70
[sec]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/editor/inspector/editor_inspector.h#L462
[ut]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/editor/inspector/editor_inspector.cpp#L4380
[todo]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/editor/inspector/editor_inspector.cpp#L4396
[clear]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/editor/inspector/editor_inspector.cpp#L4424
[plist]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/editor/inspector/editor_inspector.cpp#L4477
[group]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/editor/inspector/editor_inspector.cpp#L4506
[prefix]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/editor/inspector/editor_inspector.cpp#L4715
[split]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/editor/inspector/editor_inspector.cpp#L4814
[plugin]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/editor/inspector/editor_inspector.cpp#L1848
[map]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/editor/inspector/editor_inspector.cpp#L5821
[emit]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/editor/inspector/editor_inspector.cpp#L305
[editset]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/editor/inspector/editor_inspector.cpp#L5694
[autoclear]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/editor/inspector/editor_inspector.cpp#L5695
[undo]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/editor/inspector/editor_inspector.cpp#L5722
[changing]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/editor/inspector/editor_inspector.cpp#L5829
[reqchange]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/editor/inspector/editor_inspector.cpp#L5683
[filterunfold]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/editor/inspector/editor_inspector.cpp#L4464
[level]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/editor/inspector/editor_inspector.cpp#L936
[subinsp]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/editor/inspector/editor_properties.cpp#L3684
[page]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/editor/inspector/editor_properties_array_dict.cpp#L1019
[reorder]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/editor/inspector/editor_properties_array_dict.cpp#L960
[mne]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/editor/inspector/multi_node_edit.cpp
[mneisect]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/editor/inspector/multi_node_edit.cpp#L221
[mneget]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/editor/inspector/multi_node_edit.cpp#L144
[unfold]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/core/object/object.h#L825
[winforms]: ./winforms-propertygrid.md
[unreal]: ./unreal-details-panel.md
