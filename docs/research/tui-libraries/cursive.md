# Cursive (Rust)

A Rust library for building terminal user interfaces using a retained-mode view tree with callback-driven event handling, inspired by traditional GUI toolkits like GTK and Qt.

| Field          | Value                                     |
| -------------- | ----------------------------------------- |
| Language       | Rust                                      |
| License        | MIT                                       |
| Repository     | <https://github.com/gyscos/cursive>       |
| Documentation  | <https://docs.rs/cursive/latest/cursive/> |
| Latest Version | 0.21.1 (2024)                             |
| GitHub Stars   | ~4.7k                                     |

---

## Overview

Cursive is a retained-mode TUI framework for Rust that manages an in-memory view tree,
owns the event loop, and handles layout and rendering on behalf of the application. The
developer describes views (widgets), wires up callbacks, and calls `siv.run()` -- the
framework takes care of the rest.

**What it solves.** Building terminal interfaces typically requires managing escape
sequences, raw input handling, screen buffering, layout computation, and focus traversal.
Cursive provides all of this as a coherent framework: a view tree that the library lays
out, draws, and dispatches events through. The application author works at the level of
"add a dialog with two buttons" rather than "write cells into a buffer at coordinates."

**Design philosophy.** Cursive is modeled after traditional desktop GUI toolkits. Views
form a tree. Each view knows how to draw itself, report its size requirements, and handle
events. The framework owns the event loop, calls `layout` on the tree, draws it to the
backend, and routes input events through the focused path. Callbacks attached to views
mutate the application by receiving `&mut Cursive` -- a mutable reference to the root
application struct. This is fundamentally different from Ratatui, which gives you a buffer
and says "draw." Cursive gives you a tree and says "describe."

The three stated design goals are:

1. **Ease of use.** Simple apps should be simple. Complex apps should be manageable.
2. **Linux TTY compatibility.** Broad accessibility across terminal environments.
3. **Flexibility.** Support simple UI scripts, complex real-time applications, and games.

**Contrast with Ratatui.** Ratatui is a rendering _library_ with an immediate-mode model:
the application owns the main loop, reconstructs all widgets every frame, and pushes them
into a buffer. There is no retained state, no event routing, no layout negotiation. Cursive
is a _framework_ with a retained-mode model: it owns the event loop, maintains a persistent
view tree, negotiates layout via `required_size` / `layout` callbacks, and routes events
through the tree. The tradeoff is that Ratatui offers maximum control and minimal overhead
(ideal for dashboards and custom UIs), while Cursive offers higher-level abstractions and
less boilerplate (ideal for dialog-heavy apps, form-driven tools, and menu systems).

**History.** Cursive was created by Alexandre Bury (gyscos) and has been actively
maintained since its inception. It predates Ratatui (and its predecessor `tui-rs`),
establishing itself as the "other" major Rust TUI library. With 4,700+ stars, 259 forks,
110+ contributors, and 1,779 commits, it has a stable and active community. The library
is split into `cursive-core` (the framework logic, backend-agnostic) and `cursive` (the
main crate that bundles backend support).

---

## Architecture

### Retained-Mode View Tree

Cursive maintains a **persistent tree of views** in memory. Views are trait objects
(`Box<dyn View>`) arranged hierarchically. Container views (like `LinearLayout`, `Dialog`,
`StackView`) hold child views. The framework walks this tree to compute layout, render
frames, and dispatch events.

This is the key architectural distinction from immediate-mode frameworks. The view tree
_persists_ between frames. When the user presses a key, the framework routes the event
through the existing tree -- it does not rebuild anything. Views maintain their own state
(scroll position, text content, selection index) internally.

```
Cursive (root application)
  |
  +-- StackView (layer stack / screen)
        |
        +-- Layer 0: LinearLayout
        |     +-- TextView
        |     +-- EditView (named: "input")
        |
        +-- Layer 1: Dialog (modal popup)
              +-- TextView
              +-- [Ok] button
              +-- [Cancel] button
```

### The `Cursive` Struct

The `Cursive` struct is the root of the application. It holds:

- The **screen stack** (a `StackView` of layers per screen, plus multiple screens)
- **Global callbacks** (keyed on events)
- **User data** (arbitrary application state, `Box<dyn Any>`)
- A reference to the **callback sink** (for async event injection)
- **Theme** configuration

Key methods:

```rust
// Initialization
let mut siv = cursive::default();         // Uses default backend (crossterm)
let mut siv = cursive::crossterm();       // Explicit backend
let mut siv = cursive::pancurses();       // Alternative backend

// View management
siv.add_layer(view);                      // Push a view onto the layer stack
siv.add_fullscreen_layer(view);           // Push a fullscreen layer
siv.pop_layer();                          // Remove the top layer

// Named view access
siv.call_on_name("input", |v: &mut EditView| {
    v.set_content("hello");
});

// Global callbacks
siv.add_global_callback('q', |s| s.quit());

// User data
siv.set_user_data(MyAppState::new());
siv.with_user_data(|state: &mut MyAppState| {
    state.counter += 1;
});

// Execution
siv.run();                                // Start the event loop
siv.quit();                               // Stop the event loop
```

### The `View` Trait

The `View` trait is the core abstraction. Every UI element implements it:

