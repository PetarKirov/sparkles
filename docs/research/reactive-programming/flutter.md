# Flutter widgets, elements and render objects (Dart)

The rebuild model of Google's portable UI toolkit: `build` methods return cheap, immutable `Widget` descriptions on every rebuild; a retained `Element` tree matches each new description against the old one by type and key, skips any child whose widget is the _identical_ object, and pushes changed configuration into a retained `RenderObject` tree whose dirty flags, relayout boundaries and repaint boundaries confine layout and paint to the nodes that changed.

| Field             | Value                                                                                                                                                                                                                                   |
| ----------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language          | Dart 3.13 (the SDK bundled with this Flutter release, `bin/cache/dart-sdk/version`)                                                                                                                                                     |
| License           | BSD-3-Clause ([`LICENSE`][license])                                                                                                                                                                                                     |
| Repository        | [flutter/flutter][repo]: [`packages/flutter/lib/src/widgets`][src-widgets], [`rendering`][src-rendering], [`scheduler`][src-scheduler], [`foundation`][src-foundation]                                                                  |
| Documentation     | [Inside Flutter][inside] (docs.flutter.dev, "last updated 2026-05-05", reflects Flutter 3.50) · API docs in the source comments cited below                                                                                             |
| Category          | retained element tree reconciled against per-rebuild immutable descriptions; dirty-flag layout and paint over a retained render tree                                                                                                    |
| Versions surveyed | Flutter **3.47.4** (tag commit `9584c67`, 2026-09-10), the nixpkgs SDK `flutter-wrapped-3.47.4-sdk-links` (byte-identical to the tag for every file cited); `dart-lang/language` at `c61daed` (2026-11-23); `dart-lang/sdk` at `3.13.3` |
| Core abstraction  | `Element.updateChild(child, newWidget, slot)`: identical widget → keep; same `runtimeType` and `key` → update in place; otherwise deactivate and inflate                                                                                |

