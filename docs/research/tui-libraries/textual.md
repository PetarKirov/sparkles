# Textual (Python)

A modern, retained-mode TUI framework that brings web development patterns -- CSS styling, a DOM-like widget tree, and reactive state management -- to terminal applications in Python.

| Field          | Value                                                       |
| -------------- | ----------------------------------------------------------- |
| Language       | Python (3.9+)                                               |
| License        | MIT                                                         |
| Repository     | [Textualize/textual](https://github.com/Textualize/textual) |
| Documentation  | [textual.textualize.io](https://textual.textualize.io/)     |
| Latest Version | ~7.5.0 (January 2026)                                       |
| GitHub Stars   | ~34k                                                        |

---

## Overview

### What It Solves

Textual provides a high-level, batteries-included framework for building rich terminal user interfaces with CSS-like styling, a comprehensive widget library, and a reactive programming model. It eliminates the need to manually manage terminal state, cursor positioning, and input parsing, instead offering a declarative approach where developers describe **what** the UI should look like rather than **how** to draw it.

### Design Philosophy

Textual's core thesis is that web development patterns -- component hierarchies, CSS for styling and layout, event bubbling through a DOM, reactive data binding -- translate directly to terminal applications. The framework deliberately mirrors the web development experience: external `.tcss` stylesheets, a DOM tree of widgets, CSS selectors for querying and styling, and a message-passing event system that bubbles through the tree. This lowers the learning curve for developers already familiar with HTML/CSS/JS, while providing a much richer abstraction than traditional curses-based approaches.

### History

Textual was created by Will McGugan, a Python developer based in Edinburgh, Scotland. McGugan first built [Rich](https://github.com/Textualize/rich) in 2020 as a library for beautiful text formatting in the terminal (syntax highlighting, tables, progress bars, trees). Rich grew into a widely-used rendering engine, and in 2021 McGugan began building Textual on top of it as a full application framework. He founded [Textualize](https://www.textualize.io/) at the end of 2021 to develop both projects commercially. Between them, Rich and Textual have been downloaded over 3 billion times.

### Web Deployment

Textual applications can also run in a web browser via [textual-web](https://github.com/Textualize/textual-web) and `textual serve`. The Python app runs server-side, serializing render diffs over WebSockets to a browser client. This means a single codebase can target both terminal and browser environments with no code changes. URLs can be shared publicly, allowing anyone with internet access to use the application.

---

## Architecture

### Rendering Model

Textual uses a **retained-mode** rendering model with a DOM-like [`Widget`][textual-widget] tree. The application maintains a persistent tree of widget objects; when state changes, only the affected widgets are re-rendered. This contrasts with immediate-mode frameworks (like Ratatui or Bubble Tea) where the application redraws the entire UI each frame.

### Core Concepts

```
App
 +-- Screen
      +-- Widget (Container)
      |    +-- Widget (Button)
      |    +-- Widget (Input)
      +-- Widget (Footer)
```

- **App**: The top-level object. Manages screens, themes, bindings, and the event loop.
- **Screen**: A full-screen layer of widgets. Screens can be stacked (for modals, overlays).
- **Widget**: A rectangular region that renders content. Widgets form a tree (the DOM).
- **Message**: An event object that propagates through the DOM.

### Message-Passing System

All inter-widget communication happens through messages. Messages bubble **up** the DOM tree from child to parent (analogous to DOM event bubbling in browsers). A widget posts a message via `self.post_message(MyMessage(...))`, and any ancestor can handle it. This enforces a unidirectional data flow: **attributes flow down, messages flow up**.

### Compositor

The compositor combines rendered output from all visible widgets into a single terminal frame. It operates on Rich `Segment` objects (styled text fragments):

1. **Cuts**: Find every x-offset where a widget region begins or ends.
2. **Chops**: Divide all segment lists at cut offsets, producing uniform sub-segments.
3. **Occlusion**: Discard chops that are hidden behind higher-z widgets.
4. **Composition**: Merge the remaining top-most chops into final output lines.

The compositor supports **partial updates** -- if a single button changes color, only the region occupied by that button is recomposed and flushed, enabling smooth scrolling and responsive interaction even with many widgets on screen. Clipping, scrolling offsets, and modal screen stacking are all handled at this layer.

### Async-First

Textual is built on Python's `asyncio`. The event loop, message dispatch, timers, and workers are all async. However, synchronous usage is supported for simple cases -- the `App.run()` method blocks and manages the event loop internally.

### App Lifecycle

1. **`__init__`**: App and widget constructors run. No DOM exists yet.
2. **`compose()`**: Called to build the initial widget tree. Returns/yields child widgets.
3. **`on_mount()`**: Fired after the widget is added to the DOM. Used for initialization that requires DOM access.
4. **CSS loading**: Textual loads `.tcss` files (from `CSS_PATH`) and applies styles to the widget tree.
5. **Layout**: The layout engine computes positions and sizes for all widgets.
6. **Render**: Each widget's `render()` method produces Rich renderables.
7. **Compose to screen**: The compositor assembles the final output.
8. **Ready**: The app is interactive. Events (key, mouse, messages) flow through the DOM.

### Dirty Widget Tracking

When a reactive attribute changes or a widget calls `self.refresh()`, Textual marks that widget as **dirty**. On the next frame, only dirty widgets are re-rendered and recomposed. If multiple reactive attributes change in the same frame, Textual coalesces them into a single refresh, minimizing redundant work.

---

## Terminal Backend

### Rich Console Foundation

Textual renders through Rich's `Console` object, which handles the low-level conversion of styled content into ANSI escape sequences. Rich provides:

- True color (24-bit) output with automatic downgrade to 256-color or 16-color
- Unicode rendering with wide-character and emoji support
- Text styling (bold, italic, underline, strikethrough, dim, reverse, etc.)
- Complex renderables: tables, trees, syntax-highlighted code, Markdown, panels

### Driver Abstraction

Textual abstracts terminal I/O through a **driver** layer. The driver is responsible for:

- Entering/exiting alternate screen mode
- Enabling/disabling raw mode and mouse reporting
- Converting raw terminal input bytes into structured `Event` objects (key presses, mouse events)
- Flushing rendered output to the terminal

Platform-specific drivers handle differences between Linux, macOS, and Windows terminals. The driver abstraction also enables the **web driver** used by `textual-web` and `textual-serve`, which serializes output as WebSocket messages to a browser client.

### Capabilities

| Capability          | Support                               |
| ------------------- | ------------------------------------- |
| True color (24-bit) | Yes, with automatic fallback          |
| Mouse click         | Yes                                   |
| Mouse scroll        | Yes                                   |
| Mouse hover         | Yes (`:hover` pseudo-class in CSS)    |
| Unicode / emoji     | Yes (via Rich)                        |
| Bracketed paste     | Yes                                   |
| Focus tracking      | Yes                                   |
| Web rendering       | Yes (via textual-web / textual-serve) |

---

## Layout System

Textual uses a **CSS-inspired layout engine**. Layout is declared in `.tcss` files (or inline), never computed manually in Python code.

### Layout Modes

| Property                           | Values / Description                                         |
| ---------------------------------- | ------------------------------------------------------------ |
| `layout`                           | `horizontal`, `vertical`, `grid`                             |
| `dock`                             | `top`, `bottom`, `left`, `right` (removes from flow)         |
| `width` / `height`                 | `auto`, fixed (`40`), percentage (`50%`), fractional (`1fr`) |
| `min-width` / `max-width`          | Constrain dimensions                                         |
| `min-height` / `max-height`        | Constrain dimensions                                         |
| `margin`                           | Outer spacing (1-4 values)                                   |
| `padding`                          | Inner spacing (1-4 values)                                   |
| `overflow`                         | `auto`, `hidden`, `scroll` (x and y independently)           |
| `grid-size-columns`                | Number of columns in grid layout                             |
| `grid-size-rows`                   | Number of rows in grid layout                                |
| `grid-gutter`                      | Spacing between grid cells                                   |
| `grid-columns`                     | Explicit column widths (e.g., `1fr 2fr 1fr`)                 |
| `grid-rows`                        | Explicit row heights                                         |
| `box-sizing`                       | `border-box` (default), `content-box`                        |
| `offset` / `offset-x` / `offset-y` | Translate position (for animations)                          |

### Code Example: Multi-Panel Layout

**app.py**:

```python
from textual.app import App, ComposeResult
from textual.containers import Horizontal, Vertical
from textual.widgets import Header, Footer, Static, Tree, TextArea, RichLog


class EditorApp(App):
    CSS_PATH = "editor.tcss"

    def compose(self) -> ComposeResult:
        yield Header()
        with Horizontal(id="main"):
            # Left sidebar: file tree
            yield Tree("Project", id="file-tree")
            with Vertical(id="editor-area"):
                # Main editor pane
                yield TextArea(id="editor", language="python")
                # Bottom panel: log output
                yield RichLog(id="output", markup=True)
        yield Footer()

    def on_mount(self) -> None:
        tree = self.query_one("#file-tree", Tree)
        src = tree.root.add("src/")
        src.add_leaf("main.py")
        src.add_leaf("utils.py")
        tree.root.add_leaf("README.md")
        tree.root.expand_all()


if __name__ == "__main__":
    EditorApp().run()
```

**editor.tcss**:

```css
#main {
  layout: horizontal;
  height: 1fr;
}

#file-tree {
  width: 25;
  dock: left;
  border-right: solid $primary;
  padding: 1;
}

#editor-area {
  layout: vertical;
  width: 1fr;
}

#editor {
  height: 2fr;
  border-bottom: solid $primary-lighten-2;
}

#output {
  height: 1fr;
  min-height: 5;
  padding: 0 1;
}
```

This produces a three-panel layout: a fixed-width file tree docked to the left, a code editor taking two-thirds of the remaining vertical space, and a log panel at the bottom.

---

## Widget / Component System

### Base Widget Class

Every widget extends `textual.widget.Widget`. Two key methods define a widget's UI:

- **`render()`**: Returns a Rich renderable (string, `Text`, `Table`, etc.) for **leaf** widgets that display content directly.
- **`compose()`**: Yields child widgets for **container** widgets that build a sub-tree.

A widget uses one or the other. `render()` is for simple, self-contained content. `compose()` is for widgets that contain other widgets.

### Built-in Widget Library

Textual ships with a comprehensive set of widgets:

| Category       | Widgets                                                                                                        |
| -------------- | -------------------------------------------------------------------------------------------------------------- |
| **Text**       | `Static`, `Label`, `Digits`, `Pretty`, `Rule`, `Link`, `Tooltip`                                               |
| **Input**      | `Input`, `MaskedInput`, `TextArea`, `Checkbox`, `RadioButton`, `RadioSet`, `Switch`, `Select`, `SelectionList` |
| **Buttons**    | `Button`                                                                                                       |
| **Data**       | `DataTable`, `OptionList`, `ListView`, `ListItem`                                                              |
| **Trees**      | `Tree`, `DirectoryTree`                                                                                        |
| **Tabs**       | `Tabs`, `Tab`, `TabbedContent`, `TabPane`, `ContentSwitcher`                                                   |
| **Containers** | `Horizontal`, `Vertical`, `Grid`, `Center`, `Middle`, `ScrollableContainer`, `Collapsible`                     |
| **Feedback**   | `ProgressBar`, `LoadingIndicator`, `Sparkline`, `Log`, `RichLog`                                               |
| **Document**   | `Markdown`, `MarkdownViewer`                                                                                   |
| **Chrome**     | `Header`, `Footer`, `HelpPanel`, `KeyPanel`                                                                    |
| **Dev**        | `Placeholder`, `Welcome`                                                                                       |

### Custom Widget Example

```python
from textual.app import ComposeResult
from textual.reactive import reactive
from textual.widget import Widget
from textual.widgets import Label, ProgressBar, Static


class TaskItem(Widget):
    """A custom widget displaying a task with name, progress, and status."""

    DEFAULT_CSS = """
    TaskItem {
        layout: horizontal;
        height: 3;
        padding: 0 1;
        border: solid $primary;
        margin-bottom: 1;
    }
    TaskItem > .task-name {
        width: 20;
        content-align: left middle;
    }
    TaskItem > ProgressBar {
        width: 1fr;
    }
    TaskItem > .task-status {
        width: 12;
        content-align: center middle;
    }
    """

    progress = reactive(0.0)
    status = reactive("pending")

    def __init__(self, name: str, **kwargs) -> None:
        super().__init__(**kwargs)
        self.task_name = name

    def compose(self) -> ComposeResult:
        yield Label(self.task_name, classes="task-name")
        yield ProgressBar(total=100, show_eta=False)
        yield Static(self.status, classes="task-status")

    def watch_progress(self, value: float) -> None:
        self.query_one(ProgressBar).update(progress=value)

    def watch_status(self, value: str) -> None:
        self.query_one(".task-status", Static).update(value)
```

Key patterns:

- `DEFAULT_CSS` embeds component-scoped styles directly in the widget class.
- `compose()` declares the widget's child tree declaratively.
- `reactive` attributes automatically trigger `watch_` methods when changed.
- Child widgets are queried with CSS selectors via `self.query_one()`.

---

## Styling

### CSS System

Textual implements **TCSS** (Textual Cascading Style Sheets), a purpose-built CSS dialect for terminal UIs. Styles can be specified in three places, listed in increasing specificity:

1. **`DEFAULT_CSS`**: A class variable on widgets. Defines the widget's base styles. Lowest specificity.
2. **External `.tcss` files**: Referenced via `CSS_PATH` on the App class. Standard application-level styles.
3. **Inline styles**: Set via `widget.styles.background = "red"` or `widget.styles.css = "..."` in Python code. Highest specificity.

### Selectors

| Selector Type | Syntax                | Example                  |
| ------------- | --------------------- | ------------------------ |
| Type          | `WidgetName`          | `Button { ... }`         |
| ID            | `#id`                 | `#sidebar { ... }`       |
| Class         | `.class`              | `.active { ... }`        |
| Pseudo-class  | `:state`              | `Button:hover { ... }`   |
| Child         | `Parent > Child`      | `#main > Button { ... }` |
| Descendant    | `Ancestor Descendant` | `Screen Input { ... }`   |
| Universal     | `*`                   | `* { ... }`              |

Available pseudo-classes include `:hover`, `:focus`, `:disabled`, `:dark`, `:light`, `:blur`, and `:can-focus`.

### Supported Properties

| Category       | Properties                                                                                                                    |
| -------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| **Color**      | `color`, `background` (named, hex, RGB, HSL)                                                                                  |
| **Text**       | `text-style` (bold, italic, underline, strike, reverse), `text-align`, `text-opacity`                                         |
| **Border**     | `border` (ascii, solid, double, round, heavy, dashed, tall, wide, panel, etc.), `border-title-align`, `border-subtitle-align` |
| **Outline**    | `outline` (same types as border, does not affect layout)                                                                      |
| **Spacing**    | `margin`, `padding` (1-4 values)                                                                                              |
| **Size**       | `width`, `height`, `min-width`, `max-width`, `min-height`, `max-height`                                                       |
| **Layout**     | `layout`, `dock`, `overflow`, `box-sizing`                                                                                    |
| **Grid**       | `grid-size-columns`, `grid-size-rows`, `grid-columns`, `grid-rows`, `grid-gutter`                                             |
| **Display**    | `display`, `visibility`, `opacity`                                                                                            |
| **Position**   | `offset`, `offset-x`, `offset-y`                                                                                              |
| **Scroll**     | `scrollbar-color`, `scrollbar-background`, `scrollbar-size`                                                                   |
| **Transition** | `transition` (property, duration, easing)                                                                                     |

### Themes

Textual ships with built-in themes: `textual-dark`, `textual-light`, `nord`, `gruvbox`, `tokyo-night`, `solarized-light`, `atom-one-dark`, `atom-one-light`, and others. Themes define CSS variables (`$primary`, `$secondary`, `$accent`, `$surface`, `$error`, `$warning`, `$success`) and auto-generate light/dark shades (`$primary-lighten-1`, `$primary-darken-2`, etc.) and auto-contrast text colors (`$text`, `$text-muted`, `$text-disabled`).

Themes are switchable at runtime via the command palette or `self.theme = "nord"` in code.

### TCSS Example

```css
Screen {
  background: $surface;
}

#sidebar {
  width: 30;
  dock: left;
  background: $panel;
  border-right: tall $primary;
  transition: offset 400ms in_out_cubic;
}

#sidebar.-hidden {
  offset-x: -100%;
}

Button {
  margin: 1 2;
  min-width: 16;
  border: solid $primary;
  background: $primary;
  color: $text;
  text-style: bold;
}

Button:hover {
  background: $primary-lighten-1;
  border: solid $primary-lighten-2;
}

Button:focus {
  border: double $accent;
}

DataTable > .datatable--header {
  background: $primary-darken-1;
  text-style: bold;
  color: $text;
}

.error-text {
  color: $error;
  text-style: bold italic;
}
```

### Live CSS Editing

When running with `textual run --dev my_app.py`, changes to `.tcss` files are **hot-reloaded** instantly. The app refreshes without restarting, enabling rapid iterative design.

---

## Event Handling

### Message System

Events in Textual are **Message** objects that bubble up through the widget tree. Every widget, screen, and app can handle messages.

### Handler Naming Convention

Textual maps message classes to handler methods via naming convention:

```
on_<namespace>_<event_name>
```

For example:

- `Button.Pressed` maps to `on_button_pressed`
- `Input.Changed` maps to `on_input_changed`
- `Key` (no namespace) maps to `on_key`
- `Mount` maps to `on_mount`

### The `@on` Decorator

The `@on` decorator provides CSS-selector-based event dispatch, allowing fine-grained control over which widget's events a handler responds to:

```python
from textual import on
from textual.app import App, ComposeResult
from textual.widgets import Button, Header, Footer, Input, Static


class FormApp(App):
    CSS_PATH = "form.tcss"

    def compose(self) -> ComposeResult:
        yield Header()
        yield Input(placeholder="Enter your name", id="name-input")
        yield Input(placeholder="Enter your email", id="email-input")
        yield Static("", id="status")
        yield Button("Submit", id="submit", variant="primary")
        yield Button("Cancel", id="cancel", variant="error")
        yield Footer()

    @on(Button.Pressed, "#submit")
    def handle_submit(self, event: Button.Pressed) -> None:
        name = self.query_one("#name-input", Input).value
        email = self.query_one("#email-input", Input).value
        self.query_one("#status", Static).update(
            f"Submitted: {name} <{email}>"
        )

    @on(Button.Pressed, "#cancel")
    def handle_cancel(self, event: Button.Pressed) -> None:
        self.query_one("#name-input", Input).value = ""
        self.query_one("#email-input", Input).value = ""
        self.query_one("#status", Static).update("Cancelled.")

    @on(Input.Changed)
    def on_any_input_change(self, event: Input.Changed) -> None:
        self.query_one("#status", Static).update("")
```

Without `@on`, both button presses would route to a single `on_button_pressed` handler, requiring `if`/`elif` dispatch on `event.button.id`.

### Workers for Background Tasks

Long-running or I/O-bound operations must not block the async event loop. Textual provides **workers**:

```python
from textual.app import App
from textual.worker import Worker
from textual import work


class FetchApp(App):

    @work(exclusive=True)
    async def fetch_data(self, url: str) -> None:
        """Run in a background worker. exclusive=True cancels previous workers."""
        response = await some_http_client.get(url)
        self.query_one("#results").update(response.text)
```

Workers are tied to the DOM node that created them. If the widget is removed or the screen is popped, workers are automatically cancelled. The `exclusive=True` flag cancels any previous worker on the same method, preventing race conditions with stale responses.

### Timers

```python
def on_mount(self) -> None:
    self.set_interval(1.0, self.tick)

def tick(self) -> None:
    self.query_one("#clock", Static).update(str(datetime.now()))
```

### Key Bindings

```python
from textual.app import App
from textual.binding import Binding

class MyApp(App):
    BINDINGS = [
        Binding("q", "quit", "Quit"),
        Binding("d", "toggle_dark", "Toggle dark mode"),
        Binding("ctrl+s", "save", "Save"),
    ]

    def action_toggle_dark(self) -> None:
        self.dark = not self.dark
```

Bindings are searched from the focused widget upward through the DOM to the App. The `Footer` widget automatically displays active bindings.

---

## State Management

### Reactive Attributes

The `reactive` descriptor is the primary mechanism for state management. When a reactive attribute is assigned a new value, Textual automatically:

1. Calls the associated `watch_<name>` method (if defined).
2. Marks the widget as dirty for re-rendering.
3. Calls `render()` on the next frame to produce updated content.

```python
from textual.reactive import reactive
from textual.widget import Widget


class CounterWidget(Widget):
    count = reactive(0)

    def render(self) -> str:
        return f"Count: {self.count}"

    def watch_count(self, old_value: int, new_value: int) -> None:
        # Called whenever self.count changes
        if new_value > 10:
            self.add_class("high")
        else:
            self.remove_class("high")
```

Options on `reactive`:

- `reactive(default)` -- basic reactive attribute.
- `reactive(default, always_update=True)` -- fires the watcher even if the new value equals the old.
- `reactive(default, recompose=True)` -- re-runs `compose()` on change (rebuilds the sub-tree).
- `reactive(default, init=False)` -- skips calling the watcher on initial mount.

### Compute Methods

A method named `compute_<name>` lets Textual derive a reactive attribute's value from other state:

```python
class FullNameWidget(Widget):
    first_name = reactive("")
    last_name = reactive("")
    full_name = reactive("")

    def compute_full_name(self) -> str:
        return f"{self.first_name} {self.last_name}".strip()
```

`full_name` is automatically recomputed whenever `first_name` or `last_name` changes.

### Data Binding

`data_bind` propagates reactive attributes **downward** from parent to child widgets:

```python
from textual.app import App, ComposeResult
from textual.reactive import reactive
from textual.widget import Widget


class ClockApp(App):
    current_time = reactive("")

    def compose(self) -> ComposeResult:
        # Bind ClockApp.current_time -> ClockDisplay.current_time
        yield ClockDisplay().data_bind(ClockApp.current_time)


class ClockDisplay(Widget):
    current_time = reactive("")

    def render(self) -> str:
        return f"Time: {self.current_time}"
```

If the child attribute has a different name, keyword syntax is used: `data_bind(display_time=ClockApp.current_time)`.

Data binding is **unidirectional**: parent changes propagate to the child, but the child cannot update the parent through the binding. For child-to-parent communication, messages are used.

### Cross-Widget Communication via Messages

Custom messages allow structured communication up the DOM:

```python
from textual.message import Message


class TaskWidget(Widget):
    class Completed(Message):
        def __init__(self, task_id: str) -> None:
            super().__init__()
            self.task_id = task_id

    def mark_done(self) -> None:
        self.post_message(self.Completed(self.task_id))
```

A parent handles this with `on_task_widget_completed(self, event)`.

---

## Extensibility and Ecosystem

### Official Tools

| Package                   | Description                                                                          |
| ------------------------- | ------------------------------------------------------------------------------------ |
| `textual-dev`             | Developer tools: CSS live editing, dev console (`textual console`), widget inspector |
| `textual-web`             | Serve Textual apps in the browser via WebSocket protocol                             |
| `textual-serve`           | Local web server for Textual apps (`textual serve app.py`)                           |
| `textual-plotext`         | Plotting widget (line charts, bar charts, scatter plots via plotext)                 |
| `pytest-textual-snapshot` | SVG snapshot testing for visual regression detection                                 |

### Snapshot Testing

Textual provides first-class snapshot testing via `pytest-textual-snapshot`. Tests render the app to an SVG screenshot and compare against a stored baseline:

```python
def test_my_app(snap_compare):
    assert snap_compare("my_app.py")
```

Update snapshots with `pytest --snapshot-update`. This catches visual regressions that unit tests would miss.

### Developer Console

Running `textual console` in a separate terminal shows all events, messages, log output, and print statements from the running app -- essential because `print()` cannot write to stdout when the TUI owns the terminal.

### Command Palette

Every Textual app gets a built-in fuzzy-search command palette (Ctrl+P) that exposes theme switching, focus navigation, and user-defined commands. Apps extend it by providing `CommandProvider` classes.

### Community and Third-Party

The Textual ecosystem includes third-party widget libraries, community themes, and integrations. The project maintains an active Discord community and has been the subject of books (e.g., "Creating TUI Applications with Textual and Python", July 2025) and conference talks.

---

## Strengths

- **CSS familiarity lowers learning curve**: Developers with web experience can be productive immediately. The CSS-like syntax for layout, colors, borders, and spacing transfers directly.
- **Excellent documentation**: Comprehensive guides, API reference, tutorials, a widget gallery with live examples, and a blog with deep technical posts.
- **Hot-reloading CSS in dev mode**: `textual run --dev` watches `.tcss` files and applies changes instantly, enabling rapid visual iteration without restarting.
- **Rich widget library**: 40+ built-in widgets covering inputs, data display, navigation, documents, and layout containers. Most applications need no custom widgets.
- **Async-first architecture**: Built on asyncio, making it natural to handle network requests, file I/O, and concurrent tasks without blocking the UI.
- **Web deployment option**: The same app runs in a terminal or a browser via `textual-web` / `textual serve`, expanding distribution without code changes.
- **Snapshot testing**: SVG-based visual regression testing catches styling bugs that unit tests miss, promoting long-term maintainability.
- **Reactive state management**: `reactive` attributes, `watch_` methods, `compute_` methods, and `data_bind` provide a coherent, declarative state model with automatic UI updates.
- **Theme system**: Built-in themes with CSS variable propagation and runtime switching. Custom themes are simple Python objects.
- **Compositor with partial updates**: Only dirty regions are recomposed, enabling smooth performance even with complex widget trees.

---

## Weaknesses and Limitations

- **Python performance ceiling**: Python's interpreter overhead limits frame rates and widget counts. Complex UIs with thousands of cells (e.g., large DataTables) can feel sluggish compared to native TUI frameworks. The compositor and layout engine are written in Python, not C.
- **CSS subset can surprise web developers**: TCSS intentionally omits many CSS features (no flexbox `flex-grow`/`flex-shrink`, no `position: absolute/relative`, no `z-index`, limited selector combinators). Developers expecting full CSS often hit unexpected limitations.
- **Async complexity**: While powerful, the async-first design means that even simple apps must reason about the event loop. Blocking calls in handlers freeze the entire UI, and the worker/task model adds cognitive overhead.
- **Heavy runtime overhead**: Textual loads a full Python runtime, Rich rendering pipeline, CSS parser, layout engine, and compositor. Startup time is noticeable (hundreds of milliseconds to seconds), and memory usage is substantially higher than C/Rust/Go TUI frameworks.
- **Limited to Python ecosystem**: Cannot be embedded in applications written in other languages. No FFI-friendly C API. The framework is deeply tied to Python's object model, asyncio, and Rich.
- **No GPU acceleration or image protocol**: Rendering is purely text-based (Rich Segments). No support for Kitty graphics protocol, Sixel, or iTerm2 inline images at the framework level.
- **Web driver maturity**: `textual-web` is still in beta. Sessions are not persistent (closing the tab kills the app), and latency over the network can degrade interactivity.

---

## Lessons for D / Sparkles

Textual demonstrates that web-inspired patterns can make TUI development dramatically more accessible. Several of its design choices map well to D's strengths:

### CSS System -> Compile-Time CSS DSL via CTFE

Textual parses `.tcss` files at runtime. D could parse a CSS-like DSL **at compile time** via CTFE, catching syntax errors, invalid property names, and type mismatches before the program runs. The parsed result would be a static data structure embedded in the binary -- zero runtime parsing cost, zero allocation.

```d
// Hypothetical: compile-time CSS parsing
enum style = tcss!`
    #sidebar {
        width: 30;
        dock: left;
        border: solid blue;
    }
`;
static assert(style.rules[0].selector == "#sidebar");
```

### Widget Compose Pattern -> Template Mixins for Declarative Trees

Textual's `compose()` method yields child widgets to build a tree. D's template mixins could provide a similar declarative syntax with compile-time validation of the widget tree structure:

```d
// Hypothetical: mixin-based widget composition
mixin App!q{
    Header()
    Horizontal(id: "main") {
        Tree(id: "sidebar")
        Vertical(id: "content") {
            TextArea(id: "editor")
            LogView(id: "output")
        }
    }
    Footer()
};
```

### Reactive Attributes -> `opDispatch` or Property Introspection

Textual's `reactive` descriptor intercepts attribute writes to trigger watchers and refresh. D's `opDispatch`, `alias this`, or compile-time introspection via `__traits` could implement the same pattern without runtime descriptor overhead:

```d
// Hypothetical: reactive properties via introspection
struct Counter {
    mixin Reactive!(int, "count", 0);  // generates getter, setter, watcher hook

    void watchCount(int oldVal, int newVal) {
        if (newVal > 10) addClass("high");
    }
}
```

### Message Passing -> `std.concurrency` or Event Ranges

Textual's message bubbling maps to D's `std.concurrency` message passing for thread-safe communication, or to lazy input ranges of event objects for `@nogc`-compatible event processing:

```d
// Event processing as a range pipeline
events
    .filter!(e => e.type == EventType.buttonPressed)
    .filter!(e => e.target.id == "submit")
    .each!(e => handleSubmit(e));
```

### TCSS Files -> Compile-Time Embedded CSS Validation

Rather than loading and parsing `.tcss` files at runtime (as Textual does), D could use `import(...)` expressions to embed the file at compile time and validate it via CTFE. Invalid selectors, unknown properties, or type errors would be caught at compile time.

### Widget Rendering -> Output Ranges for `@nogc` Rendering

Textual widgets produce Rich `Segment` objects (text + style tuples). D widgets could render to output ranges, enabling `@nogc nothrow` rendering into `SmallBuffer` or directly to a terminal write buffer with zero heap allocation:

```d
@safe pure nothrow @nogc
void render(Writer)(ref Writer writer, in Style style) {
    writer.put(style.applyTo("Count: "));
    writer.putInt(count);
}
```

### Retained Mode with Dirty Tracking -> `@nogc` Diffing Buffers

Textual's compositor diffs visible regions and only repaints changed areas. D could implement a double-buffered screen model where the current and previous frames are `SmallBuffer`-backed cell grids. A `@nogc` diff pass identifies changed cells and emits only the minimal escape sequences needed, combining retained-mode convenience with `@nogc` performance.

---

## References

### Official Documentation

- [Textual Documentation](https://textual.textualize.io/) -- comprehensive guides, API reference, widget gallery
- [Textual GitHub Repository](https://github.com/Textualize/textual) -- source code, issues, discussions
- [textual-web Repository](https://github.com/Textualize/textual-web) -- browser rendering for Textual apps
- [pytest-textual-snapshot](https://github.com/Textualize/pytest-textual-snapshot) -- snapshot testing plugin
- [Textual on PyPI](https://pypi.org/project/textual/) -- package releases and version history

### Blog Posts and Articles

- [Anatomy of a Textual User Interface](https://textual.textualize.io/blog/2024/09/15/anatomy-of-a-textual-user-interface/) -- deep dive into architecture and rendering pipeline
- [Algorithms for High Performance Terminal Apps](https://textual.textualize.io/blog/2024/12/12/algorithms-for-high-performance-terminal-apps/) -- compositor algorithms, cuts, chops, and partial updates
- [CSS in the Terminal with Python and Textual](https://www.willmcgugan.com/blog/tech/post/css-in-the-terminal-with-python-and-textual/) -- Will McGugan on the CSS design decisions
- [Python Textual: Build Beautiful UIs in the Terminal](https://realpython.com/python-textual/) -- Real Python tutorial
- [Textual: a framework for terminal user interfaces](https://lwn.net/Articles/929123/) -- LWN.net technical overview

### Talks and Interviews

- [SE Radio 669: Will McGugan on Text-Based User Interfaces](https://se-radio.net/2025/05/se-radio-669-will-mcgugan-on-text-based-user-interfaces/) -- Software Engineering Radio interview (May 2025)

### Books

- _Creating TUI Applications with Textual and Python_ (July 2025) -- comprehensive book on Textual application development

---

## Markdown References

[textual-widget]: https://textual.textualize.io/api/widgets/
[textual-app]: https://textual.textualize.io/api/app/
[textual-screen]: https://textual.textualize.io/api/screen/
[textual-css]: https://textual.textualize.io/guide/CSS/
[textual-reactive]: https://textual.textualize.io/guide/reactive/
[textual-messages]: https://textual.textualize.io/guide/message_pump/
[textual-containers]: https://textual.textualize.io/api/containers/
