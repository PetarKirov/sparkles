# UI Virtualization Catalog

How UI frameworks render a viewport onto a data set far larger than it — list
virtualization, container recycling, builder delegates, clippers and the model
protocols underneath them.

This survey exists to inform one decision: how hue's DSV data browser should
scroll a multi-thousand-row grid built on [`sparkles:ui`](../../libs/ui/index.md),
a canvas-first immediate-mode toolkit. It complements three neighbouring
catalogs — [UI Layout](../ui-layout/index.md) (how widgets get sizes),
[UI backend seam](../ui-backend-seam/index.md) (how a display list reaches a
device) and [TUI Libraries](../tui-libraries/index.md) (terminal rendering
models) — none of which covers the viewport-versus-data-size axis.

**Last reviewed:** August 30, 2026

## The questions this survey answers

1. **Is clipping enough, and if not, why not?** →
   [Dear ImGui](./dear-imgui-clipper.md), which answers it in its own header.
2. **What do immediate-mode toolkits do**, given that they rebuild everything
   every frame? → [Dear ImGui](./dear-imgui-clipper.md),
   [egui](./egui-show-rows.md), [Gio](./gio-list.md)
3. **What does recycling buy, and what does it cost?** →
   [Qt Quick](./qt-quick-listview.md),
   [GTK 4](./gtk4-list-factories.md),
   [WPF / Avalonia](./avalonia-wpf-virtualizing-panels.md),
   [VS Code](./vscode-listview.md)
