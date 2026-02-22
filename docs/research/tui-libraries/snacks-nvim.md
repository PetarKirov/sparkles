# Snacks.nvim (Neovim)

A Neovim plugin suite that bundles UI primitives (floating windows, layouts, pickers, notifications) into a cohesive toolkit for building terminal UIs inside the editor.

| Field        | Value                                                                 |
| ------------ | --------------------------------------------------------------------- |
| Language     | Lua (Neovim plugin)                                                   |
| Repository   | <https://github.com/folke/snacks.nvim>                                |
| License      | Apache 2.0                                                            |
| Author       | Folke Lemaitre                                                        |
| Latest       | 2.30.0                                                                |
| Requirements | Neovim >= 0.9.4                                                       |
| Paradigm     | Event-driven, editor-embedded UI toolkit built on buffers and windows |

---

## Overview

Snacks.nvim is not a standalone TUI framework. Instead, it treats Neovim itself as the rendering engine, using buffers, floating windows, splits, highlight groups, and keymaps to construct UI surfaces. The project ships as a collection of small plugins, but the UI-focused modules (window management, layouts, pickers, notifications, input prompts, dashboards, file explorer) effectively form a reusable toolkit for building interactive interfaces inside the editor.

The value of Snacks for TUI research is its **editor-embedded** model: it demonstrates how a sophisticated UI can be layered on top of Neovim's retained window system rather than a raw terminal grid. This is a growing pattern in the Neovim ecosystem, where plugins build complex UIs without owning the terminal loop directly.

### Module inventory

Snacks ships 28+ modules. Grouped by function:

| Category      | Modules                                                                         |
| ------------- | ------------------------------------------------------------------------------- |
| **Core UI**   | `win`, `layout`, `animate`, `scroll`, `statuscolumn`, `indent`, `scope`, `dim`  |
| **Surfaces**  | `picker`, `explorer`, `notifier`, `dashboard`, `input`, `scratch`, `terminal`   |
| **Utilities** | `git`, `gitbrowse`, `debug`, `toggle`, `rename`, `bufdelete`, `words`, `keymap` |
| **Visual**    | `image`, `zen`, `dim`, `indent`                                                 |
| **Meta**      | `health`, `compat`, `bigfile`, `quickfile`                                      |

The multi-file modules (`picker/`, `explorer/`, `animate/`, `image/`, `profiler/`, `gh/`, `util/`) are internally structured as packages with subdirectories.

---

## Architecture

### Lazy Loading via Metatable `__index`

The top-level `Snacks` global is a table with a `__index` metamethod that `require()`s modules on first access:

```lua
setmetatable(M, {
  __index = function(t, k)
    t[k] = require("snacks." .. k)
    return rawget(t, k)
  end,
})
_G.Snacks = M
```

This means `Snacks.win`, `Snacks.picker`, `Snacks.notifier`, etc. are loaded lazily -- zero cost until touched. The same pattern recurs inside larger modules (e.g. `snacks.image` lazy-loads `snacks.image.terminal`, `snacks.image.placement`, etc.).

### Event-Driven Setup

`Snacks.setup()` registers autocmds that trigger module initialization on specific Neovim events:

| Event         | Modules loaded                                             |
| ------------- | ---------------------------------------------------------- |
| `UIEnter`     | `dashboard`, `scroll`, `input`, `scope`, `picker`          |
| `BufReadPre`  | `bigfile`, `image`                                         |
| `BufReadPost` | `quickfile`, `indent`                                      |
| `BufEnter`    | `explorer`                                                 |
| `LspAttach`   | `words`                                                    |
| `BufReadCmd`  | `image` (for image file patterns), `gh` (for `gh://` URIs) |

Each module can be enabled or disabled via configuration. The `setup()` function merges user options with defaults, marks modules as `enabled` if their config key is present, and fires deferred autocmds.

### Configuration System

Configuration follows a three-layer merge pattern:

1. **Module defaults** -- hardcoded in each module.
2. **User config** -- passed to `Snacks.setup(opts)`, stored in a shared `config` table.
3. **Call-site overrides** -- passed to individual constructors.

`Snacks.config.get(snack, defaults, ...)` performs a deep merge across these layers. A special `example` field can pull named config presets from `docs/examples/`, allowing configuration by reference.

