# Qt Property Browser (C++ / Qt Widgets)

The three-way split — a value **manager**, an editor **factory**, a presentation **browser** — taken further than anyone else in the corpus, and the only subject whose model contains no reflection at all.

|                        |                                                                |
| ---------------------- | -------------------------------------------------------------- |
| **Language / toolkit** | C++ / Qt Widgets                                               |
| **License**            | BSD-3-Clause                                                   |
| **Repository**         | [`qtproject/qt-solutions`][repo], `qtpropertybrowser/`         |
| **Revision read**      | [`777e95ba`][rev] (2022-10-24)                                 |
| **Category**           | Hand-built model, retained widget presentation                 |
| **Metadata source**    | none — the caller builds the property tree by hand             |
| **Presentations**      | [tree][tree-src], group-box and button browsers over one model |

## Overview

### What it solves

A property browser that is **not** an object inspector. The library ships no reflection bridge: the caller creates each property through a manager, sets its value, and links it into a parent — so the "tree" is whatever the caller built. Qt Designer's property editor is the reflection consumer that sits _above_ this library (it maps `QMetaObject` properties onto managers); that bridge is not part of the surveyed source tree and is **not verified here**.

### Design philosophy

The library's own documentation states the ownership rule that shapes everything else:

> Note that nested properties are not owned by the parent property, i.e. each subproperty is owned by the manager that created it.
>
> — [`qtpropertybrowser.cpp:94`][own]

A `QtProperty` is therefore not a node in a tree. It is a value owned by a manager that may appear at several places in several browsers at once, and the tree is a relation over those values.

## How it works

Four types carry the whole design:

- **`QtProperty`** ([`qtpropertybrowser.h:37`][prop]) — the model element: name, tooltip, enabled/modified flags, and a list of sub-properties. It holds **no value**; `hasValue()`, `valueText()` and `valueIcon()` all delegate to its manager.
- **`QtAbstractPropertyManager`** ([`qtpropertybrowser.h:78`][mgr]) — owns values for a set of properties of one type, and emits `propertyChanged`/`propertyInserted`/`propertyRemoved`. Subclasses (`QtIntPropertyManager`, `QtDatePropertyManager`, …) add typed `value()`/`setValue()` plus per-type attributes (range, single step, read-only).
- **`QtAbstractEditorFactory<PropertyManager>`** ([`qtpropertybrowser.h:181`][fac]) — creates an editor widget for a property of a manager it has been attached to, and keeps editor↔property maps so a value change can be pushed into every live editor.
- **`QtBrowserItem`** ([`qtpropertybrowser.h:215`][item]) — one **occurrence** of a property inside one browser. `QtAbstractPropertyBrowser::items(property)` returns a _list_, because the same property can appear more than once.

The browser is abstract ([`qtpropertybrowser.h:231`][browser]); `QtTreePropertyBrowser`, `QtGroupBoxPropertyBrowser` and `QtButtonPropertyBrowser` are three presentations of the identical model, each implementing only `itemInserted`/`itemRemoved`/`itemChanged`.

## Model & addressing

The tree lives in a **data model** that is independent of any browser, and the presented tree is a second structure derived from it. `createBrowserIndex` ([`qtpropertybrowser.cpp:1349`][cbi]) recursively materializes a `QtBrowserItem` for a property _and every one of its sub-properties_, eagerly, at insert time; `m_propertyToIndexes` ([`qtpropertybrowser.cpp:1223`][idx]) maps one property to the list of items presenting it.

The consequences are unusually clean:

- **Address = the `QtProperty` pointer.** It is stable for the property's lifetime and independent of where (or how many times) it is shown. Nothing in the library needs a path, an index or a name to identify a node.
- **A model change fans out to every occurrence.** `slotPropertyDataChanged` walks the item list and calls `itemChanged` per occurrence ([`qtpropertybrowser.cpp:1459`][chg]).
- **There is no rebuild to survive.** Expansion state lives on the `QTreeWidgetItem`s, which are created and destroyed only when the model changes structurally.

## Metadata

None, by design. There is no attribute vocabulary, no descriptor, no registry of types — the caller states the tree. The one layer that looks like metadata is `QtVariantPropertyManager` ([`qtvariantproperty.cpp`][variant]), a façade that owns one sub-manager per `QVariant::Type` and a per-type **attribute table**:

```cpp
d_ptr->m_typeToPropertyManager[QVariant::Int] = intPropertyManager;
d_ptr->m_typeToAttributeToAttributeType[QVariant::Int][d_ptr->m_minimumAttribute] = QVariant::Int;
```

— [`qtvariantproperty.cpp:935`][vattr]

