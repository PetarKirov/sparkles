# Ratatui — offset-anchored `List` / `Table` (Rust)

The TUI baseline: a widget that renders into a cell buffer, given a `State`
carrying the first-visible index. It bounds **painting** — and, unusually for
this catalog, it is explicit that it does _not_ bound the data.

|                         |                                                                       |
| ----------------------- | --------------------------------------------------------------------- |
| **Language**            | Rust                                                                  |
| **License**             | MIT                                                                   |
| **Repository**          | [ratatui/ratatui][ratatui] (pinned at [`a2ca2df`][ratatui-pin])       |
| **Documentation**       | [ratatui.rs][ratatui-docs]                                            |
| **Category**            | Immediate mode, terminal                                              |
| **Rendering model**     | Whole frame rebuilt into a `Buffer`; the terminal backend diffs cells |
| **Virtualization unit** | Item index, anchored by `ListState::offset`                           |

See also the [TUI Libraries deep-dive](../tui-libraries/ratatui.md) for
Ratatui's broader architecture, and the
[tree-view](../tui-libraries/tree-view-case-study.md) and
[table-span](../tui-libraries/table-span-case-study.md) case studies.

## Overview

### What it solves

Ratatui's widgets are values that consume themselves into a `Buffer`. A `List`
holds `items: Vec<ListItem>` and a `ListState` holds the scroll anchor; render
walks from the anchor and stops when the area is full.

### Design philosophy

State that must survive a frame lives in a caller-owned `State` struct, not in
the widget — the same "the application owns the scroll position" stance as
[Gio](./gio-list.md). `StatefulWidget::render` takes `&mut Self::State` and
writes the resolved offset back into it.

## How it works

The render entry point resolves the visible range, then commits it to the state:

```rust
let list_height = list_area.height as usize;

let (first_visible_index, last_visible_index) =
    self.get_items_bounds(state.selected, state.offset, list_height);

// Important: this changes the state's offset to be the beginning of the now viewable items
state.offset = first_visible_index;
```

— [`ratatui-widgets/src/list/rendering.rs`][ratatui-render]

`get_items_bounds` is a **walk**, not a division, because `ListItem`s may span
several lines:

```rust
fn get_items_bounds(
    &self,
    selected: Option<usize>,
    offset: usize,
    max_height: usize,
) -> (usize, usize) {
    let offset = offset.min(self.items.len().saturating_sub(1));

    // Note: visible here implies visible in the given area
    let mut first_visible_index = offset;
    let mut last_visible_index = offset;

    // Current height of all items in the list to render, beginning at the offset
    let mut height_from_offset = 0;

    // Calculate the last visible index and total height of the items
    // that will fit in the available space
    for item in self.items.iter().skip(offset) {
        if height_from_offset + item.height() > max_height {
            break;
        }

        height_from_offset += item.height();

        last_visible_index += 1;
    }
    // …then adjust the window so the selected item is inside it
```

— [`ratatui-widgets/src/list/rendering.rs`][ratatui-bounds]

The remainder of the function slides the window so that the selected index is
visible, honouring a configurable scroll padding — which is why the offset is
written _back_ to the state: selection can move the window, so the anchor the
caller supplied is an input, not the answer.

### The line that matters for this catalog

`for item in self.items.iter().skip(offset)`.

The walk is bounded — it breaks as soon as the area is full — but it iterates
`self.items`, a `Vec` that the caller **fully constructed before calling
render**. Ratatui bounds the per-frame _painting_ and _measuring_ cost at
`O(viewport)`, and does nothing at all for the cost of producing the items. An
application backed by a large or expensive data source must virtualize its own
data layer above Ratatui; the widget offers no seam for it.

That is not an oversight so much as a scale judgement: a `ListItem` is a
`Vec<Line>` of already-styled text, so for the list sizes a terminal UI usually
shows, materializing all of them is cheap. It stops being cheap at the scale of
a data browser over a file.

## Analysis

### 1. What the window bounds

**Paint and measure only.** The item vector is fully materialized by the caller.

### 2. How the range is computed

A walk from `state.offset`, accumulating `item.height()`, then adjusted to keep
the selection visible.

### 3. What survives between frames

`ListState` / `TableState` — the offset and the selection. No item views (there
are none to keep); the `Buffer` diff against the previous frame is what avoids
redundant terminal writes, which is a different optimization at a lower layer.

### 4. How the extent is known

Not, in the widget. `ScrollbarState` is a separate widget the caller configures
with `content_length`, which the caller computes from its own item count. Since
the items are all materialized anyway, this costs nothing here.

### 5. What breaks

- **Large or expensive data sets**, because every item is built regardless.
- **Jump-to-index by proportion** — the walk gives no pixel/line mapping without
  scanning, so a scrollbar drag maps to an item index rather than to a position
  inside the content.
- The offset being rewritten by render means the caller's stored anchor and the
  rendered anchor can differ for one frame after a selection change.

## Strengths

- Extremely simple: an integer anchor and a bounded walk.
- Variable item heights supported natively.
- Selection-follows-window logic is in the widget, including scroll padding.

## Weaknesses

- No data virtualization seam whatsoever — the defining limitation for a data
  browser.
- The scrollbar is a separate widget with a separately-supplied content length,
  so the two can disagree.

## Key design decisions and trade-offs

| Decision                                   | Rationale                                          | Trade-off                                                |
| ------------------------------------------ | -------------------------------------------------- | -------------------------------------------------------- |
| `items: Vec<ListItem>` owned by the widget | Simple, allocation-friendly, no callback machinery | `O(N)` construction per frame regardless of the viewport |
| Anchor in a caller-owned `State`           | Scroll survives the widget being a temporary value | The widget can rewrite it, so it is in/out, not just in  |
| Walk item heights instead of dividing      | Multi-line items work                              | No random access; scroll maps to indices, not offsets    |
| Scrollbar as a separate widget             | Composable; a list need not have one               | Content length is supplied twice and can drift           |

## Sources

- [`ratatui-widgets/src/list/rendering.rs`, `StatefulWidget for &List`][ratatui-render]
- [`ratatui-widgets/src/list/rendering.rs`, `get_items_bounds`][ratatui-bounds]
- [Ratatui documentation][ratatui-docs]

<!-- References -->

[ratatui]: https://github.com/ratatui/ratatui
[ratatui-pin]: https://github.com/ratatui/ratatui/tree/a2ca2df5688772baffb743b494761f4ec82b3174
[ratatui-render]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-widgets/src/list/rendering.rs#L30
[ratatui-bounds]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-widgets/src/list/rendering.rs#L129
[ratatui-docs]: https://ratatui.rs/