The merge function (`Snacks.config.merge`) does recursive table merging with `force` semantics, similar to `vim.tbl_deep_extend("force", ...)` but extended to handle non-table values and list-vs-dict detection.

---

## Window Abstraction (`Snacks.win`)

`Snacks.win` is the foundation for every visual element. It wraps Neovim's `nvim_open_win`, `nvim_win_set_config`, buffer creation, keymaps, and autocmds into a single managed object.

### Configuration Schema

The `snacks.win.Config` type extends Neovim's `vim.api.keyset.win_config` with:

| Field                    | Type / Description                                                                                             |
| ------------------------ | -------------------------------------------------------------------------------------------------------------- |
| `position`               | `"float"` \| `"top"` \| `"bottom"` \| `"left"` \| `"right"` \| `"current"`                                     |
| `width/height`           | Absolute (integer), relative (0..1 fraction of parent), or `0` (full). Can also be a `fun(self) -> number`.    |
| `min_width/max_width`    | Clamp values                                                                                                   |
| `row/col`                | Same absolute/relative/function scheme. Negative values anchor from the opposite edge. `nil` centers.          |
| `border`                 | Standard Neovim borders plus custom presets: `"top"`, `"bottom"`, `"hpad"`, `"vpad"`, `"top_bottom"`, `"bold"` |
| `backdrop`               | Number (blend opacity) or `{bg, blend, transparent}`. Creates a separate dimmed window behind the float.       |
| `style`                  | Name of a registered style preset (see below).                                                                 |
| `keys`                   | Table of key mappings. Values can be action names, functions, or full keymap specs.                            |
| `actions`                | Named action functions that keys can reference by string.                                                      |
| `wo/bo`                  | Window and buffer option overrides.                                                                            |
| `on_buf/on_win/on_close` | Lifecycle callbacks.                                                                                           |
| `fixbuf`                 | Prevents other buffers from being opened in this window (swaps them to a "main" window instead).               |
| `stack`                  | When true, multiple split windows with the same position are stacked perpendicular to each other.              |
| `resize`                 | Auto-resize on `VimResized` events.                                                                            |

### Dimension Resolution

The `dim()` method resolves dimensions against a parent size:

- `0` → full parent size minus border.
- `0 < x < 1` → fraction of parent size minus border.
- `≥ 1` → absolute cells.
- Functions are called with `self` and expected to return a number.

Positions follow the same rules: `nil` centers, negative values anchor from the far edge, `0 < p < 1` is a relative offset.

### Lifecycle

1. **`new(opts)`** -- resolves styles, merges defaults for float/split/minimal, processes keymaps, registers autocmds.
2. **`show()`** -- creates buffer (`open_buf`), applies buffer options, fires `on_buf`, creates window (`open_win`), applies window options, fires `on_win`, attaches keymaps.
3. **`update()`** -- re-applies options and (for floats) reconfigures position/size via `nvim_win_set_config`.
4. **`hide()`** -- closes the window but keeps the buffer for reuse.
5. **`close()`** -- destroys both window and buffer, cleans up autocmds and backdrop.
6. **`toggle()`** -- cycles between show/hide.

### Buffer Fixation

`fixbuf` is an interesting pattern: when another buffer is opened in this window (e.g., by `:edit`), Snacks intercepts `BufWinEnter`, moves the new buffer to a "main" window, and restores the original buffer. This keeps sidebars, explorers, and picker windows pinned.

### Backdrop

Backdrops are implemented as a separate `Snacks.win` instance with:

- `zindex` one below the parent.
- Full editor size (`width=0, height=0`).
- A dynamically created highlight group (`SnacksBackdrop_{hex}`) with the specified background color and `winblend`.
- Transparency-aware: skipped entirely when the colorscheme is transparent.

### Split Stacking

When `stack=true`, opening a second split with the same position finds an existing Snacks window in that position and splits _perpendicular_ to it. For example, two `bottom` splits are stacked side-by-side. After creation, `equalize()` distributes space evenly.

### Style Resolution

`Snacks.win.resolve(...)` walks a chain of style names. Each style can reference another style, and the chain is followed until all styles are flattened into a single config. The resolution is stack-based to handle transitive style references.

Built-in styles include `"float"` (backdrop=60, 90% size, z=50), `"split"` (40% height/width), `"minimal"` (disables cursorline, line numbers, signs, wrap, etc.), and `"help"` (bottom-aligned, 30% height, no backdrop).

---

