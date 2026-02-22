# Ratatui (Rust)

A Rust library for building rich terminal user interfaces using an immediate-mode rendering model with constraint-based layout and a composable widget system.

| Field          | Value                                            |
| -------------- | ------------------------------------------------ |
| Language       | Rust                                             |
| License        | MIT                                              |
| Repository     | <https://github.com/ratatui/ratatui>             |
| Documentation  | <https://ratatui.rs> / <https://docs.rs/ratatui> |
| Latest Version | ~0.30.0 (December 2025)                          |
| GitHub Stars   | ~18.3k                                           |

---

## Overview

Ratatui is the de facto standard TUI framework for Rust. It provides a toolkit for
building text-based user interfaces in the terminal, targeting dashboards, interactive CLI
tools, log viewers, file managers, and similar applications.

**What it solves.** Writing terminal UIs from scratch requires managing raw ANSI escape
sequences, screen buffering, cursor positioning, resize handling, and color support across
different terminal emulators. Ratatui provides a high-level abstraction over all of this:
a [`Buffer`][ratatui-buffer] you write widgets into, a [`Layout`][ratatui-layout] engine that subdivides screen real estate,
and a [`Terminal`][ratatui-terminal] that diffs frames and emits only the changed cells.

**Design philosophy.** Ratatui is deliberately minimal in what it _enforces_. It does not
own your main loop, does not impose a state management pattern, and does not bundle an
event system. The application is in control: you poll events, mutate your state, and call
`terminal.draw(...)` whenever you want a new frame. This makes Ratatui a _library_, not a
_framework_ -- it composes with any async runtime, event source, or architecture (Elm,
component-based, ad-hoc).

**History and lineage.** Ratatui was forked from Florian Dehau's `tui-rs` crate in 2023
after development on the original stalled. The community-driven fork has since far
surpassed the original in features, documentation, and ecosystem support. With 267+
contributors and 12,700+ dependent crates, it is the overwhelmingly dominant choice for
Rust TUI development.

---

## Architecture

### Rendering Model: Immediate-Mode with Double Buffering

Ratatui uses an **immediate-mode rendering model**. Every frame, the application rebuilds
the entire UI from scratch by calling `terminal.draw(|frame| { ... })`. There is no
retained widget tree; no persistent scene graph. The `draw` closure receives a [`Frame`][ratatui-frame],
which exposes `render_widget(widget, area)` to place widgets into a back buffer.

Under the hood, [`Terminal`][ratatui-terminal] maintains **two buffers** (current and previous). After the
draw closure returns, the terminal diffs the current buffer against the previous one and
writes only the changed cells to the backend. This gives the _programming model_ of
immediate mode (stateless re-render) with the _performance_ of differential updates.

```
 App State
    |
    v
 terminal.draw(|frame| {
    frame.render_widget(header, areas[0]);
    frame.render_widget(body,   areas[1]);
    frame.render_widget(footer, areas[2]);
 })
    |
    v
 Buffer (current frame)
    |  diff against previous frame
    v
 Backend (crossterm/termion/termwiz)
    |
    v
 Terminal emulator
```

### Application Pattern

Ratatui does not prescribe an architecture. The most common pattern is an **app-driven
loop**:

```rust
fn main() -> Result<()> {
    let mut terminal = ratatui::init();
    let mut app = App::new();

    loop {
        terminal.draw(|frame| app.render(frame))?;

        if let Event::Key(key) = crossterm::event::read()? {
            match app.handle_key(key) {
                Action::Quit => break,
                Action::Update => continue,
            }
        }
    }

    ratatui::restore();
    Ok(())
}
```

(See [`Terminal`][ratatui-terminal] and [`Frame`][ratatui-frame] documentation.)

This pattern is compatible with Elm/MVU if you choose to structure it that way (separate
`update` and `view` functions), but nothing in the library requires it.

### Data Flow

Data flows in one direction: **App state -> Widget construction -> Buffer -> Backend**.
Widgets are typically constructed inline during the draw call using references to app
state. They do not persist between frames.

---

## Terminal Backend

Ratatui abstracts the underlying terminal library through a [`Backend`][ratatui-backend] trait. The
[`Terminal<B: Backend>`][ratatui-terminal] struct wraps a backend and manages buffering, diffing, and cursor
state.

