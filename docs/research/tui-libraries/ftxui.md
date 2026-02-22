# FTXUI (C++)

A C++ library for building functional terminal user interfaces through declarative Element trees, a flexbox-inspired layout engine, and a dual-layer architecture separating pure rendering from interactive stateful components.

| Field          | Value                                     |
| -------------- | ----------------------------------------- |
| Language       | C++17                                     |
| License        | MIT                                       |
| Repository     | <https://github.com/ArthurSonzogni/FTXUI> |
| Documentation  | <https://arthursonzogni.github.io/FTXUI/> |
| Latest Version | ~6.1.9 (May 2025)                         |
| GitHub Stars   | ~9.6k                                     |

---

## Overview

FTXUI is a C++ library for building terminal user interfaces using a functional,
declarative approach inspired by React and the browser DOM. It targets a problem space
that most C++ TUI libraries (ncurses, notcurses) address with imperative, stateful APIs:
FTXUI instead models the UI as a tree of immutable value-like [`Element`][ftxui-element] nodes
constructed by composing pure functions, then rendered to a [`Screen`][ftxui-screen] each frame.

**What it solves.** Building terminal UIs in C++ traditionally means managing raw ANSI
sequences, stateful cursor positioning, and complex widget hierarchies with manual
invalidation. FTXUI replaces all of this with a functional composition model: you
construct an Element tree from functions like `text`, `hbox`, `vbox`, `border`, and
`gauge`, hand it to a [`Screen`][ftxui-screen], and the library handles layout computation, diffing,
and terminal output. The programmer never manages cursor state or escape codes directly.

**Design philosophy.** FTXUI has two distinct layers by design:

1. **Dom layer** -- Pure functional. Elements are values created by calling functions.
   An Element tree is built each frame, laid out by a constraint solver, and rendered to
   a Screen. There is no mutation, no retained state, no callbacks. This is the
   immediate-mode rendering layer.

2. **Component layer** -- Retained-mode. Components wrap Elements with event handling
   and mutable state. A [`Component`][ftxui-component] produces an Element tree via its `Render()` method,
   handles keyboard/mouse events via `OnEvent()`, and participates in a focus tree.
   The [`ScreenInteractive`][ftxui-screen-interactive] class drives the event loop.

This separation means you can use the dom layer alone for static output (dashboards,
progress displays, formatted reports) without ever touching the component layer. When
interactivity is needed, the component layer adds the minimum necessary statefulness.

**History.** FTXUI was created by Arthur Sonzogni and has been under active development
since 2019. It has grown to 9,600+ GitHub stars with 800+ commits. The library is
notable for having no external dependencies beyond the C++ standard library, supporting
C++20 modules, and compiling to WebAssembly via Emscripten -- enabling live interactive
demos in the browser. It works on Linux, macOS, Windows, and WebAssembly.

---

## Architecture

### Two-Tier Architecture

FTXUI's architecture separates concerns into two composable layers:

```
                    Component Layer (retained, stateful)
                    +-----------------------------------------+
                    | ScreenInteractive event loop            |
                    |   Component tree (shared_ptr)           |
                    |     Render() -> Element                 |
                    |     OnEvent(Event) -> bool              |
                    |     Focus management                    |
                    +-----------------------------------------+
                              |  calls Render() each frame
                              v
                    Dom Layer (pure, functional)
                    +-----------------------------------------+
                    | Element tree (shared_ptr<Node>)          |
                    |   text, hbox, vbox, border, gauge, ...  |
                    |   ComputeRequirement() -> up            |
                    |   SetBox() -> down                      |
                    |   Render(Screen) -> pixels               |
                    +-----------------------------------------+
                              |
                              v
                    Screen (pixel grid)
                    +-----------------------------------------+
                    | Pixel[dimx][dimy]                        |
                    | ToString() -> ANSI escape sequences      |
                    | Print() -> stdout                        |
                    +-----------------------------------------+
```

### Dom Layer: Pure Functional Elements

The dom layer is the foundation. An `Element` is a `std::shared_ptr<Node>`, where `Node`
is a base class with three key virtual methods:

- **`ComputeRequirement()`** -- Bottom-up pass. Each node computes its minimum/preferred
  size based on its children. Propagated from leaves to root.
- **`SetBox(Box)`** -- Top-down pass. The parent assigns each child its final bounding
  box based on available space and the child's requirements. Propagated from root to
  leaves.
- **`Render(Screen&)`** -- Each node writes its content into the Screen's pixel grid.

Element trees are constructed by calling functions that return `Element`:

```cpp
Element document = vbox({
    hbox({
        text("Name:") | bold,
        text(" Arthur") | color(Color::Cyan),
    }),
    separator(),
    hbox({
        gauge(0.7) | flex | color(Color::Green),
    }),
}) | border;
```

Every call creates a new node. There is no mutation: you build a new tree each frame.
The functions are pure in the sense that they take values and return values -- the
returned Element is a self-contained description of what to render. This is analogous
to React's virtual DOM or Elm's view function.

### Component Layer: Retained-Mode Interactivity

The component layer adds state and event handling on top of the dom layer. A `Component`
is a `std::shared_ptr<ComponentBase>`, where `ComponentBase` provides:

- **`Element Render()`** / **`Element OnRender()`** -- Returns an Element tree describing
  the component's current visual state.
- **`bool OnEvent(Event)`** -- Handles a keyboard or mouse event. Returns `true` if the
  event was consumed.
