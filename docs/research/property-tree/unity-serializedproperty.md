# Unity `SerializedObject` / `SerializedProperty` (C# / Unity Editor)

The corpus's sixth addressing model — a **mutable cursor** over a serialized mirror, not a node — and the only subject with a runtime **visited set** for cycles.

|                        |                                                                                                  |
| ---------------------- | ------------------------------------------------------------------------------------------------ |
| **Language / toolkit** | C# / Unity's IMGUI (`EditorGUI`) and UIElements                                                  |
| **License**            | Unity Reference-Only License — "May be used for reference purposes only" ([`README.md`][readme]) |
| **Repository**         | [`Unity-Technologies/UnityCsReference`][repo] (Unity 6000.7.0a4)                                 |
| **Revision read**      | [`225b0fbd`][rev] (2026-08-06)                                                                   |
| **Category**           | Serialized mirror + cursor; retained drawer objects                                              |
| **Metadata source**    | runtime — the serialization system, plus C# attributes resolved into drawers                     |
| **Undo**               | automatic on `ApplyModifiedProperties()`                                                         |

> [!IMPORTANT]
> **Scope: the managed layer only.** This repository is the published C# half of the
> editor; the native implementation behind every `extern` declaration is not in it. Where
> a behaviour is `[NativeName]`-bound (`NextVisible`, `HasMultipleDifferentValues`,
> `GetIsExpanded`, …) this page reports the **contract the C# layer states** and marks
> anything beyond it as **INFERENCE**. Unity was added in the Tier-2 pass specifically to
> get a source-readable subject on the axes where [Unreal][unreal] could only be read from
> documentation.

## Overview

### What it solves

The Inspector: an editor over one **or many** selected objects, driven by the same
serialization system that writes scenes and prefabs to disk, with per-type and
per-attribute customization (`PropertyDrawer`) and full undo integration.

### Design philosophy

The inspector never touches the target object's fields. It edits a **serialized mirror**
that is pulled before drawing and pushed after:

```csharp
SerializedProperty property = obj.GetIterator();
bool expanded = true;
while (property.NextVisible(expanded))
{
    using (new EditorGUI.DisabledScope("m_Script" == property.propertyPath))
        EditorGUILayout.PropertyField(property, true);
    expanded = false;
}
obj.ApplyModifiedProperties();
```

— [`Editor.cs:862`][defaultinspector]

Two things in that loop are unlike anything in the Tier-1 corpus. The tree is walked by a
**single mutable cursor** (`NextVisible(enterChildren)`), and the whole frame's edits are
committed by one call at the end.

## Model & addressing

`SerializedProperty` is an **iterator**, and the C# doc comment says so where it hands out
copies:

> Returns a copy of the SerializedProperty iterator in its current state. This is useful if
> you want to keep a reference to the current property but continue with the iteration.
>
> — [`SerializedProperty.bindings.cs:243`][copy]

The consequences run through the whole design:

- **Advancing is the walk.** `NextVisible(bool enterChildren)` ([`:522`][nextvisible]) moves
  the cursor through the _visible_ sequence — it skips the children of a collapsed row, so
  laziness is a property of the traversal rather than of a materialisation step. `depth`
  reports the nesting level, and `GetEndProperty()` bounds a subtree.
- **A durable address is a string.** `propertyPath` ([`:728`][path]) is the persistent
  identity (`materials.Array.data[2].shader`), cached against a native hash so it is only
  re-fetched when it actually changed. `FindPropertyRelative(string)` ([`:254`][relative])
  navigates by that path, `Copy()` snapshots the cursor.
- **Anything per-row is a side table keyed by that path.** The reorderable-list wrappers are
  a static dictionary keyed by `ReorderableListWrapper.GetPropertyIdentifier(property)`
  ([`PropertyHandler.cs:49`][lists]).

So Unity separates what [Unreal][unreal] fuses into one handle: the _cursor_ is cheap and
transient, the _path string_ is the identity, and `serializedObject` ([`:151`][so]) is the
mediated access. It is the same three jobs, unbundled.

## Metadata

Runtime, from two sources. The serialization system supplies the structure and the
`SerializedPropertyType` discriminant (`Integer`, `ObjectReference`, `ManagedReference`, …,
[`:85`][mrtype]); C# attributes supply presentation and are resolved into **drawer types**
through a lazily-built dictionary, `k_DrawerTypeForType`
([`ScriptAttributeUtility.cs:49`][drawerdict], built at [`:125`][builddict]).

Resolution ([`GetDrawerTypeForType`, `:164`][getdrawer]) walks the type's base chain and then
its interfaces, honouring `useForChildren` on `[CustomPropertyDrawer]` — with a documented
exception for managed references, whose _dynamic_ type is only known at runtime:

> The custom property drawers for those are defined with 'useForChildren=false' … so even if
> 's_DrawerTypeForType' is built (based on static types)
>
> — [`ScriptAttributeUtility.cs:316`][useforchildren]

## Recursion

**Descent is the cursor's `enterChildren` flag**, and expansion decides it. Two mechanisms
then matter more than the walk itself.

**Expansion lives in the serialized data.** `isExpanded` is a property _of the
`SerializedProperty`_ ([`:926`][isexpanded]), backed by native `GetIsExpanded`/`SetIsExpanded`
— not by the window, not by a view-side set. This is [Godot's][godot] "fold state on the
edited object" taken one step further: in Unity the fold state is part of the object's
serialized representation, so it survives a rebuild, a re-selection and a domain reload for
free. **INFERENCE:** where it is persisted (scene file, editor-local database) is native and
not visible here.

**Nesting is capped by the drawer list.** `PropertyHandler` holds a _list_ of drawers indexed
by nesting level, and returns `null` past its end:

```csharp
internal PropertyDrawer propertyDrawer
{
    get
    {
        if (m_PropertyDrawers == null || m_NestingLevel >= m_PropertyDrawers.Count)
            return null;
        return m_PropertyDrawers[m_NestingLevel];
    }
}
```

— [`PropertyHandler.cs:30`][nesteddrawer]

Every drawer invocation is wrapped in `IncrementNestingContext()`
([`PropertyHandler.cs:251`][nesting]), so a drawer that draws the same type again does **not**
re-enter itself: the next level either uses the next registered drawer or falls back to the
default field. That is a real, deliberate recursion guard — a per-type customization cannot
loop forever by drawing itself.

### Cycles

Unity has the **only runtime visited set in the corpus**, and its placement is the finding:

```csharp
// Managed reference objects can form a cyclical graph, so need to track visited objects
if (visited == null)
    visited = new HashSet<long>();
long refId = search.managedReferenceId;
if (!visited.Add(refId))
{
    visitChild = false;
    continue;
}
```

— [`EditorGUI.cs:7841`][visited], inside `SetExpandedRecurse` ([`:7832`][setexpanded])

It guards `SetExpandedRecurse` — **expand-all**, an _automatic_ walk — not painting. Painting
stays click-driven and needs no guard, exactly as in [Godot][godot] and [WinForms][winforms].
The rule the corpus was missing is therefore not "reflective editors need a visited set"; it
is **"a walk the user does not drive needs a visited set, and a walk they do drive does
not."** `[SerializeReference]` graphs are where Unity has to pay it, because those are the
only serialized values that can alias.

## Editing & mutation

- **Dispatch** — `PropertyHandler.OnGUI` ([`:210`][onguigui]): decorator drawers first
  (`[Header]`, `[Space]`), then a `PropertyDrawer` if one resolved for the type or the
  attribute, then a reorderable list for arrays, then `EditorGUI.DefaultPropertyField`
  ([`EditorGUI.cs:7944`][defaultfield]). A drawer returning nothing collapses to the default —
  there is no error state for an unhandled type.
- **Mutation** — writes land in the mirror, not the object. The commit boundary is
  `SerializedObject.ApplyModifiedProperties()` ([`SerializedObject.bindings.cs:122`][apply]),
  which is also where **undo is registered**; `ApplyModifiedPropertiesWithoutUndo()`
  ([`:180`][applynoundo]) is the explicit opt-out. The pull direction is `Update()`
  ([`:131`][update]) / `UpdateIfRequiredOrScript()`.
- **Commit semantics** — per frame, not per keystroke: the IMGUI loop reads, draws, and
  applies once. The transient/committed distinction is absent from this layer (no equivalent
  of [Unreal's][unreal] `InteractiveChange`); the merge is instead a property of the undo
  system's recording. **INFERENCE**, since that machinery is native.
- **Change notification** — none needed: `Update()` re-pulls the mirror every frame, so an
  external write appears on the next repaint. `SetIsDifferentCacheDirty()` ([`:125`][dirty])
  invalidates the multi-object comparison cache — "Update `hasMultipleDifferentValues` cache
  on the next `Update()` call".
- **Validation** — none in this layer; a setter's own clamping is all there is.

## Type coverage

- **Collections** — arrays are properties (`arraySize`, `GetArrayElementAtIndex`,
  [`:284`][arrayelem]) and get a `ReorderableListWrapper` with add/remove/drag, its state kept
  in a static dictionary keyed by the property path.
- **Polymorphic values** — `SerializedPropertyType.ManagedReference` is the sum type:
  `[SerializeReference]` stores a concrete type name (`managedReferenceFullTypename`) beside
  the value. The UIElements `PropertyField` treats **a change of that type name as a change of
  property type**, tearing down and rebuilding its children:

  ```csharp
  if (newPropertyType == SerializedPropertyType.ManagedReference)
      newPropertyTypeName = newProperty.managedReferenceFullTypename;
  …
  newPropertyTypeIsDifferent = newPropertyTypeName != m_SerializedPropertyReferenceTypeName;
  ```

  — [`PropertyField.cs:249`][pffield]

  This is the corpus's clearest statement of the variant-switch rule that
  [`comparison.md`][cmp] drew from [bevy][bevy]: the subtree is a function of the concrete
  type, and nothing survives its change.

- **Optional / nullable** — an `ObjectReference` may be null and renders as an empty object
  field; there is no distinct "unset" beyond that.
- **Opaque types** — a value the serializer does not know is simply not in the property
  stream. Invisible rather than shown-and-inert.

## Multi-object editing

The axis Unity was added for, and it is native and per-property:

- `hasMultipleDifferentValues` ([`:609`][mixed]) answers "do the selected objects disagree?",
  with `hasMultipleDifferentValuesBitwise` ([`:618`][mixedbits]) for flag/mask fields so a
  _partially_ agreeing bitmask can be rendered per bit.
- Rendering is a global mode, not a per-control argument: `EditorGUI.showMixedValue`
  ([`EditorGUI.cs:273`][showmixed]) is a static property that every control consults, drawing
  an em-dash with the tooltip "Mixed Values" ([`:275`][mixedcontent]) and using the sentinel
  string `"<>"` inside text fields ([`:189`][multistring]).
- Writing through the cursor writes every target, so a mixed row becomes uniform on the first
  edit.

Compared with the corpus: [WinForms][winforms] answers the same question with a merged
descriptor and `allEqual`, [Unreal][unreal] with per-object value lists, [Godot][godot] not at
all. Unity's version is the cheapest of the three for the _view_ — one static flag — and the
most demanding of the _model_, which must maintain a comparison cache it can be told to
invalidate ([`SetIsDifferentCacheDirty`][dirty]).

## Presentation & control

- **Grouping / ordering** — serialization order, with `[Header]`/`[Space]` decorator drawers;
  no category model.
- **Conditional visibility** — `NextVisible` skips what the serializer hides
  (`[HideInInspector]`, non-serialized fields); anything value-dependent is a custom drawer or
  editor.
- **Search / filter** — not in the inspector proper; `SerializedPropertyFilters` and
  `SerializedPropertyTreeView` serve the table-style windows instead.
- **Escape hatches**, in increasing scope: `[CustomPropertyDrawer]` per attribute → per type
  (`useForChildren`) → `[CustomEditor]` replacing the whole inspector → UIElements
  `PropertyField` for a retained-element tree.
- **Virtualization** — IMGUI draws only what the layout says is visible, and the reorderable
  list computes an explicit visibility rect so collapsed, off-screen array elements do not
  disturb the scrollbar ([`PropertyHandler.cs:287`][listvis]).

## Strengths

- The mirror decouples editing from the object: one pull, one push, undo attached to the push.
- Cursor + path string separates cheap traversal from durable identity.
- Mixed values are a first-class per-property answer, down to per-bit for masks.
- The nesting-indexed drawer list stops per-type customizations from recursing into
  themselves — a guard nobody else has.
- The one automatic walk that can meet a cyclic graph carries a visited set.

## Weaknesses

- Identity is a stringly-typed path; per-row state lives in static dictionaries keyed by it.
- The mutable cursor is easy to misuse — `Copy()` exists because holding "the property" while
  continuing to iterate is otherwise wrong.
- `showMixedValue` is global mutable state that every control must remember to consult and
  restore.
- No transient/committed distinction and no validation seam at this layer.
- Half the behaviour is native and unreadable, so several answers here are contracts rather
  than implementations.

## Key design decisions and trade-offs

| Decision                                 | Rationale                                                           | Trade-off                                                                          |
| ---------------------------------------- | ------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| Edit a serialized mirror, not the object | One commit point for undo, prefab overrides and multi-object writes | The mirror must be pulled every frame and invalidated explicitly                   |
| The property is a cursor, not a node     | Traversal is allocation-free; visibility is a traversal rule        | Callers must `Copy()` to retain; identity has to be a separate string              |
| `isExpanded` on the serialized property  | Survives rebuild, re-selection and domain reload with no view state | View state becomes model state, shared by every window on the object               |
| Drawer list indexed by nesting level     | A type's drawer cannot recurse into itself                          | Deep nesting silently degrades to the default field                                |
| Visited set only in `SetExpandedRecurse` | The cost is paid exactly where the walk is automatic                | Click-driven descent into a cyclic `[SerializeReference]` graph is still unbounded |
| `showMixedValue` as ambient state        | Every existing control supports multi-edit with no signature change | Global mutable flag; forgetting to restore it leaks into later rows                |

## Sources

All line numbers are at [`225b0fbd`][rev].

- [`Editor/Mono/SerializedProperty.bindings.cs`][copy] — the cursor, `propertyPath`, `isExpanded`, `hasMultipleDifferentValues`, array access
- [`Editor/Mono/SerializedObject.bindings.cs`][apply] — `Update`, `ApplyModifiedProperties`, `SetIsDifferentCacheDirty`
- [`Editor/Mono/Inspector/Editor.cs`][defaultinspector] — the default inspector loop
- [`Editor/Mono/Inspector/Core/ScriptAttributeGUI/PropertyHandler.cs`][onguigui] — drawer dispatch, nesting context, reorderable lists
- [`Editor/Mono/Inspector/Core/ScriptAttributeGUI/ScriptAttributeUtility.cs`][getdrawer] — the drawer-type registry and `useForChildren`
- [`Editor/Mono/EditorGUI.cs`][visited] — `showMixedValue`, the mixed-value content, `SetExpandedRecurse`'s visited set
- [`Editor/Mono/UIElements/Controls/PropertyField.cs`][pffield] — rebuild on managed-reference type change

<!-- References -->

[repo]: https://github.com/Unity-Technologies/UnityCsReference
[rev]: https://github.com/Unity-Technologies/UnityCsReference/tree/225b0fbdb57cc17d094e8056b71f8314aba56f73
[readme]: https://github.com/Unity-Technologies/UnityCsReference/blob/225b0fbdb57cc17d094e8056b71f8314aba56f73/README.md
[copy]: https://github.com/Unity-Technologies/UnityCsReference/blob/225b0fbdb57cc17d094e8056b71f8314aba56f73/Editor/Mono/SerializedProperty.bindings.cs#L243
[relative]: https://github.com/Unity-Technologies/UnityCsReference/blob/225b0fbdb57cc17d094e8056b71f8314aba56f73/Editor/Mono/SerializedProperty.bindings.cs#L254
[arrayelem]: https://github.com/Unity-Technologies/UnityCsReference/blob/225b0fbdb57cc17d094e8056b71f8314aba56f73/Editor/Mono/SerializedProperty.bindings.cs#L284
[nextvisible]: https://github.com/Unity-Technologies/UnityCsReference/blob/225b0fbdb57cc17d094e8056b71f8314aba56f73/Editor/Mono/SerializedProperty.bindings.cs#L522
[mixed]: https://github.com/Unity-Technologies/UnityCsReference/blob/225b0fbdb57cc17d094e8056b71f8314aba56f73/Editor/Mono/SerializedProperty.bindings.cs#L609
[mixedbits]: https://github.com/Unity-Technologies/UnityCsReference/blob/225b0fbdb57cc17d094e8056b71f8314aba56f73/Editor/Mono/SerializedProperty.bindings.cs#L618
[path]: https://github.com/Unity-Technologies/UnityCsReference/blob/225b0fbdb57cc17d094e8056b71f8314aba56f73/Editor/Mono/SerializedProperty.bindings.cs#L728
[isexpanded]: https://github.com/Unity-Technologies/UnityCsReference/blob/225b0fbdb57cc17d094e8056b71f8314aba56f73/Editor/Mono/SerializedProperty.bindings.cs#L926
[so]: https://github.com/Unity-Technologies/UnityCsReference/blob/225b0fbdb57cc17d094e8056b71f8314aba56f73/Editor/Mono/SerializedProperty.bindings.cs#L151
[mrtype]: https://github.com/Unity-Technologies/UnityCsReference/blob/225b0fbdb57cc17d094e8056b71f8314aba56f73/Editor/Mono/SerializedProperty.bindings.cs#L85
[apply]: https://github.com/Unity-Technologies/UnityCsReference/blob/225b0fbdb57cc17d094e8056b71f8314aba56f73/Editor/Mono/SerializedObject.bindings.cs#L122
[dirty]: https://github.com/Unity-Technologies/UnityCsReference/blob/225b0fbdb57cc17d094e8056b71f8314aba56f73/Editor/Mono/SerializedObject.bindings.cs#L125
[update]: https://github.com/Unity-Technologies/UnityCsReference/blob/225b0fbdb57cc17d094e8056b71f8314aba56f73/Editor/Mono/SerializedObject.bindings.cs#L131
[applynoundo]: https://github.com/Unity-Technologies/UnityCsReference/blob/225b0fbdb57cc17d094e8056b71f8314aba56f73/Editor/Mono/SerializedObject.bindings.cs#L180
[defaultinspector]: https://github.com/Unity-Technologies/UnityCsReference/blob/225b0fbdb57cc17d094e8056b71f8314aba56f73/Editor/Mono/Inspector/Editor.cs#L862
[nesteddrawer]: https://github.com/Unity-Technologies/UnityCsReference/blob/225b0fbdb57cc17d094e8056b71f8314aba56f73/Editor/Mono/Inspector/Core/ScriptAttributeGUI/PropertyHandler.cs#L30
[lists]: https://github.com/Unity-Technologies/UnityCsReference/blob/225b0fbdb57cc17d094e8056b71f8314aba56f73/Editor/Mono/Inspector/Core/ScriptAttributeGUI/PropertyHandler.cs#L49
[onguigui]: https://github.com/Unity-Technologies/UnityCsReference/blob/225b0fbdb57cc17d094e8056b71f8314aba56f73/Editor/Mono/Inspector/Core/ScriptAttributeGUI/PropertyHandler.cs#L210
[nesting]: https://github.com/Unity-Technologies/UnityCsReference/blob/225b0fbdb57cc17d094e8056b71f8314aba56f73/Editor/Mono/Inspector/Core/ScriptAttributeGUI/PropertyHandler.cs#L251
[listvis]: https://github.com/Unity-Technologies/UnityCsReference/blob/225b0fbdb57cc17d094e8056b71f8314aba56f73/Editor/Mono/Inspector/Core/ScriptAttributeGUI/PropertyHandler.cs#L287
[drawerdict]: https://github.com/Unity-Technologies/UnityCsReference/blob/225b0fbdb57cc17d094e8056b71f8314aba56f73/Editor/Mono/Inspector/Core/ScriptAttributeGUI/ScriptAttributeUtility.cs#L49
[builddict]: https://github.com/Unity-Technologies/UnityCsReference/blob/225b0fbdb57cc17d094e8056b71f8314aba56f73/Editor/Mono/Inspector/Core/ScriptAttributeGUI/ScriptAttributeUtility.cs#L125
[getdrawer]: https://github.com/Unity-Technologies/UnityCsReference/blob/225b0fbdb57cc17d094e8056b71f8314aba56f73/Editor/Mono/Inspector/Core/ScriptAttributeGUI/ScriptAttributeUtility.cs#L164
[useforchildren]: https://github.com/Unity-Technologies/UnityCsReference/blob/225b0fbdb57cc17d094e8056b71f8314aba56f73/Editor/Mono/Inspector/Core/ScriptAttributeGUI/ScriptAttributeUtility.cs#L316
[showmixed]: https://github.com/Unity-Technologies/UnityCsReference/blob/225b0fbdb57cc17d094e8056b71f8314aba56f73/Editor/Mono/EditorGUI.cs#L273
[mixedcontent]: https://github.com/Unity-Technologies/UnityCsReference/blob/225b0fbdb57cc17d094e8056b71f8314aba56f73/Editor/Mono/EditorGUI.cs#L275
[multistring]: https://github.com/Unity-Technologies/UnityCsReference/blob/225b0fbdb57cc17d094e8056b71f8314aba56f73/Editor/Mono/EditorGUI.cs#L189
[setexpanded]: https://github.com/Unity-Technologies/UnityCsReference/blob/225b0fbdb57cc17d094e8056b71f8314aba56f73/Editor/Mono/EditorGUI.cs#L7832
[visited]: https://github.com/Unity-Technologies/UnityCsReference/blob/225b0fbdb57cc17d094e8056b71f8314aba56f73/Editor/Mono/EditorGUI.cs#L7841
[defaultfield]: https://github.com/Unity-Technologies/UnityCsReference/blob/225b0fbdb57cc17d094e8056b71f8314aba56f73/Editor/Mono/EditorGUI.cs#L7944
[pffield]: https://github.com/Unity-Technologies/UnityCsReference/blob/225b0fbdb57cc17d094e8056b71f8314aba56f73/Editor/Mono/UIElements/Controls/PropertyField.cs#L249
[unreal]: ./unreal-details-panel.md
[godot]: ./godot-inspector.md
[winforms]: ./winforms-propertygrid.md
[bevy]: ./bevy-inspector-egui.md
[cmp]: ./comparison.md
