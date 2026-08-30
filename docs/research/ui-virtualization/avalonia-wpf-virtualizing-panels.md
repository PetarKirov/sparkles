# WPF and Avalonia — virtualizing panels (.NET)

The XAML lineage: virtualization as a _panel_ that participates in the ordinary
measure/arrange protocol but realizes only the containers inside the viewport.
WPF named the two modes; Avalonia re-implemented the idea two decades later and
its field list reads as a catalogue of everything the problem actually requires.

|                         |                                                                                                                |
| ----------------------- | -------------------------------------------------------------------------------------------------------------- |
| **Languages**           | C# (WPF, Avalonia)                                                                                             |
| **Licenses**            | MIT (both)                                                                                                     |
| **Repositories**        | [dotnet/wpf][wpf] (pinned at [`99caccf`][wpf-pin]) · [AvaloniaUI/Avalonia][av] (pinned at [`aee3f68`][av-pin]) |
| **Category**            | Retained, GPU                                                                                                  |
| **Rendering model**     | Two-pass Measure/Arrange over a retained visual tree                                                           |
| **Virtualization unit** | Item ↔ container control                                                                                       |

See also the [UI Layout deep-dive on WPF/XAML](../ui-layout/wpf-xaml.md) and
[Avalonia in the backend-seam catalog](../ui-backend-seam/avalonia.md).

## Overview

### What it solves

An `ItemsControl` in XAML wraps every item in a **container** (`ListBoxItem`,
`TreeViewItem`, …) carrying styling, selection and input behaviour. Containers
are real controls with templates, so `N` of them is `N` template
instantiations. `VirtualizingStackPanel` realizes containers only for the
viewport.

### Design philosophy — WPF's two modes

WPF exposes the choice as an enum, and the two values name the two distinct
optimizations:

```csharp
public enum VirtualizationMode
{
    Recycling = 1,
    Standard = 0,
}
```

— [`PresentationFramework`][wpf-mode]

- **`Standard`** — containers for off-screen items are _not created_; when an
  item scrolls in, a container is created and when it scrolls out it is
  discarded. Bounds memory and startup; scrolling still pays construction.
- **`Recycling`** — containers are pooled and re-bound to new items. Bounds
  scrolling cost too, at the price of container-lifetime state hazards.

The distinction is worth borrowing as vocabulary: _not building what you cannot
see_ and _not rebuilding what you already built_ are separate wins, and a system
can have the first without the second.

The overscan band is likewise a first-class, unit-selectable property:

```csharp
public enum VirtualizationCacheLengthUnit
{
    Item = 1,
    Page = 2,
    Pixel = 0,
}
```

— [`PresentationFramework`][wpf-cachelen]

Three units — items, pages, pixels — against Flutter's two
([`CacheExtentStyle`](./flutter-slivers.md)) and everyone else's one.

## Avalonia's implementation

`VirtualizingStackPanel` is a compact modern re-statement, and its private field
list enumerates the problem's real requirements
([`VirtualizingStackPanel.cs`][av-fields]):

```csharp
private static readonly AttachedProperty<object?> RecycleKeyProperty = …;
private readonly Action<Control, int> _recycleElement;
private readonly Action<Control> _recycleElementOnItemRemoved;
private readonly Action<Control, int, int> _updateElementIndex;
private int _scrollToIndex = -1;
private Control? _scrollToElement;
private double _lastEstimatedElementSizeU = 25;
private RealizedStackElements? _measureElements;
private RealizedStackElements? _realizedElements;
private Rect _viewport;
private Dictionary<object, Stack<Control>>? _recyclePool;
private Control? _focusedElement;
private int _focusedIndex = -1;
private double _bufferFactor;
private Rect _lastMeasuredExtendedViewport;
```

Reading it as a specification:

- **`_realizedElements` / `_measureElements`** — the realized window, kept in two
  instances that are swapped after measure, so a measure pass that fails partway
  cannot corrupt the live window
  (`(_measureElements, _realizedElements) = (_realizedElements, _measureElements)`).
- **`_recyclePool` keyed by a `RecycleKey`** — pooling per container shape,
  the same idea as VS Code's [`templateId`](./vscode-listview.md).
- **`_lastEstimatedElementSizeU = 25`** — a literal default guess for the size of
  items never measured. The extent is an estimate, and the seed is a constant.
