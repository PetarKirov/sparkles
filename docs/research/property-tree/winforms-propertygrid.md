# WinForms `PropertyGrid` (C# / .NET)

The one subject where **nesting is not the grid's job**: whether a value has children, what those children are, and how a child writes back are all answered by the value's `TypeConverter`. The grid itself is a single owner-drawn control with one shared edit box.

|                        |                                                                                                |
| ---------------------- | ---------------------------------------------------------------------------------------------- |
| **Language / toolkit** | C# / Windows Forms                                                                             |
| **License**            | MIT                                                                                            |
| **Repository**         | [`dotnet/winforms`][repo], `src/System.Windows.Forms/…/PropertyGrid/`                          |
| **Revision read**      | [`af0c793d`][rev] (2026-08-15, `main`)                                                         |
| **Category**           | Retained entry model, converter-driven recursion                                               |
| **Metadata source**    | runtime — `TypeDescriptor` (attributes, `PropertyDescriptor`, `TypeConverter`, `UITypeEditor`) |
| **Undo**               | delegated to the designer host (`IDesignerHost.CreateTransaction`)                             |

## Overview

### What it solves

The Visual Studio properties window, as a reusable control: point it at any object (or an array of objects) and it renders an editable, categorised, expandable grid, with the whole customization story expressed as **attributes and converters on the model types** rather than as grid API.

### Design philosophy

The grid's own documentation for the entry type states the delegation plainly — a `GridEntry` asks the converter both whether it can expand and what to expand into:

> ```csharp
> if (this is not IRootGridEntry && !TypeConverter.GetPropertiesSupported(this))
> {
>     // We can't get properties on this sub entry.
>     return null;
> }
> ```
>
> — [`GridEntry.cs:1283`][nochild]

## How it works

- **`GridEntry`** ([`GridEntry.cs`][ge]) is the node: label, value access, flags, children, expansion. `PropertyDescriptorGridEntry` binds one to a `PropertyDescriptor`; `CategoryGridEntry`, `ArrayElementGridEntry`, `ImmutablePropertyDescriptorGridEntry` and `MultiPropertyDescriptorGridEntry` specialise it.
- **`PropertyGridView`** ([`PropertyGridView.cs`][pgv]) is the drawing surface: it owns `_visibleRows` ([`PropertyGridView.cs:66`][rows]), a scrollbar, **one** `GridViewTextBox`, one drop-down holder and one listbox, reused for whichever row is selected.
- **`GridItem`** is the public read-only projection of a `GridEntry` — the API a caller navigates.
- **`TypeConverter` / `UITypeEditor` / attributes** are the extension surface, resolved through `TypeDescriptor`.

## Model & addressing

The tree is a **retained entry model** rebuilt from the root when the selection or a `[RefreshProperties]` write demands it, and rendered by a single control that owns no per-row widgets.

Addressing is by **entry object**, but the interesting part is what happens across a refresh: `CreateChildren(useExistingChildren: true)` recomputes the child entries and compares them pairwise with `EqualsIgnoreParent`, keeping the existing collection when they match ([`GridEntry.cs:915`][createchildren]). Identity is therefore reconstructed by **structural equality of descriptor + label**, not by a path or a handle — which is exactly enough to preserve expansion, and not enough to preserve anything the entry does not carry.

`GridEntry.Children` materialises lazily on first access ([`GridEntry.cs:194`][children]), and `InternalExpanded`'s setter builds children the first time a row is opened ([`GridEntry.cs:320`][expandset]).

## Metadata

`TypeDescriptor`, i.e. **runtime attributes with a provider indirection**. The relevant vocabulary is read once per entry into a flags bitfield ([`GridEntry.cs:345`][flags]):

| Source                                                                      | Effect                                                          |
| --------------------------------------------------------------------------- | --------------------------------------------------------------- |
| `converter.GetStandardValuesSupported`                                      | drop-down of standard values                                    |
| `converter.CanConvertFrom(string)` + `!GetStandardValuesExclusive`          | the row is text-editable                                        |
| `[ImmutableObject]` or `converter.GetCreateInstanceSupported`               | the value is immutable — child edits recreate the parent        |
| `converter.GetPropertiesSupported`                                          | **the row is expandable** ([`GridEntry.cs:385`][expandable])    |
| `[PasswordPropertyText]`                                                    | render masked                                                   |
| `editor.GetEditStyle`                                                       | modal `…` button or drop-down button                            |
| `[Browsable]`, `[Category]`, `[DisplayName]`, `[Description]`, `[ReadOnly]` | visibility, grouping, labels, help pane                         |
| `[Editor]`, `[TypeConverter]`                                               | override the resolved editor/converter for a type or a property |
| `[NotifyParentProperty]`, `[RefreshProperties]`                             | write-back propagation and rebuild policy                       |