## Layout Composition (`Snacks.layout`)

The layout module implements a **box-tree model** for multi-window arrangements. It manages a tree of horizontal/vertical boxes, where leaf nodes reference named `Snacks.win` instances.

### Layout Specification

A layout is described as a nested Lua table:

```lua
{
  box = "horizontal",
  width = 0.8,
  height = 0.8,
  { win = "input", height = 1 },
  {
    box = "vertical",
    { win = "list", width = 0.4 },
    { win = "preview" },
  },
}
```

- **`box`** nodes have a direction (`"horizontal"` or `"vertical"`) and contain child widgets.
- **`win`** leaves reference named windows from a `wins` table passed at construction time.
- Any `snacks.win.Config` field can appear on a node (e.g., `width`, `height`, `border`).

### Layout Algorithm

The algorithm in `update_box()` follows a **fixed-then-flex** distribution:

1. **Fixed children** -- children with explicit `width`/`height` > 0 are resolved first. Their size is subtracted from the available space.
2. **Flex children** -- children with `width`/`height` = 0 (or absent) share the remaining space equally (`floor(free / flex_count)`).
3. **Positioning** -- offsets are accumulated along the main axis.
4. **Root adjustment** -- if there is leftover space, the root box shrinks to fit.

Borders are accounted for by computing `border_size()` on fake `Snacks.win` instances and adjusting the parent coordinate frame.

### Box Windows

Each box node with a border (or the root) gets its own `Snacks.win` instance as a background. These `box_wins` are created at construction time with `focusable=false`, `enter=false`, and increasing `zindex` by depth. Child windows are then positioned `relative="win"` to the root box window.

### Split vs Float

When the root layout has `position` other than `"float"`, the layout wraps the tree in an extra vertical box. The outer box becomes a native Neovim split; inner windows are floats positioned relative to it. This allows the layout to act like a sidebar while retaining the full box-tree composition.

### Resizing

The layout responds to `WinResized` by comparing `screenpos` snapshots and re-running `update()`. When a child window is manually resized, the layout detects the size delta and adjusts the root window to accommodate, then re-runs layout.

### Fullscreen Toggle

`maximize()` toggles `opts.fullscreen`, which sets `width=0, height=0, col=0, row=0` on the root before layout, making it fill the editor.

### Hidden Windows

Windows can be toggled in/out of the layout via `toggle(win)`. Hidden windows are excluded from the box tree during layout but can be restored. This is used by the picker to show/hide the preview pane.

---

## Picker (`Snacks.picker`)

The picker is the most complex module. It's a full fuzzy-finder engine composed of several cooperating subsystems.

### Picker Object

A `Snacks.Picker` instance aggregates:

| Component | Type / Role                                                                                                                     |
| --------- | ------------------------------------------------------------------------------------------------------------------------------- |
| `finder`  | Async item producer. Wraps a source function into a coroutine-based pipeline.                                                   |
| `matcher` | Scores items against the query pattern. Supports fuzzy, exact, prefix, suffix, inverse, word, field-scoped, and regex matching. |
| `list`    | Virtual-scroll list with cursor management. Renders only visible items into a buffer.                                           |
| `input`   | Text input window for the search query.                                                                                         |
| `preview` | Preview pane that shows context for the selected item.                                                                          |
| `layout`  | A `Snacks.layout` instance that arranges input, list, and preview.                                                              |
| `sort`    | Comparator function from config.                                                                                                |
| `history` | Per-source search history with persistence.                                                                                     |

### Async Runtime

The picker has its own cooperative multitasking system built on Lua coroutines (`snacks.picker.util.async`):

- **`Async.new(fn)`** wraps a function in a coroutine and adds it to an active queue.
- A **`uv_check_t`** handle drives the event loop: on each libuv check event, it resumes active coroutines within a **budget** (default 10ms).
- **`yielder(ms)`** returns a throttled yield function that only actually yields when the time budget is exceeded (checked every 100 iterations).
- **`suspend()`/`resume()`** moves coroutines between active and suspended queues.
- **`schedule(fn)`** suspends the current coroutine, runs `fn` on the main thread via `vim.schedule`, and resumes with the result.

This gives the picker non-blocking behavior: the finder and matcher run as cooperative tasks that periodically yield control back to Neovim's event loop, keeping the UI responsive during large searches.

### Matcher Architecture

The matcher implements fzf-compatible query syntax:

| Syntax      | Meaning                      |
| ----------- | ---------------------------- |
| `foo`       | Fuzzy match                  |
| `'foo`      | Exact substring match        |
| `'foo'`     | Exact word boundary match    |
| `^foo`      | Exact prefix match           |
| `foo$`      | Exact suffix match           |
| `!foo`      | Inverse match (exclude)      |
| `a b`       | AND (both must match)        |
| `a \| b`    | OR (at least one must match) |
| `field:pat` | Match only the named field   |
| `file:3:5`  | File path with line:col jump |

Internally, the query string is parsed into `Mods[][]` (a 2D array representing AND-of-ORs). Each `Mods` object stores: `pattern`, `chars` (pre-split for fuzzy), `ignorecase`, `fuzzy`, `regex`, `inverse`, `exact_prefix`, `exact_suffix`, `word`, `field`, and an **entropy** score.

**Entropy-based ordering**: Mods are sorted by entropy (a heuristic for selectivity). Higher entropy patterns are checked first in the AND chain, so unlikely-to-match patterns short-circuit early. Within OR groups, lower entropy (more likely to match) patterns are checked first.

**Scoring**: The scoring system is ported from fzf (`snacks.picker.core.score`). It uses:

- Character class detection (white, nonword, delimiter, lower, upper, letter, number).
- Bonus matrices for boundary matches, camelCase transitions, consecutive characters.
- Constants matching fzf: `SCORE_MATCH=16`, `SCORE_GAP_START=-3`, `SCORE_GAP_EXTENSION=-1`.
- Path separator awareness: bonus for matches after `/`.

**Fuzzy matching**: Forward scan finds the first match positions, computing score incrementally. Then it retries from `from+1` repeatedly to find the highest-scoring alignment.

**Frecency**: Optional frecency scoring boosts recently/frequently accessed files using a logarithmic decay: `score += (1 - 1/(1 + frecency)) * 8`.

**Incremental matching**: When the new pattern is a prefix of the old one (subset detection), the matcher skips items that already failed the previous pattern. Items are processed in priority order: topk first, then previous matches, then the rest. The matcher runs as an async task that suspends when it catches up with the finder.

### Virtual-Scroll List

The list (`snacks.picker.core.list`) implements its own scrolling rather than using Neovim's native window scrolling:

- Maintains `top` (first visible index) and `cursor` (selected index).
- Renders only the visible window of items into the buffer using `nvim_buf_set_lines` and `nvim_buf_set_extmark` for highlights.
- Supports **reverse** mode (items grow upward) by translating between idx and row coordinates.
- Tracks a **topk min-heap** (capacity 1000) of the best-scoring items for instant first results.
- Mouse scroll events are intercepted via `vim.on_key` and translated to list scroll operations.
- A separate `Matcher` instance is used to compute highlight positions for the visible items only, avoiding the cost of computing positions for all items.

### Item Model

A picker item (`snacks.picker.Item`) carries:

| Field         | Description                                           |
| ------------- | ----------------------------------------------------- |
| `text`        | Primary searchable text.                              |
| `score`       | Current match score (0 = no match).                   |
| `idx`         | Original index from the finder.                       |
| `file`        | File path (for file-oriented sources).                |
| `pos`         | Cursor position `{line, col}` for jumping.            |
| `buf`         | Associated buffer number.                             |
| `parent`      | Parent item (for tree sources like the explorer).     |
| `frecency`    | Cached frecency score.                                |
| `match_tick`  | Matcher generation that last processed this item.     |
| `match_topk`  | Whether this item was in the topk set.                |
| Custom fields | Sources can add any field (e.g., `severity`, `kind`). |

---

## Explorer (`Snacks.explorer`)

The file explorer is described in the codebase as "a picker in disguise" -- it reuses the picker infrastructure with a tree-shaped data source.

### Tree Data Model

The tree (`snacks.explorer.tree`) is a singleton that maintains a hierarchy of `Node` objects:

```
Node {
  path, name, type, dir, open, expanded, hidden, ignored,
  parent, last, children, status, dir_status, severity, utime
}
```

- **`open`** -- whether the user has toggled this directory open.
- **`expanded`** -- whether the children have been read from the filesystem (`uv.fs_scandir`).
- **`children`** -- a string-keyed table of child nodes.
- **`hidden`** -- names starting with `.`.
- **`status`/`dir_status`** -- merged git status.
- **`severity`** -- LSP diagnostic severity.