```rust
pub trait View {
    // Required: render the view using the provided Printer
    fn draw(&self, printer: &Printer<'_, '_>);

    // Provided: report minimum required size given a constraint
    fn required_size(&mut self, constraint: XY<usize>) -> XY<usize> {
        XY::new(1, 1)
    }

    // Provided: called after size is finalized, propagate to children
    fn layout(&mut self, size: XY<usize>) { }

    // Provided: handle an input event
    fn on_event(&mut self, event: Event) -> EventResult {
        EventResult::Ignored
    }

    // Provided: attempt to take focus from a direction
    fn take_focus(&mut self, source: Direction) -> Result<EventResult, CannotFocus> {
        Err(CannotFocus)
    }

    // Provided: does layout need recomputation?
    fn needs_relayout(&self) -> bool { true }

    // Provided: which sub-area should be visible when scrolled?
    fn important_area(&self, view_size: XY<usize>) -> Rect {
        Rect::from_size(XY::zero(), view_size)
    }

    // Provided: run a closure on a child matching a selector
    fn call_on_any(&mut self, sel: &Selector<'_>, cb: &mut dyn FnMut(&mut dyn View)) { }

    // Provided: move focus to a child matching a selector
    fn focus_view(&mut self, sel: &Selector<'_>) -> Result<EventResult, ViewNotFound> {
        Err(ViewNotFound)
    }

    // Provided: return the type name for debugging
    fn type_name(&self) -> &'static str { ... }
}
```

The protocol is:

1. **Size negotiation:** The framework calls `required_size(constraint)` top-down. Each
   view reports how much space it ideally needs.
2. **Layout finalization:** The framework calls `layout(final_size)` top-down with the
   allocated dimensions. Container views distribute space to children.
3. **Drawing:** The framework calls `draw(&Printer)` on each view. The `Printer` handles
   coordinate translation and clipping.
4. **Event dispatch:** Input events are routed through `on_event`. Events bubble up if
   a child returns `EventResult::Ignored`.

### Layers and Screens

Cursive uses a **layer stack** for modal overlays. Each `add_layer` call pushes a new view
on top. Only the topmost layer receives input by default. This makes dialogs and popups
trivial:

```rust
siv.add_layer(
    Dialog::text("Are you sure?")
        .button("Yes", |s| { /* ... */ s.pop_layer(); })
        .button("No", |s| { s.pop_layer(); })
);
```

The framework also supports **multiple screens** (entirely separate view stacks) via
`add_screen()` and `set_screen(id)`. This is useful for multi-page wizards or mode
switching.

### Named Views

Any view can be wrapped in a `NamedView` to make it addressable by string:

```rust
// Wrapping with a name (using the Nameable trait)
let edit = EditView::new().with_name("username");

// Accessing by name from a callback
siv.call_on_name("username", |view: &mut EditView| {
    let content = view.get_content();
    // ...
});
```

This is the primary mechanism for cross-view communication. Since callbacks only receive
`&mut Cursive`, named views allow reaching into the tree to read or mutate specific views
without traversing it manually.

---

## Terminal Backend

Cursive abstracts the terminal through a backend trait. The backend handles raw terminal
I/O: entering/exiting raw mode, writing cells, reading input events, and querying terminal
size. The application selects a backend at compile time via Cargo features or at runtime
via constructor functions.

### Supported Backends

| Backend         | Cargo Feature       | Platforms             | Notes                                          |
| --------------- | ------------------- | --------------------- | ---------------------------------------------- |
| Crossterm       | `crossterm-backend` | Windows, Linux, macOS | Default since v0.21. Pure Rust, no C deps.     |
| Ncurses         | `ncurses-backend`   | Linux, macOS          | Was default before v0.21. Requires libncurses. |
| Pancurses       | `pancurses-backend` | Linux, macOS, Windows | Wraps ncurses-rs/pdcurses-sys. Needs C libs.   |
| Termion         | `termion-backend`   | Linux, macOS, Redox   | Pure Rust. Lightweight, Unix-focused.          |
| BearLibTerminal | `blt-backend`       | Linux, Windows        | Graphical terminal emulator. For games.        |

Backend selection in `Cargo.toml`:

```toml
[dependencies.cursive]
version = "0.21"
default-features = false
features = ["termion-backend"]
```

### Backend-Specific Initialization

```rust
// Default backend (crossterm)
let mut siv = cursive::default();

// Explicit backends
let mut siv = cursive::crossterm();
let mut siv = cursive::pancurses();
let mut siv = cursive::termion();

// Runtime backend selection
siv.run_with(|| {
    cursive::backends::crossterm::Backend::init().unwrap()
});
```

### Capabilities

- **8-color palette:** Universally supported, including Linux TTY.
- **Extended colors (256 / true color):** Supported on most terminal emulators. Cursive
  auto-downgrades true color to the nearest available if the terminal cannot display it.
- **Mouse support:** Available through crossterm, termion, and ncurses backends.
- **UTF-8:** Required locale. Wide character support is present but described as "initial."
- **Dummy backend:** A `DummyBackend` exists for testing without a real terminal.

---

## Layout System

Cursive uses a **constraint-based layout protocol** modeled on the classic
`required_size` / `layout` two-pass pattern from desktop GUI toolkits.

### The Two-Pass Protocol

1. **Measurement pass:** The framework asks each view "how much space do you need?" by
   calling `required_size(constraint)`. The `constraint` parameter is the maximum available
   space. Views return their ideal size. Container views query children, sum/max their
   sizes, and report upward.

2. **Layout pass:** The framework tells each view "here is your actual size" by calling
   `layout(final_size)`. Container views distribute this space to children according to
   their layout strategy (linear division, fixed sizes, weights).

### Container Views

**`LinearLayout`** -- Arranges children linearly (horizontal or vertical):

```rust
let layout = LinearLayout::vertical()
    .child(TextView::new("Name:"))
    .child(EditView::new().with_name("name"))
    .child(TextView::new("Email:"))
    .child(EditView::new().with_name("email"))
    .child(DummyView)
    .child(
        LinearLayout::horizontal()
            .child(Button::new("Ok", |s| s.quit()))
            .child(DummyView)
            .child(Button::new("Cancel", |s| s.quit()))
    );
```

**Weight-based flex distribution:**