### Backend Trait

```rust
pub trait Backend {
    type Error;

    fn draw<'a, I>(&mut self, content: I) -> Result<(), Self::Error>
    where
        I: Iterator<Item = (u16, u16, &'a Cell)>;

    fn hide_cursor(&mut self) -> Result<(), Self::Error>;
    fn show_cursor(&mut self) -> Result<(), Self::Error>;
    fn get_cursor_position(&mut self) -> Result<Position, Self::Error>;
    fn set_cursor_position<P: Into<Position>>(&mut self, position: P)
        -> Result<(), Self::Error>;
    fn clear(&mut self) -> Result<(), Self::Error>;
    fn clear_region(&mut self, clear_type: ClearType) -> Result<(), Self::Error>;
    fn size(&self) -> Result<Size, Self::Error>;
    fn window_size(&mut self) -> Result<WindowSize, Self::Error>;
    fn flush(&mut self) -> Result<(), Self::Error>;
    fn scroll_region_up(&mut self, region: Rect, amount: u16)
        -> Result<(), Self::Error>;
    fn scroll_region_down(&mut self, region: Rect, amount: u16)
        -> Result<(), Self::Error>;
}
```

### Backend Implementations

| Backend            | Crate                | Platforms       | Notes                                            |
| ------------------ | -------------------- | --------------- | ------------------------------------------------ |
| `CrosstermBackend` | `ratatui-crossterm`  | Windows + POSIX | Most popular. True color, mouse, Kitty keyboard. |
| `TermionBackend`   | `ratatui-termion`    | POSIX only      | Lightweight, Unix-focused.                       |
| `TermwizBackend`   | `ratatui-termwiz`    | Cross-platform  | From the wezterm project.                        |
| `TestBackend`      | `ratatui` (built-in) | All             | In-memory backend for testing.                   |

### Capabilities

- **True color:** Supported via `Color::Rgb(r, g, b)` on all backends (terminal-dependent).
- **Mouse support:** Available through crossterm and termion event systems.
- **Unicode / grapheme handling:** The `Buffer` and `Span` types are grapheme-aware;
  `width()` returns Unicode display width, `styled_graphemes()` iterates grapheme clusters.
- **Kitty keyboard protocol:** Supported through crossterm's `PushKeyboardEnhancementFlags`.
  Enables disambiguation of key press/release/repeat events and modifier combinations that
  traditional terminals cannot distinguish.

### Terminal Struct

The `Terminal<B: Backend>` struct is the main entry point:

```rust
impl<B: Backend> Terminal<B> {
    fn new(backend: B) -> Result<Self>;
    fn with_options(backend: B, options: TerminalOptions) -> Result<Self>;

    fn draw<F>(&mut self, f: F) -> Result<CompletedFrame>
    where
        F: FnOnce(&mut Frame);

    fn backend(&self) -> &B;
    fn backend_mut(&mut self) -> &mut B;

    fn hide_cursor(&mut self) -> Result<()>;
    fn show_cursor(&mut self) -> Result<()>;
    fn clear(&mut self) -> Result<()>;
    fn flush(&mut self) -> Result<()>;

    // Insert content above an inline viewport
    fn insert_before<F>(&mut self, height: u16, f: F) -> Result<()>;
}
```

The `TerminalOptions` struct allows selecting a **viewport mode**: `Fullscreen` (default),
`Inline(height)` for embedding a UI within scrollback, or `Fixed(rect)` for a specific
region.

---

## Layout System

Ratatui's layout engine subdivides rectangular areas using a **constraint solver** (the
`kasuari` crate, a Rust port of the Cassowary algorithm). Constraints are resolved in
priority order to produce a set of non-overlapping [`Rect`][ratatui-rect] values.

### Constraint Variants

```rust
pub enum Constraint {
    /// Allocate exactly `n` cells.
    Length(u16),
    /// Allocate a percentage of available space.
    Percentage(u16),
    /// Allocate space as a ratio (numerator / denominator).
    Ratio(u32, u32),
    /// Allocate at least `n` cells.
    Min(u16),
    /// Allocate at most `n` cells.
    Max(u16),
    /// Fill remaining space proportionally (weight-based).
    Fill(u16),
}
```

