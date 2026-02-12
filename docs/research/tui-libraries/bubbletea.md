# Bubble Tea (Go)

A functional framework for building terminal user interfaces in Go, based on The Elm Architecture (Model-View-Update).

| Field          | Value                                                              |
| -------------- | ------------------------------------------------------------------ |
| Language       | Go                                                                 |
| License        | MIT                                                                |
| Repository     | <https://github.com/charmbracelet/bubbletea>                       |
| Documentation  | <https://github.com/charmbracelet/bubbletea/tree/master/tutorials> |
| Latest Version | ~1.2.x (2025)                                                      |
| GitHub Stars   | ~39k                                                               |

---

## Overview

Bubble Tea is a Go framework for building terminal applications using The Elm Architecture (TEA), also known as Model-View-Update (MVU). It provides a simple, functional programming model where all state mutations are explicit, all rendering is a pure function of state, and all side effects are modeled as commands that produce messages.

### What It Solves

Building terminal UIs in Go traditionally involves low-level terminal manipulation, manual event loops, and ad hoc state management. Bubble Tea replaces this with a structured, testable architecture where the entire application lifecycle is expressed through three functions: `Init`, `Update`, and `View`.

### Design Philosophy

Bubble Tea directly adapts The Elm Architecture to the terminal:

- **Unidirectional data flow** -- messages flow into `Update`, state flows out, `View` renders the state.
- **No hidden state** -- the `Model` struct is the single source of truth.
- **Side effects as values** -- I/O operations are represented as `Cmd` values, not imperative calls.
- **Composition over inheritance** -- complex UIs are built by embedding sub-models and forwarding messages.

### History and Ecosystem