Because `TypeDescriptor` is a provider chain, a type can supply an entirely synthetic property list at runtime (`ICustomTypeDescriptor`), which is how designers surface properties the CLR type does not have.

## Recursion

**Converter-driven, and the converter also supplies the children.** `GetPropertiesSupported()` decides expandability; `TypeConverter.GetProperties(this, value, attributes)` returns the child `PropertyDescriptor`s ([`GridEntry.cs:1299`][getprops]). `ExpandableObjectConverter` is nothing but the default "yes, and here are my public properties" implementation — nesting is opt-in **per type on the model side**, invisible to the grid.

Two structural cases are handled outside the converter:

- **Arrays** — when a value is an array and no properties came back, the grid synthesises one `ArrayElementGridEntry` per element ([`GridEntry.cs:1337`][arrays]).
- **Immutable values** — when `GetCreateInstanceSupported` is true the children are `ImmutablePropertyDescriptorGridEntry` ([`GridEntry.cs:1376`][immutable]), because writing a child of a `struct`-like value cannot mutate in place; the parent value must be rebuilt and re-assigned.

The write-back path for those nested values is `[NotifyParentProperty]`: after a successful set, `NotifyParentsOfChanges` walks **up** the entry chain while each entry carries the attribute, firing the change on the owner it finds ([`PropertyDescriptorGridEntry.cs:357`][notifyparent]). Without that attribute on the child property, editing `Size.Width` silently fails to reach the object — a genuine, documented-by-behaviour footgun of the design.

Materialisation is **lazy on expand**, and a set that could invalidate children disposes and recreates them, preserving the expanded state:

```csharp
bool needsRefresh = wasExpanded || (refresh is not null && !refresh.RefreshProperties.Equals(RefreshProperties.None));
if (needsRefresh) { DisposeChildren(); }
```

— [`PropertyDescriptorGridEntry.cs:609`][refresh]

### Cycles

**No visited set and no depth cap were found in the surveyed sources.** The structural protections are indirect: recursion is user-driven (children exist only once a row is expanded), and the default converter for a reference type does not report `GetPropertiesSupported` unless the type opts in via `[TypeConverter(typeof(ExpandableObjectConverter))]`. A type that opts in _and_ holds a reference to itself can be expanded indefinitely, one click per level — the same posture as [Godot][godot]. _(Verified by reading `GridEntry`/`PropertyDescriptorGridEntry`; not exercised at runtime.)_

## Editing & mutation

- **Dispatch** — `UITypeEditor` first (per-property `[Editor]`, else `TypeDescriptor.GetEditor(PropertyType)` [`GridEntry.cs:769`][geteditor]); then standard values → drop-down list; then `CanConvertFrom(string)` → the shared text box; otherwise read-only text from `converter.ConvertToString`.
- **Commit** — text is converted at commit, not per keystroke: `CommitText` calls `ConvertTextToValue` ([`PropertyGridView.cs:4769`][converttext]) and on failure sets an error state, shows a modal dialog and **returns false**, blocking the navigation that triggered it. The dialog's `Cancel` reverts; anything else leaves the reader in the edit box with their text intact ([`PropertyGridView.cs:5046`][revert]). `EnsurePendingChangesCommitted` ([`PropertyGridView.cs:1511`][ensure]) is the public "flush the in-progress edit" hook.
- **Transactions and undo** — the grid does not implement undo; it opens a **designer transaction** if a host is available and lets the designer record it:

  ```csharp
  transaction = host?.CreateTransaction(undoText ?? string.Format(SR.PropertyGridSetValue, PropertyDescriptor.Name));
  ```

  — [`PropertyDescriptorGridEntry.cs:570`][transaction]

  It also brackets the write with `IComponentChangeService.OnComponentChanging`/`OnComponentChanged` for objects the descriptor will not notify itself.

