# Unreal Engine Details panel (C++ / Slate) — documentation only

The corpus's reference design for **property handles** and **multi-object editing**, and the one subject whose source could not be read.

> [!IMPORTANT]
> **Epistemic status: documentation, not source.** `EpicGames/UnrealEngine` requires an
> authenticated account, so nothing here was verified against the implementation.
> Everything below comes from the archived Unreal Engine 5.1 API reference pages cited
> at the bottom; API-reference tables truncate long type names, so a few return types are
> marked **INFERENCE**. Where the other four deep-dives say "read at revision X", this one
> says "read from the 5.1 API reference as archived on 2023-02-04 / 2023-04-01".

|                        |                                                            |
| ---------------------- | ---------------------------------------------------------- |
| **Language / toolkit** | C++ / Slate                                                |
| **License**            | proprietary (source access gated)                          |
| **Module**             | `PropertyEditor` (`/Engine/Source/Editor/PropertyEditor/`) |
| **Read from**          | UE 5.1 API reference, [archived][iph]                      |
| **Category**           | Retained node tree behind a handle abstraction             |
| **Metadata source**    | runtime — `UPROPERTY` reflection + a `meta=` string map    |

## Overview

### What it solves

The editor's Details panel: an inspector over one **or many** selected `UObject`s, with per-class layout customization (`IDetailCustomization`), per-struct-type customization (`IPropertyTypeCustomization`), and a property abstraction that hides the transaction/notification protocol from customizers.

### Design philosophy

The handle's own summary states both jobs it does:

> A handle to a property which is used to read and write the value without needing to handle Pre/PostEditChange, transactions, package modification A handle also is used to identify the property in detail customization interfaces
>
> — [`IPropertyHandle`, UE 5.1 API reference][iph]

Two things are bundled deliberately: **identity** ("which property is this?") and **mediated access** ("write it correctly"). No other subject in the corpus fuses them — Qt's [`QtProperty`][qt] is identity with no protocol, [Godot's][godot] `(object, path)` pair is identity that each caller must protocol itself, and [`bevy-inspector-egui`][bevy] has access with no identity at all.

## Model & addressing

`IPropertyHandle` is the address, and it is a shared pointer (`TSharedPtr<IPropertyHandle>`), obtained from the layout builder or by navigation:

- `GetChildHandle(FName ChildName, bool bRecurse)` and `GetChildHandle(uint32 Index)` — "Gets a child handle of this handle. Useful for accessing properties in structs."
- `GetParentHandle()`, `GetNumChildren(uint32& OutNumChildren)`
- `GetKeyHandle()` for map keys, `AsArray()` / `AsMap()` / `AsSet()` for container-typed handles
- `GeneratePathToProperty()` — "Generates a path from the parent UObject class to this property"
- `IsValidHandle()` — the explicit answer to "did my handle survive?"

The presence of both a **navigable handle graph** and a **generated path string**, plus an explicit validity predicate, is the strongest evidence in the corpus that a long-lived node address is worth its cost: customizations hold handles across panel rebuilds and ask whether they are still valid. `FPropertyNode` is the underlying node type (`GetPropertyNode()` is exposed on the handle), i.e. the panel does keep a retained tree behind the abstraction. _(That `FPropertyNode` is a tree of nodes rather than something else is **INFERENCE** from the accessor's name and the handle's navigation surface.)_

## Metadata

`UPROPERTY` reflection plus a **string-keyed metadata map**, readable from the handle at both class and instance scope:

- `GetMetaData(FName Key)`, `HasMetaData`, and typed readers `GetBoolMetaData`, `GetIntMetaData`, `GetFloatMetaData`, `GetClassMetaData`
- `GetInstanceMetaData(FName Key)` / `GetInstanceMetaDataMap()` — "Get metadata value for 'Key' for this property instance (as opposed to the class)"

The instance-vs-class split is notable: metadata is not purely a property of the type, so a customization can attach per-occurrence data to a handle. There is also a **restriction** layer — `AddRestriction(TSharedRef<const FPropertyRestriction>)`, `IsRestricted(const FString& Value, TArray<FText>& OutReasons)`, `IsHidden`, `IsDisabled`, `GenerateRestrictionToolTip` — i.e. per-value (not per-property) conditional availability, with reasons carried for display. No other subject in the corpus models "this _value_ of this enum is unavailable here, and here is why".

## Recursion