Constraints are resolved in this priority order: **Min > Max > Length > Percentage > Ratio > Fill**. `Fill` distributes any leftover space after all other constraints are satisfied, proportional to the fill weight.

### Layout API

```rust
let layout = Layout::default()
    .direction(Direction::Vertical)
    .constraints([
        Constraint::Length(3),
        Constraint::Fill(1),
        Constraint::Length(1),
    ])
    .split(area);
```

The `areas::<N>()` method provides a compile-time checked alternative that returns a
fixed-size array:

```rust
let [header, body, footer] = Layout::vertical([
    Constraint::Length(3),
    Constraint::Fill(1),
    Constraint::Length(1),
]).areas(area);
```

Layout results are cached in a **thread-local LRU cache** keyed on the layout
configuration and input area, so repeated calls with the same parameters are essentially
free.

### Multi-Panel Layout Example

A dashboard with a header, two side-by-side columns, and a footer:

```rust
use ratatui::layout::{Constraint, Direction, Layout, Rect};
use ratatui::widgets::{Block, Borders, Paragraph};
use ratatui::Frame;

fn render_dashboard(frame: &mut Frame, app: &App) {
    let area = frame.area();

    // Outer vertical split: header (3 rows) | body (fill) | footer (1 row)
    let [header_area, body_area, footer_area] = Layout::vertical([
        Constraint::Length(3),
        Constraint::Fill(1),
        Constraint::Length(1),
    ]).areas(area);

    // Body: two columns, left is 40%, right fills the rest
    let [left_col, right_col] = Layout::horizontal([
        Constraint::Percentage(40),
        Constraint::Fill(1),
    ]).areas(body_area);

    // Right column: split vertically into two panels
    let [top_right, bottom_right] = Layout::vertical([
        Constraint::Ratio(1, 2),
        Constraint::Ratio(1, 2),
    ]).areas(right_col);

    // Render widgets into each area
    frame.render_widget(
        Paragraph::new(app.title.as_str())
            .block(Block::bordered().title("Header")),
        header_area,
    );
    frame.render_widget(
        List::new(app.items.iter().map(|i| i.as_str()))
            .block(Block::bordered().title("Sidebar")),
        left_col,
    );
    frame.render_widget(
        Paragraph::new(app.detail.as_str())
            .block(Block::bordered().title("Detail")),
        top_right,
    );
    frame.render_widget(
        Paragraph::new(app.logs.as_str())
            .block(Block::bordered().title("Logs"))
            .wrap(Wrap { trim: true }),
        bottom_right,
    );
    frame.render_widget(
        Paragraph::new(app.status_line.as_str()),
        footer_area,
    );
}
```

This produces a layout like:

```
+---------------------------------------------+
|                  Header                      |
+------------------+--------------------------+
|                  |         Detail            |
|    Sidebar       +--------------------------+
|                  |          Logs             |
+------------------+--------------------------+
| status line                                  |
+---------------------------------------------+
```

---

## Widget / Component System

### The Widget Trait

The core abstraction is the `Widget` trait:

```rust
pub trait Widget {
    fn render(self, area: Rect, buf: &mut Buffer)
    where
        Self: Sized;
}
```

Key design decisions:

- **`self` by value:** Widgets are consumed on render. They are lightweight, typically
  holding references to app data, and are constructed inline during the draw call.
- **`Rect` + `Buffer`:** The widget is told _where_ to draw (`area`) and _what_ to draw
  into (`buf`). It has no knowledge of the terminal, other widgets, or global state.
- **Reference implementations:** Since v0.26.0, built-in widgets implement `Widget` for
  `&W` as well, allowing a widget to be stored and rendered multiple times.

### Built-in Widgets