- **Change notification** — push, via `IComponentChangeService`, plus the explicit `Refresh()` paths driven by `[RefreshProperties]`. There is no polling.
- **Validation** — lives in the converter (`ConvertFrom` throws) and in the property setter (any exception). The grid's contribution is the error dialog and the "stay in the editor" behaviour.

## Type coverage

- **Collections** — arrays get index rows; anything richer is a `UITypeEditor` (the classic `CollectionEditor` modal dialog), i.e. **the grid delegates collection editing out of the tree entirely**.
- **Polymorphic values** — no type picker. A property whose static type is a base class shows the runtime value's converter-supplied properties; changing the concrete type is a job for a `UITypeEditor` or a converter's standard values.
- **Optional / nullable** — no first-class unset; `ResetValue`/`CanResetValue` and `[DefaultValue]` provide "back to default" (bold rendering marks non-default), which is a different question.
- **Opaque types** — a value whose converter cannot convert to string and has no editor renders the type name and is not editable; a property whose getter throws is **hidden** rather than shown as an error ([`GridEntry.cs:1358`][hide]).

## Presentation & control

- **Grouping / ordering** — `[Category]` produces `CategoryGridEntry` headers; `PropertySort` chooses alphabetical, categorised, or both, with "paren" properties (e.g. `(Name)`) sorted first.
- **Conditional visibility** — `[Browsable(false)]` hides; `[ReadOnly]` and inherited-read-only mark non-editable; anything dynamic requires a custom `TypeDescriptionProvider`.
- **Multi-object editing** — first-class, and the most complete in the corpus. `PropertyMerger.GetMergedProperties` ([`MultiSelectRootGridEntry.PropertyMerger.cs:14`][merger]) intersects the selected objects' descriptors, and `MergePropertyDescriptor.GetValue(components, out bool allEqual)` ([`MergePropertyDescriptor.cs:200`][merge]) returns `null` with `allEqual == false` when they disagree. The row then renders **blank**:

  ```csharp
  if (value is null && _mergedDescriptor.GetValue(_objects, out bool allEqual) is null && !allEqual)
  {
      return string.Empty;
  ```

  — [`MultiPropertyDescriptorGridEntry.cs:168`][mixed]

  Writing sets every object; collections are merged through a `MultiMergeCollection` that reinitialises when the sets differ.

- **Search / filter** — none.
- **Escape hatches**, in increasing scope: `[Editor]` on one property → `UITypeEditor` for a type → `[TypeConverter]` (changes the string form _and_ the children) → `ICustomTypeDescriptor`/`TypeDescriptionProvider` (changes the property list itself) → `PropertyTab` (a whole alternative page of properties).
- **Virtualization** — real: rows are painted from the entry list against `_visibleRows` and a scroll offset, and the only live editing widgets are the single text box, the single drop-down holder and the single listbox. A thousand-row object costs a thousand entries, not a thousand controls.

## Strengths

- Nesting, editing and string conversion are all attributes of the **model type**, so a value type is inspectable everywhere without the grid knowing it exists.
- Genuine row virtualization with one shared editor — the cheapest presentation in the corpus.
- Multi-object editing with an explicit mixed-value answer (`allEqual`).
- Undo delegated to a host transaction rather than reinvented.
- Failure paths are considered: getter exceptions hide rows, conversion failures keep the reader's text.

## Weaknesses

- The converter indirection is powerful but obscure: `GetPropertiesSupported`, `GetCreateInstanceSupported` and `[NotifyParentProperty]` must line up or nested edits silently do nothing.
- No filter, no polymorphic type picker, no collection editing inside the tree.
- Identity across refresh is structural equality, so anything not encoded in the entry (caret, scroll inside a drop-down) is lost.
- `PropertyGridView.cs` is 5,431 lines with the row model, hit-testing, drawing, accessibility and the message hook interleaved — the seam is clean at the model boundary and absent inside the view.

## Key design decisions and trade-offs