Bubble Tea was created by [Charm](https://charm.sh), a company building open-source tools and infrastructure for the terminal. It is the centerpiece of a broader ecosystem:

| Project        | Role                                   | Repository                                                            |
| -------------- | -------------------------------------- | --------------------------------------------------------------------- |
| **Bubble Tea** | Application framework (MVU loop)       | [charmbracelet/bubbletea](https://github.com/charmbracelet/bubbletea) |
| **Lip Gloss**  | Terminal styling and layout primitives | [charmbracelet/lipgloss](https://github.com/charmbracelet/lipgloss)   |
| **Bubbles**    | Reusable UI components                 | [charmbracelet/bubbles](https://github.com/charmbracelet/bubbles)     |
| **Wish**       | SSH server for Bubble Tea apps         | [charmbracelet/wish](https://github.com/charmbracelet/wish)           |
| **Huh**        | Interactive forms and prompts          | [charmbracelet/huh](https://github.com/charmbracelet/huh)             |
| **Gum**        | Shell scripting TUI utilities          | [charmbracelet/gum](https://github.com/charmbracelet/gum)             |
| **Log**        | Colorful structured logging            | [charmbracelet/log](https://github.com/charmbracelet/log)             |
| **Harmonica**  | Spring-based animations                | [charmbracelet/harmonica](https://github.com/charmbracelet/harmonica) |

Bubble Tea is one of the most popular Go libraries for terminal UIs, significantly surpassing older projects like `tview` and `gocui` in adoption. It is used in production by Microsoft (Aztfy/Azure), CockroachDB, AWS (eks-node-viewer), Ubuntu (Authd), MinIO, NVIDIA, and Truffle Security.

---

## Architecture

Bubble Tea implements a strict Model-View-Update (MVU) loop. The core abstraction is the `Model` interface:

```go
type Model interface {
    // Init returns an initial command to execute when the program starts.
    Init() Cmd

    // Update is called when a message is received. It returns the updated
    // model and an optional command to execute.
    Update(Msg) (Model, Cmd)

    // View renders the UI as a string based on the current model state.
    View() string
}
```

### The MVU Cycle

```
                 ┌─────────────────────┐
                 │      Terminal        │
                 │  (keyboard, mouse,   │
                 │   resize, etc.)      │
                 └────────┬────────────┘
                          │ raw events
                          ▼
                 ┌─────────────────────┐
                 │     tea.Msg          │
                 │  (KeyMsg, MouseMsg,  │
                 │   WindowSizeMsg,     │
                 │   custom types)      │
                 └────────┬────────────┘
                          │
                          ▼
              ┌──────────────────────┐
              │   Update(msg) →      │
              │   (Model, Cmd)       │
              └─────┬──────────┬─────┘
                    │          │
            new Model      tea.Cmd
                    │          │
                    ▼          ▼
              ┌──────────┐  ┌──────────────┐
              │  View()   │  │ Execute Cmd  │
              │  → string │  │ → new Msg    │──┐
              └─────┬─────┘  └──────────────┘  │
                    │                           │
                    ▼                           │
              ┌──────────┐                      │
              │ Render   │                      │
              │ to term  │         loops back ──┘
              └──────────┘
```

1. The framework collects terminal events and wraps them as `tea.Msg` values.
2. `Update` receives each message, produces a new `Model` (Go struct value copy) and optionally a `Cmd`.
3. `View` is called on the new model. It returns a string representation of the entire UI.
4. The framework diffs the new view against the previous one and writes only the changes to the terminal.
5. If `Update` returned a `Cmd`, the framework executes it asynchronously. When the command completes, it produces a new `Msg` that re-enters the cycle.

### Msg

`Msg` is the empty interface -- any Go value can be a message:

```go
type Msg interface{}
```

The framework provides built-in message types for terminal events (`KeyMsg`, `MouseMsg`, `WindowSizeMsg`, `FocusMsg`, `BlurMsg`), and applications define custom message types for their own domain events (HTTP responses, timer ticks, etc.).

### Cmd

A `Cmd` is a function that performs I/O and returns a `Msg`:

```go
type Cmd func() Msg
```

Commands are the only way to perform side effects in Bubble Tea. The framework executes them outside the MVU loop and feeds their results back as messages. A `nil` Cmd means "no side effect."

Key built-in commands:

```go
// Quit the program
func Quit() Msg { return QuitMsg{} }

// Run multiple commands concurrently
func Batch(cmds ...Cmd) Cmd

// Run commands sequentially
func Sequence(cmds ...Cmd) Cmd

// Tick at a duration
func Tick(d time.Duration, fn func(time.Time) Msg) Cmd

// Synchronize with the system clock
func Every(duration time.Duration, fn func(time.Time) Msg) Cmd

// Set the terminal window title
func SetWindowTitle(title string) Cmd

// Query the terminal size
func WindowSize() Cmd
```

### Program

The `Program` is the runtime that drives the MVU loop:

```go
p := tea.NewProgram(initialModel, tea.WithAltScreen())
finalModel, err := p.Run()
```

Programs can be configured with options and can receive external messages via `p.Send(msg)`.

---

## Terminal Backend

Bubble Tea manages the terminal directly using ANSI escape sequences and Go's `os` package for TTY control, supplemented by the Charm `x/term` library.

### Terminal Modes

- **Raw mode** -- disables line buffering and echo so the framework receives individual keypresses.
- **Alternate screen** -- uses the terminal's alternate screen buffer so the original scrollback is preserved. Enabled via `tea.WithAltScreen()`.
- **Bracketed paste** -- enabled by default; detects pasted text vs. typed input. Disabled via `tea.WithoutBracketedPaste()`.
- **Focus reporting** -- detects when the terminal window gains or loses focus. Enabled via `tea.WithReportFocus()`.

### Mouse Support

Two levels of mouse tracking are available:

| Option                  | Events                                     | Compatibility |
| ----------------------- | ------------------------------------------ | ------------- |
| `WithMouseCellMotion()` | Click, release, wheel, drag (cell changes) | Broad         |
| `WithMouseAllMotion()`  | All of the above plus hover / all motion   | Narrower      |

Mouse events are parsed from both X10-encoded and SGR-encoded escape sequences. The `MouseMsg` struct provides:

```go
type MouseMsg struct {
    X, Y           int
    Shift, Alt, Ctrl bool
    Action         MouseAction   // Press, Release, Motion
    Button         MouseButton   // Left, Middle, Right, WheelUp, WheelDown, ...
}
```

### Color Capabilities

Color support is detected automatically and Lip Gloss handles degradation:

- **True Color (24-bit)** -- full RGB via hex codes
- **ANSI 256 (8-bit)** -- extended palette
- **ANSI 16 (4-bit)** -- basic terminal colors
- **No color** -- plain text fallback

### Rendering

The renderer operates at a configurable frame rate (default 60 FPS, max 120, set via `WithFPS()`). On each frame, the framework:

1. Calls `View()` to get the full UI string.
2. Diffs it against the previously rendered string.
3. Writes only the changed lines to the terminal using cursor movement and line clearing escape sequences.

This approach avoids flicker and minimizes I/O.

### Platform Support

- **Unix** (Linux, macOS, BSD) -- full support via POSIX TTY APIs.
- **Windows** -- support via ConPTY (Windows Console Pseudo Terminal). Works in Windows Terminal, PowerShell, and cmd.exe.

---

## Layout System

Bubble Tea has **no built-in layout system**. The `View()` function returns a plain string, and it is the developer's responsibility to compose that string. This is by design -- it keeps the core framework minimal.

Layout is handled by **Lip Gloss**, which provides string measurement and joining utilities:

### Measurement

```go
width := lipgloss.Width(renderedText)
height := lipgloss.Height(renderedText)
w, h := lipgloss.Size(renderedText)
```

These functions correctly account for ANSI escape sequences when measuring visible width and height.

### Joining

```go
// Horizontal: align elements along their top, center, or bottom edges
row := lipgloss.JoinHorizontal(lipgloss.Top, leftPanel, rightPanel)

// Vertical: align elements along their left, center, or right edges
column := lipgloss.JoinVertical(lipgloss.Left, header, body, footer)
```

### Placement

```go
// Place content within a region at a specific position
output := lipgloss.Place(width, height, lipgloss.Center, lipgloss.Center, content)
```

### Multi-Panel Layout Example

```go
func (m model) View() string {
    // Define styles
    sidebarStyle := lipgloss.NewStyle().
        Width(30).
        Height(m.height - 2).
        BorderStyle(lipgloss.RoundedBorder()).
        BorderForeground(lipgloss.Color("63")).
        Padding(1, 2)

    contentStyle := lipgloss.NewStyle().
        Width(m.width - 34).
        Height(m.height - 2).
        BorderStyle(lipgloss.RoundedBorder()).
        BorderForeground(lipgloss.Color("63")).
        Padding(1, 2)

    statusStyle := lipgloss.NewStyle().
        Width(m.width).
        Background(lipgloss.Color("63")).
        Foreground(lipgloss.Color("230")).
        Padding(0, 1)

    // Render panels
    sidebar := sidebarStyle.Render(m.sidebarContent())
    content := contentStyle.Render(m.mainContent())
    status := statusStyle.Render(m.statusText())

    // Compose layout: sidebar | content on top, status bar on bottom
    top := lipgloss.JoinHorizontal(lipgloss.Top, sidebar, content)
    return lipgloss.JoinVertical(lipgloss.Left, top, status)
}
```

The manual string-composition approach is flexible but requires developers to handle sizing, overflow, and responsive behavior explicitly. There is no constraint solver or flexbox-style automatic layout.

---

## Widget/Component System

The **Bubbles** library provides a collection of reusable components, each implemented as a Bubble Tea `Model`. Available bubbles:

| Component    | Description                                  |
| ------------ | -------------------------------------------- |
| `textinput`  | Single-line text input with cursor, paste    |
| `textarea`   | Multi-line text editor with scrolling        |
| `list`       | Filterable, paginated list with fuzzy search |
| `table`      | Tabular data display with column navigation  |
| `viewport`   | Scrollable content pane (pager-like)         |
| `spinner`    | Animated loading indicator                   |
| `paginator`  | Page navigation (dot or numeric style)       |
| `progress`   | Progress bar with optional animation         |
| `filepicker` | File system browser and selector             |
| `help`       | Auto-generated keybinding help view          |
| `key`        | Keybinding definitions and matching          |
| `timer`      | Countdown timer                              |
| `stopwatch`  | Count-up stopwatch                           |
| `cursor`     | Cursor blinking and style management         |

### Composition Pattern

Each bubble implements the `tea.Model` interface. Complex applications compose bubbles by embedding them as fields in a parent model and forwarding messages:

```go
package main

import (
    "fmt"
    "github.com/charmbracelet/bubbles/spinner"
    "github.com/charmbracelet/bubbles/textinput"
    tea "github.com/charmbracelet/bubbletea"
    "github.com/charmbracelet/lipgloss"
)

type state int

const (
    stateInput state = iota
    stateLoading
    stateDone
)

type resultMsg string

type model struct {
    state   state
    input   textinput.Model
    spinner spinner.Model
    result  string
}

func initialModel() model {
    ti := textinput.New()
    ti.Placeholder = "Enter a search query..."
    ti.Focus()

    sp := spinner.New()
    sp.Spinner = spinner.Dot
    sp.Style = lipgloss.NewStyle().Foreground(lipgloss.Color("205"))

    return model{
        state:   stateInput,
        input:   ti,
        spinner: sp,
    }
}

func (m model) Init() tea.Cmd {
    return tea.Batch(textinput.Blink, m.spinner.Tick)
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
    switch msg := msg.(type) {
    case tea.KeyMsg:
        switch msg.String() {
        case "ctrl+c":
            return m, tea.Quit
        case "enter":
            if m.state == stateInput {
                m.state = stateLoading
                return m, doSearch(m.input.Value())
            }
        }

    case resultMsg:
        m.state = stateDone
        m.result = string(msg)
        return m, nil
    }

    var cmd tea.Cmd
    switch m.state {
    case stateInput:
        m.input, cmd = m.input.Update(msg)
    case stateLoading:
        m.spinner, cmd = m.spinner.Update(msg)
    }
    return m, cmd
}

func (m model) View() string {
    switch m.state {
    case stateInput:
        return fmt.Sprintf("Search:\n\n%s\n\n(enter to search, ctrl+c to quit)", m.input.View())
    case stateLoading:
        return fmt.Sprintf("%s Searching for %q...", m.spinner.View(), m.input.Value())
    case stateDone:
        return fmt.Sprintf("Result: %s\n\n(ctrl+c to quit)", m.result)
    default:
        return ""
    }
}

func doSearch(query string) tea.Cmd {
    return func() tea.Msg {
        // Simulate an HTTP request or database query
        return resultMsg("42 results found for: " + query)
    }
}

func main() {
    p := tea.NewProgram(initialModel())
    if _, err := p.Run(); err != nil {
        fmt.Println("Error:", err)
    }
}
```

Key composition principles:

- **Embed sub-models** as struct fields in the parent model.
- **Forward messages** to the appropriate sub-model in `Update`, capturing the returned `Cmd`.
- **Delegate rendering** by calling each sub-model's `View()` and composing the strings.
- **Use `tea.Batch`** to combine commands from multiple sub-models.

---

## Styling

Styling in Bubble Tea is handled entirely by **Lip Gloss**, which provides a builder-pattern API with method chaining:

```go
var style = lipgloss.NewStyle().
    Bold(true).
    Italic(true).
    Foreground(lipgloss.Color("#FAFAFA")).
    Background(lipgloss.Color("#7D56F4")).
    PaddingTop(2).
    PaddingLeft(4).
    PaddingBottom(2).
    PaddingRight(4).
    Width(40).
    Align(lipgloss.Center).
    BorderStyle(lipgloss.RoundedBorder()).
    BorderForeground(lipgloss.Color("63"))

output := style.Render("Hello, Bubble Tea!")
```

### Text Formatting

```go
lipgloss.NewStyle().Bold(true)
lipgloss.NewStyle().Italic(true)
lipgloss.NewStyle().Faint(true)
lipgloss.NewStyle().Underline(true)
lipgloss.NewStyle().Strikethrough(true)
lipgloss.NewStyle().Blink(true)
lipgloss.NewStyle().Reverse(true)
```

### Colors

```go
// ANSI 16 basic colors
lipgloss.Color("5")        // magenta

// ANSI 256 extended palette
lipgloss.Color("86")       // aqua

// True color (24-bit)
lipgloss.Color("#FF6347")  // tomato red

// Adaptive: different color for light vs. dark terminal backgrounds
lipgloss.AdaptiveColor{Light: "236", Dark: "248"}

// Complete: specify color for each profile level
lipgloss.CompleteColor{
    TrueColor: "#0000FF",
    ANSI256:   "86",
    ANSI:      "5",
}
```

### Box Model

Lip Gloss implements a CSS-inspired box model:

```go
style := lipgloss.NewStyle().
    Padding(1, 2).           // vertical, horizontal
    Margin(1, 2).            // vertical, horizontal
    Width(40).               // minimum width
    MaxWidth(60).            // maximum width
    Height(10).              // minimum height
    MaxHeight(20).           // maximum height
    Align(lipgloss.Center).  // text alignment
    BorderStyle(lipgloss.DoubleBorder()).
    BorderForeground(lipgloss.Color("228"))
```

### Border Styles

Built-in borders: `NormalBorder()`, `RoundedBorder()`, `ThickBorder()`, `DoubleBorder()`.

Custom borders:

```go
lipgloss.Border{
    Top: "._.:*:",  Bottom: "._.:*:",
    Left: "|",      Right: "|",
    TopLeft: "*",   TopRight: "*",
    BottomLeft: "*", BottomRight: "*",
}
```

### Style Composition

```go
// Copy a style (assignment copies all values)
baseStyle := lipgloss.NewStyle().Padding(1, 2).Bold(true)
headerStyle := baseStyle.Foreground(lipgloss.Color("99"))

// Inherit unset values from a parent
childStyle := lipgloss.NewStyle().
    Foreground(lipgloss.Color("205")).
    Inherit(parentStyle) // only copies rules not already set

// Unset specific rules
plain := style.UnsetBold().UnsetBackground()
```

### Tab Handling

```go
style.TabWidth(2)                    // render tabs as 2 spaces
style.TabWidth(0)                    // remove tabs
style.TabWidth(lipgloss.NoTabConversion) // preserve literal tabs
```

---

## Event Handling

All events in Bubble Tea are values of type `tea.Msg` dispatched to the `Update` function. There is no callback registration, event bus, or observer pattern -- just a switch statement on the message type.

### Key Events

```go
type KeyMsg Key

type Key struct {
    Type  KeyType   // KeyRunes, KeyEnter, KeyCtrlC, KeyUp, KeyF1, ...
    Runes []rune    // the character(s) for KeyRunes
    Alt   bool      // whether Alt was held
    Paste bool      // whether this came from a paste operation
}
```

The `String()` method returns a human-readable representation: `"a"`, `"ctrl+c"`, `"alt+enter"`, `"up"`, `"f1"`, etc.

### Mouse Events

```go
type MouseMsg struct {
    X, Y           int
    Shift, Alt, Ctrl bool
    Action         MouseAction  // MouseActionPress, MouseActionRelease, MouseActionMotion
    Button         MouseButton  // MouseButtonLeft, MouseButtonRight, MouseButtonWheelUp, ...
}
```

### Window Size Events

```go
type WindowSizeMsg struct {
    Width  int
    Height int
}
```

Sent when the terminal is resized (SIGWINCH on Unix). Also available on demand via `tea.WindowSize()`.

### Focus Events

When focus reporting is enabled (`tea.WithReportFocus()`):

```go
type FocusMsg struct{}
type BlurMsg struct{}
```

### Comprehensive Update Example

```go
func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
    switch msg := msg.(type) {

    case tea.WindowSizeMsg:
        m.width = msg.Width
        m.height = msg.Height
        return m, nil

    case tea.KeyMsg:
        switch msg.String() {
        case "ctrl+c", "q":
            return m, tea.Quit
        case "up", "k":
            m.cursor--
            if m.cursor < 0 {
                m.cursor = len(m.items) - 1
            }
        case "down", "j":
            m.cursor++
            if m.cursor >= len(m.items) {
                m.cursor = 0
            }
        case "enter":
            m.selected = m.cursor
            return m, fetchDetails(m.items[m.cursor].ID)
        }

    case tea.MouseMsg:
        if msg.Action == tea.MouseActionPress && msg.Button == tea.MouseButtonLeft {
            m.cursor = msg.Y - m.listOffset
        }

    case detailsMsg:
        m.details = msg.Content
        return m, nil

    case errMsg:
        m.err = msg.Err
        return m, nil
    }

    return m, nil
}
```

### Custom Messages and Commands

Applications define their own message types and commands for domain-specific I/O:

```go
// Custom message types
type detailsMsg struct{ Content string }
type errMsg struct{ Err error }

// Command that performs an HTTP request and returns a message
func fetchDetails(id int) tea.Cmd {
    return func() tea.Msg {
        resp, err := http.Get(fmt.Sprintf("https://api.example.com/items/%d", id))
        if err != nil {
            return errMsg{err}
        }
        defer resp.Body.Close()
        body, _ := io.ReadAll(resp.Body)
        return detailsMsg{string(body)}
    }
}

// Combining multiple commands
return m, tea.Batch(
    fetchDetails(m.selectedID),
    spinner.Tick,
    tea.WindowSize(),
)
```

---

## State Management

### The Model IS the State

In Bubble Tea, there is no separate state container, store, or reactive system. The `Model` struct is the complete application state. Every field that affects rendering or behavior lives in the model.

```go
type model struct {
    items    []item
    cursor   int
    selected int
    width    int
    height   int
    loading  bool
    err      error

    // Sub-model state
    list     list.Model
    viewport viewport.Model
    spinner  spinner.Model
}
```

### Immutable-Style Updates

`Update` returns a _new_ `Model` value. In Go, this is a struct value copy (not a deep clone), so top-level fields are replaced but pointer-referenced data is shared. This is efficient for typical model sizes but requires care with slice and map mutations:

```go
func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
    // m is a value copy -- mutations here don't affect the original
    m.cursor++
    return m, nil
}
```

### No Global State

There is no global mutable state, singleton store, or dependency injection. All state flows through the `Model`, and all mutations flow through `Update`. This makes applications:

- **Testable** -- create a model, send messages, assert on the result.
- **Predictable** -- given the same model and message, `Update` always produces the same result.
- **Debuggable** -- the entire application state is visible in one struct.

### Sub-Model Pattern

Complex applications decompose state into sub-models:

```go
type model struct {
    page     page
    header   headerModel
    sidebar  sidebarModel
    content  contentModel
    footer   footerModel
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
    var cmds []tea.Cmd
    var cmd tea.Cmd

    m.header, cmd = m.header.Update(msg)
    cmds = append(cmds, cmd)

    switch m.page {
    case pageSidebar:
        m.sidebar, cmd = m.sidebar.Update(msg)
    case pageContent:
        m.content, cmd = m.content.Update(msg)
    }
    cmds = append(cmds, cmd)

    m.footer, cmd = m.footer.Update(msg)
    cmds = append(cmds, cmd)

    return m, tea.Batch(cmds...)
}
```

Message routing is manual -- the parent decides which child receives which messages. There is no automatic focus management or message bus.

---

## Extensibility and Ecosystem

### The Charm Ecosystem

Bubble Tea sits at the center of a rich ecosystem of complementary libraries:

| Library       | Purpose                                                    |
| ------------- | ---------------------------------------------------------- |
| **Lip Gloss** | Terminal styling: colors, borders, padding, layout joining |
| **Bubbles**   | Pre-built UI components (inputs, lists, tables, spinners)  |
| **Wish**      | Build SSH servers that serve Bubble Tea apps               |
| **Huh**       | Interactive forms, prompts, and surveys                    |
| **Gum**       | Shell-scriptable TUI components (no Go needed)             |
| **Log**       | Colorful, structured, leveled logging                      |
| **Harmonica** | Spring-based smooth animations                             |
| **Pop**       | Email sending from the terminal                            |
| **Mods**      | AI-powered terminal tools                                  |
| **VHS**       | Record terminal GIFs from scripts                          |

### Community

The Charm ecosystem has a large and active community:

- Active Discord server with thousands of members.
- Extensive example repository with dozens of complete applications.
- Third-party bubbles and middleware shared via Go modules.
- Blog posts and conference talks covering patterns and best practices.

### SSH Applications with Wish

One of Bubble Tea's distinguishing features is Wish, which lets developers serve Bubble Tea applications over SSH:

```go
// A Bubble Tea app accessible via: ssh myapp.example.com
s, _ := wish.NewServer(
    wish.WithAddress("0.0.0.0:23234"),
    wish.WithMiddleware(
        bubbletea.Middleware(teaHandler),
    ),
)
s.ListenAndServe()
```

This enables multi-user terminal applications, shared dashboards, and interactive tools accessible from any SSH client.

---

## Strengths

- **Simple mental model** -- three functions (`Init`, `Update`, `View`) define the entire application lifecycle. No callbacks, no event registration, no lifecycle hooks beyond these three.
- **Excellent documentation and examples** -- the repository includes a thorough tutorial, extensive examples, and the ecosystem has abundant community-written guides.
- **Vibrant, cohesive ecosystem** -- Lip Gloss, Bubbles, Wish, Huh, and Gum are maintained by the same team, ensuring consistent APIs and design philosophy.
- **Highly testable** -- testing is trivial because `Update` is a pure function of `(Model, Msg) -> (Model, Cmd)` and `View` is a pure function of `Model -> string`. No mocks needed for UI logic.
- **SSH application support** -- Wish makes Bubble Tea unique among TUI frameworks by enabling network-accessible terminal applications with minimal additional code.
- **Single binary deployment** -- Go's static compilation produces self-contained binaries with no runtime dependencies.
- **Framerate-limited rendering** -- the renderer batches updates at up to 60 FPS, avoiding unnecessary redraws and terminal flicker.
- **Cross-platform** -- works on Linux, macOS, and Windows (via ConPTY) without conditional compilation.
- **Active maintenance** -- backed by a company (Charm) with a sustainable business model around terminal infrastructure.

---

## Weaknesses and Limitations

- **String-based rendering loses structure** -- `View()` returns a flat string. The framework has no knowledge of widget boundaries, focus regions, or spatial relationships. Hit testing for mouse events must be implemented manually by tracking coordinates.
- **No built-in layout engine** -- developers must manually calculate widths, heights, and positions. Lip Gloss provides joining utilities but not a constraint solver, flexbox, or grid system. Responsive layouts require explicit math.
- **Go's type system limits expressiveness** -- the `Msg` type is `interface{}` (empty interface), so message dispatch requires type switches rather than exhaustive pattern matching. The compiler cannot verify that all message types are handled.
- **Manual message routing in complex apps** -- parent models must explicitly forward messages to child models. There is no automatic propagation, focus-aware routing, or message middleware. This becomes verbose in deeply nested UIs.
- **No built-in widget focus management** -- when composing multiple interactive bubbles (e.g., two text inputs), the developer must manually track which one is focused and route key events accordingly.
- **Performance limited by string operations** -- the entire UI is rebuilt as a string on every update. For very large UIs, string concatenation and the subsequent diff become a bottleneck. There is no incremental rendering or virtual terminal buffer.
- **No animation primitives in core** -- animations require manual tick commands and interpolation. Harmonica helps with easing but is a separate dependency.
- **Shallow widget library** -- while Bubbles covers common cases, it lacks advanced components like trees, split panes, tab bars, modals, or rich text editors. Developers build these from scratch.
- **Model value semantics in Go** -- returning a new `Model` value from `Update` copies the entire struct. For models with large slices or maps, this requires careful use of pointers to avoid performance issues, which partially undermines the immutable-style design.

---

## Lessons for D / Sparkles

Bubble Tea's architecture offers several patterns that translate well to D, often with improvements enabled by D's richer type system and compile-time capabilities.

### MVU Pattern with Immutable Structs and Pure Functions

Bubble Tea's core loop maps directly to D idioms:

```d
// D's `pure` attribute enforces no hidden state access
pure Model update(in Model m, in Msg msg) { ... }
pure string view(in Model m) { ... }
```

D's `immutable` and `const` qualifiers provide stronger guarantees than Go's value semantics. A `pure` function that takes `in Model` (which is `scope const` with `-preview=in`) cannot modify or retain references to the model, making the MVU contract compiler-enforced rather than conventional.

### Cmd/Msg with Sum Types

Go uses the empty interface (`interface{}`) for messages and relies on type switches. D can use `SumType` or `std.variant.Algebraic` for exhaustive, compiler-checked message dispatch:

```d
import std.sumtype;

alias Msg = SumType!(
    KeyMsg,
    MouseMsg,
    WindowSizeMsg,
    FetchResultMsg,
    ErrorMsg,
);

// Compiler error if a case is missing
Msg.match!(
    (KeyMsg k)         => handleKey(model, k),
    (MouseMsg m)       => handleMouse(model, m),
    (WindowSizeMsg ws) => handleResize(model, ws),
    (FetchResultMsg r) => handleResult(model, r),
    (ErrorMsg e)       => handleError(model, e),
);
```

Alternatively, template-based dispatch via Design by Introspection could allow compile-time resolution of message handlers based on capability traits.

### View-as-String vs. Output Ranges

Bubble Tea's biggest performance limitation is that `View()` returns a heap-allocated `string` that is then diffed. In D, the view function can write to an output range, avoiding allocation entirely:

```d
/// Renders the model's UI to an output range -- zero allocation.
void view(Writer)(in Model m, ref Writer w)
if (isOutputRange!(Writer, char))
{
    w.put("Items:\n");
    foreach (i, item; m.items)
    {
        if (i == m.cursor)
            w.put("> ");
        else
            w.put("  ");
        w.put(item.name);
        w.put('\n');
    }
}
```

This pattern is already established in Sparkles' `prettyPrint`, which writes to arbitrary output ranges including `SmallBuffer` for `@nogc` operation.

### Lip Gloss Styling with UFCS Builder Chains

Lip Gloss's method-chaining builder pattern maps directly to Sparkles' existing `stylizedTextBuilder` using UFCS and `opDispatch`:

```go
// Go / Lip Gloss
lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("205")).Render("Hello")
```

```d
// D / Sparkles (already exists in term_style.d)
"Hello".stylizedTextBuilder.bold.magenta
```

D's compile-time `opDispatch` resolves style names at compile time with zero runtime overhead, and `enum` evaluation enables CTFE for static style strings -- something Lip Gloss cannot do.

### Bubble Composition with Template Mixins and DbI

Bubble Tea's sub-model composition pattern (embed struct, forward messages, collect commands) can be expressed more powerfully in D using Design by Introspection:

```d
/// A widget that optionally supports focus, scrolling, and filtering
/// based on what capabilities the underlying model provides.
struct ComposedWidget(Models...)
{
    Models models;

    void update(Msg msg)
    {
        static foreach (i, M; Models)
        {
            static if (__traits(hasMember, M, "update"))
                models[i].update(msg);
        }
    }

    void view(Writer)(ref Writer w)
    {
        static foreach (i, M; Models)
        {
            static if (__traits(hasMember, M, "view"))
                models[i].view(w);
        }
    }
}
```

This eliminates Bubble Tea's manual message forwarding boilerplate. The compiler generates the routing code based on the capabilities of each sub-model.

### Testing Pattern with Output Ranges

Bubble Tea's testability advantage (assert on model state and view string) becomes even stronger in D with output ranges:

```d
@("app.update.keyDown.movesCursor")
@safe pure nothrow @nogc
unittest
{
    auto m = initialModel();
    m = update(m, KeyMsg(KeyType.down));
    assert(m.cursor == 1);

    SmallBuffer!(char, 1024) buf;
    view(m, buf);
    // buf[] contains the rendered view -- compare without allocation
}
```

The combination of `pure`, `@nogc`, and `SmallBuffer` means UI tests run with zero allocation and can verify both state transitions and rendered output.

---

## References

- **Repository**: <https://github.com/charmbracelet/bubbletea>
- **Tutorial**: <https://github.com/charmbracelet/bubbletea/tree/master/tutorials>
- **Examples**: <https://github.com/charmbracelet/bubbletea/tree/master/examples>
- **Bubbles (components)**: <https://github.com/charmbracelet/bubbles>
- **Lip Gloss (styling)**: <https://github.com/charmbracelet/lipgloss>
- **Wish (SSH)**: <https://github.com/charmbracelet/wish>
- **Huh (forms)**: <https://github.com/charmbracelet/huh>
- **Gum (shell scripting)**: <https://github.com/charmbracelet/gum>
- **Charm homepage**: <https://charm.sh>
- **"The Elm Architecture" (original)**: <https://guide.elm-lang.org/architecture/>
- **Charm blog**: <https://charm.sh/blog/>
- **"Building a TUI with Bubble Tea" (talk)**: Various conference presentations by the Charm team
