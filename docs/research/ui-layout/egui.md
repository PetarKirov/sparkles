# egui (Rust)

A pure-Rust immediate-mode GUI library that combines the simplicity of Dear ImGui's
single-pass rendering with per-id retained sizing memory, so application code stays
stateless while the layout system still produces stable, well-sized widgets after the
second frame.

| Field            | Value                                                |
| ---------------- | ---------------------------------------------------- |
| Language         | Rust                                                 |
| License          | MIT OR Apache-2.0                                    |
| Repository       | <https://github.com/emilk/egui>                      |
| Documentation    | <https://docs.rs/egui/latest/egui/>                  |
| Version snapshot | 0.34.x release line (2026)                           |
| Author           | Emil Ernerfeldt ([@emilk](https://github.com/emilk)) |

---

## Overview

egui (pronounced "e-gooey", originally spelled `Emigui`) is an immediate-mode GUI
library written in pure Rust. It targets three deployment modes from the same source:
WebAssembly in the browser, native desktop on Windows/macOS/Linux/Android, and
embedded inside game engines (Bevy, Macroquad, custom renderers). The official
windowing/integration crate is `eframe`, which wraps `winit` + `wgpu` (or `glow`) and
hides platform setup behind a single `App` trait.

**What it solves.** Most retained-mode GUI toolkits force you to mirror application
state into a widget tree, keep it in sync with reactive callbacks, and reason about
ownership across UI and domain layers. egui collapses that mirror: every frame, the
application walks a single function and emits the entire UI top-to-bottom from
current state. There is no scene graph to mutate, no widget identity to track, no
diffing reconciler. The trade-off is that some layout decisions that retained-mode
toolkits make once (during measure/arrange) must be made every frame here — and
sometimes, with information that is only available _after_ the first frame has
already been drawn.

**Design philosophy.** The README states egui "aims to be the easiest-to-use Rust
GUI library, and the simplest way to make a web app in Rust." That goal drives three
concrete choices: (1) no callbacks — interaction is observed by inspecting the
`Response` returned from widget calls in the same frame; (2) no manual memory
management of widget identity — `Ui::push_id` and stable source locations form an
implicit id stack; (3) no asynchronous redraw triggers — the application requests
repaints explicitly via `ctx.request_repaint()`, and otherwise egui is content to
sleep until input arrives.

**History.** Emil Ernerfeldt started the project around 2019 as `Emigui` and renamed
it to `egui` in 2020. It rapidly attracted contributors after the WebAssembly demo
went viral on Rust forums. The project is now sponsored and partially staffed by
[Rerun.io](https://rerun.io), a data-visualization startup whose flagship product —
the Rerun Viewer — is the most ambitious application built on egui to date. Other
notable users include game-development tools, blockchain explorers, scientific
visualisation prototypes, and a long tail of internal tooling that benefits from
shipping the same UI to a browser and a native binary.

**Where it sits on the paradigm spectrum.** egui is firmly in the **immediate-mode**
camp alongside [Dear ImGui](dear-imgui.md), but it differs from classical ImGui in
important ways: it is _Rust-native_ (no FFI, no `unsafe` in user code), it owns its
own font rasterisation and tessellation pipeline (no platform-specific text
rendering), and it persists certain pieces of per-widget state across frames in an
internal `Memory` store keyed on `Id`. That last point is what produces egui's
characteristic "first frame the size is wrong, second frame it's right" behaviour —
discussed in detail under [Layout Model](#layout-model).

Conceptually, egui is the **opposite** of retained-mode toolkits like GTK, Qt, or
Flutter, and it is _closer to but not identical to_ Dear ImGui. Inside the broader
UI-layout catalog, the most analogous TUI design is [nottui](../tui-libraries/nottui.md),
which uses an immediate-mode declarative API for terminals; the spiritually
opposite design is [Textual](../tui-libraries/textual.md)'s reactive
component tree.

---

## Layout Model

### Immediate-mode with per-id retained memory

The fundamental rendering primitive is the `Ui`. A `Ui` represents a rectangular
region with a current cursor and a `Layout` (direction + alignment policy). The
application receives a top-level `Ui` from a panel or window, and recursively
nests child `Ui`s via `ui.horizontal(...)`, `ui.vertical(...)`, `ui.scope(...)`,
and friends. Each widget call advances the cursor by the widget's _measured_ size
and returns a `Response`.

Crucially, while the layout pass is _single-pass_ (no separate measure/arrange
phases), egui retains a small piece of state per widget: the widget's `Id` (derived
from its source location and an id stack) maps into `Memory` to recall the size the
widget had on the _previous_ frame. This lets containers that would otherwise need
to know their children's sizes in advance (e.g., `Grid` aligning columns, `Window`
auto-shrinking to fit content, `CollapsingHeader` animating open) "remember" the
right size and use it as a hint _this_ frame.

The consequence is the canonical egui quirk:

> The first frame the size is wrong, the second frame it's right.

Concretely: a `Grid` with two columns must lay out cell 0 before it knows the width
of cell 0; it must lay out cell 1 before it knows whether cell 0 in row 2 is wider.
On frame 1, egui guesses (using a small default or zero), draws the grid, _records_
the maximum width each column actually used, and on frame 2 uses those recorded
widths as hints. The result is a single-frame flicker on initial display and after
any structural change. The library mitigates this in two ways:

1. **`Context::request_discard()`** — a widget that knows its first-frame layout is
   wrong can request that egui discard the painted output and immediately re-run
   the UI function with the now-correct sizing memory. The user sees only the
   corrected frame. `Grid` uses this internally for its first measurement pass.

2. **Double-pass rendering opt-in** — applications that prefer to pay the cost
   unconditionally can configure egui to always run two passes per frame, treating
   the first as a measurement pass whose output is discarded.

This is the architectural compromise that distinguishes egui from Dear ImGui:
Dear ImGui also retains some per-id state (open/closed flags, scroll offsets,
window positions) but does _not_ retain per-widget sizing, which is why ImGui is
sometimes criticised for layout fragility in complex containers like its table API.

### The Ui API

A `Ui` is the main interaction surface. Selected methods from the public API:

| Method                                | Effect                                                  |
| ------------------------------------- | ------------------------------------------------------- |
| `ui.horizontal(\|ui\| { ... })`       | Lay out children left-to-right.                         |
| `ui.vertical(\|ui\| { ... })`         | Lay out children top-to-bottom.                         |
| `ui.horizontal_wrapped(\|ui\| ...)`   | Like `horizontal`, wrapping to next line on overflow.   |
| `ui.columns(n, \|cols\| { ... })`     | Split current space into `n` equal columns.             |
| `ui.scope(\|ui\| { ... })`            | Run a closure with temporary style/spacing changes.     |
| `ui.group(\|ui\| { ... })`            | Visually frame a sub-region with a stroke.              |
| `ui.allocate_space(size)`             | Reserve a rectangle of exactly `size`, return its rect. |
| `ui.allocate_exact_size(size, sense)` | Reserve exact size + return a `Response` for hit-test.  |
| `ui.allocate_at_least(size, sense)`   | Reserve at least `size`; may grow.                      |
| `ui.allocate_ui_with_layout(...)`     | Allocate a size and run a closure with a custom layout. |
| `ui.available_size()`                 | Remaining size before the cursor hits the edge.         |
| `ui.set_min_size(size)` / `set_max_*` | Constrain the `Ui`'s reported size.                     |

Every widget call returns a `Response`, which is the _only_ mechanism for handling
interaction. There are no event callbacks. A `Response` carries:

- `clicked()`, `double_clicked()`, `secondary_clicked()`, `triple_clicked()`
- `hovered()`, `has_focus()`, `gained_focus()`, `lost_focus()`
- `dragged()`, `drag_started()`, `drag_stopped()`, `drag_delta()`
- `rect`, `interact_rect`, `sense`, `id`
- `changed()` — for input widgets (text edit, slider, drag value)

The `Response` model means hit-testing is intrinsically coupled to layout: a widget
_is_ at a known rectangle on this frame, so the click test is `if response.rect
.contains(pointer_pos) && pointer_pressed { ... }`. Because every widget is
drawn-and-tested in one shot, there is no separate event-routing tree.

### The Layout struct

`Layout` describes how children are arranged inside a `Ui`. It is constructed via
named factories and modifier methods:

```rust
use egui::{Align, Layout};

// Top-to-bottom, left-aligned (default for vertical panels).
let l = Layout::top_down(Align::LEFT);

// Left-to-right, vertically centered (default for horizontal rows).
let l = Layout::left_to_right(Align::Center);

// Right-to-left, useful for trailing action buttons.
let l = Layout::right_to_left(Align::Center);

// With wrap and justification:
let l = Layout::top_down(Align::LEFT)
    .with_main_align(Align::Center)
    .with_cross_align(Align::Min)
    .with_main_wrap(true)
    .with_main_justify(true);
```

The two axes are:

- **Main axis** — the direction children are stacked (vertical for `top_down`,
  horizontal for `left_to_right`).
- **Cross axis** — perpendicular to main; controls how a child is aligned within
  its allotted band.

Modifiers:

| Modifier                 | Effect                                                                      |
| ------------------------ | --------------------------------------------------------------------------- |
| `.with_main_align(a)`    | Where children sit along the main axis (Min/Center/Max).                    |
| `.with_cross_align(a)`   | Where each child sits in its cross-axis band.                               |
| `.with_main_wrap(b)`     | If `true`, children that overflow wrap to a new line/column.                |
| `.with_main_justify(b)`  | If `true`, stretch the _first_ widget per row to fill remaining main-space. |
| `.with_cross_justify(b)` | Stretch each child to fill the full cross-axis extent of the `Ui`.          |

The combinatorics are deliberate: rather than a Flexbox-style enum
(`justify-content: space-between` etc.), egui composes alignment + justification +
wrap as orthogonal toggles on top of a direction. This produces fewer named
options but cleaner semantics — every combination is meaningful.

### Panels and containers

The top-level layout primitives are **panels**, which subtract their region from a
remaining `CentralPanel`:

| Panel                    | Position                       | Notes                                             |
| ------------------------ | ------------------------------ | ------------------------------------------------- |
| `SidePanel::left`        | Anchored to left edge          | Resizable handle on right side.                   |
| `SidePanel::right`       | Anchored to right edge         | Resizable handle on left side.                    |
| `TopBottomPanel::top`    | Anchored to top edge           | Used for menu bars, toolbars.                     |
| `TopBottomPanel::bottom` | Anchored to bottom edge        | Used for status bars, footers.                    |
| `CentralPanel`           | Fills remaining space          | Must be added last; absorbs leftover area.        |
| `Window`                 | Floating, draggable, resizable | Lives in its own pseudo-z-layer.                  |
| `Area`                   | Free-positioned region         | Low-level primitive; `Window` is built on `Area`. |

The canonical "shell" of an egui app is exactly this stack of panels:

```rust
egui::TopBottomPanel::top("menu_bar").show(ctx, |ui| {
    egui::menu::bar(ui, |ui| {
        ui.menu_button("File", |ui| {
            if ui.button("Open").clicked() { /* ... */ }
            if ui.button("Quit").clicked() { /* ... */ }
        });
    });
});

egui::SidePanel::left("sidebar")
    .default_width(200.0)
    .resizable(true)
    .show(ctx, |ui| {
        ui.heading("Files");
        for file in &app.files {
            ui.selectable_label(app.selected == Some(file.id), &file.name);
        }
    });

egui::TopBottomPanel::bottom("status").show(ctx, |ui| {
    ui.label(&app.status_text);
});

egui::CentralPanel::default().show(ctx, |ui| {
    ui.heading("Content");
    // ... main content area ...
});
```

`Grid` is a 2-D table primitive that aligns columns _across rows_:

```rust
egui::Grid::new("settings_grid")
    .striped(true)
    .num_columns(2)
    .spacing([12.0, 4.0])
    .show(ui, |ui| {
        ui.label("Name");
        ui.text_edit_singleline(&mut app.name);
        ui.end_row();

        ui.label("Threads");
        ui.add(egui::Slider::new(&mut app.threads, 1..=32));
        ui.end_row();

        ui.label("Enabled");
        ui.checkbox(&mut app.enabled, "");
        ui.end_row();
    });
```

This is where the "first frame is wrong" effect is most visible: the second column
cannot know its width until row 1 is drawn, but row 0 has already been drawn
before row 1 exists. `Grid` resolves this by storing each column's maximum
observed width in `Memory` (keyed on the grid id `"settings_grid"`) and reusing it
next frame. On the very first frame, columns appear at their natural widths;
starting frame 2, they are aligned. Apps that cannot tolerate the flicker enable
`Context::request_discard()` to force a second pass before the user sees anything.

`ScrollArea` is a container that clips its child to a fixed viewport and exposes
scrollbars:

```rust
egui::ScrollArea::vertical()
    .max_height(300.0)
    .auto_shrink([false, false])
    .show(ui, |ui| {
        for line in &app.log_lines {
            ui.monospace(line);
        }
    });
```

The `auto_shrink` axis flags are important: by default a `ScrollArea` shrinks to
fit its content (which is usually wrong inside a panel), so most real applications
pass `[false, false]`. `CollapsingHeader` is the "twisty" disclosure widget:

```rust
egui::CollapsingHeader::new("Advanced options")
    .default_open(false)
    .show(ui, |ui| {
        ui.checkbox(&mut app.use_simd, "Use SIMD");
        ui.checkbox(&mut app.profile, "Enable profiler");
    });
```

Its open/closed state is stored in `Memory` under the header's `Id`, surviving
across frames without any application-level state.

### Size hints: `desired_size`, `available_size`, allocation

Widgets and containers communicate sizing through three channels:

1. **`desired_size`** — what the widget _wants_ in an unconstrained world.
   Computed by the widget from its content (e.g., `Label::desired_size` measures
   the text). The `Widget` trait does not expose this directly; instead, the
   widget calls `ui.allocate_*` with its desired size and the parent decides what
   to grant.

2. **`available_size`** — what the parent `Ui` has _left_. Returned by
   `ui.available_size()`. Widgets that should stretch (text inputs, drag areas,
   custom canvases) typically allocate exactly this.

3. **Allocation API** — three flavors:

   ```rust
   // Reserve exactly `size`. Always returns a rect of that exact size.
   let rect = ui.allocate_space(vec2(100.0, 24.0));

   // Same as above but also returns a Response for interaction.
   let (rect, response) = ui.allocate_exact_size(
       vec2(100.0, 24.0),
       egui::Sense::click(),
   );

   // Reserve at least `size`. Parent may grant more (e.g., to fill remaining
   // space when using cross_justify).
   let (rect, response) = ui.allocate_at_least(
       vec2(100.0, 24.0),
       egui::Sense::drag(),
   );
   ```

   `allocate_ui_with_layout` is the heavy-weight escape hatch:

   ```rust
   ui.allocate_ui_with_layout(
       vec2(ui.available_width(), 200.0),
       Layout::right_to_left(Align::Center),
       |ui| {
           if ui.button("Cancel").clicked() { /* ... */ }
           if ui.button("OK").clicked() { /* ... */ }
       },
   );
   ```

   This is the standard pattern for trailing action buttons: allocate a slab of
   space, install a right-to-left layout, and put your "primary" button first.

### Full layout example

A small but complete egui application that exercises the panel stack, a resizable
`SidePanel`, a `Grid`, a `ScrollArea`, and `Window`:

```rust
use eframe::egui;
use egui::{Align, Layout, Vec2};

struct DemoApp {
    files: Vec<String>,
    selected: Option<usize>,
    detail_text: String,
    log_lines: Vec<String>,
    show_about: bool,
}

impl Default for DemoApp {
    fn default() -> Self {
        Self {
            files: (0..40).map(|i| format!("file_{i:02}.txt")).collect(),
            selected: None,
            detail_text: String::new(),
            log_lines: (0..200).map(|i| format!("log line {i}")).collect(),
            show_about: false,
        }
    }
}

impl eframe::App for DemoApp {
    fn update(&mut self, ctx: &egui::Context, _: &mut eframe::Frame) {
        // Menu bar at the top.
        egui::TopBottomPanel::top("menu_bar").show(ctx, |ui| {
            egui::menu::bar(ui, |ui| {
                ui.menu_button("File", |ui| {
                    if ui.button("Quit").clicked() {
                        ui.ctx().send_viewport_cmd(egui::ViewportCommand::Close);
                    }
                });
                ui.menu_button("Help", |ui| {
                    if ui.button("About...").clicked() {
                        self.show_about = true;
                        ui.close_menu();
                    }
                });
            });
        });

        // Resizable file list on the left.
        egui::SidePanel::left("file_list")
            .default_width(180.0)
            .min_width(120.0)
            .resizable(true)
            .show(ctx, |ui| {
                ui.heading("Files");
                egui::ScrollArea::vertical()
                    .auto_shrink([false; 2])
                    .show(ui, |ui| {
                        for (i, name) in self.files.iter().enumerate() {
                            let resp = ui.selectable_label(
                                self.selected == Some(i),
                                name,
                            );
                            if resp.clicked() {
                                self.selected = Some(i);
                                self.detail_text = format!("Contents of {name}");
                            }
                        }
                    });
            });

        // Status bar.
        egui::TopBottomPanel::bottom("status").show(ctx, |ui| {
            ui.with_layout(Layout::left_to_right(Align::Center), |ui| {
                ui.label(format!(
                    "{} files | selection: {}",
                    self.files.len(),
                    self.selected
                        .map(|i| self.files[i].as_str())
                        .unwrap_or("(none)"),
                ));
                ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                    ui.hyperlink_to("egui docs", "https://docs.rs/egui");
                });
            });
        });

        // Main content area.
        egui::CentralPanel::default().show(ctx, |ui| {
            // A two-column grid showing metadata.
            egui::Grid::new("meta_grid")
                .striped(true)
                .num_columns(2)
                .spacing([16.0, 4.0])
                .show(ui, |ui| {
                    ui.label("Selection:");
                    ui.monospace(
                        self.selected
                            .map(|i| self.files[i].as_str())
                            .unwrap_or("-"),
                    );
                    ui.end_row();

                    ui.label("Detail length:");
                    ui.label(format!("{} chars", self.detail_text.len()));
                    ui.end_row();
                });

            ui.separator();

            // Scrollable text region.
            egui::ScrollArea::vertical()
                .auto_shrink([false; 2])
                .show(ui, |ui| {
                    ui.add(
                        egui::TextEdit::multiline(&mut self.detail_text)
                            .desired_width(f32::INFINITY)
                            .desired_rows(10),
                    );
                    ui.collapsing("Log", |ui| {
                        for line in &self.log_lines {
                            ui.monospace(line);
                        }
                    });
                });
        });

        // Floating "About" window, only shown when toggled.
        if self.show_about {
            egui::Window::new("About")
                .collapsible(false)
                .resizable(false)
                .default_size(Vec2::new(280.0, 120.0))
                .show(ctx, |ui| {
                    ui.label("egui demo application.");
                    ui.label("Built with eframe + egui.");
                    if ui.button("Close").clicked() {
                        self.show_about = false;
                    }
                });
        }
    }
}

fn main() -> eframe::Result<()> {
    eframe::run_native(
        "egui demo",
        eframe::NativeOptions::default(),
        Box::new(|_cc| Ok(Box::new(DemoApp::default()))),
    )
}
```

Three things to notice in this example:

- The panel insertion order (`top`, `left`, `bottom`, `Central`) is _significant_:
  each panel subtracts from the remaining region in registration order, so
  `CentralPanel` must come last to absorb leftover space.

- All interaction is observed through `Response::clicked()` immediately after the
  widget call. There is no `on_click=` callback, no event bus.

- The `Window` for "About" only exists when `self.show_about == true`. Because
  egui uses retained `Memory` keyed on `Id`, the window's position and size persist
  across show/hide cycles — re-opening the window restores it to where the user
  last dragged it.

---

## Strengths and Weaknesses

### Strengths

- **Pure Rust, end-to-end.** No FFI to C++ or platform libraries. No `unsafe` in
  user code. The font rasteriser (`epaint`), tessellator, and renderer back-ends
  are all Rust crates. Distribution is trivial — a single `cargo build` produces
  a self-contained binary, and `wasm-pack` produces a self-contained web app.

- **Web target is a first-class citizen.** The same `App::update` runs in the
  browser via WebAssembly with no platform-specific branches. This is unusual for
  GUI libraries and is the main reason for egui's adoption in browser-first tools
  (Rerun's web viewer, in-browser Rust playgrounds, etc.).

- **No callbacks, no state synchronisation.** The application owns all state, and
  the UI is a function of state. This removes the entire class of bugs where
  retained widget state diverges from application state.

- **Immediate-mode ergonomics for tools.** For developer tools, debug overlays,
  level editors, and visualisation surfaces — workloads with hundreds of small
  controls that change shape frequently — immediate-mode lets you prototype an
  entire panel in twenty lines without naming any widgets.

- **`Response` ties layout to interaction.** Because hit-testing happens at the
  same point as drawing, there is exactly one place to look for "what does this
  button do" — the line that called `ui.button(...)`.

- **Sensible defaults with deep customisation.** Style, spacing, fonts, and visual
  tokens are all configurable via `egui::Style` and `egui::Visuals`, but the
  out-of-the-box appearance is usable without any tweaking.

- **Excellent integration story.** `eframe` handles desktop + web. `bevy_egui`
  embeds it in a Bevy game. `egui-wgpu` and `egui-glow` are reusable renderer
  back-ends. The library makes no assumption about the host event loop.

### Weaknesses

- **First-frame flicker.** As discussed in [Layout Model](#layout-model), any
  container that needs to know its children's sizes in advance produces a wrong
  layout on frame 1. Mitigations exist (`request_discard`, double-pass mode), but
  they cost a redundant layout pass and complicate the mental model.

- **Re-runs the entire UI every frame.** For very large UIs (thousands of widgets),
  this is wasteful. Retained-mode toolkits skip subtrees that have not changed;
  egui does not. The library compensates by being fast (sub-millisecond UI
  evaluation for typical panels) and by sleeping when input is idle, but apps with
  pathologically large UI surfaces should partition them across panels/tabs.

- **No accessibility tree, only AccessKit hooks.** AccessKit integration exists
  and is improving, but screen-reader support is not yet on par with retained
  toolkits whose every widget naturally has an identity.

- **Custom widgets must allocate first, draw second.** The two-step pattern
  (allocate a `Rect`, then paint into it) is correct but unfamiliar; new users
  often try to paint and then ask "where did it go?".

- **One-shot rendering is conceptually opposite to reactive systems.** Developers
  coming from React, SwiftUI, or Flutter find the lack of declarative data binding
  (`@State`, `@ObservedObject`, etc.) jarring. The application _is_ the binding.

- **Floating windows are not real OS windows.** A `Window` is a movable region
  inside a single OS surface, not a separate top-level window. Multi-window apps
  are possible via `eframe`'s viewport API, but each viewport is its own egui
  context with its own memory.

- **Text shaping is approximate.** Complex scripts (Arabic, Indic, vertical CJK)
  and OpenType features (ligatures, contextual alternates) are limited. egui uses
  its own simple shaper rather than HarfBuzz.

### Lessons for `sparkles`

egui is unusual among the libraries in this catalog because it is a graphical
GUI rather than a TUI — yet it is the closest cousin to several patterns already
present in sparkles' core-cli:

- **Immediate-mode + `@nogc` is a natural fit.** Like Ratatui's draw closure (see
  [ratatui.md](../tui-libraries/ratatui.md)), egui's `update` function rebuilds
  the entire UI from current state. In D this maps cleanly onto stack-allocated
  widget structs with `@nogc` rendering paths.

- **Per-id retained memory is a real win for TUI layouts too.** A `drawTable`
  equivalent in sparkles could memo column widths from the previous frame keyed
  on a stable id, eliminating the "first frame is misaligned, then it jumps" UX.

- **`Response`-style return values pair well with UFCS chains.** A D equivalent
  would let users write `ui.button("Save").clicked` as the conditional directly,
  using the `Response` struct as an in-band signal rather than an event callback.

- **The `Layout` modifier composition is cleaner than Flexbox enums.** Splitting
  alignment / wrap / justify into orthogonal toggles produces fewer surprising
  combinations than CSS's `justify-content` × `align-items` × `flex-wrap` matrix.

---

## References

- **Project homepage:** <https://www.egui.rs> — interactive demo runs in the
  browser via WebAssembly.
- **GitHub repository:** <https://github.com/emilk/egui>
- **API documentation:** <https://docs.rs/egui/latest/egui/>
- **`eframe` crate:** <https://docs.rs/eframe/> — the official integration crate.
- **Rerun viewer:** <https://github.com/rerun-io/rerun> — the largest production
  application built on egui; a good source of advanced layout patterns.
- **`Ui` API reference:** <https://docs.rs/egui/latest/egui/struct.Ui.html>
- **`Layout` reference:** <https://docs.rs/egui/latest/egui/struct.Layout.html>
- **`Response` reference:** <https://docs.rs/egui/latest/egui/response/struct.Response.html>
- **`Grid` reference:** <https://docs.rs/egui/latest/egui/struct.Grid.html>
- **`ScrollArea` reference:** <https://docs.rs/egui/latest/egui/containers/scroll_area/struct.ScrollArea.html>
- **Related catalog entries:**
  - [Dear ImGui](dear-imgui.md) — the canonical C++ immediate-mode GUI, egui's
    closest paradigm cousin.
  - [Ratatui (TUI)](../tui-libraries/ratatui.md) — the TUI equivalent design:
    immediate-mode `draw` closure with a back-buffer diff.
  - [nottui (TUI)](../tui-libraries/nottui.md) — declarative immediate-mode TUI
    that shares egui's "function-as-UI" model.
  - [Textual (TUI)](../tui-libraries/textual.md) — a counterpoint: reactive,
    retained component tree.
