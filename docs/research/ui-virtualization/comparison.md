# Comparison and synthesis

What the eleven subjects agree on, where they diverge, and what that implies for
[`sparkles:ui`](../../libs/ui/index.md) and hue's DSV grid.

**Last reviewed:** August 30, 2026

---

## At a glance

| Subject                                                 | Mode                | Window bounds               | Range computed by                  | Retained                        | Extent                    |
| ------------------------------------------------------- | ------------------- | --------------------------- | ---------------------------------- | ------------------------------- | ------------------------- |
| [Dear ImGui](./dear-imgui-clipper.md)                   | immediate           | build + caller's data       | division (measured height)         | item height only                | declared                  |
| [egui](./egui-show-rows.md)                             | immediate           | build + caller's data       | division (given height)            | id-keyed widget state           | declared, exact           |
| [Gio](./gio-list.md)                                    | immediate           | build + caller's data       | walk from an index anchor          | scroll anchor only              | **estimated**             |
| [Ratatui](./ratatui-offsets.md)                         | immediate (TUI)     | **paint/measure only**      | walk from an offset                | offset + selection              | caller-supplied           |
| [Textual](./textual-line-api.md)                        | retained (TUI)      | build + data, per **line**  | compositor-resolved lines          | DOM, styles, strips             | declared (`virtual_size`) |
| [Flutter](./flutter-slivers.md)                         | retained            | build + data                | walk (or division if fixed-extent) | elements + kept-alives          | progressive               |
| [GTK 4](./gtk4-list-factories.md)                       | retained            | build + data                | walk + size cache                  | **widget pool** + model         | estimated, refined        |
| [Qt Quick](./qt-quick-listview.md)                      | retained            | build + data                | walk                               | **delegate pool** + model       | estimated                 |
| [WPF / Avalonia](./avalonia-wpf-virtualizing-panels.md) | retained            | build (+ data if supported) | walk + estimate                    | **container pool** + model      | estimated                 |
| [VS Code](./vscode-listview.md)                         | retained            | build; data materialized    | **prefix sums**, `O(log N)`        | **row pool** + range map        | declared, exact           |
| [Slint](./slint-repeater.md)                            | retained (compiled) | build + data                | division (cached height)           | **instance vector** + model     | declared                  |
| [**sparkles**](./sparkles-baseline.md)                  | immediate           | build + data (`DSN7`)       | division (1 line/row)              | the model + its projection memo | declared, exact           |

---

## The consensus

### Three separable wins, not one

The field has collapsed three distinct optimizations under one word, and keeping
them apart is the most useful thing this survey produces:

| #     | Win                                           | Question it answers                        | Who has it                          |
| ----- | --------------------------------------------- | ------------------------------------------ | ----------------------------------- |
| **1** | **Don't build what you can't see**            | why is startup `O(N)`?                     | everyone, including sparkles        |
| **2** | **Don't re-derive the data you already had**  | why is _scrolling_ `O(N)`?                 | every subject with a model protocol |
| **3** | **Don't rebuild the views you already built** | why is scrolling `O(V)` instead of `O(Δ)`? | the retained subjects only          |

WPF names the boundary between 1 and 3 in its own vocabulary —
`VirtualizationMode.Standard` is win 1, `VirtualizationMode.Recycling` is win 3
([`VirtualizationMode`](./avalonia-wpf-virtualizing-panels.md)) — and ships 1 by
default with 3 opt-in. Qt Quick did the same fifteen years apart: `ListView`
always had win 1; `reuseItems` added win 3 in Qt 5.15, off by default, "for
backwards compatibility reasons" ([Qt Quick](./qt-quick-listview.md)).

Win 2 is the quiet one. It has no catchy name because in most frameworks it is
not an optimization at all — it is a _consequence_ of having a model protocol.
When the view asks `model.item(i)` for the indices it needs, the data cost is
bounded automatically and nobody writes a blog post about it.

### Immediate-mode toolkits take wins 1 and 2, and never win 3

This is the sharpest pattern in the catalog, and it is unanimous across
[Dear ImGui](./dear-imgui-clipper.md), [egui](./egui-show-rows.md) and
[Gio](./gio-list.md):

- All three bound building **and** the caller's data access, via an index range
  or a builder callback.
- **None** of them pools or reuses anything per item. There is nothing to pool:
  an "item" is a few draw calls and a layout cursor advance, not an object.

Dear ImGui's header states the reasoning outright, and it is worth reading as a
claim about _where the cost lives_ rather than about clipping:

> Dear ImGui already clip items based on their bounds but: it needs to first
> layout the item to do so, and generally **fetching/submitting your own data
> incurs additional cost**.
>
> — [`imgui.h`](./dear-imgui-clipper.md)

