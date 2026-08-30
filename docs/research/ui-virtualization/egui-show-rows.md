# egui — `ScrollArea::show_rows` (Rust)

The same clipper idea as Dear ImGui, expressed as a closure that receives a
`Range<usize>` — plus the one piece of machinery Dear ImGui does not need:
an explicit fix for immediate-mode **widget identity** across a skipped range.

|                         |                                                                   |
| ----------------------- | ----------------------------------------------------------------- |
| **Language**            | Rust                                                              |
| **License**             | MIT / Apache-2.0                                                  |
| **Repository**          | [emilk/egui][egui] (pinned at [`5d3e958`][egui-pin])              |
| **Documentation**       | [docs.rs/egui `ScrollArea`][egui-docs]                            |
| **Category**            | Immediate mode, GPU                                               |
| **Rendering model**     | Rebuild every frame; per-widget state in an id-keyed memory store |
| **Virtualization unit** | Row index (`Range<usize>`)                                        |

## Overview

### What it solves

`ScrollArea::show` lays out the whole content and lets the scroll area clip it.
The doc comment on `show` names the escape hatch directly:

> Show the [`ScrollArea`], and add the contents to the viewport.
>
> If the inner area can be very long, consider using [`Self::show_rows`] instead.
>
> — [`scroll_area.rs`][egui-show]

`show_rows` is described as "Efficiently show only the visible part of a large
number of rows" ([`scroll_area.rs`][egui-show-rows]), and its documented example
is a 10 000-row list.

### Design philosophy

egui is immediate mode with a **retained side table**: widget state (whether a
collapsing header is open, where a drag started, which text-edit has focus) lives
in `Memory`, keyed by an `Id`. Those `Id`s are usually derived from the call
sequence. That makes egui the interesting case in this catalog: it is
architecturally "rebuild everything, keep nothing", except for the one thing that
virtualization is most likely to corrupt.

## How it works

The public surface is a closure over a row range:

```rust
egui::ScrollArea::vertical().show_rows(ui, row_height, total_rows, |ui, row_range| {
    for row in row_range {
        let text = format!("Row {}/{}", row + 1, total_rows);
        ui.label(text);
    }
});
```

— [`scroll_area.rs`][egui-show-rows]

The implementation is short enough to read whole, and every line is one of the
five spine questions:

```rust
self.show_viewport(ui, |ui, viewport| {
    ui.set_height((row_height_with_spacing * total_rows as f32 - spacing.y).at_least(0.0));

    let mut min_row = (viewport.min.y / row_height_with_spacing).floor() as usize;
    let mut max_row = (viewport.max.y / row_height_with_spacing).ceil() as usize + 1;
    if max_row > total_rows {
        let diff = max_row.saturating_sub(min_row);
        max_row = total_rows;
        min_row = total_rows.saturating_sub(diff);
    }

    let y_min = ui.max_rect().top() + min_row as f32 * row_height_with_spacing;
    let y_max = ui.max_rect().top() + max_row as f32 * row_height_with_spacing;
    let rect = Rect::from_x_y_ranges(ui.max_rect().x_range(), y_min..=y_max);

    ui.scope_builder(UiBuilder::new().max_rect(rect), |viewport_ui| {
        viewport_ui.skip_ahead_auto_ids(min_row); // Make sure we get consistent IDs.
        add_contents(viewport_ui, min_row..max_row)
    })
    .inner
})
```

— [`scroll_area.rs`][egui-show-rows]

Reading it in order:

1. **`ui.set_height(row_height_with_spacing * total_rows - spacing.y)`** declares
   the virtual extent up front, from `total_rows` — no measurement, exactly
   correct, and the scrollbar is proportioned from it.