- **`void OnAnimation(animation::Params&)`** -- Handles animation ticks.
- **`Component ActiveChild()`** -- Focus tree management.
- **`void Add(Component)`** / **`Component& ChildAt(size_t)`** -- Child component hierarchy.

The `ScreenInteractive` class manages the event loop:

```cpp
auto screen = ScreenInteractive::Fullscreen();
screen.Loop(component);  // blocks, runs event loop
```

Each iteration of the loop: (1) polls for events, (2) dispatches events to the component
tree via `OnEvent()`, (3) calls `Render()` on the root component to get an Element tree,
(4) lays out and renders the Element tree to the screen buffer, (5) diffs against the
previous frame and flushes changes to the terminal.

### How the Layers Compose

Components produce Elements. The framework calls `Render()` on the root Component each
frame, receives an Element tree, and passes it through the dom layer's layout and
rendering pipeline. This means:

- A Component's `Render()` method is a pure function from state to Element tree.
- The dom layer knows nothing about Components, events, or state.
- Components can freely mix hand-built Element trees with factory-created child Components.

This is a clean separation: the dom layer is a pure functional rendering engine, and the
component layer is a thin stateful shell around it.

---

## Terminal Backend

### Screen

The `Screen` class (inheriting from `Image`) is a 2D grid of `Pixel` cells. Each Pixel
holds a character (UTF-8), foreground/background colors, and style attributes (bold, dim,
underlined, etc.).

Factory methods:

- `Screen::Create(Dimension::Full())` -- Full terminal size.
- `Screen::Create(Dimension::Fixed(width), Dimension::Fixed(height))` -- Explicit size.

Key methods:

- `ToString()` -- Converts the pixel grid to a string of ANSI escape sequences.
- `Print()` -- Writes to stdout.
- `Clear()` -- Resets all pixels.
- `ResetPosition()` -- Returns a string that moves the cursor back to the origin, enabling
  in-place animation without clearing the screen.
- `RegisterHyperlink(link)` -- Registers an OSC 8 hyperlink, returns an ID for pixels.

### ScreenInteractive

`ScreenInteractive` extends `Screen` with an event loop for interactive applications:

- **`Fullscreen()`** -- Uses the alternate screen buffer, full terminal.
- **`FullscreenAlternateScreen()`** / **`FullscreenPrimaryScreen()`** -- Explicit screen
  buffer selection.
- **`FitComponent()`** -- Sizes the screen to fit the rendered component.
- **`TerminalOutput()`** -- Output-only mode, no alternate screen.
- **`FixedSize(dimx, dimy)`** -- Fixed dimensions.

Loop control:

- `Loop(component)` -- Blocks, runs the event loop.
- `Exit()` / `ExitLoopClosure()` -- Signals loop termination.
- `Post(task)` -- Queues a task for execution on the event loop thread.
- `PostEvent(event)` -- Injects a synthetic event.
- `RequestAnimationFrame()` -- Triggers a redraw on the next frame.
- `TrackMouse(bool)` -- Enables/disables mouse tracking.
- `ForceHandleCtrlC(bool)` / `ForceHandleCtrlZ(bool)` -- Signal handling control.

### Color Support

The `Color` class supports four tiers:

- **Palette1** -- Default/transparent.
- **Palette16** -- Standard 16 ANSI colors: `Color::Red`, `Color::Blue`, `Color::GrayDark`,
  `Color::CyanLight`, etc.
- **Palette256** -- Extended 256-color palette via `Color(Color::Palette256(index))`.
- **TrueColor** -- 24-bit RGB via `Color(r, g, b)` or `Color::RGB(r, g, b)`.
- **HSV** -- `Color::HSV(hue, saturation, value)` for hue-based color specification.
- **Alpha blending** -- `Color::RGBA(r, g, b, a)`, `Color::Blend(a, b)`,
  `Color::Interpolate(t, a, b)`.

The library detects terminal color capabilities at runtime and degrades gracefully.

### Platform Support

- **Linux/macOS** -- Primary targets. Full feature set.
- **Windows** -- Community-supported. Uses the Windows Console API.
- **WebAssembly** -- Via Emscripten. Renders to an HTML `<pre>` element, enabling live
  interactive demos in the browser. Mouse and keyboard events are translated from DOM
  events.

---

## Layout System

The layout system is one of FTXUI's most distinctive features. It implements a
**flexbox-inspired** model directly in the terminal, bringing CSS-like layout semantics
to character-grid rendering.

### Box Composition

The three fundamental layout primitives compose child Elements along an axis:

```cpp
// Horizontal: children laid out left to right
hbox({child1, child2, child3})

// Vertical: children laid out top to bottom
vbox({child1, child2, child3})

// Depth: children stacked on top of each other (last painted on top)
dbox({background, foreground})
```

### Grid Layout

`gridbox` arranges children in a 2D grid:

```cpp
gridbox({
    {text("R1C1"), text("R1C2"), text("R1C3")},
    {text("R2C1"), text("R2C2"), text("R2C3")},
})
```

### Flexbox Layout

`flexbox` provides full CSS Flexbox semantics with `FlexboxConfig`:

```cpp
FlexboxConfig config;
config.direction = FlexboxConfig::Direction::Row;
config.wrap = FlexboxConfig::Wrap::Wrap;
config.justify_content = FlexboxConfig::JustifyContent::SpaceEvenly;
config.align_items = FlexboxConfig::AlignItems::Center;
config.align_content = FlexboxConfig::AlignContent::SpaceBetween;
config.gap_x = 1;
config.gap_y = 0;

flexbox(children, config);
```