```rust
let layout = LinearLayout::vertical()
    .child(Panel::new(TextView::new("Header")).full_width())
    .weight(1)
    .child(Panel::new(TextView::new("Main content area")).full_width())
    .weight(3)
    .child(Panel::new(TextView::new("Footer")).full_width())
    .weight(1);
```

The `weight` method applies to the most recently added child. Children with higher
weights receive proportionally more of the available space after fixed-size children
are satisfied.

**`ResizedView`** -- Applies size constraints (min, max, fixed, full):

```rust
// Fixed width
let view = ResizedView::with_fixed_width(30, my_view);

// Min and max constraints
let view = ResizedView::with_min_width(10,
    ResizedView::with_max_width(50, my_view)
);

// Full screen
let view = ResizedView::with_full_screen(my_view);
```

**`BoxView`** -- Alias for `ResizedView` in older API. Same functionality.

**`PaddedView`** -- Adds padding (margins) around a view:

```rust
let padded = PaddedView::lrtb(2, 2, 1, 1, my_view);  // left, right, top, bottom
```

**`Panel`** -- Draws a border with an optional title:

```rust
let panel = Panel::new(my_view).title("Settings");
```

**`ScrollView`** -- Wraps a view in a scrollable container:

```rust
let scrollable = ScrollView::new(long_text_view);
// Or via the Scrollable trait:
let scrollable = long_text_view.scrollable();
```

**`Layer`** -- Fills the background behind a view (used in modal stacks).

**`StackView`** -- The internal view used by `Cursive` to manage the layer stack.
Each screen is a `StackView`.

### Non-Trivial Layout Example

A form dialog with constrained layout:

```rust
use cursive::views::*;
use cursive::view::Resizable;

let form = Dialog::around(
    LinearLayout::vertical()
        .child(
            LinearLayout::horizontal()
                .child(TextView::new("Username: ").fixed_width(12))
                .child(EditView::new().with_name("user").fixed_width(20))
        )
        .child(
            LinearLayout::horizontal()
                .child(TextView::new("Password: ").fixed_width(12))
                .child(EditView::new().secret().with_name("pass").fixed_width(20))
        )
        .child(DummyView.fixed_height(1))
        .child(
            LinearLayout::horizontal()
                .child(Checkbox::new().with_name("remember"))
                .child(TextView::new(" Remember me"))
        )
)
.title("Login")
.button("Submit", |s| {
    let user = s.call_on_name("user", |v: &mut EditView| {
        v.get_content()
    }).unwrap();
    // ... handle submission
})
.button("Cancel", |s| s.quit())
.fixed_width(40);
```

This produces:

```
+-- Login -------------------------+
| Username:  [__________________]  |
| Password:  [__________________]  |
|                                  |
| [ ] Remember me                  |
|                                  |
|          <Submit> <Cancel>       |
+----------------------------------+
```

---

## Widget / Component System

Cursive provides a rich library of built-in views covering common UI patterns.

### Text Views

| View       | Description                                               |
| ---------- | --------------------------------------------------------- |
| `TextView` | Displays static or dynamic text. Supports styled content. |
| `TextArea` | Multi-line text editor with cursor movement.              |
| `EditView` | Single-line text input. Supports secret mode, completion. |

### Selection Views

| View         | Description                                                |
| ------------ | ---------------------------------------------------------- |
| `SelectView` | Scrollable list with single selection. Supports callbacks. |
| `RadioGroup` | Coordinates a group of `RadioButton` views.                |
| `Checkbox`   | A toggleable checkbox.                                     |

### Layout Views

| View           | Description                                               |
| -------------- | --------------------------------------------------------- |
| `LinearLayout` | Horizontal or vertical arrangement with optional weights. |
| `FixedLayout`  | Children at fixed positions (absolute layout).            |
| `ListView`     | Labeled list of views (form-like, label + widget rows).   |
| `StackView`    | Layer stack. Only the top layer is active.                |
| `ScrollView`   | Wraps a view in a scrollable container.                   |

### Dialog and Decoration

| View             | Description                                         |
| ---------------- | --------------------------------------------------- |
| `Dialog`         | Titled container with content and action buttons.   |
| `Panel`          | Border wrapper with optional title.                 |
| `PaddedView`     | Adds padding (margins) around a child.              |
| `ShadowView`     | Adds a drop shadow effect behind a child.           |
| `Layer`          | Fills background behind a child (for modal stacks). |
| `ResizedView`    | Constrains child size (fixed, min, max, full).      |
| `HideableView`   | Wrapper that can show or hide its child.            |
| `EnableableView` | Wrapper that can enable or disable its child.       |
| `ThemedView`     | Applies a local theme override to its child.        |

### Interactive Views

| View          | Description                                         |
| ------------- | --------------------------------------------------- |
| `Button`      | Text label that triggers a callback on Enter/click. |
| `ProgressBar` | Animated progress indicator.                        |
| `SliderView`  | Horizontal or vertical value slider.                |
| `Menubar`     | Top-of-screen menu bar with drop-down menus.        |

### Utility Views

| View            | Description                                          |
| --------------- | ---------------------------------------------------- |
| `NamedView`     | Wraps a view with a string name for `call_on_name`.  |
| `OnEventView`   | Wraps a view to intercept or augment event handling. |
| `OnLayoutView`  | Wraps a view to override the layout callback.        |
| `FocusTracker`  | Detects focus gain/loss events.                      |
| `CircularFocus` | Makes Tab/Shift-Tab wrap around within a container.  |
| `Canvas`        | Closure-based custom view (no trait impl needed).    |
| `DummyView`     | Empty spacer view.                                   |
| `DebugView`     | Shows log output for debugging.                      |
| `TrackedView`   | Remembers its position after layout.                 |
| `LastSizeView`  | Remembers its size after layout.                     |
| `GradientView`  | Applies a color gradient effect to a child.          |
| `ScreensView`   | Switches between multiple screen states.             |