- **`_focusedElement` / `_focusedIndex` and `_scrollToElement` / `_scrollToIndex`**
  — two elements deliberately held **outside** the realized window. A focused row
  that scrolls away must keep existing or focus would be lost; a scroll target
  must be realizable before the window reaches it. This is the
  [identity escape hatch](./concepts.md#5-what-breaks), and the fact that it needs
  two dedicated pairs of fields is the finding.
- **`_bufferFactor` / `_lastMeasuredExtendedViewport`** — the overscan band and
  the viewport it was computed against.

`FirstRealizedIndex` / `LastRealizedIndex` are exposed publicly
([`VirtualizingStackPanel.cs`][av-indices]), which makes the realized window a
testable, observable property rather than an implementation detail — a small but
notable API choice.

## Analysis

### 1. What the window bounds

Container realization, measure, arrange, and render. Data access is bounded when
the `ItemsSource` supports it (`IList` indexing, or WPF's data virtualization via
`IItemsRangeInfo`), but the default in both frameworks is a fully-materialized
collection.

### 2. How the range is computed

A walk over realized elements from an anchor, with unrealized items assumed to be
`_lastEstimatedElementSizeU`. WPF additionally distinguishes _item scrolling_
from _pixel scrolling_ (`ScrollUnit`), which is precisely the choice between
"the anchor is an index" and "the anchor is an offset".

### 3. What survives between frames

The realized element window, the recycle pool, the estimated element size, the
focused and scroll-target elements, and the last measured viewport.

### 4. How the extent is known

**Estimated**, seeded from a constant and refined by measurement. Both frameworks
are known for scrollbar thumbs that resize while scrolling heterogeneous lists;
this field is why.

### 5. What breaks

- **Container-lifetime state** under `Recycling` — the WPF-era rule that a
  container must not hold item state, restated in every XAML framework since.
- **Focus loss** without the dedicated out-of-window element, hence the fields.
- **Grouping, `CanContentScroll=false`, an `ItemsControl` inside a
  `ScrollViewer` with infinite height** — all classic ways to silently disable
  virtualization in WPF, each because something asked the panel to measure all
  its children.
- **Scroll anchoring**: Avalonia threads an `IScrollAnchorProvider` through so
  that content changing size above the viewport does not move the reader.

## Strengths

- `Standard` vs `Recycling` is the clearest available vocabulary for the two
  separate wins.
- Cache length in items, pages or pixels is the most flexible overscan control
  surveyed.
- Avalonia's realized window is public and therefore testable.
- Double-buffered measure/realized lists make partial measure passes safe.

## Weaknesses

- Estimated extents, with a constant seed.
- Virtualization is easy to disable accidentally through ordinary-looking layout
  choices — the defining WPF complaint.
- The recycling hazards land on application-authored container styles and
  templates.

## Key design decisions and trade-offs

| Decision                                                 | Rationale                                                                   | Trade-off                                                |
| -------------------------------------------------------- | --------------------------------------------------------------------------- | -------------------------------------------------------- |
| Virtualization lives in a _panel_                        | Composes with the normal Measure/Arrange protocol; swappable per control    | Any ancestor granting infinite space silently defeats it |
| `Standard` vs `Recycling` as an enum                     | The two wins are genuinely separable; recycling changes container semantics | Applications must understand both to pick                |
| Cache length in item/page/pixel units                    | Different content shapes want different overscan units                      | Three units to document and reason about                 |
| Keep focused / scroll-target elements outside the window | Focus and programmatic scroll must survive virtualization                   | Two special cases threaded through the whole panel       |
| Estimate unmeasured item size from a constant            | Something must fill the extent before anything is measured                  | Scrollbar geometry visibly settles as the user scrolls   |

## Sources

- [WPF `VirtualizationMode` enum][wpf-mode]
- [WPF `VirtualizationCacheLengthUnit` enum][wpf-cachelen]
- [WPF `VirtualizingStackPanel`][wpf-vsp]
- [Avalonia `VirtualizingStackPanel` fields][av-fields]
- [Avalonia `FirstRealizedIndex` / `LastRealizedIndex`][av-indices]

<!-- References -->

[wpf]: https://github.com/dotnet/wpf
[wpf-pin]: https://github.com/dotnet/wpf/tree/99caccf23145777f910711b51961885bec783213
[wpf-mode]: https://github.com/dotnet/wpf/blob/99caccf23145777f910711b51961885bec783213/src/Microsoft.DotNet.Wpf/cycle-breakers/PresentationFramework/PresentationFramework.cs#L7672
[wpf-cachelen]: https://github.com/dotnet/wpf/blob/99caccf23145777f910711b51961885bec783213/src/Microsoft.DotNet.Wpf/cycle-breakers/PresentationFramework/PresentationFramework.cs#L7666
[wpf-vsp]: https://github.com/dotnet/wpf/blob/99caccf23145777f910711b51961885bec783213/src/Microsoft.DotNet.Wpf/src/PresentationFramework/System/Windows/Controls/VirtualizingStackPanel.cs
[av]: https://github.com/AvaloniaUI/Avalonia
[av-pin]: https://github.com/AvaloniaUI/Avalonia/tree/aee3f68551b0ac4417e32996a6627f34462edbc3
[av-fields]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/VirtualizingStackPanel.cs#L62
[av-indices]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/VirtualizingStackPanel.cs#L171