| Widget      | Description                                                      |
| ----------- | ---------------------------------------------------------------- |
| `Block`     | Container with borders, title, padding. Wraps other widgets.     |
| `Paragraph` | Multi-line styled text with wrapping and scrolling.              |
| `List`      | Scrollable list of items with selection support.                 |
| `Table`     | Multi-column table with headers, row selection, column widths.   |
| `Tabs`      | Horizontal tab bar with active tab indicator.                    |
| `Gauge`     | Progress bar (percentage-based).                                 |
| `LineGauge` | Thin-line progress indicator.                                    |
| `Chart`     | Line/scatter chart with axes, labels, and multiple datasets.     |
| `Canvas`    | Free-form drawing surface with shapes (line, rectangle, circle). |
| `Sparkline` | Inline bar chart for time-series data.                           |
| `BarChart`  | Vertical or horizontal bar chart with labels and values.         |
| `Calendar`  | Monthly calendar view.                                           |
| `Scrollbar` | Scrollbar indicator (vertical or horizontal).                    |
| `Clear`     | Clears an area (useful for overlays).                            |

Additionally, `Span`, `Line`, and `Text` implement `Widget`, so styled text can be
rendered directly without wrapping it in a `Paragraph`.

### StatefulWidget Trait

For widgets that need to remember state between renders (e.g., scroll position, selected
item):

```rust
pub trait StatefulWidget {
    type State;

    fn render(self, area: Rect, buf: &mut Buffer, state: &mut Self::State);
}
```

Usage:

```rust
// In App struct:
struct App {
    items: Vec<String>,
    list_state: ListState,  // tracks selected index and scroll offset
}

// In render:
frame.render_stateful_widget(
    List::new(app.items.iter().map(|i| i.as_str()))
        .highlight_style(Style::new().bold().yellow()),
    area,
    &mut app.list_state,
);
```

Built-in stateful widgets: `List`/`ListState`, `Table`/`TableState`,
`Scrollbar`/`ScrollbarState`.

### Custom Widget Example

Implementing a simple horizontal separator widget:

```rust
use ratatui::buffer::Buffer;
use ratatui::layout::Rect;
use ratatui::style::Style;
use ratatui::widgets::Widget;

/// A horizontal line separator that fills its area with a repeated character.
pub struct Separator {
    ch: char,
    style: Style,
}

impl Separator {
    pub fn new() -> Self {
        Self {
            ch: '─',
            style: Style::default(),
        }
    }

    pub fn char(mut self, ch: char) -> Self {
        self.ch = ch;
        self
    }

    pub fn style(mut self, style: Style) -> Self {
        self.style = style;
        self
    }
}

impl Widget for Separator {
    fn render(self, area: Rect, buf: &mut Buffer) {
        if area.height == 0 || area.width == 0 {
            return;
        }
        let line: String = std::iter::repeat(self.ch)
            .take(area.width as usize)
            .collect();
        buf.set_string(area.x, area.y, &line, self.style);
    }
}

// Usage:
frame.render_widget(
    Separator::new().char('=').style(Style::new().dark_gray()),
    separator_area,
);
```

---

## Styling

### Style Struct

```rust
pub struct Style {
    pub fg: Option<Color>,
    pub bg: Option<Color>,
    pub underline_color: Option<Color>,
    pub add_modifier: Modifier,
    pub sub_modifier: Modifier,
}
```

[`Style`][ratatui-style] is **incremental** -- applying a style patches only the fields it sets, leaving
others untouched. This enables layered styling (e.g., a `Block` style sets the background,
then a `Span` style sets the foreground).

### Color Enum

```rust
pub enum Color {
    Reset,
    Black, Red, Green, Yellow, Blue, Magenta, Cyan, Gray,
    DarkGray, LightRed, LightGreen, LightYellow,
    LightBlue, LightMagenta, LightCyan, White,
    Rgb(u8, u8, u8),     // 24-bit true color
    Indexed(u8),          // 256-color palette
}
```

(See [`Color`][ratatui-color] documentation.)

### Modifier Flags

[`Modifier`][ratatui-modifier] is a bitflag set: `BOLD`, `DIM`, `ITALIC`, `UNDERLINED`, `SLOW_BLINK`,
`RAPID_BLINK`, `REVERSED`, `HIDDEN`, `CROSSED_OUT`.

### Stylize Trait (Builder Pattern)

The `Stylize` trait provides a fluent builder that is implemented for `Style`, `Span`,
`Line`, `Text`, and string types:

```rust
use ratatui::style::Stylize;

// Style a string directly into a Span:
let greeting = "Hello, world!".green().bold().on_black();

// Build a Style object:
let style = Style::new().fg(Color::Rgb(255, 165, 0)).italic();

// Compose styled text:
let line = Line::from(vec![
    "Error: ".red().bold(),
    "file not found".white(),
]);
```