FlexboxConfig options:

| Property          | Values                                                                                    |
| ----------------- | ----------------------------------------------------------------------------------------- |
| `direction`       | `Row`, `RowInversed`, `Column`, `ColumnInversed`                                          |
| `wrap`            | `NoWrap`, `Wrap`, `WrapInversed`                                                          |
| `justify_content` | `FlexStart`, `FlexEnd`, `Center`, `Stretch`, `SpaceBetween`, `SpaceAround`, `SpaceEvenly` |
| `align_items`     | `FlexStart`, `FlexEnd`, `Center`, `Stretch`                                               |
| `align_content`   | `FlexStart`, `FlexEnd`, `Center`, `Stretch`, `SpaceBetween`, `SpaceAround`, `SpaceEvenly` |
| `gap_x`, `gap_y`  | Integer gap between items                                                                 |

### Flex Decorators

Flex decorators control how children grow and shrink within `hbox`/`vbox`:

```cpp
hbox({
    text("fixed"),
    text("grows") | flex,           // Takes remaining space
    text("fixed"),
})

hbox({
    text("a") | flex_grow,          // Grows to fill
    text("b") | flex_shrink,        // Shrinks if needed
})
```

Directional variants:

- `xflex`, `yflex` -- Flex in X or Y direction only.
- `xflex_grow`, `yflex_grow` -- Grow in X or Y only.
- `xflex_shrink`, `yflex_shrink` -- Shrink in X or Y only.

### Size Constraints

Explicit size constraints use the `size()` decorator:

```cpp
text("constrained") | size(WIDTH, EQUAL, 30)
text("minimum")     | size(HEIGHT, GREATER_THAN, 5)
text("maximum")     | size(WIDTH, LESS_THAN, 50)
```

The `WidthOrHeight` enum selects the axis (`WIDTH`, `HEIGHT`), and the `Constraint` enum
selects the relation (`EQUAL`, `GREATER_THAN`, `LESS_THAN`).

### Centering and Alignment

```cpp
text("centered") | center     // Both axes
text("h-center") | hcenter    // Horizontal only
text("v-center") | vcenter    // Vertical only
```

The `filler()` element expands to fill available space, useful for manual alignment:

```cpp
hbox({text("left"), filler(), text("right")})
```

### Non-Trivial Layout Example: Multi-Panel Dashboard

```cpp
#include <ftxui/dom/elements.hpp>
#include <ftxui/screen/screen.hpp>
#include <ftxui/dom/node.hpp>

using namespace ftxui;

int main() {
    // Left sidebar: vertical stack of labeled sections
    auto sidebar = vbox({
        text("Navigation") | bold | hcenter,
        separator(),
        text(" > Dashboard"),
        text("   Settings"),
        text("   Logs"),
        filler(),
        text("v2.1.0") | dim | hcenter,
    }) | size(WIDTH, EQUAL, 20) | border;

    // Top-right: metrics row
    auto metric = [](std::string label, float value, Color c) {
        return vbox({
            text(label) | bold | hcenter,
            gauge(value) | color(c),
        }) | flex | border;
    };

    auto metrics = hbox({
        metric("CPU", 0.73, Color::Green),
        metric("RAM", 0.58, Color::Yellow),
        metric("Disk", 0.91, Color::Red),
    });

    // Bottom-right: log area
    auto logs = vbox({
        text("Recent Logs") | bold,
        separator(),
        text("[12:01] Service started"),
        text("[12:03] Connection established"),
        text("[12:05] Processing 1,247 records"),
        text("[12:06] Checkpoint saved"),
        filler(),
    }) | flex | border;

    // Compose: sidebar | (metrics / logs)
    auto document = hbox({
        sidebar,
        vbox({
            metrics,
            logs,
        }) | flex,
    });

    auto screen = Screen::Create(Dimension::Full());
    Render(screen, document);
    screen.Print();
}
```

This produces a layout like:

```
+--------------------+-------------------+------------------+------------------+
|    Navigation      |       CPU         |       RAM        |       Disk       |
|--------------------| ########===       | ######===        | ################ |
| > Dashboard        +-------------------+------------------+------------------+
|   Settings         | Recent Logs                                             |
|   Logs             |--------------------------------------------------------|
|                    | [12:01] Service started                                |
|                    | [12:03] Connection established                         |
|                    | [12:05] Processing 1,247 records                       |
|                    | [12:06] Checkpoint saved                               |
|       v2.1.0       |                                                        |
+--------------------+--------------------------------------------------------+
```

The key points: `flex` makes the right panel grow to fill remaining space. `size(WIDTH,
EQUAL, 20)` fixes the sidebar width. `hbox` and `vbox` nest freely. `border` wraps any
Element. The entire layout is a single expression -- a tree of function calls.

---

## Widget / Component System

### Elements (Dom Layer)

Elements are the pure, functional building blocks. Every element is created by a function
call that returns `Element` (`std::shared_ptr<Node>`).

**Text and Content:**

| Function                                  | Description                            |
| ----------------------------------------- | -------------------------------------- |
| `text(str)`                               | Single-line text                       |
| `vtext(str)`                              | Vertical text (one character per line) |
| `paragraph(str)`                          | Word-wrapping paragraph                |
| `paragraphAlignLeft/Center/Right/Justify` | Aligned paragraphs                     |