| Decision                                                              | Rationale                                                                | Trade-off                                                                 |
| --------------------------------------------------------------------- | ------------------------------------------------------------------------ | ------------------------------------------------------------------------- |
| Expandability answered by `TypeConverter`                             | Any type can become a subtree without touching the grid                  | The decision is far from the grid; misconfiguration looks like a grid bug |
| Children supplied by the converter too                                | The same hook that formats a value describes its parts                   | Two unrelated concerns ride one interface                                 |
| Immutable values get their own entry class + `[NotifyParentProperty]` | Struct-like values can be edited through their parts                     | Forgetting the attribute silently drops the edit                          |
| Single control, shared editor, `_visibleRows`                         | Thousands of rows cost no widgets                                        | All hit-testing, drawing and input handling is bespoke                    |
| Undo via `IDesignerHost` transaction                                  | The designer already owns the undo stack                                 | Outside a designer host there is no undo at all                           |
| Multi-select via merged descriptors                                   | The rest of the grid is unchanged — it still sees one descriptor per row | Merged values need their own collection and event special cases           |

## Sources

All line numbers are at [`af0c793d`][rev].

- [`PropertyGridInternal/GridEntry.cs`][ge] — the node, flags, lazy children, converter-driven descent, array and immutable child entries
- [`PropertyGridInternal/PropertyDescriptorGridEntry.cs`][pdge] — set path, designer transaction, `[NotifyParentProperty]` walk, `[RefreshProperties]`
- [`PropertyGridInternal/PropertyGridView.cs`][pgv] — visible-row rendering, the shared edit box, commit and the error dialog
- [`PropertyGridInternal/MergePropertyDescriptor.cs`][merge], [`MultiPropertyDescriptorGridEntry.cs`][mixed], [`MultiSelectRootGridEntry.PropertyMerger.cs`][merger] — multi-object editing

<!-- References -->