That converts the compile-time manager-per-type design into a runtime `int propertyType` dispatch, at the cost of stringly-typed attributes (`"minimum"`, `"maximum"`, `"enumNames"`).

## Recursion

**The descent decision is `hasValue()`**, and it is a property of the manager, not of a type: `QtGroupPropertyManager` answers `false`, so its properties render as a spanned header row rather than a label/value pair ([`qttreepropertybrowser.cpp:597`][span]). A property can have both a value and children — `QtPointPropertyManager` gives its property an editable text value _and_ two `X`/`Y` sub-properties created in `initializeProperty` ([`qtpropertymanager.cpp:2836`][point]).

Composite structure is therefore **hand-written per composite type**. Every one of `QPoint`, `QSize`, `QRect`, `QFont`, `QSizePolicy`, `QLocale` has a manager that creates, names, syncs and destroys its own children. There is no generic descent to fall back on, which is exactly why the library needs ~6,600 lines of `qtpropertymanager.cpp`.

Materialization is **eager**: `createBrowserIndex` builds items for the entire subtree regardless of expansion, and `QtTreePropertyBrowserPrivate::propertyInserted` expands each new item on creation ([`qttreepropertybrowser.cpp:555`][expand]). Nothing in the design defers work to expand time, because nothing in the model is expensive to produce — the caller already paid for it.

### Cycles

Cycles are **structurally impossible, and the check is explicit**. `insertSubProperty` rejects self-insertion, then walks the candidate's entire descendant set with a visited map, refusing the insert if it finds itself:

```cpp
// traverse all children of item. if this item is a child of item then cannot add.
QList<QtProperty *> pendingList = property->subProperties();
QMap<QtProperty *, bool> visited;
```

— [`qtpropertybrowser.cpp:403`][cycle]

Sharing is allowed and cycles are not, so the model is a DAG and the presented tree is its (finite) unfolding. This is the only subject in the corpus that pays for the check up front rather than living with the consequences; it can afford to, because insertion is a rare, caller-driven event rather than something a reflection walk does thousands of times.

## Editing & mutation

**Dispatch is by manager, not by type.** `setFactoryForManager(manager, factory)` is a compile-time-typed pairing ([`qtpropertybrowser.h:246`][setfac]); `QtAbstractEditorFactory::createEditor` iterates its registered managers and returns `0` for a property belonging to none. A property whose manager has no factory is simply not editable — the fallback is a read-only text cell, produced by the delegate painting `valueText()`.

The **editor is created per edited row and destroyed on close**: `QtPropertyEditorDelegate::createEditor` ([`qttreepropertybrowser.cpp:275`][deleg]) asks the browser, which asks the factory. Crucially the delegate does **not** participate in write-back at all:

```cpp
void setModelData(QWidget *, QAbstractItemModel *, const QModelIndex &) const {}
void setEditorData(QWidget *, const QModelIndex &) const {}
```

— [`qttreepropertybrowser.cpp:204`][nodata]

Both halves are empty because the factory wires the editor **directly to the manager**. `QtSpinBoxFactoryPrivate::slotSetValue` finds the property behind the sender widget and calls `manager->setValue(property, value)` ([`qteditorfactory.cpp:184`][setval]); the reverse direction re-enters through `slotPropertyChanged`, which guards against a feedback loop by suppressing the editor's own signal:

```cpp
if (editor->value() != value) {
    editor->blockSignals(true);
    editor->setValue(value);
    editor->blockSignals(false);
}
```

— [`qteditorfactory.cpp:126`][block]