### View Wrapping and Method Chaining

Cursive uses **trait-based method chaining** to compose view wrappers concisely. Several
extension traits add convenience methods to all views:

```rust
use cursive::view::{Resizable, Scrollable, Nameable};

let view = EditView::new()
    .with_name("input")       // Nameable: wraps in NamedView
    .fixed_width(30)          // Resizable: wraps in ResizedView
    .scrollable();            // Scrollable: wraps in ScrollView
```

These are equivalent to explicit wrapping:

```rust
let view = ScrollView::new(
    ResizedView::with_fixed_width(30,
        NamedView::new("input", EditView::new())
    )
);
```

The trait-based chaining reads left-to-right (innermost view first), matching the natural
construction order. This pattern is one of Cursive's most ergonomic features.

### Custom Views

Implement the `View` trait to create custom views:

```rust
use cursive::event::{Event, EventResult, Key};
use cursive::Printer;
use cursive::Vec2;
use cursive::view::View;

struct CounterView {
    count: i32,
}

impl CounterView {
    fn new() -> Self {
        CounterView { count: 0 }
    }
}

impl View for CounterView {
    fn draw(&self, printer: &Printer) {
        printer.print((0, 0), &format!("Count: {}", self.count));
    }

    fn required_size(&mut self, _constraint: Vec2) -> Vec2 {
        Vec2::new(20, 1)
    }

    fn on_event(&mut self, event: Event) -> EventResult {
        match event {
            Event::Char('+') => {
                self.count += 1;
                EventResult::consumed()
            }
            Event::Char('-') => {
                self.count -= 1;
                EventResult::consumed()
            }
            _ => EventResult::Ignored,
        }
    }

    fn take_focus(&mut self, _: cursive::direction::Direction)
        -> Result<EventResult, cursive::view::CannotFocus>
    {
        Ok(EventResult::consumed())
    }
}
```

For quick prototyping without implementing `View`, use `Canvas`:

```rust
use cursive::views::Canvas;

let counter = Canvas::new(0i32)
    .with_draw(|count: &i32, printer: &Printer| {
        printer.print((0, 0), &format!("Count: {}", count));
    })
    .with_on_event(|count: &mut i32, event| match event {
        Event::Char('+') => { *count += 1; EventResult::consumed() }
        Event::Char('-') => { *count -= 1; EventResult::consumed() }
        _ => EventResult::Ignored,
    })
    .with_required_size(|_, _| Vec2::new(20, 1));
```

### The `ViewWrapper` Trait

For creating decorator views that mostly delegate to an inner view, `ViewWrapper`
reduces boilerplate:

```rust
use cursive::view::{View, ViewWrapper};

struct Bordered<V: View> {
    inner: V,
    border_char: char,
}

impl<V: View> ViewWrapper for Bordered<V> {
    type V = V;

    fn with_view<F, R>(&self, f: F) -> Option<R>
    where F: FnOnce(&Self::V) -> R {
        Some(f(&self.inner))
    }

    fn with_view_mut<F, R>(&mut self, f: F) -> Option<R>
    where F: FnOnce(&mut Self::V) -> R {
        Some(f(&mut self.inner))
    }

    // Override only the methods you need to customize.
    // All other View methods delegate to the inner view automatically.
}
```

The `wrap_impl!` macro can generate the `with_view` / `with_view_mut` boilerplate.

---

## Styling

Cursive uses a **theme-based styling system**. Rather than attaching styles to individual
views, the application defines a `Theme` with a `Palette` of named colors. Views reference
palette colors by role (e.g., "primary text", "highlight"), and the theme resolves them to
concrete terminal colors.

### Theme Struct

```rust
pub struct Theme {
    /// Whether shadows are drawn behind layers in a StackView.
    pub shadow: bool,

    /// How borders are drawn around views (Simple, Outset, None).
    pub borders: BorderStyle,

    /// The color palette mapping role names to colors.
    pub palette: Palette,
}
```

### Palette and PaletteColor

The `Palette` maps semantic color roles to concrete colors:

```rust
pub enum PaletteColor {
    Background,         // Application background
    Shadow,             // Shadow behind layered views
    View,               // View/widget background
    Primary,            // Primary text color
    Secondary,          // Secondary text color
    Tertiary,           // Tertiary text color
    TitlePrimary,       // Primary title text
    TitleSecondary,     // Secondary title text
    Highlight,          // Active/focused highlight
    HighlightInactive,  // Inactive/unfocused highlight
    HighlightText,      // Text within highlighted areas
}
```

### Color Types

```rust
pub enum Color {
    TerminalDefault,          // Inherit from terminal settings
    Dark(BaseColor),          // 8 base colors (universal support)
    Light(BaseColor),         // Light variants (most emulators)
    Rgb(u8, u8, u8),          // 24-bit true color (auto-downgrade)
    RgbLowRes(u8, u8, u8),   // 6x6x6 color cube (256-color palette)
}

pub enum BaseColor {
    Black, Red, Green, Yellow, Blue, Magenta, Cyan, White,
}
```

### ColorStyle and ColorType

`ColorStyle` pairs a foreground and background color for a cell:

```rust
pub struct ColorStyle {
    pub front: ColorType,
    pub back: ColorType,
}

pub enum ColorType {
    Color(Color),                // A concrete color
    Palette(PaletteColor),       // Reference a palette role
    InheritParent,               // Inherit from the parent view
}
```

This indirection through `ColorType` means views can reference palette roles rather than
hard-coding colors, enabling theme switching at runtime.

### BorderStyle