2. **`floor` / `ceil` + 1** is the uniform-height division, with one row of
   [overscan](./concepts.md#overscan--cache-extent).
3. The `if max_row > total_rows` block **preserves the window's width** while
   clamping it to the end of the list, so the last screenful is a full screenful
   rather than a shrinking remainder.
4. **`rect` positions the built rows at their true `y`** — the equivalent of
   Dear ImGui's cursor advance, done as an explicit rectangle rather than by
   moving a cursor.
5. **`skip_ahead_auto_ids(min_row)`** — see below.

### The identity fix

egui derives automatic widget `Id`s from a per-`Ui` counter. If rows 0…199 are
skipped, every widget in row 200 would receive the `Id` that row 0's widget had
on the previous frame, and all retained per-widget state — focus, drag anchors,
open/closed flags — would follow the _screen position_ rather than the _row_.

`skip_ahead_auto_ids(min_row)` advances that counter by the number of skipped
rows so a given row's widgets keep the same `Id` at any scroll offset. The
comment is one line — `// Make sure we get consistent IDs.` — and it is the
single most transferable detail in this catalog for any toolkit whose
interaction state is keyed by build order.

## Analysis

### 1. What the window bounds

Build and layout, and the caller's per-row data cost by construction (the
closure only iterates the given range). The data source itself is opaque to
egui — there is no model protocol; `total_rows` is just a number.

### 2. How the range is computed

Division by a caller-supplied uniform `row_height_sans_spacing`. Unlike
[Dear ImGui](./dear-imgui-clipper.md), egui does not measure a probe row — the
caller passes the height (typically `ui.text_style_height(&text_style)`).
Variable heights are unsupported by `show_rows`; the escape hatch is the lower
level `show_viewport`, which hands the caller a viewport `Rect` and lets it
decide what that means.

### 3. What survives between frames

The `Memory` id-keyed state store — and nothing else. That store is precisely
what `skip_ahead_auto_ids` protects.

### 4. How the extent is known

**Declared**, exactly, via `set_height` from `total_rows × row_height`. This is
the cheapest and most accurate of the three strategies and is available only
because uniform height is assumed.

### 5. What breaks

- **Variable row heights** — out of scope for `show_rows` by construction.
- **Identity**, absent `skip_ahead_auto_ids`; the fix is one call but it is
  mandatory, and it is invisible until a user drags something while scrolled.
- **Anything keyed on a row being _built_** — hover, tooltips and animations for
  off-screen rows simply do not happen, which is usually what you want but
  changes behaviour relative to `show`.

## Strengths

- The whole mechanism is ~25 lines and reads top-to-bottom as the five spine
  answers.
- Exact virtual extent with no measurement pass.
- The end-of-list clamp keeps the realized window a constant size, which keeps
  per-frame cost flat instead of dipping at the end.
- The identity problem is solved in the framework, not left to the caller.

## Weaknesses

- Uniform heights only; `show_viewport` is a much lower-level fallback.
- The caller must supply the row height, which duplicates knowledge the layout
  already has and drifts if the text style changes.
- No model protocol: egui cannot help with the _data_ half at all.

## Key design decisions and trade-offs

| Decision                                          | Rationale                                     | Trade-off                                                                          |
| ------------------------------------------------- | --------------------------------------------- | ---------------------------------------------------------------------------------- |
| Caller supplies `row_height`                      | No probe pass, no first-item special case     | Caller-side duplication; wrong height silently misaligns rows                      |
| `set_height` from `total_rows`                    | Exact extent for free                         | Only valid under uniform heights                                                   |
| One row of overscan (`+ 1`)                       | Covers the partially-visible trailing row     | Fixed, not tunable like Flutter's `cacheExtent`                                    |
| Clamp the window's _start_ at the end of the list | Constant realized-window size                 | The final rows are built slightly before they are needed                           |
| `skip_ahead_auto_ids`                             | Retained per-widget state must follow the row | Only works for _auto_ ids; explicitly-`id_salt`ed widgets are the caller's problem |

## Sources

- [`crates/egui/src/containers/scroll_area.rs`, `ScrollArea::show_rows`][egui-show-rows]
- [`crates/egui/src/containers/scroll_area.rs`, `ScrollArea::show`][egui-show]
- [egui `ScrollArea` API documentation][egui-docs]

<!-- References -->

[egui]: https://github.com/emilk/egui
[egui-pin]: https://github.com/emilk/egui/tree/5d3e958ecfd3468a460c57094ebaeca6e3c4f325
[egui-show]: https://github.com/emilk/egui/blob/5d3e958ecfd3468a460c57094ebaeca6e3c4f325/crates/egui/src/containers/scroll_area.rs#L956
[egui-show-rows]: https://github.com/emilk/egui/blob/5d3e958ecfd3468a460c57094ebaeca6e3c4f325/crates/egui/src/containers/scroll_area.rs#L967
[egui-docs]: https://docs.rs/egui/latest/egui/containers/scroll_area/struct.ScrollArea.html