**Layout:**

| Function                                | Description                  |
| --------------------------------------- | ---------------------------- |
| `hbox({...})`                           | Horizontal composition       |
| `vbox({...})`                           | Vertical composition         |
| `dbox({...})`                           | Depth composition (stacking) |
| <code v-pre>gridbox({{...},...})</code> | 2D grid layout               |
| `flexbox({...}, config)`                | CSS Flexbox layout           |

**Decorators (visual):**

| Function                 | Description                    |
| ------------------------ | ------------------------------ |
| `bold(elem)`             | Bold text                      |
| `dim(elem)`              | Dimmed/faint text              |
| `italic(elem)`           | Italic text                    |
| `underlined(elem)`       | Underlined text                |
| `underlinedDouble(elem)` | Double underline               |
| `strikethrough(elem)`    | Strikethrough text             |
| `blink(elem)`            | Blinking text                  |
| `inverted(elem)`         | Inverted foreground/background |
| `hyperlink(url, elem)`   | OSC 8 hyperlink                |

**Color:**

| Function                        | Description         |
| ------------------------------- | ------------------- |
| `color(Color, elem)`            | Foreground color    |
| `bgcolor(Color, elem)`          | Background color    |
| `color(LinearGradient, elem)`   | Gradient foreground |
| `bgcolor(LinearGradient, elem)` | Gradient background |

**Borders and Separators:**

| Function                                                      | Description                               |
| ------------------------------------------------------------- | ----------------------------------------- |
| `border(elem)`                                                | Default border (light)                    |
| `borderLight(elem)`                                           | Light border style                        |
| `borderDashed(elem)`                                          | Dashed border style                       |
| `borderHeavy(elem)`                                           | Heavy/thick border style                  |
| `borderDouble(elem)`                                          | Double-line border style                  |
| `borderRounded(elem)`                                         | Rounded corner border style               |
| `borderEmpty(elem)`                                           | Empty border (padding only)               |
| `separator()`                                                 | Horizontal/vertical line between siblings |
| `separatorLight()` / `separatorHeavy()` / `separatorDouble()` | Styled separators                         |
| `window(title, elem)`                                         | Bordered element with a title             |

**Progress and Data Visualization:**

| Function               | Description                              |
| ---------------------- | ---------------------------------------- |
| `gauge(float)`         | Horizontal progress bar (0.0 - 1.0)      |
| `gaugeUp(float)`       | Vertical gauge (bottom to top)           |
| `gaugeDown(float)`     | Vertical gauge (top to bottom)           |
| `gaugeRight(float)`    | Horizontal gauge (left to right)         |
| `gaugeLeft(float)`     | Horizontal gauge (right to left)         |
| `spinner(int, size_t)` | Animated spinner (22 built-in styles)    |
| `graph(GraphFunction)` | Line graph from a function               |
| `canvas(lambda)`       | Freeform canvas with braille/block chars |

**Scroll and Frame:**

| Function                        | Description                        |
| ------------------------------- | ---------------------------------- |
| `frame(elem)`                   | Scrollable frame                   |
| `xframe(elem)` / `yframe(elem)` | Directional scrollable frame       |
| `focus(elem)`                   | Frame that focuses on this element |
| `select(elem)`                  | Frame that selects this element    |
| `vscroll_indicator`             | Vertical scroll indicator          |
| `hscroll_indicator`             | Horizontal scroll indicator        |

**Sizing and Flex:**

| Function                        | Description                    |
| ------------------------------- | ------------------------------ |
| `flex(elem)`                    | Grow and shrink to fill        |
| `flex_grow(elem)`               | Grow to fill, do not shrink    |
| `flex_shrink(elem)`             | Shrink if needed, do not grow  |
| `xflex(elem)` / `yflex(elem)`   | Directional flex               |
| `size(axis, constraint, value)` | Explicit size constraint       |
| `filler()`                      | Empty element that fills space |

### Composability: Elements as Function Calls

The critical design pattern is that **every element is a function call**, and elements
compose by nesting function calls:

```cpp
// Nesting: the return value of one function is an argument to another
auto ui = border(
    vbox({
        hbox({
            text("Name:") | bold,
            separator(),
            text("Arthur") | color(Color::Cyan),
        }),
        separator(),
        hbox({
            text("Status:") | bold,
            separator(),
            gauge(0.85) | flex | color(Color::Green),
        }),
    })
);
```

Or equivalently, using the **pipe operator** `|` for decorators:

```cpp
auto ui = vbox({
    hbox({
        text("Name:") | bold,
        separator(),
        text("Arthur") | color(Color::Cyan),
    }),
    separator(),
    hbox({
        text("Status:") | bold,
        separator(),
        gauge(0.85) | flex | color(Color::Green),
    }),
}) | border;
```

The pipe operator is defined as:

```cpp
Element operator|(Element element, Decorator decorator) {
    return decorator(std::move(element));
}
```

This means `elem | bold` is exactly `bold(elem)`, and decorators chain left-to-right:
`text("hi") | bold | color(Color::Red)` reads as "text, then bold, then red".

### Components (Interactive Layer)

Components are created via factory functions that return `Component`
(`std::shared_ptr<ComponentBase>`):