```rust
pub enum BorderStyle {
    Simple,   // Standard single-line borders (default)
    Outset,   // 3D outset effect
    None,     // No borders
}
```

### Programmatic Theme Configuration

```rust
use cursive::theme::{BaseColor, BorderStyle, Color, PaletteColor, Theme};

let mut siv = cursive::default();

siv.update_theme(|theme| {
    theme.shadow = false;
    theme.borders = BorderStyle::Simple;
    theme.palette[PaletteColor::Background] = Color::TerminalDefault;
    theme.palette[PaletteColor::View] = Color::Dark(BaseColor::Black);
    theme.palette[PaletteColor::Primary] = Color::Light(BaseColor::White);
    theme.palette[PaletteColor::Highlight] = Color::Dark(BaseColor::Cyan);
    theme.palette[PaletteColor::HighlightInactive] = Color::Dark(BaseColor::Blue);
    theme.palette[PaletteColor::HighlightText] = Color::Dark(BaseColor::White);
});
```

### TOML Theme Loading

With the `toml` Cargo feature, themes can be loaded from files:

```toml
# theme.toml
shadow = false
borders = "simple"

[colors]
background = "black"
view       = "#222222"
primary    = "white"
secondary  = "light cyan"
tertiary   = "light magenta"
title_primary   = "light yellow"
title_secondary = "light blue"
highlight       = "dark cyan"
highlight_inactive = "dark blue"
highlight_text  = "white"
```

```rust
// Load at runtime
siv.load_theme_file("theme.toml").expect("Failed to load theme");

// Or from a string
siv.load_toml(include_str!("theme.toml")).expect("Invalid theme");
```

### Per-View Theme Overrides

The `ThemedView` wrapper applies a local theme to a subtree:

```rust
use cursive::views::ThemedView;

let themed_panel = ThemedView::new(my_custom_theme, my_view);
```

### Built-In Themes

Cursive provides two built-in themes:

- **`Theme::retro()`** -- The default. Resembles classic dialog-based tools like GNU dialog.
- **`Theme::terminal_default()`** -- Uses the terminal's native foreground/background colors.

---

## Event Handling

Cursive is **callback-driven**. Events flow through the view tree, and views respond by
returning `EventResult` values that may carry callbacks to execute.

### Event Enum

```rust
pub enum Event {
    // Character input
    Char(char),
    CtrlChar(char),
    AltChar(char),

    // Non-character keys (arrows, function keys, etc.)
    Key(Key),
    Shift(Key),
    Alt(Key),
    AltShift(Key),
    Ctrl(Key),
    CtrlShift(Key),
    CtrlAlt(Key),

    // System events
    WindowResize,
    FocusLost,
    Refresh,

    // Mouse events
    Mouse { offset: Vec2, position: Vec2, event: MouseEvent },

    // Unrecognized input sequences
    Unknown(Vec<u8>),
}
```

### EventResult

```rust
pub enum EventResult {
    /// The event was not handled. The parent should try handling it.
    Ignored,

    /// The event was consumed. An optional callback may be attached.
    Consumed(Option<Callback>),
}
```

Convenience constructors:

```rust
EventResult::consumed()              // Consumed, no callback
EventResult::with_cb(|s| s.quit())   // Consumed with a callback
EventResult::Ignored                 // Not handled
```

### Event Flow

Events flow **top-down through the focused path**, then **bubble up** if ignored:

1. The framework receives an input event from the backend.
2. It calls `on_event(event)` on the topmost layer's root view.
3. Container views forward to their focused child.
4. If a view returns `EventResult::Consumed(Some(cb))`, the callback is executed with
   `&mut Cursive`.
5. If a view returns `EventResult::Ignored`, the parent view gets a chance to handle it.
6. If the event bubbles all the way up unhandled, global callbacks are checked.

### Global Callbacks

```rust
let mut siv = cursive::default();

// Quit on 'q' or Escape
siv.add_global_callback('q', |s| s.quit());
siv.add_global_callback(Key::Esc, |s| s.quit());

// Ctrl+S to save
siv.add_global_callback(Event::CtrlChar('s'), |s| {
    // ... save logic ...
});

// Pre-event and post-event hooks
siv.set_on_pre_event('q', |s| {
    // Runs before the view tree processes the event
});
siv.set_on_post_event(Key::F1, |s| {
    // Runs after the view tree processes the event
    s.add_layer(Dialog::info("Help screen"));
});
```

### Per-View Event Handling with OnEventView

`OnEventView` wraps a view to intercept or augment its event handling:

```rust
use cursive::views::{OnEventView, TextView};
use cursive::event::Key;

let view = OnEventView::new(TextView::new("Press 'q' to quit"))
    .on_event('q', |s| s.quit())
    .on_event(Key::Esc, |s| s.quit());
```

The distinction between `on_event` and `on_pre_event`:

- **`on_event`:** Triggers when the inner view _ignores_ the event (fallback handler).
- **`on_pre_event`:** Triggers _before_ the inner view sees the event (interceptor).

The `_inner` variants (`on_event_inner`, `on_pre_event_inner`) provide access to the
wrapped view itself, enabling conditional handling based on view state:

```rust
let view = OnEventView::new(
    SelectView::<String>::new()
        .item_str("Alice")
        .item_str("Bob")
        .with_name("list")
)
.on_pre_event_inner(Key::Del, |siv, _event| {
    // Access the inner NamedView -> SelectView to remove selected item
    siv.get_mut().remove_item(
        siv.get_mut().selected_id().unwrap_or(0)
    );
    Some(EventResult::consumed())
});
```

### Callback-Driven Dialog Example

