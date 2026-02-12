# tview (Go)

A batteries-included terminal UI widget toolkit for Go, built on a retained-mode widget tree with flexbox/grid layout and framework-managed event loop.

| Field            | Value                                      |
| ---------------- | ------------------------------------------ |
| Language         | Go                                         |
| License          | MIT                                        |
| Repository       | <https://github.com/rivo/tview>            |
| Documentation    | <https://pkg.go.dev/github.com/rivo/tview> |
| Terminal Backend | [tcell](https://github.com/gdamore/tcell)  |
| GitHub Stars     | ~13.5k                                     |

---

## Overview

### What It Solves

tview is a high-level widget toolkit for building terminal user interfaces in Go. Rather than requiring developers to manage raw terminal I/O, event loops, drawing, and focus routing, tview provides a ready-made set of interactive widgets (text views, tables, forms, trees, input fields) arranged in a retained widget tree that the framework draws and manages automatically.

### Design Philosophy

tview follows a **batteries-included, widget-library** approach:

- **Retained-mode widget tree** -- the application constructs a tree of `Primitive` objects. The framework owns the draw cycle and redraws the tree on every event.
- **Framework-managed event loop** -- `Application.Run()` blocks, polling terminal events and dispatching them to the focused widget. The developer registers callbacks rather than writing a loop.
- **Flexbox/grid-inspired layout** -- `Flex` and `Grid` container primitives handle spatial arrangement, proportional sizing, and responsive breakpoints.
- **Rich built-in widget set** -- text display, tables, forms, trees, dropdowns, modals, and tabbed panels are all provided out of the box.

tview is built on [tcell](https://github.com/gdamore/tcell), which handles low-level terminal operations (cell buffer, color negotiation, mouse protocol, Unicode width).

### Contrast with Bubble Tea

tview and Bubble Tea are the two dominant Go TUI libraries, but they take fundamentally different architectural approaches:

| Aspect           | tview                                            | Bubble Tea                                     |
| ---------------- | ------------------------------------------------ | ---------------------------------------------- |
| Architecture     | Retained-mode widget tree (OOP-like)             | Model-View-Update (functional)                 |
| Event loop       | Framework-managed (`Application.Run()`)          | Framework-managed, but events are `Msg` values |
| State ownership  | Widgets own their state (getters/setters)        | Single `Model` struct owns all state           |
| Rendering        | Framework traverses widget tree and calls `Draw` | Developer returns a `string` from `View()`     |
| Layout           | Built-in `Flex` and `Grid` containers            | No built-in layout; use Lip Gloss joining      |
| Focus management | Automatic (framework tracks focus, routes input) | Manual (developer routes keys to sub-models)   |
| Side effects     | Callbacks and `QueueUpdate` from goroutines      | `Cmd` functions that produce `Msg` values      |
| Testability      | Harder (stateful widgets, callbacks)             | Easier (pure functions on value types)         |
| Customization    | Inherit `Box`, implement `Primitive` interface   | Implement `tea.Model` (three functions)        |

In short: tview manages the widget tree and event routing for you; Bubble Tea gives you pure functions and you manage everything yourself.

---

## Architecture

tview uses a **retained-mode widget tree** architecture. The developer builds a tree of `Primitive` objects, hands the root to `Application`, and the framework handles the event loop, focus tracking, and full-tree redraw cycle.

### Application

The `Application` struct is the top-level coordinator. It owns the event loop, the tcell screen, and a reference to the root primitive.

```go
app := tview.NewApplication()

// Set the root widget (fullscreen = true fills the entire terminal)
app.SetRoot(rootPrimitive, true)

// Run blocks, processing events until Stop() is called
if err := app.Run(); err != nil {
    panic(err)
}
```

Internally, `Run()` spawns two goroutines:

1. **Screen event poller** -- continuously calls `screen.PollEvent()` and sends events into a channel.
2. **Main event loop** -- reads from three sources: terminal events, queued update functions (`QueueUpdate`), and screen replacement signals (after suspension). All widget mutations and draw calls happen on this single goroutine, eliminating race conditions.

The draw cycle is non-incremental: on each event, `Application` calls `root.Draw(screen)` which traverses the entire widget tree. tcell's internal diff layer optimizes the actual terminal writes, only updating cells that changed.

### Primitive Interface

`Primitive` is the base interface for all widgets. Every visible element in a tview application implements it:

```go
type Primitive interface {
    // Draw renders this primitive onto the screen.
    Draw(screen tcell.Screen)

    // GetRect returns the current position: x, y, width, height.
    GetRect() (int, int, int, int)

    // SetRect sets the position and size (called by parent layout).
    SetRect(x, y, width, height int)

    // InputHandler returns the key event handler.
    // setFocus allows the handler to transfer focus to another primitive.
    InputHandler() func(event *tcell.EventKey, setFocus func(p Primitive))

    // Focus is called when this primitive receives focus.
    // delegate allows focus to be passed to a child.
    Focus(delegate func(p Primitive))

    // HasFocus returns true if this primitive or any child has focus.
    HasFocus() bool

    // Blur is called when focus leaves this primitive.
    Blur()

    // MouseHandler returns the mouse event handler.
    MouseHandler() func(action MouseAction, event *tcell.EventMouse,
        setFocus func(p Primitive)) (consumed bool, capture Primitive)

    // PasteHandler returns the paste event handler.
    PasteHandler() func(text string, setFocus func(p Primitive))
}
```

Key design points:

- **`Draw` is called by the framework** -- widgets never trigger their own drawing. The framework traverses the tree top-down.
- **`SetRect` is called by parent containers** -- layout managers (`Flex`, `Grid`) compute child positions and call `SetRect` before `Draw`.
- **`setFocus` callback** -- both `InputHandler` and `Focus` receive a `setFocus` function, enabling widgets to redirect focus to siblings or children.
- **`HasFocus` is recursive** -- containers return true if any descendant has focus, enabling correct focus-chain detection.

### Widget Tree

The widget tree is constructed by nesting primitives inside layout containers:

```
Application
  └─ root: Flex (FlexRow)
       ├─ TextView (header, fixedSize=1)
       ├─ Flex (FlexColumn, proportion=1)
       │    ├─ List (sidebar, fixedSize=30)
       │    └─ TextView (content, proportion=1)
       └─ TextView (footer, fixedSize=1)
```

The tree is traversed in two phases:

1. **Layout phase** -- each container calls `SetRect` on its children, computing sizes from fixed/proportional specifications.
2. **Draw phase** -- each container calls `Draw` on its children, passing the tcell screen.

### Focus Management

The `Application` tracks which `Primitive` currently has focus:

- `app.SetFocus(p)` explicitly moves focus to a primitive.
- When a key event arrives, the framework calls the focused primitive's `InputHandler`.
- The `setFocus` callback passed to `InputHandler` lets widgets transfer focus (e.g., Tab moves to the next form field).
- `Focus(delegate)` allows composite widgets to delegate focus to a specific child. For example, `Flex.Focus()` delegates to the first child marked with `takeFocus=true`.
- `Blur()` is called on the old focus target when focus changes.

This is a significant advantage over Bubble Tea, where focus management is entirely manual.

---

## Terminal Backend

tview is built on **tcell** (`github.com/gdamore/tcell/v2`), which provides the terminal abstraction layer.

### Capabilities

| Feature             | Support                                               |
| ------------------- | ----------------------------------------------------- |
| True color (24-bit) | Yes, via tcell's color negotiation                    |
| 256 color           | Yes                                                   |
| ANSI 16 color       | Yes                                                   |
| Mouse support       | Click, drag, scroll, double-click (via `EnableMouse`) |
| Unicode             | Full Unicode, including wide characters (CJK)         |
| Grapheme clusters   | Yes, via `rivo/uniseg` dependency                     |
| Bracketed paste     | Yes, via `EnablePaste`                                |
| Platform support    | Linux, macOS, FreeBSD, Windows (native console API)   |

tcell uses a cell buffer internally. When `screen.Show()` is called after a draw cycle, tcell diffs the new buffer against the previous one and writes only changed cells to the terminal. This minimizes I/O and prevents flicker.

### Screen Management

```go
// Enable mouse support
app.EnableMouse(true)

// Enable paste detection
app.EnablePaste(true)

// Suspend the TUI to run a subshell
app.Suspend(func() {
    // Terminal restored to normal mode
    cmd := exec.Command("vim", "file.txt")
    cmd.Stdin = os.Stdin
    cmd.Stdout = os.Stdout
    cmd.Run()
})
// TUI resumes automatically
```

---

## Layout System

The layout system is one of tview's most valuable features. It provides two layout containers -- `Flex` and `Grid` -- plus `Pages` for stacked view switching. These replace the manual string-composition approach required by Bubble Tea.

### Flex

`Flex` implements a flexbox-inspired layout. Children are arranged in a single direction (row or column), with sizes determined by a combination of fixed sizes and proportional weights.

```go
flex := tview.NewFlex().SetDirection(tview.FlexRow) // or tview.FlexColumn
```

**Direction constants:**

| Constant     | Alias           | Behavior                                      |
| ------------ | --------------- | --------------------------------------------- |
| `FlexRow`    | `FlexColumnCSS` | Children stacked vertically (one per row)     |
| `FlexColumn` | `FlexRowCSS`    | Children placed side by side (one per column) |

Note: tview's naming is the **opposite** of CSS flexbox. `FlexRow` means items are arranged in rows (vertical stacking), not that the flex direction is row. The `FlexRowCSS`/`FlexColumnCSS` aliases match CSS semantics.

**AddItem signature:**

```go
func (f *Flex) AddItem(
    item Primitive,   // the widget (may be nil for empty space)
    fixedSize int,    // exact size in cells (0 = flexible)
    proportion int,   // flex weight (only used when fixedSize == 0)
    focus bool,       // whether this item can receive focus
) *Flex
```

**Size calculation algorithm:**

1. Sum all `fixedSize` values and subtract from available space to get `remainingSpace`.
2. Sum all `proportion` values across flexible items to get `totalProportion`.
3. Each flexible item gets `(remainingSpace * item.proportion) / totalProportion` cells.
4. Items are positioned sequentially along the flex direction.

An item with `proportion: 2` gets twice the space of an item with `proportion: 1`. An item with `fixedSize: 0, proportion: 0` gets no remaining space (effectively zero-sized unless it has a fixed size).

**Non-trivial layout example -- IDE-like interface:**

```go
// Header bar (fixed 1 row)
header := tview.NewTextView().SetText(" File  Edit  View  Help")

// Sidebar with file tree (fixed 30 columns)
sidebar := tview.NewTreeView()

// Main editor area (takes remaining space)
editor := tview.NewTextArea()

// Bottom status bar (fixed 1 row)
status := tview.NewTextView().SetText(" main.go | UTF-8 | Go")

// Vertical split: sidebar | editor
editorArea := tview.NewFlex().
    SetDirection(tview.FlexColumn).
    AddItem(sidebar, 30, 0, true).    // fixed 30 columns
    AddItem(editor, 0, 1, false)       // takes remaining width

// Full layout: header / editorArea / status
layout := tview.NewFlex().
    SetDirection(tview.FlexRow).
    AddItem(header, 1, 0, false).      // fixed 1 row
    AddItem(editorArea, 0, 1, true).   // takes remaining height
    AddItem(status, 1, 0, false)       // fixed 1 row

app.SetRoot(layout, true)
```

This produces:

```
┌─────────────────────────────────────────────────┐
│ File  Edit  View  Help                          │  <- 1 row fixed
├──────────────┬──────────────────────────────────┤
│ project/     │                                  │
│ ├─ main.go   │  package main                    │
│ ├─ utils.go  │                                  │  <- remaining height
│ └─ go.mod    │  func main() {                   │
│              │      // ...                      │
│  30 cols     │      remaining width             │
├──────────────┴──────────────────────────────────┤
│ main.go | UTF-8 | Go                            │  <- 1 row fixed
└─────────────────────────────────────────────────┘
```

**Nested proportional example -- three-column layout with 1:2:1 ratio:**

```go
layout := tview.NewFlex().
    SetDirection(tview.FlexColumn).
    AddItem(leftPanel, 0, 1, false).   // 1/4 of width
    AddItem(centerPanel, 0, 2, true).  // 2/4 of width (double)
    AddItem(rightPanel, 0, 1, false)   // 1/4 of width
```

### Grid

`Grid` implements a CSS Grid-inspired layout with defined rows and columns. Its key differentiator is **responsive breakpoints** -- different items can be shown at different terminal sizes.

```go
grid := tview.NewGrid()
```

**Defining rows and columns:**

```go
// SetRows/SetColumns accept a variadic list of sizes:
//   >0  = fixed size in cells
//   0   = proportional (weight 1)
//  -N   = proportional (weight N), e.g., -3 gets 3x the space of 0 or -1
grid.SetRows(3, 0, 3)        // 3 fixed, flexible, 3 fixed
grid.SetColumns(30, 0, 30)   // 30 fixed, flexible, 30 fixed
```

Zero and `-1` are equivalent (both mean proportion weight 1). `-3` means three times the proportional space of `-1`.

**AddItem with responsive breakpoints:**

```go
func (g *Grid) AddItem(
    p Primitive,       // the widget
    row, column int,   // grid position (0-indexed)
    rowSpan int,       // how many rows to span
    colSpan int,       // how many columns to span
    minGridHeight int, // minimum grid height to show this item (0 = always)
    minGridWidth int,  // minimum grid width to show this item (0 = always)
    focus bool,        // whether this item can receive focus
) *Grid
```

The `minGridHeight` and `minGridWidth` parameters are the responsive mechanism. An item is only visible when the overall grid dimensions meet or exceed both minimums. When multiple items target the same primitive, the one with the highest applicable minimum is used.

**Responsive layout example -- header/footer with collapsible sidebar:**

```go
// Create widgets
header  := tview.NewTextView().SetText("Application Header")
footer  := tview.NewTextView().SetText("Status: Ready")
menu    := tview.NewList().AddItem("Dashboard", "", 'd', nil)
main    := tview.NewTextView().SetText("Main content area")
sidebar := tview.NewTextView().SetText("Sidebar info")

grid := tview.NewGrid().
    SetRows(3, 0, 3).            // header (3), content (flex), footer (3)
    SetColumns(30, 0, 30).       // menu (30), main (flex), sidebar (30)
    SetBorders(true)

// Header and footer always span full width
grid.AddItem(header, 0, 0, 1, 3, 0, 0, false)
grid.AddItem(footer, 2, 0, 1, 3, 0, 0, false)

// Narrow layout (< 100 columns): main content spans all 3 columns
grid.AddItem(main, 1, 0, 1, 3, 0, 0, false)

// Wide layout (>= 100 columns): three-column layout
grid.AddItem(menu,    1, 0, 1, 1, 0, 100, true)
grid.AddItem(main,    1, 1, 1, 1, 0, 100, false)
grid.AddItem(sidebar, 1, 2, 1, 1, 0, 100, false)
```

Behavior:

- **Terminal width < 100**: Only the `main` item (with `minGridWidth=0`) is visible in the middle row, spanning all three columns. The menu and sidebar are hidden.
- **Terminal width >= 100**: The three-column layout activates. `menu`, `main`, and `sidebar` each occupy their own column. The full-width `main` item is superseded because the three narrow items have a higher `minGridWidth`.

This mechanism provides CSS media query-like responsive behavior without any imperative resize handling.

**Grid spacing:**

```go
grid.SetGap(1, 2)           // 1 row gap, 2 column gap between cells
grid.SetMinSize(5, 10)      // minimum row height 5, minimum column width 10
```

### Pages

`Pages` manages a stack of named primitives, enabling tab-like or screen-switching behavior:

```go
pages := tview.NewPages()

pages.AddPage("main", mainView, true, true)       // name, primitive, resize, visible
pages.AddPage("settings", settingsView, true, false)
pages.AddPage("help", helpView, true, false)

// Switch between pages
pages.SwitchToPage("settings")

// Show a modal overlay (visible on top of current page)
pages.AddPage("confirm", modal, false, true)

// Query state
name, _ := pages.GetFrontPage()
```

Pages can be overlaid (multiple visible simultaneously) or exclusive (one at a time via `SwitchToPage`).

---

## Widget/Component System

tview provides a comprehensive set of built-in widgets. Most embed `Box`, which provides border, title, padding, background color, and focus highlight for free.

### Built-in Widgets

**Text display:**

| Widget     | Description                                                                                                |
| ---------- | ---------------------------------------------------------------------------------------------------------- |
| `TextView` | Scrollable text display with color tags, regions, word wrap. Implements `io.Writer` for streaming content. |
| `Table`    | Navigable table with selectable rows/columns/cells, fixed headers, and per-cell styling.                   |
| `Image`    | Terminal image rendering with dithering and aspect ratio control.                                          |

**Input:**

| Widget       | Description                                                                                       |
| ------------ | ------------------------------------------------------------------------------------------------- |
| `InputField` | Single-line text input with validation (`SetAcceptanceFunc`), autocomplete, and placeholder text. |
| `TextArea`   | Multi-line text editor with cursor, selection, clipboard, word wrap, and undo.                    |

**Selection:**

| Widget     | Description                                                                            |
| ---------- | -------------------------------------------------------------------------------------- |
| `List`     | Scrollable list with main/secondary text, keyboard shortcuts, and selection callbacks. |
| `DropDown` | Combo box with selectable options.                                                     |
| `Checkbox` | Toggle with customizable checked/unchecked strings.                                    |

**Navigation:**

| Widget         | Description                                            |
| -------------- | ------------------------------------------------------ |
| `TreeView`     | Expandable/collapsible tree with `TreeNode` hierarchy. |
| `Pages`        | Stacked page manager for view switching.               |
| `TabbedPanels` | Tabbed container with labeled tab bar.                 |

**Layout and decoration:**

| Widget  | Description                                                      |
| ------- | ---------------------------------------------------------------- |
| `Flex`  | Flexbox-style layout container.                                  |
| `Grid`  | CSS Grid-style layout with responsive breakpoints.               |
| `Frame` | Decorative wrapper adding header/footer text around a primitive. |
| `Modal` | Centered dialog with text and buttons.                           |
| `Form`  | Vertical/horizontal form aggregating input widgets and buttons.  |

### Box -- The Base Widget

Most widgets embed `Box`, which provides:

- **Border** with customizable style, color, and attributes
- **Title** with alignment (left, center, right) and color
- **Padding** inside the border
- **Background color**
- **Focus highlight** (border color changes when focused)
- **Input/mouse capture** at the widget level
- **Custom draw function** for overlaying content

```go
box := tview.NewBox().
    SetBorder(true).
    SetBorderColor(tcell.ColorCyan).
    SetTitle(" My Widget ").
    SetTitleAlign(tview.AlignCenter).
    SetBorderPadding(1, 1, 2, 2).    // top, bottom, left, right
    SetBackgroundColor(tcell.ColorDefault)
```

### Custom Widgets

To create a custom widget, either embed `Box` (recommended) or implement `Primitive` from scratch.

**Embedding Box for a custom gauge widget:**

```go
type Gauge struct {
    *tview.Box
    value   float64 // 0.0 to 1.0
    label   string
    barChar rune
}

func NewGauge(label string) *Gauge {
    return &Gauge{
        Box:     tview.NewBox(),
        label:   label,
        barChar: '\u2588', // full block
    }
}

func (g *Gauge) SetValue(v float64) *Gauge {
    g.value = v
    return g
}

func (g *Gauge) Draw(screen tcell.Screen) {
    // Draw the box (border, title, background)
    g.Box.DrawForSubclass(screen, g)

    // Get the inner area (inside border and padding)
    x, y, width, height := g.GetInnerRect()
    if width <= 0 || height <= 0 {
        return
    }

    // Draw label
    tview.Print(screen, g.label, x, y, width, tview.AlignLeft, tcell.ColorWhite)

    // Draw bar on the next line
    if height > 1 {
        barWidth := int(float64(width) * g.value)
        for i := 0; i < barWidth; i++ {
            screen.SetContent(x+i, y+1, g.barChar, nil,
                tcell.StyleDefault.Foreground(tcell.ColorGreen))
        }
    }
}
```

Usage:

```go
gauge := NewGauge("CPU Usage").SetValue(0.73)
gauge.SetBorder(true).SetTitle(" System Monitor ")

app.SetRoot(gauge, true).Run()
```

### Form

`Form` aggregates input widgets and buttons into a cohesive form layout:

```go
form := tview.NewForm().
    AddInputField("Name", "", 30, nil, nil).
    AddPasswordField("Password", "", 30, '*', nil).
    AddDropDown("Role", []string{"Admin", "User", "Guest"}, 1, nil).
    AddCheckbox("Remember me", false, nil).
    AddTextArea("Notes", "", 40, 5, 0, nil).
    AddButton("Submit", func() {
        // Access form data
        name := form.GetFormItemByLabel("Name").(*tview.InputField).GetText()
        // Process submission...
    }).
    AddButton("Cancel", func() {
        app.Stop()
    })

form.SetBorder(true).SetTitle(" Registration ").SetTitleAlign(tview.AlignCenter)
```

---

## Styling

tview uses two styling mechanisms: **tag-based inline styling** for text content, and **programmatic styling** via tcell's `Style` type for widget properties.

### Tag-Based Text Styling

Text displayed in `TextView`, `List`, `Table`, and other widgets can include inline style tags. Tags use square brackets:

```
[<foreground>:<background>:<attributes>:<url>]
```

Each field is optional. Unspecified fields remain unchanged from the current style. A dash (`-`) resets a field to the default.

**Color specification:**

- W3C color names: `red`, `green`, `blue`, `yellow`, `white`, `cyan`, `magenta`, etc.
- Hex colors: `#FF6347`, `#8080ff`

**Attribute flags** (lowercase to enable, uppercase to disable):

| Flag | Attribute      |
| ---- | -------------- |
| `b`  | Bold           |
| `d`  | Dim            |
| `i`  | Italic         |
| `l`  | Blink          |
| `r`  | Reverse        |
| `s`  | Strike-through |
| `u`  | Underline      |

**Examples:**

```go
textView := tview.NewTextView().
    SetDynamicColors(true).  // Enable tag parsing
    SetText(
        "[yellow::b]Warning:[-::-] Disk usage is at [red]92%[white]\n" +
        "[green]System[white] is [::i]operational[::I]\n" +
        "[#8080ff:#1a1a2e]Custom colors on dark background[-:-:-]\n" +
        "Click [:::https://example.com]here[:::-] for details",
    )
```

Produces:

- **Warning:** in bold yellow, followed by normal text with "92%" in red
- "System" in green, "operational" in italic
- Custom hex foreground/background colors
- "here" as a terminal hyperlink (OSC 8)

**Escaping tags:**

To display literal brackets, insert `[` before the closing bracket:

```go
"Show [red[] literally"  // Displays: Show [red] literally
```

The `tview.Escape()` function automates escaping.

**ANSI-to-tag conversion:**

```go
// Convert ANSI escape codes to tview tags
tagged := tview.TranslateANSI(ansiColoredOutput)

// Or use a writer that converts on the fly
fmt.Fprintf(tview.ANSIWriter(textView), "\033[31mred text\033[0m")
```

### Programmatic Styling

Widget properties are set via setter methods using tcell types:

```go
// Per-widget colors
textView.SetTextColor(tcell.ColorGreen)
textView.SetBackgroundColor(tcell.ColorDefault)

// Table cell styling
cell := tview.NewTableCell("Important").
    SetTextColor(tcell.ColorRed).
    SetAttributes(tcell.AttrBold).
    SetAlign(tview.AlignCenter).
    SetExpansion(1)    // flex factor for column width

// tcell.Style for full control
style := tcell.StyleDefault.
    Foreground(tcell.NewRGBColor(255, 99, 71)).
    Background(tcell.ColorDefault).
    Bold(true).
    Italic(true)
inputField.SetFieldStyle(style)
```

### Global Theme

tview provides a global `Styles` variable for theming:

```go
tview.Styles = tview.Theme{
    PrimitiveBackgroundColor:    tcell.ColorBlack,
    ContrastBackgroundColor:     tcell.ColorBlue,
    MoreContrastBackgroundColor: tcell.ColorGreen,
    BorderColor:                 tcell.ColorCyan,
    TitleColor:                  tcell.ColorWhite,
    GraphicsColor:               tcell.ColorCyan,
    PrimaryTextColor:            tcell.ColorWhite,
    SecondaryTextColor:          tcell.ColorYellow,
    TertiaryTextColor:           tcell.ColorGreen,
    InverseTextColor:            tcell.ColorBlack,
    ContrastSecondaryTextColor:  tcell.ColorDarkCyan,
}
```

All built-in widgets reference `tview.Styles` for their default colors, so changing this variable themes the entire application.

---

## Event Handling

tview uses a **framework-managed, callback-based** event system. Events flow from the terminal through the `Application` to the focused widget, with interception points at multiple levels.

### Global Input Capture

`SetInputCapture` on `Application` intercepts all key events before they reach any widget:

```go
app.SetInputCapture(func(event *tcell.EventKey) *tcell.EventKey {
    switch event.Key() {
    case tcell.KeyEsc:
        app.Stop()
        return nil   // consume the event
    case tcell.KeyCtrlS:
        saveFile()
        return nil
    }
    switch event.Rune() {
    case 'q':
        if !editor.HasFocus() {  // don't consume 'q' if editor is focused
            app.Stop()
            return nil
        }
    }
    return event  // pass to focused widget
})
```

Returning `nil` consumes the event. Returning the event (or a modified event) passes it downstream.

### Widget-Level Input Capture

Any widget (anything embedding `Box`) can install its own capture:

```go
sidebar.SetInputCapture(func(event *tcell.EventKey) *tcell.EventKey {
    if event.Key() == tcell.KeyTab {
        app.SetFocus(editor)
        return nil
    }
    return event
})
```

The capture chain is: Application capture -> focused widget's ancestor captures (top-down) -> focused widget's `InputHandler`.

### Widget-Specific Callbacks

Each widget type provides semantically appropriate callbacks:

```go
// InputField -- text changes and completion
input.SetChangedFunc(func(text string) {
    // Called on every keystroke
    results := search(text)
    updateResults(results)
})
input.SetDoneFunc(func(key tcell.Key) {
    // Called when Enter, Tab, or Escape is pressed
    if key == tcell.KeyEnter {
        submit(input.GetText())
    }
})
input.SetAutocompleteFunc(func(currentText string) []string {
    // Return suggestions based on current text
    return filterSuggestions(currentText)
})

// List -- selection events
list.SetSelectedFunc(func(index int, main, secondary string, shortcut rune) {
    // Item activated (Enter pressed)
    openItem(index)
})
list.SetChangedFunc(func(index int, main, secondary string, shortcut rune) {
    // Highlight moved (arrow keys)
    previewItem(index)
})

// Table -- cell selection
table.SetSelectedFunc(func(row, column int) {
    cell := table.GetCell(row, column)
    editCell(row, column, cell.Text)
})
table.SetSelectionChangedFunc(func(row, column int) {
    updateStatusBar(row, column)
})

// TreeView -- node events
tree.SetSelectedFunc(func(node *tview.TreeNode) {
    // Node activated
    if node.IsExpanded() {
        node.Collapse()
    } else {
        node.Expand()
    }
})

// Form -- cancel
form.SetCancelFunc(func() {
    pages.SwitchToPage("main")
})
```

### Mouse Handling

```go
// Enable mouse globally
app.EnableMouse(true)

// Global mouse capture
app.SetMouseCapture(func(event *tcell.EventMouse, action tview.MouseAction) (tview.MouseAction, *tcell.EventMouse) {
    if action == tview.MouseLeftClick {
        x, y := event.Position()
        logClick(x, y)
    }
    return action, event  // pass to widgets
})

// Widget-level mouse capture
widget.SetMouseCapture(func(action tview.MouseAction, event *tcell.EventMouse) (tview.MouseAction, *tcell.EventMouse) {
    // Handle or pass through
    return action, event
})
```

### Thread-Safe Updates from Goroutines

When background goroutines need to update widgets, they must use `QueueUpdate` or `QueueUpdateDraw` to serialize access on the main event loop goroutine:

```go
go func() {
    // Background work (HTTP request, file I/O, etc.)
    data, err := fetchData()

    // WRONG: directly mutating a widget from a goroutine
    // textView.SetText(data)  // RACE CONDITION

    // CORRECT: queue the update to run on the main goroutine
    app.QueueUpdateDraw(func() {
        if err != nil {
            textView.SetText("[red]Error: " + err.Error())
        } else {
            textView.SetText(data)
        }
    })
}()
```

- `QueueUpdate(f)` executes `f` on the main goroutine but does **not** trigger a redraw.
- `QueueUpdateDraw(f)` executes `f` and then redraws. This is the most common choice.
- `Draw()` can also be called from any goroutine to trigger a redraw without queuing a function.

---

## State Management

tview takes an **object-oriented, widgets-own-their-state** approach. There is no framework-imposed state pattern like Bubble Tea's MVU.

### Widgets as State Containers

Each widget holds its own state internally and exposes it through getters and setters:

```go
// InputField owns its text
input.SetText("initial value")
text := input.GetText()

// List owns its items and selection
list.AddItem("Item 1", "Description", '1', nil)
index, text := list.GetCurrentItem()

// Table owns its cells
table.SetCell(0, 0, tview.NewTableCell("Name").SetTextColor(tcell.ColorYellow))
cell := table.GetCell(0, 0)

// TreeView owns its node hierarchy
root := tview.NewTreeNode("Root")
child := tview.NewTreeNode("Child")
root.AddChild(child)
tree.SetRoot(root)
currentNode := tree.GetCurrentNode()

// TextView owns its text content and scroll position
textView.SetText("content")
textView.ScrollToEnd()
rows, cols := textView.GetScrollOffset()
```

### Application-Level State

Since widgets own their state, there is no single model struct. Application state is typically spread across:

1. The widget tree itself (text content, selection indices, scroll positions).
2. Closure variables captured by callbacks.
3. Optionally, an explicit application struct that holds references to widgets.

```go
type App struct {
    app      *tview.Application
    pages    *tview.Pages
    list     *tview.List
    detail   *tview.TextView
    items    []Item          // domain data
    selected int
}

func (a *App) onItemSelected(index int, _, _ string, _ rune) {
    a.selected = index
    item := a.items[index]
    a.detail.SetText(item.Description)
}
```

### Thread Safety

Widget state is not inherently thread-safe. All mutations must happen on the main event loop goroutine (inside callbacks or via `QueueUpdate`). The `QueueUpdate`/`QueueUpdateDraw` mechanism is the only safe way to mutate widgets from background goroutines.

---

## Extensibility and Ecosystem

### Built-in Completeness

tview's main extensibility strategy is to provide a comprehensive built-in widget set. The library includes widgets for most common terminal UI needs: text display, forms, tables, trees, modals, tabs, and flexible layouts. This reduces the need for third-party components compared to more minimal frameworks.

### Custom Widgets

Custom widgets are created by implementing `Primitive` (usually by embedding `Box`):

1. Embed `*tview.Box` for free border, title, padding, and focus support.
2. Override `Draw(screen tcell.Screen)` for custom rendering.
3. Optionally override `InputHandler()` and `MouseHandler()` for custom interaction.
4. Call `Box.DrawForSubclass(screen, self)` in `Draw` to render the box chrome.

### Community Extensions

The tview ecosystem is smaller than Charm's. Some third-party projects extend tview with additional widgets (e.g., enhanced file browsers, syntax-highlighted text views), but the community relies primarily on the built-in set. Notable applications built with tview include:

- **K9s** -- Kubernetes cluster management CLI
- **lazydocker** -- Docker management TUI
- **podman-tui** -- Podman container management

### Limitations vs. Bubble Tea Ecosystem

- No equivalent to Lip Gloss's standalone styling library (tview's styling is tag-based and widget-bound).
- No SSH serving equivalent to Wish.
- No shell-scripting tool equivalent to Gum.
- Community contributions tend to be applications rather than reusable component libraries.

---

## Strengths

- **Comprehensive built-in widget set** -- covers text, tables, forms, trees, tabs, modals, and more without third-party dependencies.
- **Flex and Grid layout system** -- the most capable layout system among Go TUI libraries. Proportional sizing, fixed sizes, and nesting handle complex layouts declaratively.
- **Responsive layout via Grid breakpoints** -- `minGridWidth`/`minGridHeight` parameters enable CSS media query-like behavior, showing different layouts at different terminal sizes.
- **Built-in focus management** -- the framework tracks focus, routes input to the focused widget, and supports Tab/Shift-Tab navigation in forms. Developers do not need to implement focus tracking.
- **Easy to get started** -- a functional UI can be built in under 20 lines. The widget-tree approach is intuitive for developers familiar with desktop UI toolkits (Qt, GTK, WPF).
- **Good for form-heavy applications** -- the `Form` widget aggregates inputs, dropdowns, checkboxes, and buttons with automatic focus cycling.
- **Thread-safe update queue** -- `QueueUpdate`/`QueueUpdateDraw` provide a clean pattern for background goroutine-to-UI communication.
- **Chainable API** -- all setters return the receiver, enabling fluent construction.
- **Mature and stable** -- actively maintained since 2018, used in production by major projects (K9s, lazydocker).

---

## Weaknesses and Limitations

- **Monolithic design** -- tview is a single package with tightly coupled widgets. You cannot use the layout system without the widget system, or the styling without the event loop.
- **Widgets are harder to customize than in Ratatui/Bubble Tea** -- widget rendering is encapsulated inside `Draw` methods. Changing how a `List` renders its items requires forking the widget rather than passing a custom render function.
- **Less testable than MVU** -- state is distributed across mutable widgets. Testing requires constructing an `Application`, sending synthetic events, and inspecting widget state via getters. There is no equivalent to Bubble Tea's "send a message, assert on the model" pattern.
- **Callback-heavy architecture** -- complex applications accumulate many `SetChangedFunc`, `SetSelectedFunc`, `SetDoneFunc`, and `SetInputCapture` callbacks, which can be harder to trace than a single `Update` function.
- **Tag-based styling is limited** -- style tags in text content are powerful for inline coloring but cannot express layout, padding, or borders. The tag syntax is tview-specific and not reusable outside the framework.
- **Less composable than functional approaches** -- widgets are concrete types with fixed behavior. Composition relies on embedding (Go struct embedding) rather than functional composition, making it harder to create mix-and-match behavior.
- **Full-tree redraw on every event** -- while tcell diffs the cell buffer, the entire widget tree is traversed and `Draw` is called on every widget for every event. For very deep widget trees this adds overhead, though in practice terminal UIs are rarely deep enough for this to matter.
- **No incremental or virtual rendering** -- all widgets are drawn, even those outside the viewport. No virtualization for large lists or tables (though `SetContent` provides a virtual table interface for data).

---

## Lessons for D / Sparkles

### Flex Layout

tview's `AddItem(widget, fixedSize, proportion)` API maps naturally to D named parameters:

```d
flex.add(widget, fixed: 0, proportion: 1);
flex.add(header, fixed: 3, proportion: 0);
```

The proportional size algorithm (linear distribution of remaining space by weight) is simple enough to implement `@nogc` with a fixed-size scratch buffer for tracking item sizes. A `SmallBuffer!(FlexItem, 16)` would handle typical layout trees without allocation.

### Grid with Responsive Breakpoints

tview's responsive Grid is one of its most interesting features. D's CTFE could validate grid definitions at compile time:

```d
// Compile-time grid validation
enum layout = Grid.define(
    rows: [3, 0, 3],          // header, flex, footer
    columns: [30, 0, 30],     // sidebar, flex, sidebar
);
static assert(layout.rows.length == 3);
static assert(layout.columns.length == 3);

// Runtime breakpoints via terminal size
if (termWidth >= 100)
    grid.show(menu, sidebar);
else
    grid.hide(menu, sidebar);
```

The `minGridWidth`/`minGridHeight` approach could be expressed as a list of layout rules evaluated at runtime, with the grid definition itself validated at compile time.

### Box Embedding Pattern

tview's `Box` provides border, title, padding, and focus highlight to all widgets. In D, this could be achieved through:

- **`alias this`** -- a widget struct with `alias this` to a `BoxProperties` member, giving transparent access to border/title/padding methods.
- **Mixin templates** -- `mixin BoxBehavior;` injecting border drawing, padding calculation, and focus tracking into any widget struct.

```d
struct MyWidget
{
    mixin BoxBehavior;  // provides draw border, getInnerRect, focus handling

    void drawContent(ref Screen screen, Rect inner)
    {
        // Custom rendering within the inner rect
    }
}
```

### Primitive Interface as Template Constraint

Go's `Primitive` interface is checked at runtime via duck typing. D can check it at compile time using template constraints or Design by Introspection:

```d
enum isPrimitive(T) = is(typeof((T t) {
    tcell.Screen s;
    t.draw(s);
    auto r = t.getRect();    // returns Rect
    t.setRect(0, 0, 80, 24);
    bool f = t.hasFocus();
    t.focus();
    t.blur();
}));

void addItem(P)(P widget, int fixedSize, int proportion)
if (isPrimitive!P)
{
    // Statically dispatched -- no virtual call overhead
}
```

This gives the same polymorphism as Go's interface but with compile-time checking and monomorphized code generation. For runtime polymorphism, a type-erased wrapper (like `std.variant` or a manual vtable) could be used.

### Tag-Based Text Styling at Compile Time

tview parses `[red::b]text[-::-]` at runtime. D's compile-time string parsing could validate and convert tags at compile time:

```d
// Compile-time tag parsing and validation
enum styledText = parseStyleTags!("[red::b]Warning:[-::-] Disk at [yellow]92%[-]");
// styledText is a StyledSpan[] computed at compile time
// Invalid tags produce a compile error with line/column info

// Runtime: just iterate pre-parsed spans, no parsing overhead
void render(ref Screen screen, typeof(styledText) spans) @nogc { ... }
```

This eliminates the runtime parsing cost and catches malformed tags at compile time rather than silently ignoring them.

### QueueUpdate for Thread-Safe UI Updates

tview's `QueueUpdate` pattern maps to D's `std.concurrency`:

```d
import std.concurrency : send, receive, thisTid, spawn;

// Background thread sends UI updates as messages
spawn({
    auto data = fetchData();
    send(ownerTid, UIUpdate(data));
});

// Main event loop receives and applies updates
receive(
    (UIUpdate update) {
        widget.setText(update.text);
        screen.redraw();
    },
);
```

D's `send`/`receive` provides typed message passing with compile-time safety, similar to `QueueUpdate` but without the untyped `func()` closure.

### Focus Management

tview's built-in focus management (tracking the focused widget, routing input, supporting Tab navigation) is worth adopting. Most minimal TUI libraries leave focus management to the developer, which is error-prone and repetitive. A D framework could provide:

- A focus tracker in the application struct that maintains a `Primitive*` or type-erased reference.
- Automatic Tab/Shift-Tab cycling through focusable children in layout containers.
- `setFocus` delegate passed to input handlers, matching tview's pattern.

```d
struct Application
{
    Primitive focused;

    void setFocus(Primitive p)
    {
        if (focused !is null)
            focused.blur();
        focused = p;
        focused.focus();
    }

    void handleKey(KeyEvent event)
    {
        if (event.key == Key.tab)
            setFocus(focused.nextFocusable());
        else if (focused !is null)
            focused.handleInput(event, &setFocus);
    }
}
```

---

## References

- **Repository**: <https://github.com/rivo/tview>
- **API Documentation**: <https://pkg.go.dev/github.com/rivo/tview>
- **Wiki (tutorials, custom widgets, concurrency)**: <https://github.com/rivo/tview/wiki>
- **tcell (terminal backend)**: <https://github.com/gdamore/tcell>
- **uniseg (Unicode segmentation)**: <https://github.com/rivo/uniseg>
- **Grid demo (responsive layout)**: <https://github.com/rivo/tview/tree/master/demos/grid>
- **Flex demo**: <https://github.com/rivo/tview/tree/master/demos/flex>
- **K9s (major tview application)**: <https://github.com/derailed/k9s>