### Text Hierarchy

Styled text is built from three composable types:

```
Text (multiple lines)
  └── Line (single line, optional alignment)
        └── Span (contiguous text with one Style)
```

```rust
let text = Text::from(vec![
    Line::from(vec![
        Span::styled("Name: ", Style::new().bold()),
        Span::raw("Ratatui"),
    ]),
    Line::from("A terminal UI library".dim().italic()),
]);
```

Each level can have its own style. A `Line`'s style is applied first, then each `Span`'s
style patches over it. A `Text`'s style is applied before all contained lines.

---

## Event Handling

**Ratatui does not handle events.** This is a deliberate design decision -- it keeps the
library focused on rendering and avoids coupling to a specific event source or async
runtime.

Event handling is the application's responsibility. The typical approach is to use the same
backend library (usually crossterm) for both rendering and input.

### Typical Event Loop Pattern

```rust
use std::time::Duration;
use crossterm::event::{self, Event, KeyCode, KeyEvent, KeyModifiers};

struct App {
    running: bool,
    counter: i64,
}

impl App {
    fn handle_event(&mut self, event: Event) {
        match event {
            Event::Key(KeyEvent { code, modifiers, .. }) => {
                match (code, modifiers) {
                    (KeyCode::Char('q'), _) |
                    (KeyCode::Char('c'), KeyModifiers::CONTROL) => {
                        self.running = false;
                    }
                    (KeyCode::Up, _) => self.counter += 1,
                    (KeyCode::Down, _) => self.counter -= 1,
                    _ => {}
                }
            }
            Event::Resize(_, _) => {
                // Terminal will auto-resize buffers on next draw
            }
            _ => {}
        }
    }
}

fn main() -> Result<()> {
    let mut terminal = ratatui::init();
    let mut app = App { running: true, counter: 0 };

    while app.running {
        terminal.draw(|frame| {
            // ... render using app state ...
        })?;

        // Block for up to 250ms waiting for an event
        if event::poll(Duration::from_millis(250))? {
            app.handle_event(event::read()?);
        }
    }

    ratatui::restore();
    Ok(())
}
```

### Async Event Handling

For async applications, crossterm provides `EventStream` (a tokio `Stream`):

```rust
use crossterm::event::EventStream;
use futures::StreamExt;

let mut events = EventStream::new();
loop {
    tokio::select! {
        Some(Ok(event)) = events.next() => app.handle_event(event),
        _ = tick_interval.tick() => { /* periodic update */ }
    }
    terminal.draw(|frame| app.render(frame))?;
}
```

---

## State Management

Ratatui imposes no state management pattern. The conventional approach is an **App struct**
that holds all application state:

```rust
struct App {
    // Application data
    items: Vec<Item>,
    input_buffer: String,
    mode: AppMode,

    // Widget state (for stateful widgets)
    list_state: ListState,
    table_state: TableState,
    scroll_state: ScrollbarState,
}

enum AppMode {
    Normal,
    Editing,
    Help,
}
```

### Stateful Widget State

Some widgets need to track state across frames (e.g., which item is selected, scroll
offset). Ratatui provides companion `*State` structs:

- **`ListState`** -- selected index, scroll offset
- **`TableState`** -- selected row, scroll offset
- **`ScrollbarState`** -- position, content length, viewport length

These are stored in the application's `App` struct and passed mutably during rendering:

```rust
// Selecting an item
app.list_state.select(Some(3));

// Rendering with state
frame.render_stateful_widget(list_widget, area, &mut app.list_state);
```

The state structs are intentionally simple data holders. The application is responsible for
updating them (e.g., moving selection on key press).

### Patterns in Practice

Applications commonly evolve toward one of:

1. **Flat App struct** -- all state in one struct, simple applications.
2. **Component pattern** -- sub-structs with their own render/handle methods, composed in
   a parent App.
3. **Elm / MVU** -- separate `Model`, `update(msg)`, and `view(model)` functions. Ratatui
   is fully compatible with this but does not provide the scaffolding.

---

## Extensibility and Ecosystem