```rust
use cursive::views::{Dialog, EditView, TextView};
use cursive::Cursive;

fn main() {
    let mut siv = cursive::default();

    siv.add_layer(
        Dialog::around(
            EditView::new()
                .on_submit(show_greeting)
                .with_name("name")
                .fixed_width(25)
        )
        .title("Enter your name")
        .button("Ok", |s| {
            let name = s.call_on_name("name", |v: &mut EditView| {
                v.get_content()
            }).unwrap();
            show_greeting(s, &name);
        })
        .button("Quit", |s| s.quit())
    );

    siv.run();
}

fn show_greeting(s: &mut Cursive, name: &str) {
    s.pop_layer();
    s.add_layer(
        Dialog::around(
            TextView::new(format!("Hello, {}!", name))
        )
        .button("Ok", |s| s.quit())
    );
}
```

### Async Event Injection

The `cb_sink()` method returns a channel sender for injecting callbacks from background
threads:

```rust
let sink = siv.cb_sink().clone();

std::thread::spawn(move || {
    // ... long-running work ...
    sink.send(Box::new(|s: &mut Cursive| {
        s.add_layer(Dialog::info("Background work complete!"));
    })).unwrap();
});
```

This is the primary mechanism for communicating between async/threaded work and the UI.

---

## State Management

### View-Internal State

In Cursive's retained model, each view owns its own mutable state. An `EditView` holds its
text buffer. A `SelectView` holds its items and selection index. A `ScrollView` holds its
scroll offset. State persists between frames because the view tree persists.

Views are mutated through `&mut self` in their `on_event` handler or externally through
`call_on_name`:

```rust
// Mutate a view by name
siv.call_on_name("counter", |view: &mut TextView| {
    view.set_content("Updated text");
});
```

### User Data

For application-level state that does not belong to any specific view, Cursive provides a
typed storage slot:

```rust
struct AppState {
    logged_in: bool,
    username: String,
    items: Vec<String>,
}

siv.set_user_data(AppState {
    logged_in: false,
    username: String::new(),
    items: vec![],
});

// Access from a callback
siv.with_user_data(|state: &mut AppState| {
    state.logged_in = true;
    state.username = "admin".to_string();
});

// Or retrieve directly
if let Some(state) = siv.user_data::<AppState>() {
    println!("User: {}", state.username);
}
```

The user data slot stores a single `Box<dyn Any>`. For multiple pieces of state, use a
struct that groups them.

### Shared Mutable State Across Callbacks

Because each callback only receives `&mut Cursive`, sharing state between multiple
callbacks requires one of:

**Pattern 1: User data (recommended for global state)**

```rust
siv.set_user_data(0u32);  // Counter

siv.add_global_callback('+', |s| {
    s.with_user_data(|count: &mut u32| *count += 1);
    update_display(s);
});

siv.add_global_callback('-', |s| {
    s.with_user_data(|count: &mut u32| *count -= 1);
    update_display(s);
});
```

**Pattern 2: `Rc<RefCell<T>>` (for state shared between specific callbacks)**

```rust
use std::cell::RefCell;
use std::rc::Rc;

let shared_state = Rc::new(RefCell::new(Vec::<String>::new()));

let state_clone = shared_state.clone();
siv.add_layer(
    Dialog::around(
        EditView::new().on_submit(move |s, text| {
            state_clone.borrow_mut().push(text.to_string());
            s.pop_layer();
        })
    )
);
```

This pattern is necessary when closures captured at different points in the code need
access to the same data. It incurs a runtime borrow-check cost (`RefCell` panics on
concurrent borrows).

**Pattern 3: Named views as state containers**

Use the views themselves as the source of truth:

```rust
// Read state from the view when you need it
siv.call_on_name("items", |view: &mut SelectView<String>| {
    let selected = view.selection().unwrap();
    // ... use selected item ...
});
```

---

## Extensibility and Ecosystem

### Third-Party View Crates

| Crate                      | Description                                          |
| -------------------------- | ---------------------------------------------------- |
| `cursive_table_view`       | Sortable, scrollable data table with columns.        |
| `cursive_tree_view`        | Hierarchical tree with expand/collapse.              |
| `cursive-aligned-view`     | Aligns a child view within available space.          |
| `cursive-tabs`             | Tabbed container switching between child views.      |
| `cursive_buffered_backend` | Backend wrapper that buffers output for performance. |
| `cursive-hjkl`             | Vim-style hjkl navigation wrapper.                   |
| `cursive-syntect`          | Syntax highlighting via the syntect library.         |

### Community

- **Gitter chat** for discussion and support.
- Active maintenance with regular releases (50+ releases).
- Used in real-world applications: Git clients, password managers, Spotify TUI clients.

### Ecosystem Size

The Cursive ecosystem is **smaller than Ratatui's**. Ratatui has 12,700+ dependent crates
and a much larger selection of community widgets. Cursive's third-party view library is
modest but covers common needs (tables, trees, tabs). The difference is partly due to
architectural philosophy: Cursive's retained-mode view tree with trait objects makes
third-party views somewhat heavier to implement than Ratatui's stateless `Widget` trait.

---

## Strengths

- **High-level, batteries-included API.** Dialog-heavy apps require very little code.
  A functional form with validation can be built in under 50 lines.
- **Familiar OOP-like architecture.** Developers coming from GTK, Qt, or Swing will
  recognize the view tree, event bubbling, and layout negotiation patterns.
- **Built-in event loop and focus management.** The framework handles event routing, focus
  traversal (Tab/Shift-Tab), and layer management. The application does not need to
  implement any of this.
- **Excellent for dialog-heavy and form-driven apps.** The `Dialog`, `EditView`,
  `SelectView`, `RadioGroup`, and `Checkbox` views cover form scenarios comprehensively.
- **Backend flexibility.** Five backends covering pure-Rust, ncurses-based, and
  graphical (BearLibTerminal) options. Backend swapping is a Cargo feature flag.