Descent is by handle: a struct-typed property yields child handles, and `AddChildStructure(TSharedRef<FStructOnScope>)` lets a customization graft an entirely synthetic struct into the tree. Containers are entered through `AsArray()`/`AsMap()`/`AsSet()`, which expose add/insert/delete/swap interfaces (`IPropertyHandleArray` etc.), and `GetIndexInArray()` reports an element's position.

Laziness and cycle handling could **not be determined** from the API reference: neither is visible in the public surface. Unreal's object graph certainly contains cycles (an actor's components reference their owner), so some guard must exist — but this survey has no evidence for what it is, and none is claimed here.

## Editing & mutation

The handle _is_ the mutation protocol:

- `SetValue(T, EPropertyValueSetFlags::Type)` — flags carry the transient/committed distinction; `EPropertyValueSetFlags::DefaultFlags` is the default parameter ([`SetValue`][setvalue]). The flag vocabulary (an `InteractiveChange` flag for drags, a `NotTransactable` flag) is widely used in customization code, but the enum's own page is **not archived**, so its enumerators are **not verified here**.
- `NotifyPreChange()`, `NotifyPostChange(EPropertyChangeType::Type)`, `NotifyFinishedChangingProperties()` — each documented as _not_ needed when `SetValue` is used, "since it will be called automatically". The existence of `NotifyFinishedChangingProperties` as a separate call is the corpus's clearest statement that "still dragging" and "done dragging" are different events.
- `SetOnPropertyValueChanged`, `SetOnChildPropertyValueChanged`, `SetOnChildPropertyValuePreChange`, `SetOnPropertyResetToDefault` — per-handle observers, including the **child-changed** direction that [WinForms][winforms] expresses as `[NotifyParentProperty]`.
- `ResetToDefault()`, `CanResetToDefault()`, `DiffersFromDefault()`, and an override hook `ExecuteCustomResetToDefault(FResetToDefaultOverride)` — "default" is a first-class concept, not a convention.
- `SetIgnoreValidation(bool)` — "Sets whether or not data validation should occur for this property and all of its children", so validation is a subtree-scoped switch.

Transactions and package modification are stated to be the handle's responsibility, so undo is automatic for anything written through it.

## Type coverage