[repo]: https://github.com/dotnet/winforms
[rev]: https://github.com/dotnet/winforms/tree/af0c793d58f30c92a3e42b5fabb8fee1ffe14796
[ge]: https://github.com/dotnet/winforms/blob/af0c793d58f30c92a3e42b5fabb8fee1ffe14796/src/System.Windows.Forms/System/Windows/Forms/Controls/PropertyGrid/PropertyGridInternal/GridEntry.cs
[children]: https://github.com/dotnet/winforms/blob/af0c793d58f30c92a3e42b5fabb8fee1ffe14796/src/System.Windows.Forms/System/Windows/Forms/Controls/PropertyGrid/PropertyGridInternal/GridEntry.cs#L194
[expandset]: https://github.com/dotnet/winforms/blob/af0c793d58f30c92a3e42b5fabb8fee1ffe14796/src/System.Windows.Forms/System/Windows/Forms/Controls/PropertyGrid/PropertyGridInternal/GridEntry.cs#L320
[flags]: https://github.com/dotnet/winforms/blob/af0c793d58f30c92a3e42b5fabb8fee1ffe14796/src/System.Windows.Forms/System/Windows/Forms/Controls/PropertyGrid/PropertyGridInternal/GridEntry.cs#L345
[expandable]: https://github.com/dotnet/winforms/blob/af0c793d58f30c92a3e42b5fabb8fee1ffe14796/src/System.Windows.Forms/System/Windows/Forms/Controls/PropertyGrid/PropertyGridInternal/GridEntry.cs#L385
[geteditor]: https://github.com/dotnet/winforms/blob/af0c793d58f30c92a3e42b5fabb8fee1ffe14796/src/System.Windows.Forms/System/Windows/Forms/Controls/PropertyGrid/PropertyGridInternal/GridEntry.cs#L769
[createchildren]: https://github.com/dotnet/winforms/blob/af0c793d58f30c92a3e42b5fabb8fee1ffe14796/src/System.Windows.Forms/System/Windows/Forms/Controls/PropertyGrid/PropertyGridInternal/GridEntry.cs#L915
[nochild]: https://github.com/dotnet/winforms/blob/af0c793d58f30c92a3e42b5fabb8fee1ffe14796/src/System.Windows.Forms/System/Windows/Forms/Controls/PropertyGrid/PropertyGridInternal/GridEntry.cs#L1283
[getprops]: https://github.com/dotnet/winforms/blob/af0c793d58f30c92a3e42b5fabb8fee1ffe14796/src/System.Windows.Forms/System/Windows/Forms/Controls/PropertyGrid/PropertyGridInternal/GridEntry.cs#L1299
[arrays]: https://github.com/dotnet/winforms/blob/af0c793d58f30c92a3e42b5fabb8fee1ffe14796/src/System.Windows.Forms/System/Windows/Forms/Controls/PropertyGrid/PropertyGridInternal/GridEntry.cs#L1337
[hide]: https://github.com/dotnet/winforms/blob/af0c793d58f30c92a3e42b5fabb8fee1ffe14796/src/System.Windows.Forms/System/Windows/Forms/Controls/PropertyGrid/PropertyGridInternal/GridEntry.cs#L1358
[immutable]: https://github.com/dotnet/winforms/blob/af0c793d58f30c92a3e42b5fabb8fee1ffe14796/src/System.Windows.Forms/System/Windows/Forms/Controls/PropertyGrid/PropertyGridInternal/GridEntry.cs#L1376
[pdge]: https://github.com/dotnet/winforms/blob/af0c793d58f30c92a3e42b5fabb8fee1ffe14796/src/System.Windows.Forms/System/Windows/Forms/Controls/PropertyGrid/PropertyGridInternal/PropertyDescriptorGridEntry.cs
[notifyparent]: https://github.com/dotnet/winforms/blob/af0c793d58f30c92a3e42b5fabb8fee1ffe14796/src/System.Windows.Forms/System/Windows/Forms/Controls/PropertyGrid/PropertyGridInternal/PropertyDescriptorGridEntry.cs#L357
[transaction]: https://github.com/dotnet/winforms/blob/af0c793d58f30c92a3e42b5fabb8fee1ffe14796/src/System.Windows.Forms/System/Windows/Forms/Controls/PropertyGrid/PropertyGridInternal/PropertyDescriptorGridEntry.cs#L570
[refresh]: https://github.com/dotnet/winforms/blob/af0c793d58f30c92a3e42b5fabb8fee1ffe14796/src/System.Windows.Forms/System/Windows/Forms/Controls/PropertyGrid/PropertyGridInternal/PropertyDescriptorGridEntry.cs#L609
[pgv]: https://github.com/dotnet/winforms/blob/af0c793d58f30c92a3e42b5fabb8fee1ffe14796/src/System.Windows.Forms/System/Windows/Forms/Controls/PropertyGrid/PropertyGridInternal/PropertyGridView.cs
[rows]: https://github.com/dotnet/winforms/blob/af0c793d58f30c92a3e42b5fabb8fee1ffe14796/src/System.Windows.Forms/System/Windows/Forms/Controls/PropertyGrid/PropertyGridInternal/PropertyGridView.cs#L66
[ensure]: https://github.com/dotnet/winforms/blob/af0c793d58f30c92a3e42b5fabb8fee1ffe14796/src/System.Windows.Forms/System/Windows/Forms/Controls/PropertyGrid/PropertyGridInternal/PropertyGridView.cs#L1511
[converttext]: https://github.com/dotnet/winforms/blob/af0c793d58f30c92a3e42b5fabb8fee1ffe14796/src/System.Windows.Forms/System/Windows/Forms/Controls/PropertyGrid/PropertyGridInternal/PropertyGridView.cs#L4769
[revert]: https://github.com/dotnet/winforms/blob/af0c793d58f30c92a3e42b5fabb8fee1ffe14796/src/System.Windows.Forms/System/Windows/Forms/Controls/PropertyGrid/PropertyGridInternal/PropertyGridView.cs#L5046
[merge]: https://github.com/dotnet/winforms/blob/af0c793d58f30c92a3e42b5fabb8fee1ffe14796/src/System.Windows.Forms/System/Windows/Forms/Controls/PropertyGrid/PropertyGridInternal/MergePropertyDescriptor.cs#L200
[mixed]: https://github.com/dotnet/winforms/blob/af0c793d58f30c92a3e42b5fabb8fee1ffe14796/src/System.Windows.Forms/System/Windows/Forms/Controls/PropertyGrid/PropertyGridInternal/MultiPropertyDescriptorGridEntry.cs#L168
[merger]: https://github.com/dotnet/winforms/blob/af0c793d58f30c92a3e42b5fabb8fee1ffe14796/src/System.Windows.Forms/System/Windows/Forms/Controls/PropertyGrid/PropertyGridInternal/MultiSelectRootGridEntry.PropertyMerger.cs#L14
[godot]: ./godot-inspector.md