The toolkit's own per-item cost is small enough that the reason to virtualize is
_the application's_ data cost. That is precisely the shape of the
[sparkles measurement](./sparkles-baseline.md): before `DSN7` the view half was
2.8 ms and the model half 2.4 ms, the latter rising to 7.4 ms the moment a sort
was engaged.

### Recycling exists where constructing a view is expensive

The four subjects that pool — [GTK 4](./gtk4-list-factories.md),
[Qt Quick](./qt-quick-listview.md),
[WPF/Avalonia](./avalonia-wpf-virtualizing-panels.md),
[VS Code](./vscode-listview.md) — all construct genuinely heavy per-item objects:
a DOM subtree, a QML object graph with live bindings, a GTK widget with CSS and
accessibility, a WPF container with a control template. Recycling is worth its
complexity in exact proportion to that weight.

And the complexity is real and consistent. Every one of them documents the same
family of hazards:

| Hazard                                       | GTK 4                  | Qt Quick                                                | WPF/Avalonia                          | VS Code                         |
| -------------------------------------------- | ---------------------- | ------------------------------------------------------- | ------------------------------------- | ------------------------------- |
| Per-item state survives into the next item   | `unbind` must clear it | "Avoid storing any state inside a delegate"             | container-state rule since 2006       | `item.stale` tracking           |
| Async/animated work outlives its item        | cancel on `unbind`     | pause on `pooled`                                       | —                                     | —                               |
| Pooled view is still live                    | —                      | "might still be alive and respond to connected signals" | —                                     | `isReusingConnectedDomNode`     |
| Focus / scroll target must escape the window | —                      | —                                                       | `_focusedElement`, `_scrollToElement` | index-tracked, not node-tracked |

> [!IMPORTANT]
> Recycling is not a faster version of rebuilding — it is a **semantic change**.
> Both Qt Quick and WPF shipped it as an opt-in mode precisely because existing
> item code could not be silently migrated onto it.

### Everyone splits setup from bind — even the ones that rebuild

The setup/bind split is the deepest structural agreement, and it appears in
frameworks that pool and frameworks that do not:

- [GTK 4](./gtk4-list-factories.md): `setup` / `bind` signals on the factory.
- [Slint](./slint-repeater.md): `init()` / `update(index, data)` on
  `RepeatedItemTree`, generated by the compiler.
- [VS Code](./vscode-listview.md): `renderTemplate` / `renderElement` per
  template id.
- [Flutter](./flutter-slivers.md): widget (cheap config) vs element (retained
  state) — the split moved one level up.

