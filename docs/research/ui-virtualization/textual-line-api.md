# Textual — the line API (Python)

A retained widget tree whose compositor asks each widget for **individual
lines**, not for a rendered whole. Virtualization here is not a list feature; it
is the rendering protocol, and any widget gets it by overriding one method.

|                         |                                                                      |
| ----------------------- | -------------------------------------------------------------------- |
| **Language**            | Python                                                               |
| **License**             | MIT                                                                  |
| **Repository**          | [Textualize/textual][textual] (pinned at [`06dbeef`][textual-pin])   |
| **Documentation**       | [textual.textualize.io][textual-docs]                                |
| **Category**            | Retained, terminal                                                   |
| **Rendering model**     | Retained DOM + CSS; compositor requests lines from widgets per frame |
| **Virtualization unit** | One screen line (`Strip`)                                            |

See also the [TUI Libraries deep-dive](../tui-libraries/textual.md).

## Overview

### What it solves

Textual's compositor knows which regions of the screen are dirty and which
widget occupies each. Rather than asking a widget to render itself and then
cropping, it asks for the crop directly:

```python
def render_lines(self, crop: Region) -> list[Strip]:
    """Render the widget into lines.

    Args:
        crop: Region within visible area to render.

    Returns:
        A list of list of segments.
    """
```

— [`src/textual/widget.py`][textual-render-lines]

and, one line at a time:

```python
def render_line(self, y: int) -> Strip:
    """Render a line of content.

    Args:
        y: Y Coordinate of line.

    Returns:
        A rendered line.
    """
```

— [`src/textual/widget.py`][textual-render-line]

### Design philosophy

The base `Widget.render_line` serves the line from a render cache — it renders
the whole widget once and slices. That is the convenient default for small
widgets. The virtualization story is that **`render_line` is a hook**: a widget
whose content is larger than memory (or than patience) overrides it and
synthesizes line `y` on demand, and the compositor never notices the difference.

`ScrollView` is the base class for exactly that case, and its docstring is
careful to say so:

> A base class for a Widget that handles its own scrolling (i.e. doesn't rely
> on the compositor to render children).
>
> — [`src/textual/scroll_view.py`][textual-scrollview]

with a note steering ordinary users away:

> This is the typically wrong class for making something scrollable. If you want
> to make something scroll, set its `overflow` style to auto or scroll.
>
> — [`src/textual/scroll_view.py`][textual-scrollview]

That is the retained/virtual split stated as API guidance: containers scroll
their _children_ through the compositor; a `ScrollView` scrolls _content that has
no children_, and pays for that by answering line requests itself.

## How it works

A `ScrollView` declares its size and serves its lines:

- **`virtual_size`** is the content's full size in cells. `get_content_width` and
  `get_content_height` simply return `self.virtual_size.width` / `.height`
  ([`scroll_view.py`][textual-scrollview]) — a **declared** extent, exactly like
  [egui](./egui-show-rows.md)'s `set_height`, and the value the scrollbars are
  proportioned against.
- **`render_line(y)`** receives a widget-relative `y`; the subclass adds
  `self.scroll_offset.y` to get the content line, produces just that line, and
  returns it as a `Strip` of styled segments.
- **`_size_updated(size, virtual_size, container_size)`**
  ([`scroll_view.py`][textual-scrollview]) re-evaluates scrollbars whenever
  either the widget or the virtual size changes, so a content size that grows
  during a background scan is a supported, ordinary event.

The unit of work is a `Strip` — an immutable, cached list of styled segments with
a known cell width. Strips are comparable and hashable, which lets the
compositor skip re-emitting a line that did not change.

## Analysis

### 1. What the window bounds

Build, layout and paint of the content, and — because `render_line` is called
per visible line — the subclass's data access as well. `DataTable` and `Log` in
the standard library use exactly this to hold far more rows than they render.

### 2. How the range is computed

By the compositor, from the widget's screen region and the dirty regions; the
widget receives already-resolved line indices. Within a `ScrollView`, the mapping
is `content_y = y + scroll_offset.y` — a division by a uniform line height of
exactly one cell, which the terminal makes true by construction.

### 3. What survives between frames

The retained DOM, the CSS style cache, `_render_cache` for widgets that use the
default whole-render path, and the `Strip` objects themselves. A `ScrollView`
subclass typically retains its own data model and any per-line cache it wants —
the framework does not prescribe one.

### 4. How the extent is known

**Declared** via `virtual_size`, and re-declarable at any time.

### 5. What breaks

- **The subclass owns everything.** Overriding `render_line` opts out of children,
  layout, and per-child event routing; hit testing becomes arithmetic the widget
  performs on its own coordinates.
- **Per-line cost must be genuinely low**, since it is paid per visible line per
  frame with no framework-level memo.
- Uniform line height is assumed by the terminal itself, so the usual
  variable-size hazards are absent here — this is the one subject where that
  problem does not exist.

## Strengths

- Virtualization is the default rendering protocol, not a special widget: any
  widget that wants it overrides one method.
- The line granularity matches the terminal's own model exactly, so the extent is
  always exact and the mapping is always a subtraction.
- `Strip` immutability gives cheap change detection above the cell diff.

## Weaknesses

- A `ScrollView` is all-or-nothing: it gives up child widgets, and with them
  layout and event dispatch.
- No model protocol; the data half is entirely the subclass's design.
- Per-line Python calls are not free, which pushes real implementations to cache
  strips themselves.

## Key design decisions and trade-offs

| Decision                                                | Rationale                                                | Trade-off                                                        |
| ------------------------------------------------------- | -------------------------------------------------------- | ---------------------------------------------------------------- |
| Compositor requests lines, not renders                  | Virtualization becomes the protocol rather than a widget | Widgets that want it must reason in absolute content coordinates |
| `render_line` defaults to slicing a whole-widget render | Small widgets stay trivial to write                      | The default is `O(content)`; the win requires opting in          |
| `virtual_size` declared by the widget                   | Exact scrollbars with no measurement                     | The widget must know its content size, or update it as it learns |
| `ScrollView` forgoes children                           | The content is one virtual surface, not a tree           | Hit testing, focus and layout inside the content are hand-rolled |

## Sources

- [`src/textual/widget.py`, `Widget.render_line`][textual-render-line]
- [`src/textual/widget.py`, `Widget.render_lines`][textual-render-lines]
- [`src/textual/scroll_view.py`, `ScrollView`][textual-scrollview]
- [Textual documentation][textual-docs]

<!-- References -->

[textual]: https://github.com/Textualize/textual
[textual-pin]: https://github.com/Textualize/textual/tree/06dbeef4bb70fb718236aa418ed658ef4667a126
[textual-render-line]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/widget.py#L4250
[textual-render-lines]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/widget.py#L4271
[textual-scrollview]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/scroll_view.py#L15
[textual-docs]: https://textual.textualize.io/
