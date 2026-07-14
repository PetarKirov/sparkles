# Dear ImGui (C++)

A bloat-free, immediate-mode graphical user interface library for C++ aimed at tools,
debug overlays, content-creation editors, and engine-side UIs. The canonical reference
implementation of the immediate-mode GUI paradigm in mainstream use, and the inspiration
for a wide family of ports (including [`imtui`](../tui-libraries/imtui.md), which renders
Dear ImGui in a terminal).

| Field            | Value                                                 |
| ---------------- | ----------------------------------------------------- |
| Author           | Omar Cornut (@ocornut), with hundreds of contributors |
| Language         | C++ (single-header-style, no STL required)            |
| License          | MIT                                                   |
| Repository       | <https://github.com/ocornut/imgui>                    |
| Wiki             | <https://github.com/ocornut/imgui/wiki>               |
| Version snapshot | 1.92.x (2026 release line)                            |
| First release    | 2014                                                  |

---

## Overview

Dear ImGui (the "Dear" prefix is a deliberate disambiguator from the more generic phrase
"imgui") is a C++ library for building graphical user interfaces that follows the
**immediate-mode GUI** model. Originally written by Omar Cornut in 2014 -- initially used
internally at Media Molecule during development of _Tearaway Unfolded_ on the PS Vita --
it has since become the de facto standard for in-tool and in-engine UI across the
game-development industry and a substantial chunk of the graphics-programming world. It
ships with virtually every major game engine integration (Unity, Unreal, Godot, Bevy
[via egui's parallel evolution], and dozens of homebrew engines) and is the UI behind
high-profile creator tools (Sketchfab's viewers, NVIDIA's various profiling overlays,
the editors in many indie engines).

**What it solves.** Building a GUI for an in-house tool with a retained-mode framework
(Qt, GTK, WPF) means writing a widget class hierarchy, wiring signals/slots, owning
widget state separately from the underlying data model, and synchronising the two on
every change. For a five-engineer game studio that just wants "a slider for this float
and a checkbox for this bool" attached to a live game world, that overhead is
disproportionate. Dear ImGui eliminates it: the UI is just a sequence of function calls,
re-issued every frame, with no persistent widget objects.

**Design philosophy.** Three principles dominate the design:

1. **State lives in the application.** The library stores only enough internal state to
   manage windows, layout cursors, focus, and animations. The data being edited
   (`float volume`, `bool enabled`, `int selected_index`) is owned by the application;
   Dear ImGui reads and writes it directly through pointer arguments.
2. **The UI is rebuilt every frame from scratch.** There is no widget tree. Each frame
   you call `ImGui::NewFrame()`, issue a sequence of widget calls in the order they
   should appear, and call `ImGui::Render()`. The library's job is to record those
   calls into a draw list and let your application's renderer (OpenGL, Vulkan, DirectX,
   Metal, software, terminal) submit them.
3. **The library does not own anything.** Not the window, not the renderer, not the
   event loop, not the input source. The application provides input each frame and a
   backend renders the produced vertex/index/command buffers. Dear ImGui ships
   reference backends for every major windowing and graphics API in the `backends/`
   directory, but they are opt-in glue.

This philosophy yields a particular ergonomic signature: the "two-line slider". To put a
slider on screen that edits a float, you write:

```cpp
float volume = 0.5f;
ImGui::SliderFloat("Volume", &volume, 0.0f, 1.0f);
```

Two lines (one of them the variable declaration, which already existed). The slider
appears, the variable is updated when the user drags, and there is no widget object, no
event handler, no model-view binding. This 2-line ergonomic is the **central advantage** of
the immediate-mode model and the reason Dear ImGui dominates the tooling space.

### History

- **2014.** Omar Cornut publishes `imgui` on GitHub. Initial design drew on Casey
  Muratori's "immediate-mode GUIs" talks and on internal tooling work at Media Molecule.
- **2014-2017.** Steady iteration. Widget set fills out (input boxes, combos, plots,
  trees, menus, popups, drag-and-drop). The renderer-agnostic draw-list architecture
  stabilises.
- **2018.** The library is renamed **Dear ImGui** to disambiguate from generic "imgui"
  references.
- **2019.** Version 1.71 lands the **docking branch** -- separate branch of development
  introducing dockable windows and multi-viewport (host-OS window) support. Used in
  production by many users from the docking branch directly.
- **2020.** Version 1.80 (released January 2021) ships the **modern Tables API**, a
  ground-up replacement for the legacy `Columns()` system. Tables become competitive
  with retained-mode UI tables (sortable, resizable, freezable, scrollable).
- **2020.** Multi-viewport and docking work continues in parallel on the docking branch.
- **2023-2024.** Docking and multi-viewport features merge into the main branch over
  several releases through 1.89 / 1.90.
- **Present.** Active development continues. The Tables API and docking are mature; new
  work focuses on multi-select, text editing, performance, and platform polish.

The library has been remarkably stable across this decade-plus of development: code
written against the 1.50 API in 2016 generally still compiles and runs against current
1.91, with at most cosmetic warnings about deprecated function names.

---

## Layout Model

Dear ImGui's layout is fundamentally a **cursor-based, paragraph-flow model**. Each
window maintains a "cursor" -- an `(x, y)` position in window-local coordinates. When you
issue a widget call, the widget is drawn at the cursor position, the cursor advances
**downward** by the widget's height plus an item-spacing gap, and the next widget
follows. The flow is vertical by default; explicit calls move the cursor sideways or
back up.

This is not a constraint solver. It is not a flexbox. It is a moving caret, exactly like
text flowing in a paragraph -- which is also why the model feels natural when adding
"another control" to an existing window.

### Windows

Everything visible in Dear ImGui lives inside a window. A window is a movable, resizable,
collapsible container; it has a title bar, borders, optional scrollbars, and a content
region. Windows are opened with `Begin` and closed with `End`:

```cpp
ImGui::Begin("Inspector");
// widget calls here
ImGui::End();
```

`Begin`/`End` must be matched. The return value of `Begin` indicates whether the window
is currently visible (collapsed or hidden windows skip rendering); widgets inside an
invisible window are not drawn but their state is still processed. The full signature is:

```cpp
bool ImGui::Begin(const char* name,
                  bool* p_open = nullptr,
                  ImGuiWindowFlags flags = 0);
```

`p_open` is an optional pointer to a `bool`; if non-null, a close button appears in the
title bar and the library sets `*p_open = false` when the user clicks it.
`ImGuiWindowFlags` controls everything from "no title bar" through "no resize", "no
move", "always auto-resize", "tooltip semantics", "popup semantics", etc.

**Child windows** are nested regions inside a parent window with their own scrollbar and
clipping rectangle:

```cpp
ImGui::BeginChild("Log",
                  ImVec2(0, 200),
                  ImGuiChildFlags_Borders);
for (const auto& line : log_lines) ImGui::TextUnformatted(line.c_str());
ImGui::EndChild();
```

A child of size `(0, 200)` means "full available width, 200 pixels tall". The `0` in
either axis means "use available space"; a negative value means "available space minus
this amount".

### Docking

Since the docking work merged from branch (long used as 1.71+ on the docking branch) and
landed in main around 1.89 / 1.90, windows can be **docked** into a parent dock node,
split a dock region into halves, or be torn off into separate OS windows
(multi-viewport). Docking is opt-in per ImGui context:

```cpp
ImGuiIO& io = ImGui::GetIO();
io.ConfigFlags |= ImGuiConfigFlags_DockingEnable;
io.ConfigFlags |= ImGuiConfigFlags_ViewportsEnable; // optional, multi-viewport
```

Applications typically create one full-window dockspace at the top of each frame using
`DockSpaceOverViewport(...)`, then `Begin`-ed windows automatically dock into it on
first appearance.

### The cursor and flow

Inside a window, layout is **vertical by default**. Each call to a widget function
(`Button`, `Text`, `Checkbox`, `SliderFloat`, etc.) advances the cursor by the widget's
height plus `ItemSpacing.y`:

```cpp
ImGui::Text("Position");
ImGui::SliderFloat3("##pos", &pos.x, -100.0f, 100.0f);
ImGui::Checkbox("Visible", &visible);
ImGui::Button("Reset");
```

This produces four widgets stacked vertically, each on its own row.

To put two widgets on the same row, call `ImGui::SameLine()` between them. `SameLine`
moves the cursor **back to the previous line's vertical position** and advances `x` by
`ItemSpacing.x` (or by an explicit offset):

```cpp
if (ImGui::Button("OK")) confirm();
ImGui::SameLine();
if (ImGui::Button("Cancel")) cancel();
```

Other layout primitives that nudge the cursor:

- **`ImGui::NewLine()`** -- forces a blank line of `FontSize` height; the cursor goes
  back to the left margin on the next row.
- **`ImGui::Spacing()`** -- inserts a small vertical gap (one `ItemSpacing.y`).
- **`ImGui::Dummy(ImVec2 size)`** -- inserts an invisible widget of the given size,
  consuming layout space. Useful for "leave 50 px of vertical breathing room here".
- **`ImGui::Indent(float w = 0)` / `ImGui::Unindent(float w = 0)`** -- shifts the left
  margin right or left by `w` (or by `IndentSpacing` if `0`). Used for nested sections,
  tree-view bodies, etc.
- **`ImGui::Separator()`** -- draws a horizontal line and advances the cursor.

### Sizing widgets

By default each widget chooses its own size: text takes its measured size, sliders take
a fraction of the available width, buttons hug their label, and so on. Three layers
control item width:

- **`ImGui::SetNextItemWidth(float w)`** -- one-shot override for the **next** widget
  only. `w > 0` is an absolute pixel width; `w < 0` is `availableWidth + w` (so `-1.0f`
  means "available width minus 1 pixel").
- **`ImGui::PushItemWidth(float w)` / `ImGui::PopItemWidth()`** -- stack-scoped override
  for all widgets between push and pop. Same convention for negative widths.
- **`ImGui::CalcItemWidth()`** -- queries the current default item width (taking pushes
  and the window's content region into account). Useful inside custom widgets that need
  to pick their own size while respecting the caller's `PushItemWidth`.

To find out how much space remains in the current content region:

```cpp
ImVec2 avail = ImGui::GetContentRegionAvail();
// avail.x: remaining width to the right of the cursor
// avail.y: remaining height below the cursor
```

This is the read-side counterpart to `Dummy`/`SetNextItemWidth` and is how responsive
layouts adapt to varying window sizes.

### Style stack

Spacing, padding, frame rounding, alpha, colours, and a long list of similar visual
parameters live on a per-context **style** stack. To temporarily override one for a
section of UI, push it, draw, then pop:

```cpp
ImGui::PushStyleVar(ImGuiStyleVar_ItemSpacing, ImVec2(2.0f, 2.0f));
ImGui::PushStyleColor(ImGuiCol_Button, IM_COL32(40, 40, 60, 255));

ImGui::Button("Tight 1");
ImGui::Button("Tight 2");

ImGui::PopStyleColor();
ImGui::PopStyleVar();
```

`ImGuiStyleVar_ItemSpacing` is the spacing between widgets on the same row and between
rows -- the same value `SameLine` uses for its default x-offset. Other commonly pushed
style vars are `FramePadding` (padding inside button frames), `WindowPadding` (margin
between window edges and content), `IndentSpacing`, and `FrameRounding`.

### Tables (modern API, since 1.80)

Up through 1.71, Dear ImGui shipped a `Columns()` API for splitting a region into
side-by-side columns. It is still present for backwards compatibility but is
**deprecated for new code** and feature-frozen. Since 1.80 (released January 2021), the
modern **Tables API** is the recommended way to lay out tabular data and grid-like UI.

The Tables API is far richer than `Columns()`: columns can be resized, reordered,
hidden, sorted, frozen against scrolling, and given per-column width policies
(fixed-width, stretch, auto-fit), and the table itself can have headers, scroll on both
axes, draw bordered cells, and persist user customisation across runs.

The basic skeleton is:

```cpp
ImGuiTableFlags flags =
    ImGuiTableFlags_Resizable |
    ImGuiTableFlags_Reorderable |
    ImGuiTableFlags_Hideable |
    ImGuiTableFlags_Sortable |
    ImGuiTableFlags_RowBg |
    ImGuiTableFlags_BordersV;

if (ImGui::BeginTable("processes", 4, flags))
{
    ImGui::TableSetupColumn("PID",    ImGuiTableColumnFlags_WidthFixed,   64.0f);
    ImGui::TableSetupColumn("Name",   ImGuiTableColumnFlags_WidthStretch, 0.0f);
    ImGui::TableSetupColumn("CPU%",   ImGuiTableColumnFlags_WidthFixed,   72.0f);
    ImGui::TableSetupColumn("Memory", ImGuiTableColumnFlags_WidthFixed,   96.0f);
    ImGui::TableHeadersRow();

    for (const Process& p : processes)
    {
        ImGui::TableNextRow();

        ImGui::TableSetColumnIndex(0);
        ImGui::Text("%d", p.pid);

        ImGui::TableNextColumn();
        ImGui::TextUnformatted(p.name.c_str());

        ImGui::TableNextColumn();
        ImGui::Text("%.1f%%", p.cpu_percent);

        ImGui::TableNextColumn();
        ImGui::Text("%llu KiB", p.rss_bytes / 1024);
    }
    ImGui::EndTable();
}
```

The core entry points:

- **`BeginTable(id, columnCount, flags = 0, outerSize = ImVec2(0,0), innerWidth = 0)`**
  Opens a table with the given identifier and column count. Returns `false` if the
  table is clipped or otherwise skipped; in that case do not issue cell calls and do
  not call `EndTable`.
- **`TableSetupColumn(label, flags = 0, initWidth = 0.0f, userId = 0)`** Declares a
  column. Must be called between `BeginTable` and the first row. Columns can be added
  in arbitrary order via `userId` but visually appear in declaration order unless
  reordered by the user.
- **`TableHeadersRow()`** Emits a header row using the labels passed to
  `TableSetupColumn`. Header cells are clickable for sorting if the column is sortable.
- **`TableNextRow(flags = 0, minRowHeight = 0)`** Advances to the next row.
- **`TableSetColumnIndex(int n)`** Jumps the cell cursor to column `n` of the current
  row. Returns `false` if that column is hidden.
- **`TableNextColumn()`** Advances to the next column of the current row (or, if at the
  end of the row, starts a new row). Returns `false` if the column is hidden -- a
  convenient way to write "if visible, draw this cell".

Selected `ImGuiTableFlags`:

| Flag                              | Meaning                                                                |
| --------------------------------- | ---------------------------------------------------------------------- |
| `Resizable`                       | User can drag column edges to resize.                                  |
| `Reorderable`                     | User can drag column headers to reorder.                               |
| `Hideable`                        | User can hide columns via header context menu.                         |
| `Sortable`                        | Header clicks toggle sort. Use `TableGetSortSpecs` to read sort state. |
| `RowBg`                           | Alternate row background colour.                                       |
| `BordersInnerH` / `BordersOuterH` | Horizontal border lines.                                               |
| `BordersInnerV` / `BordersOuterV` | Vertical border lines.                                                 |
| `ScrollX` / `ScrollY`             | Enable horizontal / vertical scrolling.                                |
| `SizingFixedFit`                  | Columns default to `WidthFixed`, fit content.                          |
| `SizingStretchProp`               | Columns default to `WidthStretch`, weights proportional.               |
| `SizingStretchSame`               | Columns default to `WidthStretch`, equal weights.                      |
| `PadOuterX` / `NoPadInnerX`       | Padding tweaks.                                                        |

Selected `ImGuiTableColumnFlags`:

| Flag                             | Meaning                                                                                     |
| -------------------------------- | ------------------------------------------------------------------------------------------- |
| `WidthStretch`                   | Column shares leftover width with other stretch columns, proportional to the init weight.   |
| `WidthFixed`                     | Column is a fixed pixel width (initial value from `TableSetupColumn`, then user-resizable). |
| `WidthAuto`                      | Column auto-fits to its content (no user resizing).                                         |
| `AutoResizeToFit`                | Column resizes to fit content each frame.                                                   |
| `NoResize`                       | Disable user resizing of this column.                                                       |
| `NoReorder`                      | Pin column position.                                                                        |
| `NoHide`                         | Disable user hiding via the header context menu.                                            |
| `NoClip`                         | Disable clipping of cells against the column edge.                                          |
| `NoSort` / `Sort*`               | Disable sorting, or force descending/ascending default.                                     |
| `IndentEnable` / `IndentDisable` | Apply or skip the window indent for cells in this column (default: column 0 indents).       |
| `DefaultHide`                    | Column starts hidden until toggled by user.                                                 |

The Tables API is what makes Dear ImGui competitive for **structured data UIs** -- log
viewers, asset browsers, profilers, entity inspectors -- and is the most significant
single feature added since the library's creation.

### Other layout helpers worth knowing

A handful of additional functions round out the cursor model and come up frequently in
real-world Dear ImGui code:

- **`ImGui::GetCursorPos()` / `SetCursorPos(ImVec2)`** -- read or write the layout
  cursor's window-local position. Useful for "draw this widget exactly here" overrides;
  use sparingly, since manually positioning widgets breaks the implicit flow and makes
  layouts fragile to font/scale changes.
- **`ImGui::GetCursorScreenPos()` / `SetCursorScreenPos(ImVec2)`** -- the same but in
  absolute screen coordinates. Required when bridging to the draw-list API
  (`ImGui::GetWindowDrawList()->AddLine(...)`) which works in screen space.
- **`ImGui::AlignTextToFramePadding()`** -- shifts the cursor down by `FramePadding.y`
  so that a `Text` call sits on the same baseline as the framed widget (`Button`,
  `InputText`) on the same `SameLine` row. Essential for getting "label: [input]" rows
  visually aligned.
- **`ImGui::BeginGroup()` / `EndGroup()`** -- treat a sequence of widgets as a single
  layout item. `IsItemHovered()` after `EndGroup` reports hover over any of the
  contained items, and `SameLine` after the group treats the group as one block.
- **`ImGui::PushID(id)` / `PopID()`** -- pushes onto the ID stack so two widgets with
  the same label inside two different scopes (e.g. one row per item in a list, all
  containing a "Delete" button) don't collide. The library uses label text as the
  default ID; the ID stack disambiguates duplicates.

### Sample skeleton: a full frame

Putting the pieces together, a typical Dear ImGui main loop looks like:

```cpp
void render_ui(AppState& app)
{
    // ---- Inspector window with two widgets per row ----
    ImGui::Begin("Inspector");

    ImGui::Text("Camera");
    ImGui::PushItemWidth(120.0f);
    ImGui::SliderFloat("Fov",    &app.camera.fov,    20.0f, 120.0f);
    ImGui::SameLine();
    ImGui::SliderFloat("Near",   &app.camera.znear,   0.01f, 10.0f);
    ImGui::SameLine();
    ImGui::SliderFloat("Far",    &app.camera.zfar,    10.0f, 5000.0f);
    ImGui::PopItemWidth();

    ImGui::Separator();
    ImGui::Spacing();

    ImGui::Checkbox("Wireframe", &app.wireframe);
    ImGui::SameLine();
    ImGui::Checkbox("VSync",     &app.vsync);

    ImGui::End();

    // ---- Log child inside a second window ----
    ImGui::Begin("Logs");
    {
        ImGui::BeginChild("##logregion",
                          ImVec2(0, -ImGui::GetFrameHeightWithSpacing()),
                          ImGuiChildFlags_Borders);
        for (const auto& line : app.log)
            ImGui::TextUnformatted(line.c_str());
        if (app.log_autoscroll && ImGui::GetScrollY() >= ImGui::GetScrollMaxY())
            ImGui::SetScrollHereY(1.0f);
        ImGui::EndChild();

        ImGui::Checkbox("Auto-scroll", &app.log_autoscroll);
        ImGui::SameLine();
        if (ImGui::Button("Clear")) app.log.clear();
    }
    ImGui::End();
}
```

Each frame, your main loop calls `ImGui::NewFrame()`, then `render_ui(app)`, then
`ImGui::Render()`, and finally hands the resulting draw data to your renderer backend.
The application state is just a plain struct that the UI reads and writes directly.

---

### Example: a per-row action button list

A pattern that exercises `PushID`, `SameLine`, and selectable rows -- the classic
"list of items, each with inline action buttons" UI:

```cpp
void render_task_list(std::vector<Task>& tasks)
{
    if (ImGui::BeginTable("tasks", 3,
            ImGuiTableFlags_RowBg |
            ImGuiTableFlags_BordersInnerH |
            ImGuiTableFlags_SizingFixedFit))
    {
        ImGui::TableSetupColumn("Done", ImGuiTableColumnFlags_WidthFixed,   48.0f);
        ImGui::TableSetupColumn("Title", ImGuiTableColumnFlags_WidthStretch);
        ImGui::TableSetupColumn("",      ImGuiTableColumnFlags_WidthFixed, 120.0f);
        ImGui::TableHeadersRow();

        for (size_t i = 0; i < tasks.size(); ++i)
        {
            ImGui::PushID(static_cast<int>(i));
            ImGui::TableNextRow();

            ImGui::TableSetColumnIndex(0);
            ImGui::Checkbox("##done", &tasks[i].done);

            ImGui::TableSetColumnIndex(1);
            ImGui::AlignTextToFramePadding();
            ImGui::TextUnformatted(tasks[i].title.c_str());

            ImGui::TableSetColumnIndex(2);
            if (ImGui::SmallButton("Edit"))   begin_edit(tasks[i]);
            ImGui::SameLine();
            if (ImGui::SmallButton("Delete")) tasks.erase(tasks.begin() + i);

            ImGui::PopID();
        }
        ImGui::EndTable();
    }
}
```

Note the use of `PushID(i)` so the two `"##done"` checkboxes (and the two `"Edit"`
buttons) in different rows are treated as distinct widgets. Without it, Dear ImGui's
internal ID hashing would collapse them to the same control and clicking any row's
"Delete" would activate the first row.

## Strengths and Weaknesses

### Strengths

- **The two-line slider.** The central advantage of immediate-mode GUI is the
  cost-per-control: adding "one more float to tweak" is one function call, end of story.
  For tooling, debug overlays, profilers, and engine-side inspectors, this productivity
  edge is unmatched. Retained-mode frameworks cannot beat it because their model
  requires a widget object plus state-sync plumbing for every control.
- **No framework lock-in.** Dear ImGui does not own the event loop, the window, the
  renderer, the input source, or the state. It plugs into any host -- a custom engine, a
  Vulkan sample, a Unity inspector overlay, a terminal renderer (see
  [`imtui`](../tui-libraries/imtui.md)) -- with a small backend file.
- **C++ but C-ABI friendly.** The public API is essentially a free-function namespace
  with POD parameters and pointers. Bindings exist in dozens of languages (Rust via
  `imgui-rs`, Python via `pyimgui`, D via `bindbc-imgui`, Go, C#, Lua, Zig, ...).
- **Single-context, single-thread simplicity.** One `ImGuiContext`, called from one
  thread per frame. No reactive graph, no virtual DOM, no scheduler. Trivial to reason
  about.
- **Stable API across a decade.** Code from 2015 still mostly works in 2025. Deprecated
  functions usually keep working with warnings for years.
- **The Tables API is competitive with retained-mode tables.** Modern Tables (since
  1.80) cover the use cases that retained-mode UI tables traditionally win on --
  sorting, resizing, freezing, scrolling, custom cells. The mental cost of a Dear ImGui
  table is comparable to a HTML table but with full live-state behaviour.
- **Docking and multi-viewport.** Editor-style "drag a panel out into its own OS
  window" is supported natively.
- **Renderer-agnostic draw output.** The library emits a list of vertex/index/command
  buffers; the application's renderer is in full control of how to display them.
- **Industry-tested at scale.** Used in shipping AAA-game tools, NVIDIA's developer
  tools, robotics simulators, scientific viewers, and countless indie projects. Years
  of real-world abuse have shaken out the edge cases.

### Weaknesses

- **Cursor-based layout fights responsive design.** The flow model is paragraph-style,
  not constraint-based. Building a UI that genuinely adapts to width changes (a panel
  that switches between one-column and two-column layouts at a breakpoint, or a control
  bar that wraps when narrow) takes manual `GetContentRegionAvail` queries and explicit
  branching. There is no flexbox, no constraint solver, no `Stretch` / `Fill`
  primitive other than `WidthStretch` columns inside tables.
- **No semantic state model.** Because state lives in the application, Dear ImGui has
  no built-in answer to "undo / redo across UI edits", "two-way binding to a backing
  store", or "form validation". Applications either grow their own machinery or accept
  that the UI is direct manipulation of live state.
- **Performance scales linearly with widget count per frame.** Each visible widget is
  re-issued every frame. For UIs with thousands of widgets (deep tree views with many
  expanded nodes, very long lists) you must use **list clippers**
  (`ImGuiListClipper`) to skip off-screen items, or your frame rate dies. Tables and
  scrolling regions already do this for you; trees and custom widgets do not.
- **No accessibility story.** Dear ImGui draws pixels (or terminal cells, in
  [`imtui`](../tui-libraries/imtui.md)'s case). Screen readers, AT-SPI, and platform
  accessibility APIs see nothing. This is a fundamental consequence of immediate-mode
  rendering and a hard reason not to ship Dear ImGui in consumer end-user UIs.
- **Mediocre i18n.** Right-to-left scripts, complex shaping (Arabic, Indic), and
  bidirectional text are not first-class. The font atlas system supports any glyphs you
  bake in but the layout itself is left-to-right paragraph flow.
- **Immediate-mode is not output-driven.** The mental model of Dear ImGui is
  **frame-driven**: every frame is one-shot, full re-issue. This is fine for a
  60-Hz-driven application but is a poor fit for **static, one-shot terminal output**
  where you want to print a snapshot and stop. Frameworks like
  [`ratatui`](../tui-libraries/ratatui.md) (immediate-mode rendering, but also
  frame-driven) share this property; truly static "print a styled report and exit" use
  cases are not what immediate-mode GUI tools are designed for. (Sparkles itself targets
  this static-output niche, which is conceptually orthogonal to Dear ImGui's frame
  loop.)
- **`Columns()` legacy.** The old columns API is still present and visible in old
  tutorials, which can mislead newcomers. Use Tables for new code.

### Comparison to neighbours in this catalogue

- vs **[`imtui`](../tui-libraries/imtui.md)** -- imtui is **literally Dear ImGui ported
  to the terminal**. It reuses Dear ImGui's API, layout cursor, widgets, and tables
  almost unchanged, with a custom backend that rasterises into a character grid instead
  of triangles. The strengths and weaknesses analysis above carries over essentially
  verbatim; the only difference is that imtui's draw target is terminal cells.
- vs **[`ratatui`](../tui-libraries/ratatui.md)** -- both are immediate-mode in the
  re-render-every-frame sense, but ratatui's layout system is **constraint-based**
  (Cassowary, via the `kasuari` crate). Where Dear ImGui has a moving cursor and
  `SameLine`, ratatui has a `Layout` that subdivides a `Rect` according to a list of
  `Constraint`s. Ratatui is therefore far better at responsive resizing; Dear ImGui is
  far better at the two-line slider ergonomic.
- vs **[`ink`](../tui-libraries/ink.md)** -- Ink uses a real flexbox layout engine
  (Yoga) and a retained virtual-DOM model. It is the opposite end of the spectrum from
  Dear ImGui on essentially every axis: retained vs immediate, declarative React-style
  components vs imperative function calls, flexbox vs cursor-flow.
- vs **Android's ConstraintLayout** ([`android-constraintlayout.md`](./android-constraintlayout.md))
  -- ConstraintLayout is a Cassowary-family solver doing whole-graph constraint
  resolution; Dear ImGui is a moving caret. Different problems, different tools. The
  comparison is most useful as a reminder that "immediate-mode" addresses
  **interaction ergonomics** (state ownership, call-site brevity), while "constraint
  layout" addresses **spatial reasoning** (declaring relationships between things). A
  hypothetical library could have one without the other in either direction.

---

## References

- **GitHub repository** -- <https://github.com/ocornut/imgui>
- **Wiki landing page** -- <https://github.com/ocornut/imgui/wiki>
- **FAQ** -- <https://github.com/ocornut/imgui/blob/b62bfd6b06de958e4630b715225b7e8409bfd0f9/docs/FAQ.md>
- **Tables API documentation** -- <https://github.com/ocornut/imgui/wiki/Tables-API>
  (and the main tracking issue [#3740](https://github.com/ocornut/imgui/issues/3740))
- **Examples and backends** -- <https://github.com/ocornut/imgui/tree/b62bfd6b06de958e4630b715225b7e8409bfd0f9/examples>
- **`imgui.h` (public API)** -- <https://github.com/ocornut/imgui/blob/b62bfd6b06de958e4630b715225b7e8409bfd0f9/imgui.h>
- **`imgui_demo.cpp` (canonical example of every feature)** --
  <https://github.com/ocornut/imgui/blob/b62bfd6b06de958e4630b715225b7e8409bfd0f9/imgui_demo.cpp>
- **Background reading on immediate-mode GUIs** -- Casey Muratori's "Immediate-Mode
  Graphical User Interfaces" talk, archived at <https://caseymuratori.com/blog_0001>
- **Selected ports and bindings:**
  - `imtui` (terminal port): <https://github.com/ggerganov/imtui> -- see
    [`../tui-libraries/imtui.md`](../tui-libraries/imtui.md)
  - `imgui-rs` (Rust): <https://github.com/imgui-rs/imgui-rs>
  - `pyimgui` (Python): <https://github.com/pyimgui/pyimgui>
  - `cimgui` (auto-generated C API used by most bindings):
    <https://github.com/cimgui/cimgui>
- **Industry adoption examples** -- the [Dear ImGui Gallery](https://github.com/ocornut/imgui/issues?q=label%3Agallery)
  issues showcase shipping tools using the library.