The tree is expanded lazily: `expand(node)` calls `uv.fs_scandir` to read directory entries, creates child nodes, and removes stale entries. The `walk()` method performs a depth-first traversal with sorted children (directories first, then alphabetical).

### Git Integration

`snacks.explorer.git` provides per-directory git status by running `git status --porcelain=v2`. Status is merged upward: a directory's status is the "worst" status among its children. The git module also tracks dirty state for incremental refresh.

### Diagnostics

`snacks.explorer.diagnostics` aggregates LSP diagnostics by file path and propagates severity up to parent directories, so folders containing errors show an error indicator.

### Filtering

The tree walker accepts a filter configuration (`hidden`, `ignored`, `exclude`, `include` globs). Glob matching uses a compiled globber utility from `snacks.picker.util`. The `include` filter takes precedence -- if a file matches an include glob, it's shown even if it would otherwise be hidden.

### File Operations

The actions module (`snacks.explorer.actions`) handles:

- Create, delete, rename, copy, move.
- System trash integration (tries `trash`, `gio trash`, `kioclient5`, `kioclient`, PowerShell's `SendToRecycleBin`).
- Reveal (expand tree to show a specific file).

### Snapshot Diffing

`Tree:snapshot(node, fields)` captures the current state of a subtree (selected fields for each node). `Tree:changed(node, snapshot)` compares against a previous snapshot to detect whether a re-render is needed. This avoids redundant finder/layout cycles when nothing has changed.

---

## Notification System (`Snacks.notifier`)

### Architecture

The notifier is a singleton that maintains two collections:

- **`queue`** -- currently visible/pending notifications.
- **`history`** -- all past notifications (for the history viewer).

A `uv_timer_t` fires at `refresh` interval (default 50ms), triggering `process()` → `update()` → `layout()`.

### Notification Lifecycle

1. **`add(opts)`** -- creates or updates a notification. Assigns an auto-incrementing ID, resolves the level, sets the icon, and records timestamps with nanosecond precision.
2. **`update()`** -- removes expired notifications. A notification stays visible if: it hasn't been shown yet, timeout is 0, it's the current window/buffer, a custom `keep` predicate returns true, or it hasn't timed out yet.
3. **`render(notif)`** -- creates/reuses a `Snacks.win`, clears the buffer, invokes the style renderer, computes wrapped height, and applies `more_format` footer if content is truncated.
4. **`layout()`** -- positions all visible notifications using a slot-based algorithm.

### Slot-Based Layout

The layout system uses a boolean array (`rows[]`) representing every editor row. Initially all rows are marked free, then margins, tabline, and statusline rows are marked occupied. For each notification (sorted by level then time):

1. `layout.find(height, wanted_row)` scans for a contiguous block of `height` free rows, searching top-down or bottom-up based on `top_down` config.
2. If found, the rows are marked occupied (plus any gap), and the notification window is positioned at `col = columns - width - margin.right`, `row = found_row - 1`.
3. If no slot is found, the notification is hidden and retried later.

This gives a notification-stack behavior similar to macOS or VS Code toast notifications.

### Render Styles

Three built-in render styles:

- **`compact`** -- title in the border, message in the body.
- **`minimal`** -- no border, icon as a right-aligned virtual text overlay.
- **`fancy`** -- icon + title on line 1, horizontal rule on line 2, message below. Time displayed via right-aligned virtual text.

Each style is a function `(buf, notif, ctx)` that writes lines and extmarks into the notification buffer.

---

## Animation System (`Snacks.animate`)

### Design

The animation module provides a generic `from → to` interpolation engine:

1. **`Animation.new(opts)`** -- creates an animation with easing function, duration, and optional int rounding.
2. **`start(from, to, cb)`** -- precomputes all step values into an array, then starts a `uv_timer_t` at the computed step interval.
3. Each timer tick calls `step()`, which invokes the callback with the current value and a context `{anim, prev, done}`.
4. **`stop()`** halts the timer and clears the step array.

### Duration Model

Duration can be specified as:

- `step` -- ms per unit of change.
- `total` -- max total duration.
- When both are specified, the minimum wins.

For linear+integer animations, the step size is quantized to whole numbers to avoid sub-pixel jitter.

### Easing

The `snacks.animate.easing` module provides 45+ easing functions following the standard `(t, b, c, d)` signature (time, begin, change, duration). These include linear, quadratic, cubic, elastic, bounce, back, etc.

### Integration

Animation is used by:

- **`scroll`** -- smooth scrolling with configurable easing and a fast-repeat mode.
- **`indent`** -- animated scope highlighting that grows outward from the cursor.
- **`dim`** -- animated dimming of out-of-scope code.

The `Snacks.animate.enabled({buf, name})` check allows per-buffer or per-feature animation toggle via variables.

---

## Smooth Scrolling (`Snacks.scroll`)

The scroll module intercepts Neovim's native scrolling and replaces it with animated transitions:

- Tracks per-window `State` objects containing `current` view, `target` view, and an active `Animation`.
- Detects scroll events by comparing `winsaveview()` snapshots.
- When a scroll target changes, creates an animation from current `topline` to target `topline`.
- During animation, each step sets `scrolloff=0`, computes the interpolated position, and calls `winrestview()`.
- Supports a `animate_repeat` config for faster animation when scrolling rapidly (triggered after a configurable delay).

---

## Dashboard (`Snacks.dashboard`)

The dashboard renders a declarative startup screen:

- **Sections** are described as nested Lua tables with `section`, `key`, `action`, `icon`, `text`, etc.
- Built-in section generators: `header`, `keys`, `recent_files`, `projects`, `session`.
- The rendering engine resolves sections recursively, applies formatters (icon, footer, header, title, key, desc, file), and lays out blocks with alignment, padding, and gap control.
- Multi-pane support: the `pane_gap` and `col`/`row` options allow side-by-side layout.
- The dashboard lives in a normal buffer with extmarks for highlighting, making it a first-class Neovim buffer that responds to keymaps.

---

## Image Rendering (`Snacks.image`)

The image module enables inline image display using the **Kitty Graphics Protocol**:

- Supports kitty, wezterm, and ghostty terminals.
- Handles format conversion (ImageMagick) for non-PNG formats, videos, PDFs.
- Two display modes:
  - **Inline** -- uses unicode placeholder characters in the buffer. The terminal renders the image behind these placeholders.
  - **Float** -- shows images in floating windows positioned near the reference in the document.
- Integrates with Treesitter to find image references in markdown, HTML, and other document types.
- The `snacks.image.placement` module manages the relationship between image data and display positions.

---

## Scope Detection (`Snacks.scope`)

The scope module detects the current code scope at the cursor:

- **Treesitter-based** -- walks the syntax tree to find the enclosing block (function, class, if, for, etc.).
- **Indent-based fallback** -- when Treesitter isn't available, detects scope by indent level changes.
- Configuration: `min_size`, `max_size`, `cursor` (use cursor column), `edge` (include surrounding lines), `siblings` (expand with adjacent single-line scopes).
- Fires callbacks on scope change, used by `indent` and `dim` for visual effects.

---

## Indent Guides (`Snacks.indent`)

Renders vertical indent guides and scope highlights:

- Uses Neovim's decoration provider API (`nvim_set_decoration_provider`) for efficient per-line rendering.
- Indent guides are drawn as `│` characters via `virt_text` extmarks.
- Scope highlighting can be rendered as:
  - **Scope** -- a single highlighted vertical line for the current scope.
  - **Chunk** -- box-drawing characters (`┌`, `└`, `─`, `│`) that visually wrap the scope.
- Animated scope transitions: when the scope changes, the highlight grows outward from the cursor position using the animation system.

---

## Focus Dimming (`Snacks.dim`)

Dims code outside the current scope:

- Attaches to the scope listener.
- On each redraw, sets extmarks with `SnacksDim` highlight (linked to `DiagnosticUnnecessary`) on lines outside the active scope.
- Animated: when the scope changes, the dimming boundary smoothly transitions using easing.

---

## Zen Mode (`Snacks.zen`)

Provides a distraction-free editing mode:

- Toggleable via `Snacks.zen()`.
- Hides UI chrome (statusline, tabline, etc.) and optionally dims surrounding windows.
- Uses the `dim` module for the dimming effect.

---

## Patterns and Techniques

### Cooperative Async via Coroutines

The `snacks.picker.util.async` module is a bespoke cooperative scheduler worth studying:

- Uses a `uv_check_t` handle (runs once per libuv iteration) as the execution driver.
- Active coroutines are processed round-robin within a time budget.
- `yielder()` amortizes yield checks: only checks `uv.hrtime()` every 100 iterations, avoiding measurement overhead in tight loops.
- Coroutines can `suspend()` to wait for external events (e.g., `vim.schedule` results), moving to a separate suspended queue.
- The `wake()` pattern allows one coroutine to await another's completion.

This is relevant for Sparkles because it shows how to build responsive async UIs without threads, using only coroutines and event loop integration.

### Configuration as Inheritance Chain

Style resolution (`Snacks.win.resolve`) walks a chain of named styles, each potentially referencing another. This is reminiscent of CSS class composition but much simpler -- just recursive table merging. The pattern allows modules to define specialized styles that inherit from generic ones:

```
notification → float → minimal → defaults
```

### Z-Index Management

`Snacks.win.zindex()` scans existing windows and returns a z-index above all current Snacks windows (with a +2 gap). Layout children get `zindex = root + depth + 1`, ensuring correct stacking. Backdrops are always `zindex - 1` below their parent.

### Buffer as Canvas

Throughout Snacks, buffers are used as rendering targets:

- Lines are set with `nvim_buf_set_lines`.
- Rich formatting uses `nvim_buf_set_extmark` with `virt_text`, `virt_text_pos`, `hl_group`, and `priority`.
- The `winhighlight` window option remaps highlight groups per-window, enabling different visual themes for different surfaces.

This "buffer as canvas" pattern is the fundamental rendering primitive, replacing the cell-grid model of standalone TUI frameworks.

### TopK with Min-Heap

The picker list maintains a min-heap of the top 1000 scoring items. When the matcher produces a new high-scoring result, it's inserted into the heap. On the next render, topk items are processed first, giving instant initial results even while the full match is still running.

### Snapshot-Based Change Detection

The explorer's `snapshot()` / `changed()` pattern captures specific fields of a subtree and does a structural comparison. This is a simple alternative to dirty flags or reactive dependencies -- take a snapshot before, take one after, and compare.

---

## Relevance for Sparkles

### Directly Applicable Patterns

- **Box-tree layout model**: The layout algorithm in `Snacks.layout` (fixed-then-flex distribution, border accounting, nested box composition) is directly applicable to a tree view layout system. The specification format (nested tables with `box`/`win` discriminator) is ergonomic and could map to D structs.

- **Cooperative async with time budgets**: The coroutine-based scheduler with `yielder()` and budget-based round-robin is a pattern that could be adapted for D fibers. The key insight is amortizing time checks (every 100 iterations) to avoid `hrtime()` overhead.

- **Virtual-scroll list**: The picker list's approach of rendering only visible items, maintaining cursor/top state independently, and using a topk heap for fast initial display is directly relevant to a tree view that may have thousands of nodes.

- **Explorer as picker-with-tree-source**: The explorer shows that a tree view can be implemented as a flat list with indent + expand/collapse state, reusing generic list/filter/action infrastructure rather than building a separate tree widget.

- **Snapshot-based dirty detection**: A lightweight alternative to reactive change propagation, useful when the data model is simple and changes are infrequent relative to checks.

### Design Insights

- **Style registry**: Named presets with inheritance chains provide theming without a full CSS system. For Sparkles, this could be a `StyleConfig` struct with merge semantics.

- **Configuration layering**: The three-layer merge (defaults → global → call-site) with `merge()` and `example` references is a good ergonomic pattern for configurable components.

- **Buffer fixation**: The `fixbuf` pattern of intercepting buffer changes and redirecting them is relevant for any persistent panel in a terminal UI.

- **Notification slot allocation**: The boolean row-array approach is simple and effective for stacking popups without overlap.

### Key Limitation

Snacks relies entirely on Neovim's window system and cannot run outside the editor. Its abstractions are useful references, but Sparkles must implement equivalent primitives (surfaces, z-ordering, backdrop blending, event dispatch) directly against terminal escape sequences.

---

## See Also

- [Tree-View Case Study][tree-view-case-study] — Detailed snacks.nvim explorer analysis and comparative study with 13 libraries
- [Comparison][comparison] — Cross-library design synthesis and recommendations
- [Ratatui][ratatui] — Alternative tree-view design with clean separation of data and state

[tree-view-case-study]: tree-view-case-study.md
[comparison]: comparison.md
[ratatui]: ratatui.md