| Factory Function                        | Description                        |
| --------------------------------------- | ---------------------------------- |
| `Button(label, callback)`               | Clickable button with callback     |
| `Checkbox(label, &bool)`                | Toggle with label, bound to a bool |
| `Radiobox(entries, &selected)`          | Single selection from a list       |
| `Input(&str, placeholder)`              | Text input field                   |
| `Menu(entries, &selected)`              | Navigable menu                     |
| `Dropdown(config)`                      | Collapsible dropdown selector      |
| `Toggle(entries, &selected)`            | Horizontal toggle switch           |
| `Slider(label, &value, min, max, step)` | Numeric slider                     |

**Container components** group children and manage focus:

```cpp
auto container = Container::Vertical({
    input_name,
    input_email,
    button_submit,
});

auto container = Container::Horizontal({
    menu,
    content_panel,
});

auto container = Container::Tab({
    tab1_content,
    tab2_content,
    tab3_content,
}, &selected_tab);
```

**Decorator components** add behavior to existing components:

| Decorator                                | Description                                       |
| ---------------------------------------- | ------------------------------------------------- |
| `Renderer(component, fn)`                | Overrides the Render() of a component             |
| `Renderer(fn)`                           | Creates a non-interactive component from a lambda |
| `CatchEvent(component, fn)`              | Intercepts events before the component sees them  |
| `Maybe(component, &bool)`                | Conditionally shows/hides a component             |
| `Modal(main, modal, &show)`              | Overlay modal dialog                              |
| `Hoverable(component, &hovered)`         | Tracks mouse hover state                          |
| `Collapsible(label, content)`            | Expandable/collapsible section                    |
| `ResizableSplitLeft(left, right, &size)` | Draggable split pane                              |

### Custom Components

For complex interactive elements, subclass `ComponentBase`:

```cpp
class MyComponent : public ComponentBase {
public:
    MyComponent(std::string& name, int& counter)
        : name_(name), counter_(counter) {}

    Element OnRender() override {
        return vbox({
            text("Name: " + name_) | bold,
            text("Count: " + std::to_string(counter_)),
            gauge(counter_ / 100.0f) | color(Color::Cyan),
        }) | border;
    }

    bool OnEvent(Event event) override {
        if (event == Event::Character('+')) {
            counter_++;
            return true;
        }
        if (event == Event::Character('-')) {
            counter_--;
            return true;
        }
        return false;
    }

private:
    std::string& name_;
    int& counter_;
};

// Usage:
auto component = Make<MyComponent>(name, counter);
```

For simpler cases, `Renderer` avoids the need for a subclass:

```cpp
auto component = Renderer([&] {
    return vbox({
        text("Hello " + name) | bold,
        separator(),
        gauge(progress) | color(Color::Green),
    }) | border;
});
```

---

## Styling

### Decorator-Based Styling

Styling in FTXUI is applied through decorators -- functions that wrap an Element with
visual attributes. Decorators can be applied in two equivalent ways:

```cpp
// Function call syntax
bold(color(Color::Blue, text("hello")))

// Pipe operator syntax (preferred -- reads left to right)
text("hello") | color(Color::Blue) | bold
```

Both produce the same Element tree. The pipe operator version is idiomatic FTXUI.

### Color Application

```cpp
// Foreground color
text("error") | color(Color::Red)

// Background color
text("highlight") | bgcolor(Color::Yellow)

// TrueColor RGB
text("custom") | color(Color(135, 206, 235))  // sky blue
text("custom") | color(Color::RGB(135, 206, 235))

// HSV color
text("hue") | color(Color::HSV(180, 255, 255))  // cyan via HSV

// Palette256
text("extended") | color(Color(Color::Palette256(208)))  // orange
```

### Linear Gradients

Gradients can be applied to both foreground and background:

```cpp
// Simple two-color gradient
text("gradient") | color(LinearGradient(Color::Red, Color::Blue))

// Angled gradient with multiple stops
auto gradient = LinearGradient()
    .Angle(45)
    .Stop(Color::Red, 0.0)
    .Stop(Color::Yellow, 0.5)
    .Stop(Color::Green, 1.0);

text("rainbow") | color(gradient)
text("bg-grad") | bgcolor(LinearGradient(Color::Blue, Color::Cyan))
```

### Combining Decorators

Decorators compose freely via the pipe operator:

```cpp
auto styled = text("Important!")
    | bold
    | underlined
    | color(Color::Red)
    | bgcolor(Color::GrayDark)
    | border;
```

The order matters for nesting: `border` wraps the colored text, not the other way around.
Colors and attributes are applied to the innermost element and propagate to its content.

### Border Styles

```cpp
auto content = text("content");

content | border            // Light (default)
content | borderLight       // Thin lines
content | borderDashed      // Dashed lines
content | borderHeavy       // Thick lines
content | borderDouble      // Double lines
content | borderRounded     // Rounded corners
content | borderEmpty       // Padding only, no visible border
```

---

## Event Handling

### Event Types

The `Event` struct represents terminal input. Events are created via static factory
methods:

```cpp
// Character events
Event::Character('a')
Event::Character("a")

// Special keys
Event::ArrowUp, Event::ArrowDown, Event::ArrowLeft, Event::ArrowRight
Event::Return, Event::Escape, Event::Tab, Event::TabReverse
Event::Backspace, Event::Delete, Event::Insert
Event::Home, Event::End, Event::PageUp, Event::PageDown
Event::F1 ... Event::F12

// Modifiers: Ctrl, Alt, CtrlAlt variants for each letter
Event::CtrlA, Event::AltA, Event::CtrlAltA
Event::CtrlC, Event::CtrlZ  // (can be intercepted)

// Mouse events
Event::Mouse(...)  // with button, motion type, coordinates
```