Ratatui has a thriving ecosystem of companion crates:

### Official / Semi-Official

| Crate            | Purpose                                                 |
| ---------------- | ------------------------------------------------------- |
| `ratatui-macros` | Declarative macros for layout, spans, and lines.        |
| `ratatui-core`   | Core traits extracted for third-party widget libraries. |

### Community Widgets

| Crate             | Purpose                                               |
| ----------------- | ----------------------------------------------------- |
| `tui-textarea`    | Multi-line text editor widget with cursor, selection. |
| `tui-input`       | Single-line text input widget.                        |
| `tui-logger`      | Log viewer widget integrated with the `log` crate.    |
| `tui-big-text`    | Large ASCII-art text rendering (figlet-style).        |
| `tui-scrollview`  | Scrollable container widget.                          |
| `tui-tree-widget` | Tree view with expand/collapse.                       |
| `tui-popup`       | Modal popup overlay.                                  |

### Tooling

- **`cargo-generate` templates** -- `cargo generate ratatui/templates` scaffolds a new
  project with best-practice structure (async, component-based, etc.).
- **`ratatui-book`** -- The official documentation site at ratatui.rs with tutorials,
  concepts, and API guides.

### Community

- Active **Discord server** with dedicated help channels.
- **Matrix bridge** for open-protocol access.
- **Forum** at forum.ratatui.rs for long-form discussion.
- **Open Collective** sponsorship for sustainable development.
- 12,700+ dependent crates on crates.io.

---

## Strengths

- **Zero-cost abstractions.** Widgets are consumed by value; the immediate-mode model means
  no persistent allocations for a widget tree. The double-buffer diff minimizes terminal I/O.
- **Excellent documentation.** The ratatui.rs website provides concept guides, tutorials,
  FAQ, and a showcase. The API docs on docs.rs are thorough with examples.
- **Very active community.** 267+ contributors, rapid release cadence, responsive Discord.
  Issues and PRs are addressed quickly.
- **Flexible architecture.** No forced event system, async runtime, or state pattern. Works
  with tokio, async-std, synchronous polling, or anything else.
- **Comprehensive built-in widget set.** Covers the vast majority of dashboard and
  interactive-app needs out of the box.
- **Strong type system prevents misuse.** `Rect` ensures bounds are respected, `Constraint`
  prevents invalid layout specs, and the borrow checker enforces buffer access safety.
- **Layout caching.** Constraint solving results are LRU-cached per thread, avoiding
  redundant computation on unchanged layouts.
- **Backend-agnostic.** Swapping terminal backends requires changing one type parameter.
  The `TestBackend` enables fully deterministic UI testing without a terminal.
- **Modular crate architecture.** `ratatui-core` allows third-party widget crates to depend
  on just the trait definitions without pulling in the entire widget library.

---

## Weaknesses and Limitations

- **Immediate-mode requires manual optimization for complex UIs.** Every frame rebuilds all
  widgets. For very large or deeply nested interfaces, this can become expensive. There is
  no built-in mechanism to skip unchanged subtrees.
- **No built-in event handling.** The application must manage its own event loop, polling,
  debouncing, and dispatch. This is flexible but means more boilerplate for every project.
- **No built-in async support.** Ratatui's `draw` is synchronous. Integrating with async
  runtimes requires manual coordination (e.g., `tokio::select!` in the event loop).
- **Steep learning curve for custom widgets.** Writing to a raw `Buffer` requires manual
  coordinate arithmetic. There is no relative positioning or automatic clipping within a
  widget's render method.
- **No built-in layout caching invalidation.** The LRU cache is per-thread and fixed-size;
  it does not have a mechanism for the application to signal that a layout has changed.
- **No built-in component lifecycle.** Unlike retained-mode frameworks, there is no
  mount/unmount, focus management, or event bubbling built in. Applications must implement
  these patterns themselves.
- **Limited text shaping.** Grapheme width calculation is approximate and does not account
  for all edge cases in complex scripts or emoji sequences with variation selectors.
- **`u16` coordinate space.** Terminal dimensions and positions use `u16`, which is
  sufficient for real terminals but can be surprising when computing layouts
  programmatically.

---

## Lessons for D / Sparkles