- **Named view access.** The `call_on_name` pattern provides a clean way to reach into
  the view tree without passing references through layers of callbacks.
- **Theme support with TOML loading.** Theme switching at runtime, palette-based color
  roles, and external theme files.
- **Method chaining for view composition.** The `Resizable`, `Scrollable`, and `Nameable`
  traits enable fluent, left-to-right view wrapping that reads naturally.
- **Canvas for quick custom views.** The closure-based `Canvas` view allows prototyping
  custom rendering without implementing the full `View` trait.
- **Async callback injection.** The `cb_sink()` channel enables safe communication from
  background threads to the UI thread.

---

## Weaknesses and Limitations

- **Trait object overhead.** Views are stored as `Box<dyn View>`, incurring virtual
  dispatch on every `draw`, `layout`, `on_event`, and `required_size` call. This is
  negligible for most apps but prevents whole-program monomorphization optimizations.
- **`Rc<RefCell<T>>` for shared state.** Sharing mutable state across callbacks requires
  reference-counted interior mutability, which trades compile-time safety for runtime
  panics on borrow violations. This is a common pain point for Cursive users.
- **Harder to do fully custom rendering.** The `Printer` abstraction is convenient for
  text-based views but limiting for pixel-level or cell-level custom drawing (e.g.,
  sparklines, charts, custom graphs). Ratatui's raw `Buffer` access is more flexible here.
- **Less suitable for dashboard-style UIs.** Cursive's layout system is designed for
  dialogs and forms, not for splitting a screen into many independently-updating panels.
  Ratatui's constraint solver handles this more naturally.
- **Smaller community and ecosystem than Ratatui.** Fewer third-party widgets, fewer
  examples, less Stack Overflow coverage. Ratatui has roughly 4x the GitHub stars and
  a much larger dependent crate count.
- **Callback spaghetti in complex apps.** As applications grow, the callback-based event
  model can lead to deeply nested closures and difficult-to-follow control flow. There is
  no built-in architectural pattern (like Elm/MVU) to impose structure.
- **Single-threaded UI assumption.** The `Cursive` struct is not `Send` or `Sync`. All
  view mutations must happen on the main thread, with `cb_sink()` as the only bridge to
  async work.
- **No incremental layout.** The entire view tree is re-laid-out and re-drawn on every
  event, even if only a small part changed. There is no dirty-tracking or partial
  invalidation at the framework level (individual views can optimize via
  `needs_relayout`).
- **Weight system limitations.** The `LinearLayout` weight system is documented but noted
  as "currently unused by layout process" in the docs, suggesting it may not work as
  expected in all versions.

---

## Lessons for D / Sparkles

This section maps Cursive's patterns to D idioms, evaluating what would translate well
and where D's unique capabilities could improve upon the design.

### View Trait -> D Interface or Template Constraint

Cursive's `View` trait uses dynamic dispatch (`dyn View`). In D, there are two paths:

**Runtime polymorphism via D interface** (closest analog, necessary for a heterogeneous
view tree):

```d
interface View {
    void draw(ref const Printer printer) const;
    Vec2 requiredSize(Vec2 constraint);
    void layout(Vec2 size);
    EventResult onEvent(Event event);
    Result!(EventResult, CannotFocus) takeFocus(Direction dir);
    bool needsRelayout() const;
}
```

**Compile-time polymorphism via template constraint** (for static view trees,
zero-overhead):

```d
enum isView(T) = is(typeof((ref T v, ref const Printer p) {
    v.draw(p);
    Vec2 s = v.requiredSize(Vec2.init);
    v.layout(Vec2.init);
    EventResult r = v.onEvent(Event.init);
}));
```

D could offer **both**: a template-based fast path for compile-time-known trees, and an
interface-based path for dynamic trees. This dual approach is not easily achievable in
Rust due to its stricter trait object rules.

### Method Chaining -> UFCS in D (Natural Fit)

Cursive's wrapping traits:

```rust
EditView::new().with_name("input").fixed_width(30).scrollable()
```

This maps directly to D's UFCS:

```d
auto view = editView()
    .withName("input")
    .fixedWidth(30)
    .scrollable;
```

D's UFCS is even more flexible than Rust's trait-based extension methods because it works
on any type without needing a trait definition. Free functions in scope automatically
participate:

```d
/// Any view -> ResizedView wrapping it at fixed width.
auto fixedWidth(V)(V view, uint width) if (isView!V) {
    return ResizedView!V(view, SizeConstraint.fixed(width));
}
```

### Named View Access -> D AA Lookup or Compile-Time Indexing

Cursive's `call_on_name` pattern (runtime string lookup):

```d
// Runtime approach: associative array of views by name
View[string] namedViews;
if (auto v = "input" in namedViews) {
    if (auto edit = cast(EditView)*v) {
        edit.setContent("hello");
    }
}
```

D could also offer a **compile-time** variant using string template parameters:

```d
// Compile-time approach: view tree with string-indexed children
auto tree = viewTree(
    named!("input", editView()),
    named!("output", textView()),
);

// Zero-cost access at compile time
tree.get!"input".setContent("hello");
```

This would be a significant improvement over Cursive's runtime lookup, catching name
mismatches at compile time.

### Weight-Based Layout -> D Struct with DbI

Cursive's weight system:

```rust
LinearLayout::vertical()
    .child(header).weight(1)
    .child(body).weight(3)
    .child(footer).weight(1)
```

In D, using Design by Introspection, the layout container can detect whether a child
provides a weight capability:

```d
enum hasWeight(T) = is(typeof(T.init.layoutWeight) : uint);

struct LinearLayout(Children...) {
    void layout(Vec2 available) {
        // For each child, check if it has a weight
        static foreach (i, C; Children) {
            static if (hasWeight!C)
                uint w = children[i].layoutWeight;
            else
                uint w = 1;  // default weight
        }
        // ... distribute space proportionally ...
    }
}
```