4. **How does a scrollbar describe content that was never measured?** →
   [concepts § virtual extent](./concepts.md#virtual-extent),
   [Gio](./gio-list.md), [egui](./egui-show-rows.md)
5. **What breaks when a view no longer contains every row?** →
   [concepts § what breaks](./concepts.md#5-what-breaks) — identity, focus,
   accessibility, hit testing
6. **What does a terminal change about the problem?** →
   [Textual](./textual-line-api.md), [Ratatui](./ratatui-offsets.md)
7. **Where does sparkles stand, measured rather than guessed?** →
   [sparkles baseline](./sparkles-baseline.md)
8. **So what should sparkles do?** → [comparison](./comparison.md)

## Master catalog

| Subject                | Language   | Mode            | Mechanism                                  | Model protocol         | Recycles   | Link                                       |
| ---------------------- | ---------- | --------------- | ------------------------------------------ | ---------------------- | ---------- | ------------------------------------------ |
| **Dear ImGui**         | C++        | immediate       | `ImGuiListClipper` index range             | ✗ (caller's loop)      | ✗          | [→](./dear-imgui-clipper.md)               |
| **egui**               | Rust       | immediate       | `ScrollArea::show_rows(Range)`             | ✗ (closure)            | ✗          | [→](./egui-show-rows.md)                   |
| **Gio**                | Go         | immediate       | `layout.List` + `ListElement` builder      | ✗ (closure)            | ✗          | [→](./gio-list.md)                         |
| **Ratatui**            | Rust       | immediate (TUI) | `ListState::offset` + bounded walk         | ✗ (owns a `Vec`)       | ✗          | [→](./ratatui-offsets.md)                  |
| **Textual**            | Python     | retained (TUI)  | `render_line(y)` / `render_lines(crop)`    | subclass-defined       | ✗          | [→](./textual-line-api.md)                 |
| **Flutter**            | Dart       | retained        | slivers + `SliverChildBuilderDelegate`     | builder                | elements   | [→](./flutter-slivers.md)                  |
| **GTK 4**              | C          | retained        | `GListModel` + `GtkListItemFactory`        | `GListModel`           | widgets    | [→](./gtk4-list-factories.md)              |
| **Qt Quick**           | C++/QML    | retained        | `ListView` + `reuseItems` pool             | `QAbstractItemModel`   | delegates  | [→](./qt-quick-listview.md)                |
| **WPF / Avalonia**     | C#         | retained        | `VirtualizingStackPanel`                   | `ItemsSource`          | containers | [→](./avalonia-wpf-virtualizing-panels.md) |
| **VS Code**            | TypeScript | retained        | range diff + `RowCache` + `RangeMap`       | `IListVirtualDelegate` | DOM rows   | [→](./vscode-listview.md)                  |
| **Slint**              | Rust       | retained        | `Repeater::ensure_updated_listview`        | `Model`                | instances  | [→](./slint-repeater.md)                   |
| **sparkles (hue DSV)** | D          | immediate       | `DsvWindow` (`DSN4`) + `DsvModel` (`DSN7`) | retained model         | ✗          | [→](./sparkles-baseline.md)                |

## Taxonomy

### By what the window bounds

| Bounds                 | Subjects                                                                                                                                                                                                                                                                                             |
| ---------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Paint and measure only | [Ratatui](./ratatui-offsets.md)                                                                                                                                                                                                                                                                      |
| Build, layout, paint   | [WPF / Avalonia](./avalonia-wpf-virtualizing-panels.md) (default), [VS Code](./vscode-listview.md)                                                                                                                                                                                                   |
| …and data access       | [Dear ImGui](./dear-imgui-clipper.md), [egui](./egui-show-rows.md), [Gio](./gio-list.md), [Textual](./textual-line-api.md), [Flutter](./flutter-slivers.md), [GTK 4](./gtk4-list-factories.md), [Qt Quick](./qt-quick-listview.md), [Slint](./slint-repeater.md), [sparkles](./sparkles-baseline.md) |

### By how the visible range is computed

| Strategy                            | Random access | Variable sizes | Subjects                                                                                                                                                                                                               |
| ----------------------------------- | ------------- | -------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Division** by a uniform size      | `O(1)`        | ✗              | [Dear ImGui](./dear-imgui-clipper.md), [egui](./egui-show-rows.md), [Slint](./slint-repeater.md), [sparkles](./sparkles-baseline.md)                                                                                   |
| **Walk** from an index anchor       | relative only | ✓              | [Gio](./gio-list.md), [Ratatui](./ratatui-offsets.md), [Flutter](./flutter-slivers.md), [GTK 4](./gtk4-list-factories.md), [Qt Quick](./qt-quick-listview.md), [WPF / Avalonia](./avalonia-wpf-virtualizing-panels.md) |
| **Prefix sums** over declared sizes | `O(log N)`    | ✓              | [VS Code](./vscode-listview.md)                                                                                                                                                                                        |
| **Compositor-resolved lines**       | `O(1)`        | n/a            | [Textual](./textual-line-api.md)                                                                                                                                                                                       |

### By how the scroll extent is known

| Strategy                              | Subjects                                                                                                                                                                                                |
| ------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Declared** (exact, no measurement)  | [egui](./egui-show-rows.md), [Textual](./textual-line-api.md), [Slint](./slint-repeater.md), [VS Code](./vscode-listview.md), [Dear ImGui](./dear-imgui-clipper.md), [sparkles](./sparkles-baseline.md) |
| **Estimated** from measured items     | [Gio](./gio-list.md), [GTK 4](./gtk4-list-factories.md), [Qt Quick](./qt-quick-listview.md), [WPF / Avalonia](./avalonia-wpf-virtualizing-panels.md)                                                    |
| **Progressive** (exact where visited) | [Flutter](./flutter-slivers.md)                                                                                                                                                                         |

### By setup/bind split

| Form                                         | Subjects                                                                                                                                                               |
| -------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Explicit two-phase API                       | [GTK 4](./gtk4-list-factories.md) (`setup`/`bind`), [VS Code](./vscode-listview.md) (`renderTemplate`/`renderElement`), [Slint](./slint-repeater.md) (`init`/`update`) |
| Split across object kinds                    | [Flutter](./flutter-slivers.md) (widget vs element)                                                                                                                    |
| Implicit, via a pool lifecycle               | [Qt Quick](./qt-quick-listview.md) (`pooled`/`reused`), [WPF / Avalonia](./avalonia-wpf-virtualizing-panels.md)                                                        |
| None — rebuild, preserve identity separately | [Dear ImGui](./dear-imgui-clipper.md), [egui](./egui-show-rows.md), [Gio](./gio-list.md), [Ratatui](./ratatui-offsets.md), [sparkles](./sparkles-baseline.md)          |

## Milestones

| Year | Event                                                                                                                                         |
| ---- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| 1996 | Windows `LVS_OWNERDATA` — the Win32 "virtual list view", a callback per visible item                                                          |
| 2006 | WPF ships `VirtualizingStackPanel` with `VirtualizationMode.Standard`                                                                         |
| 2008 | WPF 3.5 SP1 adds `VirtualizationMode.Recycling` and `VirtualizationCacheLength`                                                               |
| 2009 | Qt Quick 1.0 `ListView` instantiates only visible delegates                                                                                   |
| 2014 | Android `RecyclerView` makes "recycling" the mainstream name for the idea                                                                     |
| 2015 | Dear ImGui gains `ImGuiListClipper` (evolving out of the earlier `CalcListClipping`)                                                          |
| 2017 | Flutter's sliver protocol and `ListView.builder`                                                                                              |
| 2020 | Qt 5.15 adds `ListView.reuseItems` — recycling, opt-in                                                                                        |
| 2020 | GTK 4 ships `GtkListView` / `GtkListItemFactory`, retiring `GtkTreeView`                                                                      |
| 2026 | sparkles `DSN4` — hue's DSV grid renders a row window, then `DSN7` retains the model it is a window onto ([baseline](./sparkles-baseline.md)) |

> [!NOTE]
> Dates before 2020 are from release history rather than from the pinned trees
> this survey reads; treat them as orientation, not as citations.

## Reading paths

**"I want the short version."** →
[comparison § the consensus](./comparison.md#the-consensus), then
[comparison § what this means for sparkles](./comparison.md#what-this-means-for-sparkles).

**"I'm designing virtualization for an immediate-mode toolkit."** →
[concepts](./concepts.md) → [Dear ImGui](./dear-imgui-clipper.md) →
[egui](./egui-show-rows.md) → [Gio](./gio-list.md) →
[sparkles baseline](./sparkles-baseline.md) → [comparison](./comparison.md).

**"I want to know whether to recycle."** →
[Qt Quick](./qt-quick-listview.md) (the hazards, stated by the vendor) →
[GTK 4](./gtk4-list-factories.md) (the setup/bind split) →
[VS Code](./vscode-listview.md) (the minimal range diff) →
[comparison § architectural trade-offs](./comparison.md#architectural-trade-offs).

**"My scrollbar is wrong."** →
[concepts § virtual extent](./concepts.md#virtual-extent) →
[Gio](./gio-list.md) (estimation, honestly) →
[VS Code](./vscode-listview.md) (prefix sums, exactly).

**"I'm doing this in a terminal."** →
[Textual](./textual-line-api.md) → [Ratatui](./ratatui-offsets.md) →
[sparkles baseline](./sparkles-baseline.md).

## Sources

Every subject page cites the upstream tree it was read from, pinned to a commit.
The sparkles figures come from a phase-decomposition benchmark in
`apps/hue/src/dsv_bench.d`; see
[the baseline](./sparkles-baseline.md#what-is-not-virtualized--the-measurement).

<!-- References -->