> [!NOTE]
> This page covers how widgets are authored, rebuilt and rendered, read for a design question in [`sparkles:ui`][sparkles-ui]: JSX-like authoring over a per-frame rebuild, with subtree skipping by value. Three other pages cover adjacent parts of Flutter and are not repeated here: [the layout protocol][layout-flutter] (`BoxConstraints`, flex, slivers, the widget catalogue), [the engine's `DisplayList`][engine-flutter] (the op records below the layer tree), and [slivers and builder delegates][slivers-flutter] (virtualized lists). Its siblings in this survey are [Solid components][solid-components] (no re-render at all) and [Jetpack Compose][compose] (re-execution scoped by read tracking). Every claim was read at the pinned tag; each `probe (Flutter 3.47.4, flutter test)` block is a headless widget test run against that SDK on 2026-11-24.

---

## Overview

### What it solves

Flutter wants the authoring model of a function from state to UI, re-run whenever the state changes, without rebuilding the world. Its answer is to make the re-run produce only descriptions, and to keep everything expensive in two retained trees. The `Widget` class comment says what a widget is: _"A given widget can be included in the tree zero or more times. […] Each time a widget is placed in the tree, it is inflated into an [Element]"_ ([`framework.dart`][fw-widget]). The framework architecture docs state the workload this has to survive ([Inside Flutter][inside]):

> _"One of the most distinctive aspects of Flutter is its aggressive composability. […] `Padding` is a widget rather than a property of other widgets. As a result, user interfaces built with Flutter consist of many, many widgets."_

and the claim it makes about the cost:

> _"Flutter's widget building algorithm is sublinear. […] The framework keeps a list of dirty elements and jumps directly to them during the build phase, skipping over clean elements."_

### Design philosophy

1. **Descriptions are immutable and disposable.** `build` must depend only on _"the fields of the widget, which themselves must not change over time"_ and on inherited state ([`StatelessWidget.build`][fw-build-contract]). Immutability is what makes the cheapest test sound: if the widget is the same object, nothing below it can have changed.
2. **Identity, not equality, cuts the walk.** `Widget.operator ==` is `@nonVirtual` and is `Object` identity ([`framework.dart`][fw-widget-eq]). The docs argue an equality override would make reconciliation quadratic ([below](#why-identity-and-not-equality)).
3. **Reconcile child lists, not trees.** _"Contrary to popular belief, Flutter does not employ a tree-diffing algorithm"_; each element compares its own child list in O(N) ([Inside Flutter][inside]; [`updateChildren`][fw-updatechildren]).
4. **Dirty flags at every layer.** Build, layout, compositing bits, paint and semantics each keep their own dirty list, flushed once per frame in depth order ([`drawFrame`][wb-drawframe]).
5. **The retained trees are separate on purpose.** _"An obvious simplification would be to combine these trees into one tree. However, in practice there are a number of benefits"_: performance (layout walks skip the many composition-only elements), clarity, and type safety ([Inside Flutter][inside]).

---

## The three trees

| Tree             | Node type (base)                                                                                             | Created by                                                               | Owns                                                                                                                                                                                                     | Lifetime                                                                                                                                |
| ---------------- | ------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| **Widget**       | `Widget` ([source][fw-widget]): `StatelessWidget`, `StatefulWidget`, `InheritedWidget`, `RenderObjectWidget` | a `build` method, or a `const` expression evaluated once at compile time | `final` configuration fields and an optional `key`; nothing else                                                                                                                                         | one rebuild (or forever, if `const` or cached); the same instance may sit at several positions at once                                  |
| **Element**      | `Element` ([source][fw-element-eq]), which implements `BuildContext`                                         | `Widget.createElement()` in `inflateWidget` ([source][fw-inflate])       | parent and child links, `slot`, `depth`, dirty bit, the current widget, the `State` (for `StatefulElement`), the inherited-widget map and dependency set, the `RenderObject` (for `RenderObjectElement`) | from mount to unmount; survives every rebuild in which `canUpdate` holds; can be parked inactive for the rest of a frame and reparented |
| **RenderObject** | `RenderObject` ([`object.dart`][ro-markneedslayout]); `RenderBox` for 2D boxes                               | `RenderObjectWidget.createRenderObject` ([source][fw-row-widget])        | constraints, size, parent data (offset), layout/paint/compositing dirty bits, the relayout-boundary flag, a composited layer if it is a repaint boundary                                                 | the lifetime of its `RenderObjectElement`                                                                                               |

The render tree is a subset of the element tree: `StatelessElement`, `StatefulElement` and `InheritedElement` are `ComponentElement`s that have one child element and no render object ([`ComponentElement.performRebuild`][fw-component-rebuild]). A `Padding` widget is a `SingleChildRenderObjectWidget`; its element owns a `RenderPadding` and copies the configuration across in `updateRenderObject` ([`Padding`][basic-padding]):

```dart
// packages/flutter/lib/src/widgets/basic.dart — Padding
@override
void updateRenderObject(BuildContext context, RenderPadding renderObject) {
  renderObject
    ..padding = padding
    ..textDirection = Directionality.maybeOf(context);
}
```

What persists across frames is therefore everything except the widgets: element identity and `State`, the render objects with their last constraints and sizes, and the layer tree. A rebuild allocates a fresh widget graph for the rebuilt region and throws it away when the next rebuild replaces it.

---

## Rebuild mechanics

### Marking dirty: `setState` → `markNeedsBuild` → `scheduleBuildFor`

`State.setState(fn)` calls `fn` synchronously (asserting it did not return a `Future`) and then `_element!.markNeedsBuild()` ([`setState`][fw-setstate]). The docs record why the API takes a callback: the original API _was_ `markNeedsBuild`, and _"people used it like a good luck charm, any time they weren't sure if they needed to call it, they would call it, just in case"_ ([design discussion][fw-setstate-design]).

`markNeedsBuild` returns at once unless the element is active, sets `_dirty`, and calls `owner!.scheduleBuildFor(this)` ([source][fw-markneedsbuild]). Its doc names the rule that keeps a frame to one build per element: _"applications and widgets should be structured so as to only mark widgets dirty during event handlers before the frame begins, not during the build itself."_ A debug assertion allows a mark during build only for a descendant of the element currently building, _"because the framework builds parent widgets before children, which means a dirty descendant will always be built."_

`BuildOwner.scheduleBuildFor` calls `onBuildScheduled` once per frame (which `WidgetsBinding` wires to `_handleBuildScheduled`, ending in `ensureVisualUpdate`, [source][wb-buildscheduled]) and appends to the element's `BuildScope` dirty list, which `_scheduleBuildFor` guards with an `_inDirtyList` flag so an element is listed once ([`scheduleBuildFor`][fw-schedulebuildfor], [`BuildScope._scheduleBuildFor`][fw-schedule-scope]).

### Flushing: `buildScope` and the depth-sorted dirty list

`WidgetsBinding.drawFrame` calls `buildOwner!.buildScope(rootElement!)` ([source][wb-drawframe]); `buildScope` runs an optional callback and then `_flushDirtyElements` ([`buildScope`][fw-buildscope]). The flush sorts the list with `Element._sort`, by `depth` and then clean-before-dirty, and rebuilds in that order ([`_flushDirtyElements`][fw-flush], [`_sort`][fw-sort]):

```dart
// packages/flutter/lib/src/widgets/framework.dart — Element._sort
static int _sort(Element a, Element b) {
  final int diff = a.depth - b.depth;
  if (diff != 0) {
    return diff;
  }
  final bool isBDirty = b.dirty;
  if (a.dirty != isBDirty) {
    return isBDirty ? -1 : 1;
  }
  return 0;
}
```

Parents first means a dirty child under a dirty parent is normally rebuilt by its parent's pass and is clean (so `rebuild` returns immediately) by the time the loop reaches it. Elements marked dirty _during_ the flush set `_dirtyElementsNeedsResorting`; `_dirtyElementIndexAfter` re-sorts and walks the index back past any entry that moved ([source][fw-flush]). The `buildScope` doc states the invariant: elements dirtied during the pass _"must be deeper than the `context` node, and deeper than any previously-built node in this pass"_ ([source][fw-buildscope]).

A `BuildScope` can be nested: `LayoutBuilder`'s element owns its own scope and rebuilds its child from inside layout, through `owner!.buildScope(this, callback)`, only when its constraints changed or it was marked dirty ([`_rebuildWithConstraints`][lb-rebuild]). That is the one sanctioned way for build to depend on layout.

### `updateChild`: identity first, then type and key

A rebuilt `ComponentElement` calls `build()` and hands the result to `updateChild(_child, built, slot)` ([`performRebuild`][fw-component-rebuild]). `updateChild` is _"the core of the widgets system"_ ([source][fw-updatechild]); with the hot-reload checks and timeline code removed:

```dart
// packages/flutter/lib/src/widgets/framework.dart — Element.updateChild (abridged)
if (newWidget == null) {
  if (child != null) deactivateChild(child);
  return null;
}
if (child != null) {
  if (child.widget == newWidget) {                     // identical: Widget.== is identity
    if (child.slot != newSlot) updateSlotForChild(child, newSlot);
    return child;                                      // the whole subtree is skipped
  } else if (Widget.canUpdate(child.widget, newWidget)) {
    if (child.slot != newSlot) updateSlotForChild(child, newSlot);
    child.update(newWidget);                           // reuse element, push new config
    return child;
  }
  deactivateChild(child);
}
return inflateWidget(newWidget, newSlot);              // new element (or retaken GlobalKey)
```

`Widget.canUpdate` is the whole identity rule ([source][fw-canupdate]):

```dart
static bool canUpdate(Widget oldWidget, Widget newWidget) {
  return oldWidget.runtimeType == newWidget.runtimeType && oldWidget.key == newWidget.key;
}
```

An `update` never skips by value. `StatelessElement.update` and `StatefulElement.update` end in `rebuild(force: true)` ([`StatelessElement`][fw-stateless-el], [`StatefulElement.update`][fw-stateful-update]); `ProxyElement.update` does too ([source][fw-proxy-update]); a `RenderObjectElement` calls `widget.updateRenderObject(this, renderObject)` and then reconciles its children ([`_performRebuild`][fw-ro-rebuild], [`MultiChildRenderObjectElement.update`][fw-multichild-update]). So a parent rebuild walks down through every child whose widget is a new object, which in ordinary code is every child the parent's `build` constructed.

The value comparison Flutter does use sits one layer lower, in render-object setters. `RenderPadding.padding` returns early if `_padding == value` and otherwise calls `markNeedsLayout` ([`shifted_box.dart`][ro-padding-setter]); `RenderOpacity.opacity` compares, then updates only the composited layer ([`proxy_box.dart`][ro-opacity-setter]). The `RenderBox` class doc makes it a convention: _"Consider layout and paint to be expensive; be conservative about calling [markNeedsLayout] or [markNeedsPaint]. They should only be called if the layout (or paint, respectively) has actually changed"_ ([`box.dart`][box-conservative]). Equality is cheap there because a setter compares one leaf value, not a subtree.

### Why identity and not equality

The `Element.rebuild` doc has a section titled _Not rebuilding_ ([source][fw-not-rebuilding]):

> _"Before an [Element] is told to update itself with a new [Widget], the old and new objects are compared using `operator ==`. In general, this is equivalent to doing a comparison using [identical] […]. It is strongly advised to avoid overriding `operator ==` on [Widget] objects. While doing so seems like it could improve performance, in practice, for non-leaf widgets, it results in O(N²) behavior. This is because by necessity the comparison would have to include comparing child widgets, and if those child widgets also implement `operator ==`, it ultimately results in a complete walk of the widget tree... which is then repeated at each level of the tree. In practice, just rebuilding is cheaper. (Additionally, if *any* subclass of [Widget] used in an application implements `operator ==`, then the compiler cannot inline the comparison anywhere, because it has to treat the call as virtual […].)"_

and its alternative:

> _"Instead, the best way to avoid unnecessary rebuilds is to cache the widgets that are returned from [State.build], so that each frame the same widgets are used until such time as they change. […] `const` widgets, for example, are a form of automatic caching."_

The rule is enforced only by the analyzer. `Widget` marks `==` and `hashCode` `@nonVirtual` ([source][fw-widget-eq]), and an override is a warning, not an error. The VM still dispatches to an override, so the equality skip _works_ when forced:

```text
probe (Flutter 3.47.4, flutter analyze) — a StatelessWidget `Label` overriding == and hashCode
warning • The member '==' is declared non-virtual in 'Widget' and can't be overridden in subclasses • lib/eq_probe.dart:7:17 • invalid_override_of_non_virtual_member
warning • The member 'hashCode' is declared non-virtual in 'Widget' and can't be overridden in subclasses • lib/eq_probe.dart:9:11 • invalid_override_of_non_virtual_member
```

```text
probe (Flutter 3.47.4, flutter test) — same override (warnings ignored); pumpWidget(Eq(['x'].join())) four times
Eq builds over 4 pumps: 1
```

The cost argument is specific to Flutter's representation: a widget's children are other widget objects, so a deep `==` is a tree walk, and nothing records that a subtree was already compared. A skip test that compares only a node's own inputs (with children identified separately) does not have the quadratic shape.

### `const` as canonicalised caching

A `const` constructor call is evaluated at compile time and canonicalised: equal arguments give the _same_ instance, so `child.widget == newWidget` holds on every rebuild and `updateChild` returns before touching the subtree. The `StatelessWidget` performance notes list _"Use `const` widgets where possible, and provide a `const` constructor for the widget so that users of the widget can also do so"_ ([source][fw-stateless-perf]); the `StatefulWidget` notes call a cached widget _"massively more efficient"_ than _"a new (but identically-configured) widget"_ and `const` _"equivalent to caching a widget and re-using it"_ ([source][fw-stateful-perf]). Inside Flutter names the cached-child idiom the _reprojection_ pattern ([Inside Flutter][inside]); `AnimatedBuilder.child` is the framework's own instance of it ([`rebuild` doc][fw-not-rebuilding]).

```dart
// probe source (abridged): Counted.build counts its calls per label
class ParentState extends State<Parent> {
  final Widget cached = Counted('cached');     // not const, but one instance
  void poke() => setState(() {});
  @override
  Widget build(BuildContext context) => Column(children: <Widget>[
    const Counted('const'),
    cached,
    Counted('fresh'),                           // field-for-field equal, new object
  ]);
}
```

```text
probe (Flutter 3.47.4, flutter test) — mount, then 3 × setState
builds after 1 mount + 3 setState: {const: 1, cached: 1, fresh: 4}
```

What matters is identity, not the `const` keyword: the `cached` field, built once in `State`, skips exactly like the canonical constant, and the equal `fresh` instance rebuilds every time. `const` is the language's way of making identity follow from equal compile-time arguments; it is unavailable as soon as any argument is a runtime value (a callback, a `State` field, a list built from data).

### Lifecycle that a rebuild drives

| Hook                         | Called when                                                                                                                                    | Source                                                                          |
| ---------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| `createState`, `initState`   | inflation of a `StatefulWidget`; `initState` then `didChangeDependencies` precede the first `build`                                            | [`StatefulElement._firstBuild`][fw-stateful-el]                                 |
| `didUpdateWidget(oldWidget)` | the parent supplied a new, `canUpdate`-compatible widget; `state.widget` is already the new one; `build` always follows                        | [`State.didUpdateWidget`][fw-didupdatewidget], [`update`][fw-stateful-update]   |
| `didChangeDependencies`      | an `InheritedWidget` this element depends on notified; deferred to the start of the next `performRebuild`                                      | [`StatefulElement.performRebuild`][fw-stateful-el]                              |
| `deactivate`                 | the element left its parent this frame (it may be reinserted via a `GlobalKey` before the frame ends)                                          | [`_InactiveElements`][fw-inactive], [`deactivateChild`][fw-deactivatechild]     |
| `activate`                   | a deactivated element was reinserted; `StatefulElement.activate` then marks itself dirty so `build` reallocates whatever `deactivate` released | [`StatefulElement.activate`][fw-stateful-activate]                              |
| `dispose`                    | `finalizeTree` at the end of the frame unmounts every element still inactive, deepest first                                                    | [`finalizeTree`][fw-finalize], [`StatefulElement.unmount`][fw-stateful-unmount] |

`build` lives on `State`, not on `StatefulWidget`, partly so that closures created in `build` capture the long-lived `State` rather than a widget that the next rebuild replaces: with the build on the widget, a closure _"would implicitly refer to the original widget and the `$color` still prints blue even through the widget has been updated to green"_ ([`State.build`][fw-state-build-closure]).

---

## Keys and identity

### Key classes

| Key                             | Equality                               | Scope                                                    | Source                                                  |
| ------------------------------- | -------------------------------------- | -------------------------------------------------------- | ------------------------------------------------------- |
| none                            | —                                      | position among siblings, plus `runtimeType`              | [`canUpdate`][fw-canupdate]                             |
| `ValueKey<T>(value)`            | `runtimeType` and `value ==`           | siblings                                                 | [`key.dart`][key-value]                                 |
| `ObjectKey(value)`              | `runtimeType` and `identical(value)`   | siblings                                                 | [`framework.dart`][fw-objectkey]                        |
| `UniqueKey()`                   | identity of the key                    | siblings; a fresh one every build forces a fresh element | [`key.dart`][key-unique]                                |
| `GlobalKey` / `GlobalObjectKey` | identity of the key (or of the object) | the whole app, through `BuildOwner._globalKeyRegistry`   | [`GlobalKey`][fw-globalkey], [registry][fw-gk-registry] |

Keys are the one place widget equality _is_ value equality. A `LocalKey` is just a sibling discriminator ([`LocalKey`][key-local]); it does not identify anything outside its parent's child list.

### `updateChildren`: top scan, bottom scan, key map

`MultiChildRenderObjectElement.update` calls `updateChildren(oldChildren, newWidgets)` ([source][fw-multichild-update]). The algorithm comment ([`updateChildren`][fw-updatechildren]):

> _"The cases it tries to optimize for are: the old list is empty; the lists are identical; there is an insertion or removal of one or more widgets in only one place in the list. If a widget with a key is in both lists, it will be synced. Widgets without keys might be synced but there is no guarantee."_

1. **Top.** Walk both lists forward while `canUpdate(old, new)` holds, calling `updateChild` on each pair.
2. **Bottom.** Walk both lists backward while `canUpdate` holds, _without_ syncing yet, so that every sync happens in new-list order.
3. **Middle, old side.** Put each remaining old child with a key into `Map<Key, Element>`; deactivate each remaining old child without a key at once.
4. **Middle, new side.** For each remaining new widget: if it has a key and the map holds a `canUpdate`-compatible element, take it out of the map and update it; otherwise inflate a new element (`updateChild(null, …)`).
5. **Bottom again.** Sync the pairs found in step 2.
6. **Leftovers.** Deactivate whatever is still in the key map.

The slot passed to each child is an `IndexedSlot(index, previousSibling)`, so a moved child's render object is re-inserted after its new previous sibling, and a child whose index changed gets a new slot even if its previous sibling did not ([doc][fw-updatechildren]).

Two consequences follow from step 3. Unkeyed widgets of the same type always match in the top scan, so without keys **state stays with the position**. And an unkeyed child that falls inside the unmatched middle range is always rebuilt from scratch, even if it did not move:

```text
probe (Flutter 3.47.4, flutter test) — a Column of StatefulWidget Item(label); each State
records the label it was created with ("bornAs"); pairs are widget<-state, then the lifecycle log
no keys   : c<-a a<-b b<-c |
ValueKey  : c<-c a<-a b<-b |
mixed     : k2<-k2 u<-u k1<-k1 | init u, dispose u
```

- **no keys**, `[a, b, c]` → `[c, a, b]`: every `State` stays at its position and receives another item's widget.
- **`ValueKey`**, same reorder: each `State` follows its key; nothing is created or disposed.
- **mixed**, `[k1, u, k2]` → `[k2, u, k1]`: both scans stop at once, so the unkeyed `u` lands in the middle range and is disposed and recreated although it never moved.

Inside Flutter summarises the same algorithm and its limit: _"Unmatched children are discarded and rebuilt from scratch whereas matched children are rebuilt with their new widgets"_ ([Inside Flutter][inside]). There is no minimal-move computation; moves fall out of reinsertion by slot.

### `GlobalKey` reparenting

`inflateWidget` first asks `_retakeInactiveElement` whether the new widget's `GlobalKey` names an element that exists elsewhere ([`inflateWidget`][fw-inflate]). If it does and `canUpdate` holds, the element is detached from its old parent (`forgetChild`, `deactivateChild`), removed from the inactive set, re-activated under the new parent and updated with the new widget ([`_retakeInactiveElement`][fw-retake]). The move has to happen within one frame, because `finalizeTree` unmounts whatever is still inactive at the end of it ([`finalizeTree`][fw-finalize]).

```text
probe (Flutter 3.47.4, flutter test) — Item('x') moves from under a Padding to under a Center in one pump
move ValueKey : init x, init x, dispose x
move GlobalKey: init x
```

A `LocalKey` only discriminates siblings, so the move creates a new `State` and disposes the old one; the `GlobalKey` carries the `State` (and its subtree) across.

The class doc prices it: _"Reparenting an [Element] using a global key is relatively expensive, as this operation will trigger a call to [State.deactivate] on the associated [State] and all of its descendants; then force all widgets that depends on an [InheritedWidget] to rebuild"_ ([`GlobalKey` doc][fw-globalkey-doc]). The rebuild comes from `Element.activate`, which clears the element's dependencies and calls `didChangeDependencies` if it had any, because its inherited map may now differ ([`activate`][fw-activate]). The doc also warns that a `GlobalKey` created in `build` _"will throw away the state of the subtree associated with the old key and create a new fresh subtree for the new key"_ every frame.

---

## `InheritedWidget`: the only dependency tracking

Every element carries `_inheritedElements`, a `PersistentHashMap<Type, InheritedElement>` copied by reference from its parent; an `InheritedElement` stores `parent.put(widget.runtimeType, this)` ([`_inheritedElements`][fw-inherited-map], [`_updateInheritance`][fw-inherit-update]). Lookup is therefore one hash probe, not a walk up the ancestors; Inside Flutter gives the reason: parent walks _"would become O(N²) in the depth of the tree"_ ([Inside Flutter][inside]).

`dependOnInheritedWidgetOfExactType<T>()` finds the element and calls `dependOnInheritedElement`, which adds it to the caller's `_dependencies` set and the caller to the ancestor's `_dependents` map ([source][fw-depend]). When the `InheritedWidget` is rebuilt with a new instance, `InheritedElement.updated` calls `notifyClients` only if `widget.updateShouldNotify(oldWidget)` returns true ([`updated`][fw-updated]); `notifyClients` calls `notifyDependent` for every dependent, which calls `didChangeDependencies`, which calls `markNeedsBuild` ([`notifyClients`][fw-notify-clients], [`didChangeDependencies`][fw-didchangedeps]). The dependents are thus scheduled in the same `buildScope` pass, below the inherited widget, wherever they sit.

| Property            | Behaviour                                                                                                                                                                                                                                                                 |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Granularity         | per element (a whole `build`), per inherited widget type; `updateShouldNotify` is a user-written equality on the inherited data                                                                                                                                           |
| Recording           | dynamic: whatever `build` called `dependOn…` on                                                                                                                                                                                                                           |
| Forgetting          | **never while active.** `_dependencies` is not cleared per rebuild; it is unregistered in `deactivate` and cleared in `activate` ([`_ensureDeactivated`][fw-deactivate], [`activate`][fw-activate]). A dependency taken once on a branch no longer reached still notifies |
| Non-dependent reads | `getInheritedWidgetOfExactType` reads without subscribing                                                                                                                                                                                                                 |
| Aspects             | `InheritedModel<T>` stores a `Set<T>` of aspects per dependent and asks `updateShouldNotifyDependent(oldWidget, aspects)` ([`InheritedModelElement`][im-element], [`InheritedModel`][im-model])                                                                           |

`InheritedModel` is the finest grain Flutter's core offers: _"When the model is rebuilt, dependents will also be rebuilt, but only if there was a change in the model that corresponds to the aspect they provided"_ ([`inherited_model.dart`][im-doc]). Its aspect set, like the dependency set, only grows while the element is active ([`updateDependencies`][im-element]). Everything else that looks reactive (`ValueListenableBuilder`, `AnimatedBuilder`, `ListenableBuilder`) is a `StatefulWidget` that listens and calls `setState`, i.e. the coarse mechanism at a smaller subtree.

---

## Layout

The protocol itself — constraints down, sizes up, parent sets position, `BoxConstraints` and the three constraint regimes — is covered in [the layout survey][layout-flutter]. What matters here is what layout reuses.

**Single pass with an equality early-out.** `RenderObject.layout(constraints, parentUsesSize:)` returns immediately when the node is not dirty and the constraints equal the previous ones ([`layout`][ro-layout]):

```dart
// packages/flutter/lib/src/rendering/object.dart — RenderObject.layout (abridged)
_isRelayoutBoundary = !parentUsesSize || sizedByParent || constraints.isTight || parent == null;
if (!_needsLayout && constraints == _constraints) {
  return;                                      // reuse last size and child positions
}
_constraints = constraints;
if (sizedByParent) performResize();
performLayout();
_needsLayout = false;
markNeedsPaint();
```

So the layout cache key is **value equality of the incoming constraints**, and a parent's `performLayout` is told to call `layout` on every child unconditionally; the child decides ([doc][ro-layout]). Inside Flutter: _"the only information that flows from parent to child are the constraints and the only information that flows from child to parent is the geometry"_ ([Inside Flutter][inside]).

**Relayout boundaries.** In 3.47 the boundary is a flag, `bool? _isRelayoutBoundary`, recomputed in every `layout` call from the formula above ([source][ro-relayout-flag]; older releases kept a `_relayoutBoundary` pointer to the boundary node). `markNeedsLayout` sets `_needsLayout` and, if the node is a boundary, adds it to the `PipelineOwner`'s `_nodesNeedingLayout`; otherwise it calls `markParentNeedsLayout`, which recurses up ([`markNeedsLayout`][ro-markneedslayout], [`markParentNeedsLayout`][ro-markparent]). `flushLayout` sorts the dirty boundaries by depth and calls `_layoutWithoutResize` on each still-dirty one ([`flushLayout`][ro-flushlayout]). A node is a boundary when its parent ignores its size (`parentUsesSize: false`), when its size depends only on constraints (`sizedByParent`), or when the constraints are tight.

**`sizedByParent` and dry layout.** A `sizedByParent` box computes its size in `performResize` from constraints alone; `RenderBox.performResize` defaults to `computeDryLayout(constraints)` ([`sizedByParent`][ro-sizedbyparent]). Dry layout, `getDryLayout(constraints)`, answers "what size would you take" _"without changing any internal state"_ and must agree with real layout ([`getDryLayout`][box-drylayout]).

**Intrinsics and their cost.** `getMinIntrinsicWidth` and its three siblings, `getDryLayout` and `getDryBaseline` all carry the same doc line: _"Calling this function is expensive as it can result in O(N^2) behavior"_ ([`getMinIntrinsicWidth`][box-intrinsic], [`getDryLayout`][box-drylayout]). Results are memoized per node in `_LayoutCacheStorage`, maps keyed by `(dimension, extent)` or by `BoxConstraints` ([source][box-cache]), and the price of that cache is a dependency that crosses relayout boundaries: `RenderBox.markNeedsLayout` clears the cache and, if it was non-empty, calls `markParentNeedsLayout` _"regardless of relayout boundaries"_ ([source][box-markneedslayout]). `IntrinsicWidth`/`IntrinsicHeight` are documented as _"relatively expensive, because it adds a speculative layout pass before the final layout phase. […] In the worst case, this render object can result in a layout that is O(N²) in the depth of the tree"_ ([`proxy_box.dart`][pb-intrinsic]).

---

## Paint and compositing

**Repaint boundaries.** `markNeedsPaint` sets `_needsPaint` and walks up until it reaches a node with `isRepaintBoundary && _wasRepaintBoundary`, which it adds to `_nodesNeedingPaint` ([`markNeedsPaint`][ro-markneedspaint]). Everything painted into the same layer as the dirty node repaints. `flushPaint` processes the list deepest first and calls `PaintingContext.repaintCompositedChild` for each, which reuses the boundary's `OffsetLayer`, removes its children and repaints the subtree into it ([`flushPaint`][ro-flushpaint], [`_repaintCompositedChild`][ro-repaint]). Going down, `paintChild` stops recording at a repaint-boundary child and `_compositeChild` either repaints it (if dirty) or **appends its existing layer with a new offset** ([`paintChild`][ro-paintchild], [`_compositeChild`][ro-compositechild]). The `RepaintBoundary` doc states the trade: _"This widget creates a separate display list for its child, which can improve performance if the subtree repaints at different times than the surrounding parts of the tree"_ ([`RepaintBoundary`][basic-repaint]). Below the boundary, paint is all-or-nothing: there is no per-node display-list reuse inside one layer.

**Layer-property updates.** `markNeedsCompositedLayerUpdate` lets a repaint boundary change a property of its own layer (opacity, for `RenderOpacity`) without repainting its children; `flushPaint` routes such nodes to `PaintingContext.updateLayerProperties` ([`markNeedsCompositedLayerUpdate`][ro-layerupdate], [`opacity` setter][ro-opacity-setter]).

**Compositing bits.** `needsCompositing` says whether a node or a descendant creates a layer; ancestors that clip or transform must then push a layer instead of drawing directly. `markNeedsCompositingBitsUpdate` walks up until a repaint boundary (or an already-dirty node) and enqueues; `flushCompositingBits` recomputes the bits top-down in depth order ([`markNeedsCompositingBitsUpdate`][ro-compbits], [`flushCompositingBits`][ro-flushcomp]). It does not schedule a frame, since _"it cannot be the case that *only* the compositing bits changed"_.

A probe makes the regions visible. Three leaf render objects sit in a `Row` under an `Align`: `tight` inside a `SizedBox` (tight constraints), `loose` directly in the row (the row reads its size), and `other`, optionally wrapped in a `RepaintBoundary`. A pass-through `RenderProxyBox` above the row counts its own layouts; every leaf counts layouts and paints, and its setter skips equal values.

```text
probe (Flutter 3.47.4, flutter test) — Align > Counter('above-row') > Row[SizedBox(Leaf tight), Leaf loose, Leaf other]
same values (no-op)          layouts={} paints={}
tight leaf changes           layouts={tight: 1} paints={tight: 1, loose: 1, other: 1}
loose leaf changes           layouts={above-row: 1, loose: 1} paints={tight: 1, loose: 1, other: 1}
tight changes, other in RB   layouts={tight: 1} paints={tight: 1, loose: 1}
```

1. **No-op.** Equal widget fields reach `updateRenderObject`, the setter compares and returns: no layout, no paint.
2. **Tight leaf.** It is its own relayout boundary, so only it is laid out; but it is not a repaint boundary, so the whole root layer repaints, siblings included.
3. **Loose leaf.** Dirtiness climbs through `Row` and the counting box to `Align` (the first node under tight constraints); `tight` and `other` are asked to lay out again with equal constraints and return early, so they do not appear.
4. **`other` behind a `RepaintBoundary`.** Its layer is reused, so it is not repainted.

---

## The frame pipeline

`SchedulerBinding` drives one frame in two engine callbacks ([`SchedulerPhase`][sb-phase]):

| Phase                 | Entry                                                           | Work                                                                                                     |
| --------------------- | --------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| `transientCallbacks`  | `handleBeginFrame` ([source][sb-begin])                         | `scheduleFrameCallback` callbacks with the frame timestamp: `Ticker`s, hence every `AnimationController` |
| `midFrameMicrotasks`  | after `handleBeginFrame` returns                                | microtasks queued by the animation callbacks                                                             |
| `persistentCallbacks` | `handleDrawFrame` ([source][sb-draw])                           | `WidgetsBinding.drawFrame`: build (`buildScope`), then `RendererBinding.drawFrame`, then `finalizeTree`  |
| ↳ build               | `buildOwner!.buildScope(rootElement!)` ([source][wb-drawframe]) | rebuild dirty elements, depth order                                                                      |
| ↳ layout              | `rootPipelineOwner.flushLayout()` ([source][rb-drawframe])      | dirty relayout boundaries, depth order; `LayoutBuilder`s may build here                                  |
| ↳ compositing bits    | `flushCompositingBits()`                                        | recompute `needsCompositing`                                                                             |
| ↳ paint               | `flushPaint()`                                                  | dirty repaint boundaries, deepest first, into layers                                                     |
| ↳ composite           | `renderView.compositeFrame()`                                   | layer tree → `Scene` → engine                                                                            |
| ↳ semantics           | `flushSemantics()`                                              | accessibility tree to the OS                                                                             |
| ↳ finalize            | `buildOwner!.finalizeTree()`                                    | unmount still-inactive elements (`dispose`), verify `GlobalKey` uniqueness in debug                      |
| `postFrameCallbacks`  | rest of `handleDrawFrame`                                       | `addPostFrameCallback` callbacks, then `idle`                                                            |

The ten-step list in the `drawFrame` doc is the authoritative statement of this order ([`WidgetsBinding.drawFrame`][wb-drawframe]). A `setState` from an event handler marks the element, which requests a frame; the rebuild happens at the next vsync, so state writes within one event are batched for free.

---

## The authoring syntax

A Flutter UI is a nested expression of constructor calls with named arguments. `child:` and `children:` are ordinary named parameters (`Padding({super.key, required this.padding, super.child})`, [`Padding`][basic-padding]); a widget with two content slots simply has two named parameters. Since Dart 2, `new` is optional and `const` is implied inside a constant context; since Dart 2.3 collection `if`/`for`/spread let a `children:` list stay one expression. The motivation section of that feature is a statement of Flutter's syntax goal ([`control-flow-collections`][lang-cfc]):

> _"A key goal of Flutter's API design is that, as much as possible, the textual layout of the code reflects the nesting structure of the resulting user interface. If a Button constructor call is nested inside a Padding constructor, that button is surrounded by that padding on the screen. Ideally, a `build()` method for a widget is a single nested expression tree that you can read from top-to-bottom and outside-in."_

**Depth and closing labels.** Because every wrapper (`Padding`, `Center`, `Expanded`, `GestureDetector`) is a widget, nesting is deep and the closing `)` run is long. The tooling answer is editor-rendered **closing labels**: the analysis server's `analysis.closingLabels` notification reports _"a useful label associated with some range which may be useful to display to the user within the editor at the end of the range to indicate what construct is closed at that location. Closing labels include constructor/method calls and List arguments that span multiple lines"_ ([analysis server API, `3.13.3`][dart-closing-labels]). The formatter's "tall" style, which prefers block indentation for nested Flutter code, is covered in [the `dart_style` deep-dive][dart-style].

**Requests for markup.** The long-running request for JSX-like syntax was [flutter/flutter#11609][gh-11609], _"Consider JSX-like syntax inside dart code"_ (opened 2017-08-14, 239 comments, closed and locked 2018-08-01; read through the GitHub API on 2026-11-24). The team's recorded positions in it:

- Named slots are not special: _"'child' and 'children' aren't special. Consider ListTile for example. […] XML-ish syntax just doesn't seem to handle this very well"_ ([Hixie, 2017-08-15][gh-11609-slots]).
- Prior art: a former Adobe Flex engineer listed the costs of markup-plus-code (code dominating real apps, IDE complexity, evolving the XML schema) ([HansMuller, 2017-08-17][gh-11609-flex]).
- Large build methods are a performance anti-pattern: _"having a build method that's built out of the results of other methods is somewhat of an antipattern that we'd rather discourage rather than make easier"_ ([Hixie, 2017-08-21][gh-11609-perf]). This is the rebuild model talking: a widget is a rebuild and identity boundary, a helper method is neither (the [`prefer_const_over_helper` template][fw-stateless-perf] says the same).
- The direction taken instead was language sugar, sketched in the thread as _"Remove "new" and "const", infer the class for enum values, allow int literals for doubles"_ ([Hixie, 2018-01-19][gh-11609-sugar]); the closing comment points any markup effort at build-system code-generation hooks ([Hixie, 2018-08-01][gh-11609-close]).

Each of those sugar items has since shipped (versions from the `accepted/` directory names of `dart-lang/language`, Dart 2.0 from general knowledge, unverified locally): optional `new` and implicit `const` (Dart 2), int-to-double literals (2.1), collection control flow (2.3), **dot shorthands** (3.10, [`dot-shorthands`][lang-dot]) and **primary constructors** (3.13, [`primary-constructors`][lang-primary], _"a conciseness feature. It does not provide any new semantics at all"_). On this SDK both compile in a widget:

```dart
// probe source (Dart 3.13.3)
class const Greeting({super.key, required final String name}) extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: .center,
    children: [Text('hi $name', textDirection: .ltr)],
  );
}
```

```text
probe (Flutter 3.47.4, flutter test) — pumpWidget(const Directionality(textDirection: .ltr, child: Greeting(name: 'D')))
found: 1
```

A further proposal in `working/`, implied argument names (`:onError` for `onError: onError`), targets the same repetition ([`3102 - implied-name`][lang-implied]); it is not accepted. No markup syntax has been accepted, and no `jsx`/`markup` proposal exists in `dart-lang/language` at `c61daed`.

---

## Known pain points and limitations

1. **Rebuild granularity is the `build` method.** `setState` rebuilds the whole subtree that `build` constructs, down to every non-identical widget: _"The indirect cost […] is high: it causes the widget to rebuild, possibly triggering rebuilds for the entire subtree rooted at this widget, and further triggering a relayout and repaint of the entire corresponding [RenderObject] subtree"_ ([`setState`][fw-setstate-perf]). The documented cure is structural: _"Push the state to the leaves"_ ([`StatefulWidget`][fw-stateful-perf]).
2. **The `const` discipline.** The skip works only when the author can make the widget a compile-time constant or cache it by hand. A single runtime argument anywhere in a subtree's constructor call defeats `const` for that whole expression, and the analyzer lints (`prefer_const_constructors`) exist to keep authors doing it.
3. **Equality is off limits for widgets** but is the rule one layer down (render-object setters, constraints, `updateShouldNotify`). The author has to know which layer they are in.
4. **Changing shape costs state.** Wrapping a child conditionally changes its depth or type, which fails `canUpdate`; the docs say to _"always wrap the child widget in an [IgnorePointer] and control the [IgnorePointer.ignoring] property"_ instead, or to hold the common part with a `GlobalKey` ([`StatefulWidget`][fw-stateful-perf]).
5. **Lists need keys, and unkeyed children in a changed range are recreated** (probe above).
6. **`GlobalKey` is expensive and easy to misuse**: reparenting deactivates the subtree and rebuilds its inherited dependents; one created in `build` destroys its subtree every frame ([`GlobalKey`][fw-globalkey-doc]).
7. **`build` purity is a convention.** `build` may run on any parent rebuild, dependency change or hot reload (_"During a hot reload, every element is marked dirty"_, [`rebuild` doc][fw-rebuild-doc]); work belongs in `initState`/`didUpdateWidget`. `setState` during build of a non-descendant, `setState` after `dispose`, and ancestor lookups from a deactivated element all throw in debug only ([`markNeedsBuild`][fw-markneedsbuild], [`setState`][fw-setstate], [`dependOn…` checks][fw-inherited-map]).
8. **`BuildContext` is an `Element`.** It is valid only while mounted; holding it across an `await` is the classic bug, and `mounted` checks are the defence the `setState` error message recommends ([`setState`][fw-setstate]).
9. **Intrinsics break boundaries**: an intrinsic or dry-layout query makes the child's next `markNeedsLayout` climb past relayout boundaries ([`RenderBox.markNeedsLayout`][box-markneedslayout]).
10. **Repaint is per layer**: any `markNeedsPaint` repaints everything up to the nearest repaint boundary, and boundaries cost a layer each, so choosing them is a manual profiling exercise (`debugRepaintRainbowEnabled`, [`RepaintBoundary`][basic-repaint]).

---

## Strengths

- **A pure-function authoring model** with real persistent state behind it: `build` reads like immediate mode, `State` and render objects are retained.
- **Cheap, sound skip test.** Pointer equality is O(1), needs no user code, and is correct by immutability.
- **Linear reconciliation per child list**, with keys as an explicit, local escape hatch and `GlobalKey` for non-local moves.
- **Every phase is dirty-list driven and depth sorted**; layout reuse keys on constraint equality, paint reuse on layers.
- **The framework is plain Dart**: every widget, including `Row` and `Text`, is library code a user could have written.

## Weaknesses

- **Two reconciliations stand between a state change and a pixel**: widget against element, then configuration against render object.
- **Skipping depends on author discipline** (`const`, caching, splitting widgets, keys).
- **Coarse dependency tracking**: per element, never forgotten while active; anything finer is `InheritedModel` or a listener widget.
- **Lifecycle complexity**: `deactivate`/`activate`/`dispose`, `didUpdateWidget`, `didChangeDependencies`, and their ordering rules, all to keep a retained tree consistent with a rebuilt description.
- **Deep syntax**: nesting is the composition model, and the tooling (closing labels, formatter) compensates rather than removes it.

## Key design decisions and trade-offs

| Decision                                                                  | Rationale                                                                                        | Trade-off                                                                                                 |
| ------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------- |
| Immutable widgets rebuilt wholesale; retained elements and render objects | `build` is a pure function; persistent state lives elsewhere                                     | Allocation per rebuild; a second tree to keep in sync; lifecycle hooks for every way they can disagree    |
| Identity short-circuit, `==` non-virtual                                  | O(1), no user code, sound by immutability; avoids an O(N²) deep compare and keeps `==` inlinable | Equal-but-new widgets always rebuild; skipping needs `const` or manual caching                            |
| `canUpdate` = `runtimeType` + `key`                                       | Cheap, predictable identity                                                                      | Position-based state without keys; depth or type changes lose state                                       |
| Per-list O(N) top/bottom/key-map reconciliation                           | Handles the common edits linearly                                                                | Unkeyed middle children recreated; no minimal moves                                                       |
| `GlobalKey` registry for reparenting                                      | Non-local moves (hero transitions, navigation) keep state                                        | Global hash table; deactivate/activate of the subtree; dependents rebuild                                 |
| `InheritedWidget` hash map per element, notify via `updateShouldNotify`   | O(1) lookup, no ancestor walks                                                                   | Element-level granularity; dependencies sticky until deactivation                                         |
| Constraint-equality layout early-out, relayout boundaries as a flag       | Sublinear relayout in the common case                                                            | Intrinsics and baselines add cross-boundary dependencies; `parentUsesSize` must be stated by every parent |
| Repaint boundaries own layers                                             | Clean subtrees composited by reference                                                           | All-or-nothing repaint inside a layer; each boundary costs a layer, chosen by hand                        |

---

## Lessons for a D UI toolkit

The design question: [`sparkles:ui`][sparkles-ui] has no retained element or DOM tree; it rebuilds a widget arena of 256-byte nodes every frame and derives draw ops from it. The working idea is that the per-frame rebuild _is_ the semantics, with speed from compile-time markup (static subtrees as constant data), skipping a subtree whose inputs compare equal (reusing its nodes, layout and op range), and identity from source position plus a loop key. Flutter is the closest prior art: it also rebuilds cheap descriptions, but keeps two retained trees to make that affordable.

### What the Element tree buys, and what an arena must reproduce

| Flutter's Element provides                       | Mechanism                                                              | Per-frame arena equivalent                                                                                                                                                                                                          |
| ------------------------------------------------ | ---------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Stable identity across rebuilds                  | the element object itself; `canUpdate` (type + key) decides continuity | an identity key per node: (static call-site id, loop key) hashed with the parent's id. Source position replaces `runtimeType` (strictly finer: two `Text` calls at different sites are different), the loop key replaces `LocalKey` |
| `State` storage                                  | `StatefulElement.state`                                                | a side table keyed by identity, surviving frames, not stored in the arena                                                                                                                                                           |
| `initState` / `dispose`                          | inflate / `finalizeTree` unmount                                       | after the build, diff the set of identities seen this frame against last frame's: new keys get init, missing keys get dispose — one hash-set difference per frame, no tree walk                                                     |
| `didUpdateWidget(old)`                           | `update` hands the previous widget                                     | keep the previous frame's inputs for each stateful identity (or just its input hash) so the hook can compare                                                                                                                        |
| `deactivate`/`activate`, `GlobalKey` reparenting | inactive set, `_globalKeyRegistry`, end-of-frame unmount               | free, if identity does not include the parent path: an explicitly global key that is found anywhere this frame keeps its state. The one-frame rule becomes "seen in this frame's build"                                             |
| Dependency tracking (`InheritedWidget`)          | per-element sets, `updateShouldNotify`                                 | not needed for correctness — everything is rebuilt; needed only to invalidate a skip (below)                                                                                                                                        |

Flutter's probe results translate directly. With position-only identity, a reordered list keeps state by position (`no keys`); with keyed identity, state follows (`ValueKey`). An arena keyed by (site, loop key) avoids the `mixed` case by construction: an unkeyed node's identity is its own site, not its index in a changed middle range, so siblings moving around it do not recreate it.

### The skip: identity in Flutter, value in the plan

Flutter's `identical` skip is the "skip by value" idea with the comparison made free by construction: the author proves equality, by `const` or by caching, and the framework checks a pointer. It rejected deep `==` for two reasons ([above](#why-identity-and-not-equality)): a widget's children are widgets, so `==` is a tree walk repeated at every level, and a virtual `==` blocks inlining. Neither reason holds for the plan as stated:

- **Compare a node's own inputs, not its subtree.** If a skippable subtree is a compiled component whose inputs are a fixed struct of values (props) and whose children are static markup or are themselves keyed by site, then "inputs equal" is one `memcmp`/`==` on that struct. Children are covered by the recursion, not by the comparison.
- **Static subtrees are identity-equal by construction.** Compile-time markup with no dynamic holes is Flutter's `const`, made automatic: the D compiler knows it, as `const` in Dart does, and needs no author discipline.
- **What breaks a value skip is hidden input.** Flutter's `const` child is still rebuilt when an `InheritedWidget` it depends on changes, because `didChangeDependencies` marks it dirty independently of its parent ([`InheritedElement.notifyClients`][fw-notify-clients]). A sparkles skip needs the same: theme, locale, hover/focus state and any ambient read must be part of the compared inputs, or must invalidate the subtree. Making ambient values explicit inputs is simpler than per-node dependency sets, and Flutter's sticky dependency sets show how coarse the tracked version ends up.
- **Equality on floats and closures.** Flutter's setters compare `double`s with `==` and its widgets hold closures that are never equal across rebuilds (one reason it could not use widget equality in practice). A D props struct with delegate fields has the same problem; either delegates are excluded from the skip comparison (and read through the identity's stored state) or a subtree with fresh closures never skips.

### Boundaries as the analogue of reusing layout and op ranges

| Flutter                                                                                                                  | Reuse in a per-frame arena                                                                                                                                                                                     |
| ------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `layout()` early-out: not dirty and `constraints == _constraints` ([source][ro-layout])                                  | a skipped subtree also reuses its last layout if the constraints handed to its root are equal; cache key = (inputs hash, constraints)                                                                          |
| Relayout boundary: parent ignores child's size, or constraints are tight                                                 | a subtree whose size cannot affect its parent (fixed or tight slot) can be re-laid out alone; without that, a changed subtree's size must propagate up to the first such node, as `markParentNeedsLayout` does |
| Intrinsics/dry layout crossing boundaries ([source][box-markneedslayout])                                                | any measure-before-layout query creates a dependency the skip must honour; a cached measurement belongs to the same key                                                                                        |
| Repaint boundary: clean subtree's layer appended by reference with a new offset ([`_compositeChild`][ro-compositechild]) | a skipped subtree's draw-op range is copied or referenced, translated by the new origin; draw ops in local coordinates make this a range copy plus one offset                                                  |
| Paint is all-or-nothing within a layer                                                                                   | an arena that rebuilds the op stream every frame can be finer than Flutter: every skipped subtree is its own reusable range, with no layer object or compositing bit per boundary                              |

The probe's second row is the warning: Flutter laid out one node and repainted three, because paint reuse exists only at layer granularity. A per-frame op stream with per-subtree ranges does not have that coupling.

### Costs that exist only to keep a retained tree in sync

- **`canUpdate`, `updateChild` and `updateChildren`**: matching a fresh description to old elements. An arena rebuilt from scratch has no old nodes to match; identity is computed, not searched for (a hash lookup in the state table, only for stateful or skippable nodes).
- **`didUpdateWidget`, `updateRenderObject`, and every render-object setter's compare-and-mark**: pushing new configuration into old objects field by field.
- **`deactivate`/`activate`/`finalizeTree` and the inactive set**: needed because an element may leave and re-enter within a frame.
- **`markNeedsBuild`, the dirty list, depth sorting and re-sorting**: needed because only part of the tree rebuilds. A full rebuild has no dirty list; a skip replaces it with an input comparison at each skippable root.
- **Compositing bits and `markNeedsCompositingBitsUpdate`**: bookkeeping for which retained nodes own layers.
- **`GlobalKey` registry cost**: an arena pays it only for nodes that opt into global identity.

What does not go away: state storage and its init/dispose diff, the identity scheme, the layout cache and its invalidation rules, and the requirement that every input to a skipped subtree be visible to the comparison. Those are Flutter's real lessons; the rest is the price of a retained tree.

---

## Sources

- [flutter/flutter at `3.47.4`][repo] · [`LICENSE`][license]
- Widgets: [`framework.dart`][fw-file] — [`Widget`][fw-widget], [`canUpdate`][fw-canupdate], [`StatelessWidget` performance][fw-stateless-perf], [`StatefulWidget` performance][fw-stateful-perf], [`State.setState`][fw-setstate], [`didUpdateWidget`][fw-didupdatewidget], [`State.build` design][fw-state-build-closure], [`InheritedWidget`][fw-inherited-widget], [`BuildScope`][fw-buildscope-class], [`BuildOwner.scheduleBuildFor`][fw-schedulebuildfor], [`buildScope`][fw-buildscope], [`finalizeTree`][fw-finalize], [`Element.updateChild`][fw-updatechild], [`updateChildren`][fw-updatechildren], [`inflateWidget`][fw-inflate], [`_retakeInactiveElement`][fw-retake], [`rebuild`][fw-rebuild], [`InheritedElement`][fw-inherited-el] · [`inherited_model.dart`][im-model] · [`basic.dart` — `Padding`][basic-padding], [`RepaintBoundary`][basic-repaint] · [`layout_builder.dart`][lb-rebuild] · [`binding.dart` — `drawFrame`][wb-drawframe]
- Rendering: [`object.dart`][ro-file] — [`layout`][ro-layout], [`markNeedsLayout`][ro-markneedslayout], [`flushLayout`][ro-flushlayout], [`markNeedsPaint`][ro-markneedspaint], [`flushPaint`][ro-flushpaint], [`paintChild`][ro-paintchild], [`markNeedsCompositingBitsUpdate`][ro-compbits] · [`box.dart`][box-file] — [`getDryLayout`][box-drylayout], [`_LayoutCacheStorage`][box-cache], [`markNeedsLayout`][box-markneedslayout] · [`proxy_box.dart`][pb-intrinsic] · [`shifted_box.dart`][ro-padding-setter] · [`binding.dart`][rb-drawframe]
- Scheduler and foundation: [`scheduler/binding.dart`][sb-phase] · [`foundation/key.dart`][key-value]
- Official docs: [Inside Flutter][inside] (docs.flutter.dev, page last updated 2026-05-05, read 2026-11-24; web page, not pinned)
- Dart language: [`control-flow-collections`][lang-cfc] · [`dot-shorthands`][lang-dot] · [`primary-constructors`][lang-primary] · [`implied-name` (working)][lang-implied] · analysis server [`analysis.closingLabels`][dart-closing-labels]
- Community: [flutter/flutter#11609][gh-11609] (read via the GitHub API, 2026-11-24)
- Related: [Flutter layout][layout-flutter] · [Flutter engine][engine-flutter] · [Flutter slivers][slivers-flutter] · [`dart_style`][dart-style] · [Solid components][solid-components] · [Jetpack Compose][compose] · [Reactive programming survey][index-umbrella] · [`sparkles:ui`][sparkles-ui]

<!-- References -->

[repo]: https://github.com/flutter/flutter/tree/9584c6713b324636289d067944a46fd6b49df14b
[license]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/LICENSE
[src-widgets]: https://github.com/flutter/flutter/tree/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets
[src-rendering]: https://github.com/flutter/flutter/tree/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/rendering
[src-scheduler]: https://github.com/flutter/flutter/tree/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/scheduler
[src-foundation]: https://github.com/flutter/flutter/tree/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/foundation
[fw-file]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/framework.dart
[fw-objectkey]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/framework.dart#L89-L114
[fw-globalkey-doc]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/framework.dart#L116-L158
[fw-globalkey]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/framework.dart#L159-L196
[fw-widget]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/framework.dart#L312-L397
[fw-widget-eq]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/framework.dart#L364-L370
[fw-canupdate]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/framework.dart#L372-L384
[fw-stateless-perf]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/framework.dart#L416-L462
[fw-build-contract]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/framework.dart#L540-L572
[fw-stateful-perf]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/framework.dart#L625-L688
[fw-didupdatewidget]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/framework.dart#L1013-L1036
[fw-setstate-design]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/framework.dart#L1115-L1135
[fw-setstate-perf]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/framework.dart#L1137-L1158
[fw-setstate]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/framework.dart#L1160-L1222
[fw-state-build-closure]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/framework.dart#L1381-L1463
[fw-inherited-widget]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/framework.dart#L1855-L1877
[fw-row-widget]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/framework.dart#L1893-L1938
[fw-inactive]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/framework.dart#L2101-L2184
[fw-buildscope-class]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/framework.dart#L2697-L2888
[fw-schedule-scope]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/framework.dart#L2729-L2742
[fw-flush]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/framework.dart#L2811-L2887
[fw-schedulebuildfor]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/framework.dart#L2947-L3009
[fw-buildscope]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/framework.dart#L3043-L3142
[fw-gk-registry]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/framework.dart#L3161
[fw-finalize]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/framework.dart#L3344-L3458
[fw-element-eq]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/framework.dart#L3570-L3602
[fw-sort]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/framework.dart#L3629-L3643
[fw-updatechild]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/framework.dart#L3950-L4088
[fw-updatechildren]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/framework.dart#L4090-L4321
[fw-retake]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/framework.dart#L4494-L4547
[fw-inflate]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/framework.dart#L4569-L4615
[fw-deactivatechild]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/framework.dart#L4645-L4658
[fw-activate]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/framework.dart#L4767-L4785
[fw-deactivate]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/framework.dart#L4810-L4835
[fw-inherited-map]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/framework.dart#L5055-L5080
[fw-depend]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/framework.dart#L5086-L5102
[fw-inherit-update]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/framework.dart#L6272-L6277
[fw-didchangedeps]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/framework.dart#L5196-L5207
[fw-markneedsbuild]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/framework.dart#L5345-L5404
[fw-rebuild-doc]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/framework.dart#L5435-L5446
[fw-not-rebuilding]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/framework.dart#L5480-L5512
[fw-rebuild]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/framework.dart#L5516-L5552
[fw-component-rebuild]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/framework.dart#L5823-L5873
[fw-stateless-el]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/framework.dart#L5897-L5910
[fw-stateful-el]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/framework.dart#L5913-L5997
[fw-stateful-update]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/framework.dart#L5999-L6021
[fw-stateful-activate]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/framework.dart#L6024-L6032
[fw-stateful-unmount]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/framework.dart#L6041-L6060
[fw-proxy-update]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/framework.dart#L6156-L6163
[fw-inherited-el]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/framework.dart#L6265-L6443
[fw-updated]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/framework.dart#L6402-L6413
[fw-notify-clients]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/framework.dart#L6427-L6442
[fw-ro-rebuild]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/framework.dart#L6819-L6856
[fw-multichild-update]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/framework.dart#L7303-L7314
[im-doc]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/inherited_model.dart#L14-L27
[im-model]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/inherited_model.dart#L121-L216
[im-element]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/inherited_model.dart#L219-L249
[basic-padding]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/basic.dart#L2317-L2341
[basic-repaint]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/basic.dart#L7491-L7544
[lb-rebuild]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/layout_builder.dart#L225-L271
[wb-drawframe]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/binding.dart#L1471-L1597
[wb-buildscheduled]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/binding.dart#L1430-L1460
[rb-drawframe]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/rendering/binding.dart#L691-L702
[ro-file]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/rendering/object.dart
[ro-repaint]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/rendering/object.dart#L128-L186
[ro-paintchild]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/rendering/object.dart#L244-L267
[ro-compositechild]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/rendering/object.dart#L269-L292
[ro-flushlayout]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/rendering/object.dart#L1137-L1204
[ro-flushcomp]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/rendering/object.dart#L1239-L1260
[ro-flushpaint]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/rendering/object.dart#L1293-L1350
[ro-relayout-flag]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/rendering/object.dart#L2545-L2573
[ro-markneedslayout]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/rendering/object.dart#L2638-L2695
[ro-markparent]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/rendering/object.dart#L2707-L2718
[ro-layout]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/rendering/object.dart#L2786-L2944
[ro-sizedbyparent]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/rendering/object.dart#L2955-L2988
[ro-compbits]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/rendering/object.dart#L3194-L3229
[ro-markneedspaint]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/rendering/object.dart#L3318-L3379
[ro-layerupdate]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/rendering/object.dart#L3381-L3418
[box-file]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/rendering/box.dart
[box-cache]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/rendering/box.dart#L1134-L1156
[box-conservative]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/rendering/box.dart#L1207-L1214
[box-intrinsic]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/rendering/box.dart#L1630-L1646
[box-drylayout]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/rendering/box.dart#L2001-L2022
[box-markneedslayout]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/rendering/box.dart#L2839-L2861
[pb-intrinsic]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/rendering/proxy_box.dart#L609-L612
[ro-opacity-setter]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/rendering/proxy_box.dart#L901-L917
[ro-padding-setter]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/rendering/shifted_box.dart#L146-L164
[sb-phase]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/scheduler/binding.dart#L160-L199
[sb-begin]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/scheduler/binding.dart#L1226-L1274
[sb-draw]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/scheduler/binding.dart#L1338-L1376
[key-local]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/foundation/key.dart#L62-L66
[key-unique]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/foundation/key.dart#L72-L83
[key-value]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/foundation/key.dart#L137-L163
[inside]: https://docs.flutter.dev/resources/inside-flutter
[lang-cfc]: https://github.com/dart-lang/language/blob/c61daed2fc5d14091f3518c33fdc59e0ae1148fa/accepted/2.3/control-flow-collections/feature-specification.md#L17-L23
[lang-dot]: https://github.com/dart-lang/language/blob/c61daed2fc5d14091f3518c33fdc59e0ae1148fa/accepted/3.10/dot-shorthands/feature-specification.md
[lang-primary]: https://github.com/dart-lang/language/blob/c61daed2fc5d14091f3518c33fdc59e0ae1148fa/accepted/3.13/primary-constructors/feature-specification.md#L34-L35
[lang-implied]: https://github.com/dart-lang/language/blob/c61daed2fc5d14091f3518c33fdc59e0ae1148fa/working/3102%20-%20implied-name/feature-specification.md
[dart-closing-labels]: https://github.com/dart-lang/sdk/blob/1d1a730ef918d602aedafc939a4cf5940e7589ab/pkg/analysis_server/doc/api.html#L1429-L1462
[gh-11609]: https://github.com/flutter/flutter/issues/11609
[gh-11609-slots]: https://github.com/flutter/flutter/issues/11609#issuecomment-322599663
[gh-11609-flex]: https://github.com/flutter/flutter/issues/11609#issuecomment-323164882
[gh-11609-perf]: https://github.com/flutter/flutter/issues/11609#issuecomment-323850722
[gh-11609-sugar]: https://github.com/flutter/flutter/issues/11609#issuecomment-359098914
[gh-11609-close]: https://github.com/flutter/flutter/issues/11609#issuecomment-409440643
[layout-flutter]: ../ui-layout/flutter.md
[engine-flutter]: ../ui-backend-seam/flutter-engine.md
[slivers-flutter]: ../ui-virtualization/flutter-slivers.md
[dart-style]: ../code-formatting/dart-style.md
[solid-components]: ./solid-components.md
[compose]: ./jetpack-compose.md
[index-umbrella]: ./index.md
[sparkles-ui]: ../../libs/ui/index.md
