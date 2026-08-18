# Concepts

The vocabulary the deep-dives use, defined once. Each term is grounded in at least one surveyed implementation, so a definition can be checked rather than argued about.

**Last reviewed:** August 18, 2026

---

## Structure

### Subject

The value being edited. A `UObject` in [Unreal][unreal], an `Object` in [Godot][godot], one or more `object`s in [WinForms][winforms], a `&mut dyn PartialReflect` in [bevy][bevy], and — in [Qt's property browser][qt] — nothing at all, because the model _is_ the subject.

### Model node vs presented node

A **model node** is an element of whatever structure the library keeps; a **presented node** is one row on screen. The corpus's cleanest statement of the difference is Qt's: a `QtProperty` is a model node, a `QtBrowserItem` is one _occurrence_ of it in one browser, and `items(property)` returns a list because a property may be shown several times ([`qtpropertybrowser.h:215`][qtitem]).

Three of five subjects collapse the two: [Godot's][godot] presented node is a widget, [bevy's][bevy] is a stack frame, and [WinForms'][winforms] `GridEntry` is both at once.

### Node address

Whatever the library uses to say "this node" across time. Five distinct answers appear:

| Address                               | Subject              | Survives a rebuild by                                     |
| ------------------------------------- | -------------------- | --------------------------------------------------------- |
| pointer to a model node               | [Qt][qt]             | there being no rebuild                                    |
| `(object, property path string)`      | [Godot][godot]       | re-lookup; the panel restores selection and focus by hand |
| entry object, re-matched structurally | [WinForms][winforms] | `EqualsIgnoreParent` comparison of freshly built children |
| handle (`IPropertyHandle`)            | [Unreal][unreal]     | the handle itself, with `IsValidHandle()` to ask          |
| hashed structural path (`egui::Id`)   | [bevy][bevy]         | being recomputed identically next frame                   |

### Descent decision

The predicate that answers "is this value a leaf, or a subtree?". Type-driven ([Godot][godot]: `Variant` type + hint), converter-driven ([WinForms][winforms]: `TypeConverter.GetPropertiesSupported`), discriminant-driven ([bevy][bevy]: `ReflectMut::Struct` vs `Opaque`), manager-driven ([Qt][qt]: `hasValue()`), or — in D — a compile-time `static if` over `isAggregateType`, demonstrated in [`reflect-descent.d`](./examples/reflect-descent.d).

### Materialisation

When the children of an expandable node come into existence. **Eager** ([Qt][qt] builds the whole browser-item tree at insert), **lazy on expand** ([WinForms][winforms] `GridEntry.Children`; [Godot's][godot] sub-inspector, which checks the fold state first), or **per frame while visible** ([bevy][bevy], where a closed region simply does not execute).

### Cut

Stopping a descent that would not terminate. A **visited set** over values (nobody in the corpus), over types (the D compile-time walk must, or the build fails), a **depth cap** (nobody, except [Godot's][godot] purely cosmetic colour level), or nothing at all plus the observation that recursion is user-driven ([Godot][godot], [WinForms][winforms]).

---

## Metadata

### Metadata channel

Where per-field facts other than the type come from: .NET attributes read through `TypeDescriptor` ([WinForms][winforms]), a `PropertyInfo` hint/hint-string/usage triple ([Godot][godot]), a string map (`UPROPERTY(meta=…)`, [Unreal][unreal]), a type registry of arbitrary option objects ([bevy][bevy]), or D UDAs — the only compile-time member of the family ([`uda-metadata.d`](./examples/uda-metadata.d)).

### Static vs value-dependent metadata

A label, a group and a range are functions of the **type**; "show this field only when that one is `gradient`" is a function of the **value**. Runtime channels blur the two ([Godot's][godot] `_validate_property` rewrites usage flags per rebuild); a compile-time channel cannot, so a value-dependent condition has to be carried as data and evaluated per frame.

### Descriptor

A runtime object standing for one field: `PropertyDescriptor` ([WinForms][winforms]), `PropertyInfo` ([Godot][godot]), `FProperty` ([Unreal][unreal]). D has no runtime equivalent; the nearest thing is a value computed in CTFE, which is a different object with a different lifetime.

---

## Editing

### Editor dispatch

Mapping a value to the widget that edits it. **Factory bound to a manager** ([Qt][qt]), **registry keyed by concrete type** ([bevy][bevy]'s `InspectorEguiImpl`), **converter plus `UITypeEditor`, overridable per property** ([WinForms][winforms]), **plugin chain with last-registered-wins** ([Godot's][godot] `EditorInspectorPlugin`).

### Mutation ownership

Who writes the value. **Direct in place** ([bevy][bevy]: `&mut`), **through the model's setter** ([Qt][qt]: the factory calls `manager->setValue`), **through a transaction** ([Godot][godot]: `EditorUndoRedoManager`; [WinForms][winforms]: `IDesignerHost.CreateTransaction`), or **through a mediating handle that owns the protocol** ([Unreal][unreal]: `SetValue` performs the transaction and notification itself).

### Transient vs committed edit

A slider mid-drag and a slider released are different events. [Unreal][unreal] separates them at the API (`SetValue` flags plus `NotifyFinishedChangingProperties`); [Godot][godot] has a `changing` flag whose meaning is narrower than it looks — the value _is_ written on every keystroke, and the flag only suppresses the rebuild that would destroy the widget being typed into ([`editor_inspector.cpp:5829`][changing]); [Godot's][godot] undo merging (`UndoRedo::MERGE_ENDS`) recovers the drag case for undo purposes only. [Qt][qt] and [bevy][bevy] have no such concept.

### Commit point

When typed text becomes a value. Per keystroke ([Qt][qt], [bevy][bevy]) or on commit with conversion and failure handling ([WinForms][winforms]: `ConvertTextToValue` at commit, a modal error dialog, and the reader's text preserved unless they choose to revert).

### Write-back through an immutable parent

Editing `size.width` when `size` is a value type. [WinForms][winforms] models it explicitly: children of a `GetCreateInstanceSupported` value become `ImmutablePropertyDescriptorGridEntry`, and `[NotifyParentProperty]` makes the change walk up to the owner that can be re-assigned. Getting this wrong is silent: the edit appears to happen and does not reach the object.

---

## Presentation

### Mixed value

What a row shows when the selected objects disagree. Blank ([WinForms][winforms], driven by `allEqual == false`), a per-object list the customizer may render however it likes ([Unreal][unreal]'s `GetPerObjectValues`), or **the first object's value with no indication at all** ([Godot][godot], [`multi_node_edit.cpp:144`][mne]).

### Restriction

A value that is present but unavailable, with a reason. [Unreal][unreal] has `IsRestricted`/`IsHidden`/`IsDisabled` with `OutReasons`; [bevy][bevy] reaches the same effect for variants by disabling unconstructable ones and explaining on hover. Distinct from hiding the whole row.

### Constructability

Whether a variant or element can be created blank. In Rust it is a registry question (`ReflectDefault`, [bevy][bevy]); in D almost every type has `.init`, and the residual case is an author's `@disable this()` — measured in [`sumtype-variants.d`](./examples/sumtype-variants.d).

### Virtualization vs pagination

Rendering only visible rows while the model holds all of them ([WinForms][winforms]'s `_visibleRows`; `sparkles:ui`'s `viewSlice`), versus showing a fixed-size window of a collection with page controls ([Godot][godot]'s `max_array_dictionary_items_per_page`). Pagination is what a widget-per-row architecture reaches for when virtualization is unavailable.

<!-- References -->

[qt]: ./qt-property-browser.md
[godot]: ./godot-inspector.md
[winforms]: ./winforms-propertygrid.md
[bevy]: ./bevy-inspector-egui.md
[unreal]: ./unreal-details-panel.md
[qtitem]: https://github.com/qtproject/qt-solutions/blob/777e95ba69952f11eaec0adfb0cb987fabcdecb3/qtpropertybrowser/src/qtpropertybrowser.h#L215
[changing]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/editor/inspector/editor_inspector.cpp#L5829
[mne]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/editor/inspector/multi_node_edit.cpp#L144