This avoids runtime checks entirely -- the layout logic is specialized per-child at
compile time.

### Theme / Palette -> D Enum-Based Palette with CTFE Theme Parsing

Cursive's `PaletteColor` enum maps directly to D:

```d
enum PaletteColor {
    background, shadow, view,
    primary, secondary, tertiary,
    titlePrimary, titleSecondary,
    highlight, highlightInactive, highlightText,
}

struct Theme {
    bool shadow;
    BorderStyle borders;
    Color[PaletteColor] palette;
}
```

D's CTFE could **parse TOML themes at compile time**:

```d
// Compile-time theme parsing -- zero runtime cost
enum myTheme = parseThemeToml(import("theme.toml"));

// The theme struct is fully resolved at compile time
static assert(myTheme.palette[PaletteColor.primary] == Color.rgb(255, 255, 255));
```

This is impossible in Rust (TOML parsing at compile time is not feasible without `const`
evaluation of the parser). D's CTFE can execute arbitrary code at compile time, including
string parsing.

### Callback Pattern -> D Delegates, or MVU Alternative

Cursive's callback model:

```rust
siv.add_global_callback('q', |s| s.quit());
```

D delegates are the direct translation:

```d
siv.addGlobalCallback('q', (ref Cursive s) { s.quit(); });
```

However, D could also offer an **MVU (Model-View-Update) alternative** that avoids
callback spaghetti entirely:

```d
struct AppState { int count; bool running; }

enum Msg { increment, decrement, quit }

AppState update(AppState state, Msg msg) pure {
    final switch (msg) {
        case Msg.increment: return AppState(state.count + 1, true);
        case Msg.decrement: return AppState(state.count - 1, true);
        case Msg.quit:      return AppState(state.count, false);
    }
}
```

The MVU approach with pure update functions is a better fit for D's `pure` and `@nogc`
capabilities than the `Rc<RefCell<T>>` pattern that Cursive users resort to for shared
state.

### Retained View Tree -> Tradeoffs vs. Immediate-Mode for D's `@nogc` Goals

Cursive's retained-mode architecture has inherent tension with `@nogc`:

- **View tree allocation:** `Box<dyn View>` requires heap allocation. In D with `@nogc`,
  this would need `pureMalloc`-based allocators or arena allocation.
- **State persistence:** Views hold mutable state across frames, which is natural in
  retained mode but means allocation lifetimes are unbounded.
- **Trait objects / interfaces:** Dynamic dispatch through `dyn View` (or D's `interface`)
  requires indirection and prevents inlining.

By contrast, **immediate-mode** (Ratatui's approach) is more naturally `@nogc`-friendly:

- Widgets are stack-allocated value types, constructed and consumed per frame.
- No persistent tree means no long-lived heap allocations.
- Template-based widgets enable full monomorphization.

A D TUI framework could pursue a **hybrid approach**:

- **Immediate-mode rendering** for the draw path (`@nogc`, stack-allocated widgets).
- **Retained state** for input focus, scroll positions, and text buffers, stored in a
  flat `App` struct rather than distributed across a view tree.
- **Compile-time view composition** using D's template system to build static view trees
  where the structure is known, avoiding dynamic dispatch entirely.

This would combine Cursive's ergonomic view composition with Ratatui's rendering
efficiency, enabled by D's unique ability to straddle compile-time and runtime patterns.

---

## References

- **GitHub Repository:** <https://github.com/gyscos/cursive>
- **API Reference (docs.rs):** <https://docs.rs/cursive/latest/cursive/>
  - View trait: <https://docs.rs/cursive/latest/cursive/view/trait.View.html>
  - Cursive struct: <https://docs.rs/cursive/latest/cursive/struct.Cursive.html>
  - Views module: <https://docs.rs/cursive/latest/cursive/views/index.html>
  - Theme module: <https://docs.rs/cursive/latest/cursive/theme/index.html>
  - Event module: <https://docs.rs/cursive/latest/cursive/event/enum.Event.html>
  - EventResult: <https://docs.rs/cursive/latest/cursive/event/enum.EventResult.html>
  - PaletteColor: <https://docs.rs/cursive/latest/cursive/theme/enum.PaletteColor.html>
  - ColorStyle: <https://docs.rs/cursive/latest/cursive/theme/struct.ColorStyle.html>
  - LinearLayout: <https://docs.rs/cursive/latest/cursive/views/struct.LinearLayout.html>
  - Dialog: <https://docs.rs/cursive/latest/cursive/views/struct.Dialog.html>
  - SelectView: <https://docs.rs/cursive/latest/cursive/views/struct.SelectView.html>
  - ResizedView: <https://docs.rs/cursive/latest/cursive/views/struct.ResizedView.html>
  - OnEventView: <https://docs.rs/cursive/latest/cursive/views/struct.OnEventView.html>
  - Canvas: <https://docs.rs/cursive/latest/cursive/views/struct.Canvas.html>
  - ViewWrapper: <https://docs.rs/cursive/latest/cursive/view/trait.ViewWrapper.html>
  - NamedView: <https://docs.rs/cursive/latest/cursive/views/struct.NamedView.html>
- **Backends Wiki:** <https://github.com/gyscos/cursive/wiki/Backends>
- **Ecosystem:**
  - cursive_table_view: <https://github.com/BonsaiDen/cursive_table_view>
  - cursive_tree_view: <https://github.com/BonsaiDen/cursive_tree_view>
  - cursive-tabs: <https://github.com/deinstapel/cursive-tabs>
  - cursive-aligned-view: <https://github.com/deinstapel/cursive-aligned-view>