Even the immediate-mode subjects have a degenerate form of it: the _structure_ is
recreated per frame but the _identity_ is preserved separately —
[egui's `skip_ahead_auto_ids`](./egui-show-rows.md) is nothing but the bind half
applied to state rather than to content.

### Identity is the universal hazard

Every subject has an identity mechanism, and every one of them exists because
something is keyed by a position that virtualization moves:

- [egui](./egui-show-rows.md) advances its auto-id counter by the skipped-row
  count.
- [Avalonia](./avalonia-wpf-virtualizing-panels.md) keeps the focused and
  scroll-target elements outside the realized window.
- [Flutter](./flutter-slivers.md) carries `semanticIndexCallback` because
  accessibility indices cannot be inferred from a realized subset.
- [Qt Quick](./qt-quick-listview.md) re-binds model roles automatically and warns
  that nothing else is.
- [sparkles](./sparkles-baseline.md) offsets `viewRow` by `windowStart` in
  `DsvCopy.rawCell` — a bug that shipped and was fixed.

The general rule: **any value derived from a view coordinate must be translated
through the window offset, and any state keyed by build order must be keyed by
data identity instead.**

---

## Architectural trade-offs

### Division vs walk vs prefix sums

| Strategy                    | Random access     | Variable sizes | Extent          | Used by                             |
| --------------------------- | ----------------- | -------------- | --------------- | ----------------------------------- |
| **Division**                | `O(1)`            | ✗              | exact, declared | egui, Slint, ImGui, sparkles        |
| **Walk from an anchor**     | ✗ (relative only) | ✓              | estimated       | Gio, Ratatui, GTK, Qt, WPF, Flutter |
| **Prefix sums / range map** | `O(log N)`        | ✓              | exact           | VS Code                             |

Division is the best deal available when uniformity is _true_ rather than
assumed. In a terminal grid it is true by construction — a row is one line —
which is why sparkles gets `O(1)` seeking and an exact extent for free, and why
the extent problem that dominates the GUI subjects simply does not arise.

The walk's cost is not the walk; it is the **estimated extent**, which is why
Avalonia carries a literal `_lastEstimatedElementSizeU = 25` and Gio recomputes
`Position.Length` from a mean every frame. Users experience this as a scrollbar
thumb that changes size as they travel.

### Overscan is universal, its unit is not

| Framework                                    | Knob                        | Unit                                     |
| -------------------------------------------- | --------------------------- | ---------------------------------------- |
| [Flutter](./flutter-slivers.md)              | `cacheExtent` (default 250) | logical pixels **or** viewport multiples |
| [WPF](./avalonia-wpf-virtualizing-panels.md) | `CacheLength`               | pixels, items **or** pages               |
| [Qt Quick](./qt-quick-listview.md)           | `cacheBuffer`               | pixels                                   |
| [egui](./egui-show-rows.md)                  | `+ 1`                       | rows, hard-coded                         |
| [sparkles](./sparkles-baseline.md)           | `+ 8`                       | rows, hard-coded                         |

Nobody scrolls without a band; the only question is whether it is configurable.

---

## What this means for sparkles

### The finding

`sparkles:ui` is an immediate-mode toolkit whose per-item construction is cheap:
a widget is a POD record in a flat arena, not an object with a template, a style
context, and a lifecycle. It therefore sits with
[Dear ImGui](./dear-imgui-clipper.md), [egui](./egui-show-rows.md) and
[Gio](./gio-list.md), and the unanimous choice of that family is **wins 1 and 2,
never win 3**.

Sparkles had win 1 (`DSN4`'s `DsvWindow`) and lacked win 2: every scroll notch
re-sniffed, re-parsed and re-projected the whole file — three times over, once
in the adapter, once in `DsvCopy` and once in the fuzzy filter. The
[measurement](./sparkles-baseline.md) said so unambiguously: 1.9 ms (44.6M
instructions) of re-sniff whose verdict was then overridden by flags the caller
already had, 290 µs of re-parsing bytes that had not changed, and 5.2 ms of
re-sorting — under an active sort — a permutation recomputed identically every
time. The view rebuild, the _only_ part win 3 could attack, was 2.8 ms.

### What was done

**Win 2, in the order the measurement gave** — `DSN7`, a persistent per-document
model that the window is a query against rather than a pipeline the window
re-runs. This is [GTK's `GListModel`](./gtk4-list-factories.md) /
[Slint's `Model`](./slint-repeater.md) reduced to its essentials: the model
outlives the view, and the view indexes it.

1. **Stop re-sniffing and re-parsing.** `DsvModel.of` resolves the dialect,
   parses, samples the types and decodes the header names once;
   `modelFor` reuses it whenever the bytes and flags are unchanged.
2. **Retain the projection.** The row permutation is a function of
   `(doc, ProjectionSpec, rowMask)`, and a scroll changes none of them, so it is
   memoized on the model. The fuzzy filter mask is memoized beside it, which
   both removes a whole-file fuzzy match per notch and gives the permutation
   memo a stable key.
3. **Route every consumer through it.** `adaptDsv`, `DsvCopy.of` and
   `fuzzyRowMask` all take the model, which is what removed the second and third
   parses.

| Scroll notch, 3012 rows |      re-derived |            retained |    Δ |
| ----------------------- | --------------: | ------------------: | ---: |
| unsorted                | 5.0 ms / 79.14M | **2.7 ms / 26.94M** | 1.9× |
| with a sort engaged     | 10 ms / 214.47M | **2.8 ms / 26.98M** | 3.6× |

The two are now the same cost — 0.15% apart in instructions, which is what makes
it a claim rather than an impression — and that is the property to look for: the
sort has stopped participating in scrolling. What remains is the view rebuild,
so the notch is now, as predicted, dominated by the one thing win 3 addresses.

### On win 3 specifically

The view half is now essentially the whole notch — the retained notch is 26.94M
instructions against the view rebuild's 26.62M — so this is live. The catalog says to take the cheapest form first, and it is not recycling:

- **Skip the rebuild entirely when nothing changed.** The most common case in a
  drag is a frame where the window did not move; no subject in this catalog
  rebuilds then.
- **Diff the range, not the tree.** [VS Code's `render`](./vscode-listview.md)
  shows the minimal shape: `relativeComplement` for what entered and left,
  `intersect` for what merely needs its contents updated. It is set arithmetic on
  two integer ranges, and it does not require pooling anything.
- **Only then pool.** And if sparkles ever does, the field's four independent
  warnings about item-lifetime state apply verbatim — with the extra sparkles
  wrinkle that the widget arena is _relocatable_, so a retained reference into it
  is a pointer-stability question as well as a semantic one.

> [!NOTE]
> The user-facing symptom — "scrolling relayouts the table" — was fixed by
> `DSN3`'s pinned geometry rather than by retaining anything. That is worth
> remembering: _stability_ and _speed_ looked like the same problem and were not.

---

## Sources

Every claim above is cited in the subject page it links to. The sparkles numbers
come from `apps/hue/src/dsv_bench.d`, run with
`dub test :hue -- --bench -i dsv.bench`.

<!-- References -->