Event introspection:

```cpp
event.is_character()    // printable character input
event.is_mouse()        // mouse event
event.character()       // returns the UTF-8 character string
event.mouse()           // returns mouse data (button, motion, x, y)
```

### Handling Events in Components

The `OnEvent(Event)` method returns `true` if the event was consumed:

```cpp
class MyWidget : public ComponentBase {
    bool OnEvent(Event event) override {
        if (event == Event::Character('q')) {
            // Handle 'q' key
            return true;  // consumed
        }
        if (event.is_mouse()) {
            auto& mouse = event.mouse();
            if (mouse.button == Mouse::Left &&
                mouse.motion == Mouse::Pressed) {
                // Handle click at (mouse.x, mouse.y)
                return true;
            }
        }
        // Pass to children
        return ComponentBase::OnEvent(event);
    }
};
```

### CatchEvent Decorator

`CatchEvent` intercepts events before they reach a component:

```cpp
auto input = Input(&text, "placeholder");

// Filter: only allow digits
input |= CatchEvent([](Event event) {
    return event.is_character() && !std::isdigit(event.character()[0]);
});

// Intercept Enter key
auto component = CatchEvent(inner_component, [&](Event event) {
    if (event == Event::Return) {
        submit();
        return true;
    }
    return false;
});
```

### Event Propagation

Events propagate through the component tree:

1. The root component receives the event.
2. If the root has an active child (focus), the event is forwarded to it.
3. The active child may forward to its own active child (recursive).
4. The deepest focused component handles the event first.
5. If it returns `false` (not consumed), the event bubbles back up.

This is similar to DOM event bubbling in web browsers.

---

## State Management

FTXUI does not impose a state management framework. State is managed by the application
through three common patterns:

### Pattern 1: Lambda Capture (Most Common)

State lives in `main()` (or any enclosing scope) and is captured by reference in
component factory calls and lambdas:

```cpp
int main() {
    // State
    std::string name;
    std::string password;
    int counter = 0;
    bool show_modal = false;

    // Components capture state by reference
    auto input_name = Input(&name, "Enter name");
    auto input_pass = Input(&password, "password");
    auto btn = Button("Increment", [&] { counter++; });

    auto renderer = Renderer(
        Container::Vertical({input_name, input_pass, btn}),
        [&] {
            return vbox({
                text("Name: " + name),
                text("Count: " + std::to_string(counter)),
                separator(),
                input_name->Render(),
                input_pass->Render(),
                btn->Render(),
            }) | border;
        }
    );

    auto screen = ScreenInteractive::FitComponent();
    screen.Loop(renderer);
}
```

This pattern works because `ScreenInteractive::Loop()` blocks, so the captured references
remain valid for the lifetime of the event loop.

### Pattern 2: ComponentBase Subclass

State lives as member variables of a custom `ComponentBase` subclass:

```cpp
class FormComponent : public ComponentBase {
    std::string name_;
    std::string email_;
    bool submitted_ = false;

    Component input_name_ = Input(&name_, "name");
    Component input_email_ = Input(&email_, "email");
    Component submit_ = Button("Submit", [this] { submitted_ = true; });

public:
    FormComponent() {
        Add(Container::Vertical({input_name_, input_email_, submit_}));
    }

    Element OnRender() override {
        if (submitted_) {
            return text("Submitted: " + name_ + " <" + email_ + ">") | border;
        }
        return vbox({
            text("Registration") | bold | hcenter,
            separator(),
            input_name_->Render(),
            input_email_->Render(),
            submit_->Render(),
        }) | border;
    }
};
```

### Pattern 3: External State Struct

For larger applications, a state struct is defined separately and references are threaded
through:

```cpp
struct AppState {
    std::string search_query;
    std::vector<std::string> results;
    int selected_result = 0;
    bool loading = false;
};

Component BuildUI(AppState& state) {
    auto search = Input(&state.search_query, "Search...");
    auto results = Menu(&state.results, &state.selected_result);
    // ... compose components referencing state ...
}
```

In all patterns, the key insight is that FTXUI Components are essentially closures over
mutable state. The `Render()` method reads the current state each frame, producing a new
Element tree. Event handlers mutate the state, triggering a visual update on the next
frame.

---

## Extensibility and Ecosystem

### Self-Contained

FTXUI has **no external dependencies** beyond the C++ standard library. This is a
deliberate design choice: the library compiles with any C++17-compliant compiler without
pulling in ncurses, terminfo, or any other system library.

### Integration

- **CMake FetchContent** -- The recommended integration method. Add FTXUI as a dependency
  in three lines of CMake.
- **vcpkg** -- `vcpkg install ftxui`.
- **Conan** -- Available in Conan Center.
- **Bazel** -- Supported via MODULE.bazel.
- **System packages** -- Available in Debian, Ubuntu, Arch Linux (AUR), openSUSE, Nix.
- **Header-only friendly** -- While not strictly header-only, the library is small enough
  to compile quickly as part of a project.
- **C++20 modules** -- Supported for compilers that implement C++ modules.

### WebAssembly