This section maps Ratatui's patterns to D idioms, identifying what would translate
naturally and where D's unique capabilities could improve upon the design.

### Widget Trait -> D Template Interfaces or Design by Introspection

Ratatui's `Widget` trait:

```rust
pub trait Widget {
    fn render(self, area: Rect, buf: &mut Buffer);
}
```

In D, this maps to either a **template interface** (duck-typed) or **DbI** (Design by
Introspection, checking for capabilities at compile time):

```d
/// Duck-typed widget concept -- no interface required.
enum isWidget(T) = is(typeof((T w, Rect area, ref Buffer buf) {
    w.render(area, buf);
}));

/// Render any widget via template constraint.
void renderWidget(W)(W widget, Rect area, ref Buffer buf)
if (isWidget!W)
{
    widget.render(area, buf);
}
```

For optional capabilities (like `StatefulWidget`), DbI shines:

```d
enum isStatefulWidget(T) = isWidget!T && is(typeof(T.init.State));

void renderWidget(W)(W widget, Rect area, ref Buffer buf, ref W.State state)
if (isStatefulWidget!W)
{
    widget.render(area, buf, state);
}
```

This avoids virtual dispatch entirely -- all widget calls are monomorphized at compile
time, matching Rust's approach but with D's introspection ergonomics.

### Constraint-Based Layout -> CTFE for Compile-Time Validation

Ratatui's `areas::<N>()` method catches array-length mismatches at compile time. D can go
further with CTFE:

```d
/// Validate constraints at compile time.
auto layout(size_t N)(Constraint[N] constraints, Direction dir = Direction.vertical)
{
    // Could validate that percentages sum to <= 100,
    // that there is at most one Fill, etc.
    static assert(
        constraints.percentageSum <= 100,
        "Constraint percentages exceed 100%"
    );
    return LayoutSpec!N(constraints, dir);
}

// Usage:
enum myLayout = layout([
    Constraint.length(3),
    Constraint.fill(1),
    Constraint.length(1),
]);
```

CTFE could also pre-compute fixed layouts for known terminal sizes, useful for
size-constrained embedded terminals.

### Buffer Abstraction -> D Output Ranges and @nogc SmallBuffer

Ratatui's `Buffer` is a flat `Vec<Cell>` indexed by `(x, y)`. In D, this maps naturally to
a `@nogc`-compatible buffer:

```d
@safe pure nothrow @nogc:

struct Cell {
    dchar grapheme;  // or SmallBuffer!(char, 8) for multi-codepoint graphemes
    Style style;
}

struct Buffer {
    Rect area;
    SmallBuffer!(Cell, 4096) content;  // stack-allocated for typical terminal sizes

    ref Cell opIndex(ushort x, ushort y) return {
        return content[(y - area.y) * area.width + (x - area.x)];
    }

    /// Diff against previous frame, output only changed cells.
    void diff(ref const Buffer prev, ref OutputRange sink) { ... }
}
```

The `SmallBuffer` from sparkles/core-cli avoids GC allocation for buffers that fit in the
inline capacity, falling back to `pureMalloc` for larger terminals.

### Style Builder -> UFCS Chains in D

Ratatui's `Stylize` trait:

```rust
"hello".green().bold().on_black()
```

This translates directly to D's UFCS:

```d
auto styled = "hello".fg(Color.green).bold.bg(Color.black);
```

Or with compile-time `stylizedTextBuilder` from the existing sparkles codebase:

```d
enum greeting = "hello"
    .stylizedTextBuilder(true)
    .green
    .bold
    .onBlack;
```

### Immediate-Mode Rendering -> Natural Fit for D

D's lack of a GC-dependent retained widget tree makes immediate-mode rendering a natural
choice. Widgets can be `struct` values on the stack, constructed and consumed within a
single `draw` call, with zero GC pressure:

```d
terminal.draw((ref Frame frame) @nogc {
    auto areas = layout.split(frame.area);
    frame.renderWidget(Paragraph("Hello"), areas[0]);
    frame.renderWidget(myList, areas[1]);
});
```

The `@nogc` attribute can be enforced on the entire render path, guaranteeing no hidden
allocations during frame rendering.

### Backend Abstraction -> D Interface or Template Parameter

Two viable approaches:

1. **Runtime polymorphism** via D `interface` (for dynamic backend switching):

```d
interface Backend {
    void draw(scope CellIterator content);
    void flush();
    void clear();
    TermSize size();
    // ...
}
```

2. **Compile-time polymorphism** via template parameter (zero-overhead, Ratatui's approach):

```d
struct Terminal(B) if (isBackend!B) {
    B backend;
    Buffer current;
    Buffer previous;

    void draw(scope void delegate(ref Frame) @nogc renderFn) { ... }
}
```

The template approach is more idiomatic for D and mirrors Ratatui's `Terminal<B>`. A
`TestBackend` can be used for deterministic testing without a real terminal.

---

## References

- **Ratatui Documentation Site:** <https://ratatui.rs>
  - Concepts: <https://ratatui.rs/concepts/>
  - Widgets: <https://ratatui.rs/concepts/widgets/>
  - Layout: <https://ratatui.rs/concepts/layout/>
- **API Reference (docs.rs):** <https://docs.rs/ratatui/latest/ratatui/>
  - Widget trait: <https://docs.rs/ratatui/latest/ratatui/widgets/trait.Widget.html>
  - StatefulWidget trait: <https://docs.rs/ratatui/latest/ratatui/widgets/trait.StatefulWidget.html>
  - Layout: <https://docs.rs/ratatui/latest/ratatui/layout/struct.Layout.html>
  - Constraint: <https://docs.rs/ratatui/latest/ratatui/layout/enum.Constraint.html>
  - Style: <https://docs.rs/ratatui/latest/ratatui/style/struct.Style.html>
  - Color: <https://docs.rs/ratatui/latest/ratatui/style/enum.Color.html>
  - Backend trait: <https://docs.rs/ratatui/latest/ratatui/backend/trait.Backend.html>
  - Terminal: <https://docs.rs/ratatui/latest/ratatui/struct.Terminal.html>
  - Buffer: <https://docs.rs/ratatui/latest/ratatui/buffer/struct.Buffer.html>
- **GitHub Repository:** <https://github.com/ratatui/ratatui>
- **Community:**
  - Discord: <https://discord.gg/pMCEU9hNEj>
  - Forum: <https://forum.ratatui.rs>
- **History:**
  - Original tui-rs by Florian Dehau: <https://github.com/fdehau/tui-rs>
  - Fork announcement and rationale: <https://github.com/ratatui/ratatui/discussions/167>
- **Ecosystem:**
  - tui-textarea: <https://github.com/rhysd/tui-textarea>
  - tui-input: <https://github.com/sayanarijit/tui-input>
  - tui-logger: <https://github.com/gin66/tui-logger>
  - ratatui-macros: <https://github.com/ratatui/ratatui-macros>
  - Project templates: <https://github.com/ratatui/templates>

---

## Markdown References

[ratatui-buffer]: https://docs.rs/ratatui/latest/ratatui/buffer/struct.Buffer.html
[ratatui-terminal]: https://docs.rs/ratatui/latest/ratatui/struct.Terminal.html
[ratatui-frame]: https://docs.rs/ratatui/latest/ratatui/frame/struct.Frame.html
[ratatui-layout]: https://docs.rs/ratatui/latest/ratatui/layout/struct.Layout.html
[ratatui-constraint]: https://docs.rs/ratatui/latest/ratatui/layout/enum.Constraint.html
[ratatui-rect]: https://docs.rs/ratatui/latest/ratatui/layout/struct.Rect.html
[ratatui-widget]: https://docs.rs/ratatui/latest/ratatui/widgets/trait.Widget.html
[ratatui-stateful-widget]: https://docs.rs/ratatui/latest/ratatui/widgets/trait.StatefulWidget.html
[ratatui-style]: https://docs.rs/ratatui/latest/ratatui/style/struct.Style.html
[ratatui-color]: https://docs.rs/ratatui/latest/ratatui/style/enum.Color.html
[ratatui-modifier]: https://docs.rs/ratatui/latest/ratatui/style/struct.Modifier.html
[ratatui-backend]: https://docs.rs/ratatui/latest/ratatui/backend/trait.Backend.html
[ratatui-cell]: https://docs.rs/ratatui/latest/ratatui/buffer/struct.Cell.html