So **commit is live, per keystroke or per spin**, with no transient/committed distinction, no validation seam (the editor widget's own validator is the only gate), and **no undo**: the library has no command, transaction or change-set concept whatsoever. An application that wants undo must interpose its own manager subclass.

Change notification is the Qt signal graph: manager → browser (`slotPropertyDataChanged`) → every occurrence. External mutation of the underlying application object is invisible unless the application calls `setValue` on the manager, because the manager _is_ the storage.

## Type coverage

- **Collections** — absent. No array, list or map property exists; a caller who wants one builds N sub-properties and manages add/remove itself.
- **Polymorphic / sum-typed values** — absent as a concept. The nearest thing is `QtEnumPropertyManager` (a closed list of names) and `QtFlagPropertyManager` (a set of checkboxes). Changing the "type" of a value means destroying properties and creating others, which the browser handles only because insert/remove are ordinary model events.
- **Optional / nullable** — absent. `QtVariantPropertyManager::value()` returns an invalid `QVariant` for a property it does not manage ([`qtvariantproperty.cpp:1337`][invalid]), but there is no "unset" state a user can enter or leave.
- **Unsupported types** — `QtVariantPropertyManager::addProperty(int propertyType, …)` returns `0` when `isPropertyTypeSupported` is false ([`qtvariantproperty.cpp:1307`][unsup]). Failure is at construction, not at render: there is no "opaque value" row, because a property that cannot be made does not exist.

## Presentation & control

- **Grouping and ordering** — insertion order, positioned with `insertSubProperty(property, afterProperty)`. Groups are ordinary valueless properties. There is no sort, no category vocabulary.
- **Conditional visibility** — `setEnabled(false)` greys a property; hiding means removing it from the model, which removes it from every browser at once.
- **Multi-object editing** — not supported, and nothing in the model gestures at it. One property has one value in one manager.
- **Search / filter** — absent.
- **Escape hatches** — three, at three levels: a custom **manager** (new value type and attributes), a custom **factory** (new editor for an existing manager), a custom **browser** (new presentation of the whole model). This is the cleanest seam story in the corpus, and it is a direct consequence of the model owning no presentation.
- **Virtualization** — inherited from `QTreeWidget`, which paints only visible rows, but every row is a materialized `QTreeWidgetItem` and every property is a heap object with a `QMap` entry in its manager. Only the **edited** row has an editor widget.

## Strengths

- One model, three presentations, proven in-tree — the strongest evidence in the corpus that presentation-independence is achievable rather than aspirational.
- Node identity is a pointer with a lifetime the caller controls: no path strings, no index invalidation, no rebuild-survival problem.
- Cycle-freedom is an enforced model invariant, not a rendering heuristic.
- The occurrence list (`items(property)`) makes "the same value shown twice" a first-class case instead of a bug.

## Weaknesses

- No reflection, so the caller writes the tree; composite types cost a bespoke manager each (`qtpropertymanager.cpp` is 6,611 lines).
- No undo, no transactions, no transient-edit concept.
- No collections, no polymorphism, no multi-object editing, no filtering.
- Values live in managers, so the "real" application object must be mirrored into and out of the browser by hand.
- Unmaintained: the surveyed tree is a Qt-4-era solutions repository, still carrying `#if QT_VERSION >= 0x040400` guards and `QStyleOptionViewItemV3`.

## Key design decisions and trade-offs

| Decision                                                           | Rationale                                                                                    | Trade-off                                                                   |
| ------------------------------------------------------------------ | -------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| Property holds no value; the manager does                          | One place per type for value, attributes and change signals; editors bind to a typed manager | The application's own object is not the model — everything must be mirrored |
| Presented node ≠ model node (`QtBrowserItem` per occurrence)       | One property can appear in several browsers and several places                               | Every notification must fan out over an occurrence list                     |
| Eager, full materialization of the item tree                       | Model changes are caller-driven and rare; no lazy machinery needed                           | A large model costs its full item tree even when collapsed                  |
| Cycle check on insert                                              | Makes the unfolding total; no depth caps anywhere else                                       | O(descendants) per insert, paid by the caller's build loop                  |
| Editor↔manager wiring by the factory, delegate write-back disabled | Live two-way sync; the same editor works in any browser                                      | No commit/rollback point exists, so no undo and no validation seam          |
| Composite structure hand-written per manager                       | Full control of child naming, ranges and sync                                                | No generic descent; every new composite type is new code                    |

## Sources

All line numbers are at [`777e95ba`][rev].

- [`qtpropertybrowser/src/qtpropertybrowser.h`][prop] — `QtProperty`, `QtAbstractPropertyManager`, `QtAbstractEditorFactory`, `QtBrowserItem`, `QtAbstractPropertyBrowser`
- [`qtpropertybrowser/src/qtpropertybrowser.cpp`][cycle] — sub-property insertion and the cycle check, browser-index creation, change fan-out
- [`qtpropertybrowser/src/qttreepropertybrowser.cpp`][tree-src] — the tree presentation, the editor delegate, expansion
- [`qtpropertybrowser/src/qteditorfactory.cpp`][setval] — editor↔manager wiring
- [`qtpropertybrowser/src/qtpropertymanager.cpp`][point] — the typed managers and their composite children
- [`qtpropertybrowser/src/qtvariantproperty.cpp`][variant] — the runtime type→manager registry and attribute tables

<!-- References -->

[repo]: https://github.com/qtproject/qt-solutions
[rev]: https://github.com/qtproject/qt-solutions/tree/777e95ba69952f11eaec0adfb0cb987fabcdecb3
[prop]: https://github.com/qtproject/qt-solutions/blob/777e95ba69952f11eaec0adfb0cb987fabcdecb3/qtpropertybrowser/src/qtpropertybrowser.h#L37
[mgr]: https://github.com/qtproject/qt-solutions/blob/777e95ba69952f11eaec0adfb0cb987fabcdecb3/qtpropertybrowser/src/qtpropertybrowser.h#L78
[fac]: https://github.com/qtproject/qt-solutions/blob/777e95ba69952f11eaec0adfb0cb987fabcdecb3/qtpropertybrowser/src/qtpropertybrowser.h#L181
[item]: https://github.com/qtproject/qt-solutions/blob/777e95ba69952f11eaec0adfb0cb987fabcdecb3/qtpropertybrowser/src/qtpropertybrowser.h#L215
[browser]: https://github.com/qtproject/qt-solutions/blob/777e95ba69952f11eaec0adfb0cb987fabcdecb3/qtpropertybrowser/src/qtpropertybrowser.h#L231
[setfac]: https://github.com/qtproject/qt-solutions/blob/777e95ba69952f11eaec0adfb0cb987fabcdecb3/qtpropertybrowser/src/qtpropertybrowser.h#L246
[own]: https://github.com/qtproject/qt-solutions/blob/777e95ba69952f11eaec0adfb0cb987fabcdecb3/qtpropertybrowser/src/qtpropertybrowser.cpp#L94
[cycle]: https://github.com/qtproject/qt-solutions/blob/777e95ba69952f11eaec0adfb0cb987fabcdecb3/qtpropertybrowser/src/qtpropertybrowser.cpp#L403
[cbi]: https://github.com/qtproject/qt-solutions/blob/777e95ba69952f11eaec0adfb0cb987fabcdecb3/qtpropertybrowser/src/qtpropertybrowser.cpp#L1349
[idx]: https://github.com/qtproject/qt-solutions/blob/777e95ba69952f11eaec0adfb0cb987fabcdecb3/qtpropertybrowser/src/qtpropertybrowser.cpp#L1223
[chg]: https://github.com/qtproject/qt-solutions/blob/777e95ba69952f11eaec0adfb0cb987fabcdecb3/qtpropertybrowser/src/qtpropertybrowser.cpp#L1459
[tree-src]: https://github.com/qtproject/qt-solutions/blob/777e95ba69952f11eaec0adfb0cb987fabcdecb3/qtpropertybrowser/src/qttreepropertybrowser.cpp
[deleg]: https://github.com/qtproject/qt-solutions/blob/777e95ba69952f11eaec0adfb0cb987fabcdecb3/qtpropertybrowser/src/qttreepropertybrowser.cpp#L275
[nodata]: https://github.com/qtproject/qt-solutions/blob/777e95ba69952f11eaec0adfb0cb987fabcdecb3/qtpropertybrowser/src/qttreepropertybrowser.cpp#L204
[expand]: https://github.com/qtproject/qt-solutions/blob/777e95ba69952f11eaec0adfb0cb987fabcdecb3/qtpropertybrowser/src/qttreepropertybrowser.cpp#L555
[span]: https://github.com/qtproject/qt-solutions/blob/777e95ba69952f11eaec0adfb0cb987fabcdecb3/qtpropertybrowser/src/qttreepropertybrowser.cpp#L597
[setval]: https://github.com/qtproject/qt-solutions/blob/777e95ba69952f11eaec0adfb0cb987fabcdecb3/qtpropertybrowser/src/qteditorfactory.cpp#L184
[block]: https://github.com/qtproject/qt-solutions/blob/777e95ba69952f11eaec0adfb0cb987fabcdecb3/qtpropertybrowser/src/qteditorfactory.cpp#L126
[point]: https://github.com/qtproject/qt-solutions/blob/777e95ba69952f11eaec0adfb0cb987fabcdecb3/qtpropertybrowser/src/qtpropertymanager.cpp#L2836
[variant]: https://github.com/qtproject/qt-solutions/blob/777e95ba69952f11eaec0adfb0cb987fabcdecb3/qtpropertybrowser/src/qtvariantproperty.cpp
[vattr]: https://github.com/qtproject/qt-solutions/blob/777e95ba69952f11eaec0adfb0cb987fabcdecb3/qtpropertybrowser/src/qtvariantproperty.cpp#L935
[unsup]: https://github.com/qtproject/qt-solutions/blob/777e95ba69952f11eaec0adfb0cb987fabcdecb3/qtpropertybrowser/src/qtvariantproperty.cpp#L1307
[invalid]: https://github.com/qtproject/qt-solutions/blob/777e95ba69952f11eaec0adfb0cb987fabcdecb3/qtpropertybrowser/src/qtvariantproperty.cpp#L1337