FTXUI compiles to WebAssembly via Emscripten, rendering to an HTML `<pre>` element in the
browser. This enables interactive online demos where users can try components without
installing anything. The FTXUI documentation site features live WebAssembly examples for
most components.

### Community

FTXUI powers 50+ known projects including games (2048, Minesweeper), system monitors
(htop-style dashboards), git TUIs, and various interactive CLI tools. The library itself
is comprehensive enough that third-party extension libraries are rare -- most needs are
met by composing the built-in elements and components.

---

## Strengths

- **DOM-like composability via function composition.** UI is built by nesting function
  calls: `border(vbox({text("a"), separator(), text("b")}))`. This is declarative,
  readable, and maps directly to the visual hierarchy.

- **Pipe operator for decorator chaining.** `text("hi") | bold | color(Color::Red) | border`
  reads naturally left-to-right, avoiding deep nesting for styled elements.

- **Flexbox-inspired layout.** The `FlexboxConfig` brings CSS Flexbox semantics to the
  terminal: direction, wrap, justify-content, align-items, gap. This is rare in TUI
  libraries and enables responsive layouts.

- **Clean dual dom/component architecture.** The pure functional dom layer can be used
  independently for static rendering. The component layer adds only the necessary
  statefulness for interactivity. Neither layer is aware of the other's internals.

- **Zero dependencies.** No ncurses, no terminfo, no system libraries. Compiles with any
  C++17 compiler on any platform.

- **WebAssembly target.** Compiles to WASM via Emscripten for in-browser demos. This is
  unique among TUI libraries and excellent for documentation.

- **Good documentation with live demos.** The documentation site features interactive
  WebAssembly examples for most components, allowing users to try before installing.

- **Small binary size.** No heavy dependencies means compact output binaries.

- **Rich built-in elements.** 22 spinner styles, braille canvas, gauges in all directions,
  linear gradients, hyperlinks -- the standard library of elements is comprehensive.

- **Mouse support.** Click, scroll, motion tracking, drag-to-resize split panes. Full
  mouse integration without external event libraries.

- **Unicode and fullwidth character support.** Correct handling of CJK characters, emoji,
  and other multi-cell Unicode.

---

## Weaknesses and Limitations

- **C++ complexity.** `shared_ptr` ownership, template error messages, and manual memory
  management patterns (captured references must outlive the event loop) add cognitive
  overhead compared to Rust (ownership) or Go (GC) alternatives.

- **No built-in async/concurrency model.** `ScreenInteractive::Loop()` blocks the calling
  thread. Background work requires manual threading with `Post()` to marshal updates back.
  No built-in task/future/channel system.

- **Limited text input features.** The `Input` component is basic compared to web-style
  text fields. No built-in multi-line editor, syntax highlighting, or rich text editing.

- **No built-in scrollable list virtualization.** Large lists are fully rendered in the
  Element tree. There is no built-in row recycling or lazy rendering for thousand-item
  lists.

- **Documentation depth varies.** While the API reference exists, narrative documentation
  (guides, tutorials, architecture explanations) is thinner than libraries like Ratatui
  or Textual.

- **No accessibility layer.** No screen reader support or semantic markup. Terminal
  inherent limitation, but no effort toward bridging it.

- **No built-in theming system.** Colors and styles are applied per-element. There is no
  theme object or style-sheet abstraction for consistent application-wide styling.

- **Windows support is secondary.** While functional, Windows is community-maintained
  and may lag behind Linux/macOS in feature coverage.

- **Single-threaded event loop.** The `ScreenInteractive` event loop is single-threaded.
  CPU-intensive rendering blocks event processing.

---

## Lessons for D / Sparkles

FTXUI's functional DOM architecture maps remarkably well to D's language features. Several
of its core patterns can be adopted or improved upon in a D implementation.

### Element Composition via Functions maps to D's UFCS + Templates

FTXUI builds UIs by nesting function calls:

```cpp
// C++ FTXUI
border(hbox({text("Name"), separator(), text("Arthur")}))
```

In D, UFCS (Uniform Function Call Syntax) makes this even more natural:

```d
// D with UFCS
hbox(text("Name"), separator(), text("Arthur")).border
```

No special pipe operator is needed. UFCS gives D the same left-to-right readability that
FTXUI achieves with `operator|`, but as a built-in language feature. A D TUI library
could define `text`, `hbox`, `vbox`, `border` as free functions, and UFCS would provide
the composition syntax for free.

### Pipe Operator maps to UFCS Chaining

FTXUI's most idiomatic pattern:

```cpp
// C++ FTXUI
text("hello") | bold | color(Color::Blue) | border
```

In D, this is simply:

```d
// D with UFCS
text("hello").bold.color(Color.blue).border
```

D's UFCS is strictly more powerful: it works with any free function, not just those that
define `operator|`. And it works at compile time with no runtime overhead. A D TUI library
gets FTXUI's compositional elegance without any operator overloading machinery.

### Flexbox Layout maps to @nogc Structs with CTFE Validation

FTXUI's `FlexboxConfig` is a plain struct with enums:

```cpp
FlexboxConfig config;
config.direction = FlexboxConfig::Direction::Row;
config.justify_content = FlexboxConfig::JustifyContent::Center;
```

D can do this with `@nogc` structs and use CTFE for compile-time validation:

```d
// D equivalent
auto config = FlexboxConfig(
    direction: Direction.row,
    justifyContent: JustifyContent.center,
    gap: Gap(x: 1, y: 0),
);

// Or with a builder using UFCS:
auto config = flexboxConfig
    .direction(Direction.row)
    .justifyContent(JustifyContent.center)
    .gap(1, 0);
```

The layout constraint solver (ComputeRequirement + SetBox) can be implemented as `@nogc
pure nothrow` functions operating on stack-allocated node arrays, avoiding all heap
allocation for the layout pass.

### Dual Dom/Component Layers maps to @nogc Elements + DbI Components

FTXUI's two-tier architecture translates directly:

1. **Dom layer** -- Pure `@nogc nothrow` Element types. Elements are value types (D
   structs) stored in a `SmallBuffer`-backed tree. Layout computation is a pure function
   from Element tree to positioned boxes. No GC allocation, no exceptions, no state.

2. **Component layer** -- Stateful components using Design by Introspection. A component
   is any type that provides a `render()` method (returning an Element) and optionally
   an `onEvent()` method. DbI detects available capabilities:

   ```d
   // D with DbI
   auto component = struct {
       string name;
       int counter;

       Element render() {
           return vbox(
               text("Name: " ~ name).bold,
               separator(),
               gauge(counter / 100.0).color(Color.green),
           ).border;
       }

       bool onEvent(Event e) {
           if (e == Event.character('+')) { counter++; return true; }
           return false;
       }
   };
   ```

   The framework uses `__traits(hasMember, T, "onEvent")` to detect whether a component
   handles events, falling back to a no-op if not. This is the Design by Introspection
   pattern from the Sparkles guidelines.

### Lambda-Captured State maps to D Delegates and Struct Components

FTXUI's most common state pattern -- lambda capture in `main()` -- maps to D delegates:

```d
void main() {
    string name;
    int counter;

    auto renderer = makeRenderer(() {
        return vbox(
            text("Name: " ~ name),
            text("Count: ").bold,
            gauge(counter / 100.0),
        ).border;
    });
}
```

But D also enables struct-based components with UFCS, which FTXUI cannot express as
cleanly due to C++'s lack of UFCS:

```d
struct Counter {
    int value = 0;

    Element render() {
        return text(value.to!string)
            .bold
            .color(value > 0 ? Color.green : Color.red)
            .border;
    }
}
```

### Element as Value Type maps to SmallBuffer-Backed Trees

FTXUI uses `shared_ptr<Node>` for elements, which means heap allocation for every node.
In D, elements could be value types stored in a `SmallBuffer`:

```d
// D: Element tree without GC allocation
struct Element {
    ElementKind kind;
    Style style;
    SmallBuffer!(Element*, 8) children;
    // ... payload union for text, gauge value, etc.
}
```

For small-to-medium UIs (the common case in CLI tools), the entire Element tree fits in
a `SmallBuffer` with no heap allocation. This is a significant performance advantage
over FTXUI's `shared_ptr`-per-node approach.

### WebAssembly Target

D compiles to WebAssembly via LDC, just as C++ compiles via Emscripten. FTXUI's
architecture -- pure Element tree rendered to a pixel grid, then serialized to
ANSI or HTML -- is inherently portable. A D TUI library following this architecture
could target WASM with the same approach: render to a `Screen` abstraction, serialize
to ANSI for terminals or HTML for browsers.

### Key Takeaways

| FTXUI Pattern              | D / Sparkles Equivalent                          |
| -------------------------- | ------------------------------------------------ |
| `Element` via `shared_ptr` | `Element` as `@nogc` struct in `SmallBuffer`     |
| `operator\|` pipe          | UFCS (built-in, zero cost)                       |
| `FlexboxConfig` struct     | Named-argument struct with CTFE validation       |
| `ComponentBase` virtual    | DbI trait detection (`__traits(hasMember, ...)`) |
| Lambda capture state       | D delegates / struct member state                |
| `ComputeRequirement`       | `@nogc pure nothrow` layout pass                 |
| `Screen` pixel grid        | `SmallBuffer!(Pixel, N)` grid                    |
| WebAssembly via Emscripten | WebAssembly via LDC                              |

---

## References

- **Repository**: <https://github.com/ArthurSonzogni/FTXUI>
- **API Documentation**: <https://arthursonzogni.github.io/FTXUI/>
- **DOM Elements Reference**: <https://arthursonzogni.github.io/FTXUI/group__dom.html>
- **Component Reference**: <https://arthursonzogni.github.io/FTXUI/group__component.html>
- **Screen Reference**: <https://arthursonzogni.github.io/FTXUI/group__screen.html>
- **Examples Directory**: <https://github.com/ArthurSonzogni/FTXUI/tree/main/examples>
- **FlexboxConfig Header**: <https://github.com/ArthurSonzogni/FTXUI/blob/main/include/ftxui/dom/flexbox_config.hpp>
- **Online Interactive Demos**: <https://arthursonzogni.github.io/FTXUI/examples/>

---

## Markdown References

[ftxui-element]: https://arthursonzogni.github.io/FTXUI/group__dom.html
[ftxui-screen]: https://arthursonzogni.github.io/FTXUI/group__screen.html
[ftxui-component]: https://arthursonzogni.github.io/FTXUI/group__component.html
[ftxui-screen-interactive]: https://arthursonzogni.github.io/FTXUI/group__component.html
[ftxui-flexbox]: https://github.com/ArthurSonzogni/FTXUI/blob/main/include/ftxui/dom/flexbox_config.hpp