- **Collections** — `AsArray`/`AsMap`/`AsSet` plus `GetKeyHandle`, i.e. containers are handled inside the tree with a dedicated interface per kind (unlike WinForms' modal collection editor).
- **Polymorphic values** — `GeneratePossibleValues(TArray<TSharedPtr<FString>>& Out, TArray<FText>& OutToolTips, TArray<bool>& OutRestrictedItems)` — "Generates a list of possible enum/class options for the property", and the restriction machinery greys entries out with reasons. This is the same shape as [`bevy-inspector-egui`][bevy]'s constructable check, generalised to classes and driven by metadata rather than by constructability.
- **Optional / nullable** — not determined.
- **Opaque types** — `AccessRawData(TArray<void*>&)` and `EnumerateRawData` are the escape hatch: a customization can reach the bytes for anything the panel cannot present.

## Multi-object editing

This is the axis Unreal designed for, and it is visible directly in the handle API:

- `GetNumPerObjectValues()` — "Gets the number of objects that this handle is editing"
- `GetPerObjectValues(TArray<FString>& OutPerObjectValues)` — "Gets a unique value for each object this handle is editing"
- `GetPerObjectValue(int32 ObjectIndex, FString& OutObjectValue)`, `SetPerObjectValue`, `SetPerObjectValues`
- `GetOuterObjects(TArray<UObject*>&)`, `GetNumOuterObjects()`, `GetOuterBaseClass()`, `ReplaceOuterObjects`

So a handle is **inherently plural**: it addresses "this property, across N objects", and the single-object case is N = 1. Every getter returns an `FPropertyAcc…`-prefixed result type rather than a bare value — the API tables truncate it, and the enumerators are **not verified**, but the shape (a result code beside the out-parameter) is what lets "the objects disagree" be a normal answer rather than an error. Compare the alternatives: [WinForms][winforms] reaches the same place with a merged descriptor and an `allEqual` out-parameter, while [Godot][godot] returns the first object's value and shows nothing at all.

## Customization

Two interfaces, at two scopes:

- **`IDetailCustomization`** — "Interface for any class that lays out details for a specific class", with `CustomizeDetails(IDetailLayoutBuilder&)`. Whole-class layout: reorder categories, hide properties, add rows.
- **`IPropertyTypeCustomization`** — "Base class for property type customizations", with `CustomizeHeader(TSharedRef<IPropertyHandle>, FDetailWidgetRow&, IPropertyTypeCustomizationUtils&)` and `CustomizeChildren(...)`, plus `ShouldInlineKey()`. Per-**type**, everywhere that type appears; the header/children split means a customization can collapse a struct into a single inline row _and_ still expose its children.

The archived page lists 30+ engine-internal implementations of `IPropertyTypeCustomization` (`FMathStructCustomization`, `FColorStructCustomization`, `FSlateBrushStructCustomization`, `FInstancedStructDetails`, …), which is itself evidence: the built-in composite types are customizations rather than special cases in the panel.

Handles also carry the panel's own default widgets — `CreatePropertyNameWidget`, `CreatePropertyValueWidget`, `CreateDefaultPropertyButtonWidgets`, `CreateDefaultPropertyCopyPasteActions` — so a customization can replace part of a row and keep the rest.

## Strengths (as documented)

- The handle unifies identity, navigation, mediated writes, transactions and multi-object access behind one interface.
- Multi-object editing is the default shape of the API, not an add-on.
- Transient vs committed edits are explicit (`SetValue` flags plus `NotifyFinishedChangingProperties`).
- Per-value restrictions with human-readable reasons.
- Header/children customization split allows inlining without losing the subtree.

## Weaknesses (as documented)

- The API is very large: `IPropertyHandle` alone lists dozens of `GetValue` overloads, one per engine type — the price of a typed accessor over an untyped node.
- Metadata is stringly-typed (`GetMetaData(FName)` plus typed parsers).
- Everything is `TSharedPtr`/`TSharedRef`, so the node graph is reference-counted and lifetime is implicit.
- Source access is gated, so none of the above can be checked against behaviour.

## Key design decisions and trade-offs

| Decision                                            | Rationale (documented)                                             | Trade-off                                                                                |
| --------------------------------------------------- | ------------------------------------------------------------------ | ---------------------------------------------------------------------------------------- |
| One handle type for identity + access               | Customizations never write the change protocol                     | The interface accretes: value access, metadata, restrictions, widgets, per-object values |
| Handles are inherently N-object                     | Multi-select is the editor's normal case                           | Every read returns a result code; "one object" is a degenerate case everywhere           |
| `SetValue` owns transactions and notification       | Undo cannot be forgotten                                           | Writing outside the handle requires the manual `NotifyPre/PostChange` pair               |
| Type customizations rather than built-in composites | `FVector`, `FColor`, `FSlateBrush` use the same seam as user types | The seam must be powerful enough for the engine's own needs, hence its size              |
| Restrictions as first-class, with reasons           | A value can be unavailable for reasons the user can read           | Another metadata channel to consult when rendering any picker                            |

## Sources

Archived Unreal Engine 5.1 API reference pages (the live pages return HTTP 403 to the link checker):

- [`IPropertyHandle`][iph] — the handle's full member list, quoted above (archived 2023-02-04)
- [`IPropertyTypeCustomization`][iptc] — `CustomizeHeader`/`CustomizeChildren`/`ShouldInlineKey` and the engine implementations (archived 2023-04-01)
- [`IDetailCustomization`][idc] — `CustomizeDetails` (archived 2023-04-01)
- [`IPropertyHandle::SetValue`][setvalue] — the `EPropertyValueSetFlags::Type` parameter (live page; UE 5.6 documentation)

<!-- References -->

[iph]: https://web.archive.org/web/20230204095057/https://docs.unrealengine.com/5.1/en-US/API/Editor/PropertyEditor/IPropertyHandle/
[iptc]: https://web.archive.org/web/20230401044503/https://docs.unrealengine.com/5.1/en-US/API/Editor/PropertyEditor/IPropertyTypeCustomization/
[idc]: https://web.archive.org/web/20230401054617/https://docs.unrealengine.com/5.1/en-US/API/Editor/PropertyEditor/IDetailCustomization/
[setvalue]: https://dev.epicgames.com/documentation/en-us/unreal-engine/API/Editor/PropertyEditor/IPropertyHandle/SetValue/1
[qt]: ./qt-property-browser.md
[godot]: ./godot-inspector.md
[winforms]: ./winforms-propertygrid.md
[bevy]: ./bevy-inspector-egui.md
