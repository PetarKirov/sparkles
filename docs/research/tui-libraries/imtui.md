# ImTui (C++)

A terminal backend for Dear ImGui that brings the entire immediate-mode GUI widget library to text-based terminals, mapping pixel draw commands to character cells via ncurses.

| Field        | Value                                             |
| ------------ | ------------------------------------------------- |
| Language     | C++                                               |
| License      | MIT                                               |
| Repository   | <https://github.com/ggerganov/imtui>              |
| Dear ImGui   | v1.81 (bundled)                                   |
| GitHub Stars | ~3.5k                                             |
| Dependencies | libncurses (terminal), Emscripten (web, optional) |

---

## Overview

ImTui is a terminal rendering backend for Dear ImGui, the widely-used C++ immediate-mode
GUI library. Rather than rendering to a GPU framebuffer as Dear ImGui normally does, ImTui
intercepts ImGui's draw lists and converts them into character cells displayed in a text
terminal via ncurses. The result is that the **entire Dear ImGui widget library** -- windows,
buttons, sliders, text inputs, trees, tables, menus, popups, tabs, plots -- works
unmodified in a terminal.

**What it solves.** Building interactive terminal UIs typically requires a dedicated widget
toolkit (ncurses panels, custom rendering logic, manual state management). ImTui sidesteps
all of this by reusing Dear ImGui's battle-tested widget set. If you already know ImGui's
API, you can build a terminal application with zero additional learning.

**Design philosophy.** ImTui inherits Dear ImGui's **pure immediate-mode** paradigm. There
are no widget objects. There is no retained tree. There are no callbacks. The UI is a
function of your data, called every frame. A button is a single function call that returns
`true` when clicked. A slider is a function call that modifies a float by pointer. The
application owns all state; ImGui holds only transient interaction metadata (which widget
is hovered, which is active, current input state).

This represents one extreme of the TUI design space: where Textual (Python) is fully
retained-mode with a persistent widget tree, CSS styling, and message passing, ImTui is
fully immediate-mode with no widget lifecycle, no event routing, and no state
synchronization -- just function calls that write to a buffer.

**Author.** ImTui was created by Georgi Gerganov, also the creator of llama.cpp and
whisper.cpp. The project demonstrates his interest in efficient, minimal C++ systems that
do more with less.

---

## Architecture

### Pure Immediate-Mode Rendering

ImTui follows Dear ImGui's architecture exactly. The rendering pipeline each frame is:

```
Application State
    |
    v
ImGui function calls (Button, Text, SliderFloat, ...)
    |
    v
ImGui builds internal draw lists (vertices, indices, draw commands)
    |
    v
ImTui_ImplText_RenderDrawData() converts draw lists to TScreen cells
    |
    v
ImTui_ImplNcurses_DrawScreen() diffs against previous frame, writes to terminal
    |
    v
Terminal emulator
```

There is no retained widget tree anywhere in this pipeline. Each frame, the application
calls ImGui functions in sequence. ImGui accumulates geometry (triangles, text glyphs) into
draw lists. ImTui's text backend rasterizes those triangles into a flat array of character
cells. The ncurses backend diffs the current frame against the previous frame and writes
only the changed cells to the terminal.

### No Widget Objects

In Dear ImGui / ImTui, there are no widget objects to construct, configure, store, or
destroy. A button is:

```cpp
if (ImGui::Button("Click me")) {
    // Handle click -- this block executes on the frame the button is pressed
}
```

This single line:

1. Lays out the button at the current cursor position
2. Renders the button text and border into the draw list
3. Checks if the mouse is over the button (hover state)
4. Checks if the mouse button was pressed and released on it (active/click state)
5. Returns `true` if the button was activated this frame

The widget function IS the render code IS the event handling code. There is nothing to
construct beforehand and nothing to clean up afterward.

### The Hot/Active Widget Model

Instead of a focus tree or event propagation system, Dear ImGui uses a simple two-state
model for widget interaction:

- **Hot** -- the mouse cursor is currently over this widget. Determines hover highlights.
- **Active** -- the user is currently interacting with this widget (mouse button is held
  down on it). Only one widget can be active at a time.

Widget identity is determined by an **ID stack** built from string labels, integer indices,
and pointer values. When you call `ImGui::Button("OK")`, ImGui hashes the string `"OK"`
combined with the current window's ID to produce a unique identifier. This ID is used to
track hot/active state across frames without storing any widget objects.

### Double-Buffered Terminal Output

ImTui's ncurses backend maintains a `screenPrev` buffer that records the previous frame's
cells. During `ImTui_ImplNcurses_DrawScreen()`, it compares current and previous frames
row-by-row and character-by-character, emitting ncurses calls only for changed cells. This
minimizes terminal I/O and reduces flicker.

### Cell Data Format

Each terminal cell is packed into a 32-bit `TCell` value:

```
Bits  0-15:  character code (ASCII/Unicode codepoint)
Bits 16-23:  foreground color index (ANSI 256-color palette)
Bits 24-31:  background color index (ANSI 256-color palette)
```

This compact representation enables efficient diffing and bulk memory operations.

---

## Terminal Backend

ImTui provides multiple backend implementations that bridge Dear ImGui's rendering to
different output targets.

### ImTui_ImplNcurses (Terminal)

The primary backend for native terminal applications.

```cpp
// Initialization
ImTui::TScreen* screen = ImTui_ImplNcurses_Init(
    true,   // mouseSupport
    60.0f,  // fps_active  -- redraw rate when application is active
    -1.0f   // fps_idle    -- redraw rate when idle (-1 = same as active)
);

// Per-frame
bool hadInput = ImTui_ImplNcurses_NewFrame();  // returns true if user input occurred
// ... ImGui calls ...
ImTui_ImplNcurses_DrawScreen(hadInput);  // uses active or idle FPS based on input

// Shutdown
ImTui_ImplNcurses_Shutdown();
```

The ncurses backend handles:

- **Terminal initialization:** `initscr()`, `cbreak()`, `noecho()`, `curs_set(0)` for raw
  mode with hidden cursor.
- **Color pairs:** Dynamically allocates ncurses color pairs from a 256x256 foreground/
  background lookup table via `init_pair()`.
- **Mouse support:** Enables terminal mouse reporting, decodes button press/release and
  scroll events via `getmouse()`, and feeds coordinates into `ImGui::GetIO().MousePos`.
- **Keyboard input:** Maps ncurses key codes to ImGui key indices. Handles arrow keys,
  function keys, and synthesizes modifier states (Ctrl+A/C/V/X/Y/Z).
- **VSync / frame pacing:** A `VSync` class manages active and idle frame rates using
  `std::this_thread::sleep_for()`, with input-aware wake-up to maintain responsiveness.

### ImTui_ImplText (Core Rasterizer)

The text backend is the core of ImTui. It converts Dear ImGui's vector draw data (triangles
from the draw list) into character cells on a `TScreen`.

```cpp
ImTui_ImplText_Init();                                        // configure ImGui style for terminal
ImTui_ImplText_NewFrame();                                    // prepare for new frame
// ... ImGui calls, then ImGui::Render() ...
ImTui_ImplText_RenderDrawData(ImGui::GetDrawData(), screen);  // rasterize to cells
```

The rasterizer:

- **Triangle rasterization:** Implements scanline fill for each triangle in the draw list,
  computing horizontal spans per row and filling cells within clipped bounds.
- **Glyph rendering:** For text characters (detected by varying UV coordinates across
  triangle vertices), computes the centroid of the glyph's two triangles, snaps to integer
  cell coordinates, and writes the character with its color.
- **Color conversion:** The `rgbToAnsi256()` function maps ImGui's 32-bit RGBA colors to
  the ANSI 256-color palette -- detecting grayscale values for the 232-255 range and
  converting RGB to the 6x6x6 color cube (indices 16-231).
- **Style configuration:** On init, configures ImGui for terminal constraints: disables
  anti-aliasing, sets minimal padding/spacing, and uses a 1.0-pixel monospace-compatible
  font size.

### ImTui_ImplEmscripten (WebAssembly)

An Emscripten backend that compiles ImTui to WebAssembly and renders to an HTML page. The
browser displays a grid of styled `<span>` elements mimicking a terminal. Input is bridged
from JavaScript to C++ via `EMSCRIPTEN_KEEPALIVE` exported functions:

- `set_mouse_pos()`, `set_mouse_down()`, `set_mouse_up()`, `set_mouse_wheel()`
- `set_key_down()`, `set_key_up()`, `set_key_press()`
- Modifier key tracking for Shift, Ctrl, Alt

This enables live web demos of ImTui applications (e.g., the hnterm Hacker News client runs
at hnterm.ggerganov.com).

### Capabilities Summary

| Capability    | Support                                                   |
| ------------- | --------------------------------------------------------- |
| Colors        | ANSI 256-color palette (mapped from ImGui's true color)   |
| Mouse         | Click, release, scroll (via ncurses mouse reporting)      |
| Keyboard      | Full key input with modifier detection                    |
| Unicode       | Basic (single-codepoint characters, no grapheme clusters) |
| Box drawing   | Not native -- uses ASCII approximations from ImGui        |
| True color    | No (quantized to 256-color)                               |
| Web rendering | Yes (via Emscripten/WebAssembly)                          |

---

## Layout System

ImTui inherits Dear ImGui's **cursor-based procedural layout**. There is no constraint
solver, no flexbox, no grid system. Layout is purely sequential: ImGui maintains a cursor
position within each window, and each widget advances the cursor.

### Cursor Model

By default, each widget occupies a full row and advances the cursor downward. The
application controls layout with explicit commands:

```cpp
// Vertical stacking (default)
ImGui::Text("Line 1");       // cursor moves down
ImGui::Text("Line 2");       // cursor moves down again

// Horizontal placement
ImGui::Text("Left");
ImGui::SameLine();            // next widget goes on the same line
ImGui::Text("Right");

// Explicit width
ImGui::SetNextItemWidth(200); // next input/slider will be 200 pixels wide
ImGui::SliderFloat("##val", &value, 0.0f, 1.0f);

// Indentation
ImGui::Indent(16.0f);
ImGui::Text("Indented text");
ImGui::Unindent(16.0f);
```

### Child Regions

Scrollable sub-regions are created with `BeginChild` / `EndChild`:

```cpp
ImGui::BeginChild("scrolling_region", ImVec2(0, 200), true);
for (int i = 0; i < 100; i++)
    ImGui::Text("Item %d", i);
ImGui::EndChild();
```

The child region clips its content and provides independent scrolling.

### Columns and Tables

Multi-column layouts use the table API:

```cpp
if (ImGui::BeginTable("my_table", 3)) {
    ImGui::TableSetupColumn("Name");
    ImGui::TableSetupColumn("Value");
    ImGui::TableSetupColumn("Action");
    ImGui::TableHeadersRow();

    for (auto& item : items) {
        ImGui::TableNextRow();
        ImGui::TableNextColumn(); ImGui::Text("%s", item.name);
        ImGui::TableNextColumn(); ImGui::Text("%d", item.value);
        ImGui::TableNextColumn();
        if (ImGui::SmallButton("Delete"))
            deleteItem(item);
    }
    ImGui::EndTable();
}
```

### Layout Example: Dashboard

```cpp
// Main window fills the terminal
ImGui::SetNextWindowPos(ImVec2(0, 0));
ImGui::SetNextWindowSize(ImGui::GetIO().DisplaySize);
ImGui::Begin("Dashboard", nullptr,
    ImGuiWindowFlags_NoResize | ImGuiWindowFlags_NoMove |
    ImGuiWindowFlags_NoCollapse);

ImGui::Text("System Monitor");
ImGui::Separator();

// Left panel (using child region for fixed width)
ImGui::BeginChild("left_panel", ImVec2(30, 0), true);
ImGui::Text("Navigation");
if (ImGui::Selectable("Overview", selected == 0)) selected = 0;
if (ImGui::Selectable("Processes", selected == 1)) selected = 1;
if (ImGui::Selectable("Network", selected == 2)) selected = 2;
ImGui::EndChild();

ImGui::SameLine();

// Right panel (fills remaining space)
ImGui::BeginChild("right_panel", ImVec2(0, 0), true);
ImGui::Text("Detail view for: %s", panels[selected]);
// ... render selected panel content ...
ImGui::EndChild();

ImGui::End();
```

### Limitations

The cursor-based layout is procedural and sequential. There is no way to express "this
widget should fill the remaining space" as a declarative constraint. Complex layouts require
manual size calculations or creative use of child regions. ImGui's layout was designed for
GPU-rendered tool windows where pixel precision is available; in a terminal, the
character-cell grid adds further constraints that ImGui is unaware of.

---

## Widget / Component System

ImTui provides access to the **full Dear ImGui widget set**. Every widget that works in
ImGui's OpenGL/Vulkan/DirectX backends works in the terminal (though visual fidelity varies
due to character-cell rendering).

### Windows

```cpp
ImGui::Begin("My Window");    // creates a movable, resizable window
// ... widgets ...
ImGui::End();

// Window with flags
ImGui::Begin("Fixed", nullptr,
    ImGuiWindowFlags_NoResize |
    ImGuiWindowFlags_NoMove |
    ImGuiWindowFlags_NoTitleBar);
```

### Text Display

```cpp
ImGui::Text("Plain text");
ImGui::TextColored(ImVec4(1,0,0,1), "Red text");
ImGui::TextWrapped("This text will wrap at the window edge...");
ImGui::TextDisabled("Grayed out");
ImGui::BulletText("Bulleted item");
ImGui::LabelText("Label", "Value: %d", 42);
```

### Buttons and Toggles

```cpp
if (ImGui::Button("Click Me"))           doSomething();
if (ImGui::SmallButton("x"))             closePanel();
if (ImGui::ArrowButton("##left", ImGuiDir_Left)) goBack();
ImGui::Checkbox("Enable feature", &enabled);
ImGui::RadioButton("Option A", &choice, 0);
ImGui::RadioButton("Option B", &choice, 1);
```

### Input Widgets

```cpp
static char name[128] = "";
ImGui::InputText("Name", name, sizeof(name));

static char bio[1024] = "";
ImGui::InputTextMultiline("Bio", bio, sizeof(bio), ImVec2(0, 100));

static int count = 0;
ImGui::InputInt("Count", &count);

static float temp = 98.6f;
ImGui::InputFloat("Temp", &temp, 0.1f, 1.0f, "%.1f");
```

### Sliders and Drags

```cpp
static float volume = 0.5f;
ImGui::SliderFloat("Volume", &volume, 0.0f, 1.0f);

static int brightness = 50;
ImGui::SliderInt("Brightness", &brightness, 0, 100);

static float speed = 1.0f;
ImGui::DragFloat("Speed", &speed, 0.01f, 0.0f, 10.0f);
```

### Selection Widgets

```cpp
// Combo box (dropdown)
static int current = 0;
const char* items[] = { "Apple", "Banana", "Cherry" };
ImGui::Combo("Fruit", &current, items, IM_ARRAYSIZE(items));

// List box
static int listIdx = 0;
ImGui::ListBox("Items", &listIdx, items, IM_ARRAYSIZE(items), 4);

// Selectable items (for custom lists)
for (int i = 0; i < itemCount; i++) {
    if (ImGui::Selectable(items[i], selected == i))
        selected = i;
}
```

### Trees and Collapsing Headers

```cpp
if (ImGui::CollapsingHeader("Settings")) {
    ImGui::Checkbox("Auto-save", &autoSave);
    ImGui::SliderInt("Interval", &interval, 1, 60);
}

if (ImGui::TreeNode("File System")) {
    if (ImGui::TreeNode("Documents")) {
        ImGui::Text("report.pdf");
        ImGui::Text("notes.txt");
        ImGui::TreePop();
    }
    ImGui::TreePop();
}
```

### Tables

```cpp
if (ImGui::BeginTable("processes", 4,
        ImGuiTableFlags_Sortable | ImGuiTableFlags_Borders)) {
    ImGui::TableSetupColumn("PID");
    ImGui::TableSetupColumn("Name");
    ImGui::TableSetupColumn("CPU %");
    ImGui::TableSetupColumn("Memory");
    ImGui::TableHeadersRow();

    for (auto& proc : processes) {
        ImGui::TableNextRow();
        ImGui::TableNextColumn(); ImGui::Text("%d", proc.pid);
        ImGui::TableNextColumn(); ImGui::Text("%s", proc.name);
        ImGui::TableNextColumn(); ImGui::Text("%.1f%%", proc.cpu);
        ImGui::TableNextColumn(); ImGui::Text("%s", proc.memory);
    }
    ImGui::EndTable();
}
```

### Menus

```cpp
if (ImGui::BeginMainMenuBar()) {
    if (ImGui::BeginMenu("File")) {
        if (ImGui::MenuItem("Open", "Ctrl+O"))  openFile();
        if (ImGui::MenuItem("Save", "Ctrl+S"))  saveFile();
        ImGui::Separator();
        if (ImGui::MenuItem("Quit", "Ctrl+Q"))  quit = true;
        ImGui::EndMenu();
    }
    if (ImGui::BeginMenu("Edit")) {
        if (ImGui::MenuItem("Undo", "Ctrl+Z"))  undo();
        if (ImGui::MenuItem("Redo", "Ctrl+Y"))  redo();
        ImGui::EndMenu();
    }
    ImGui::EndMainMenuBar();
}
```

### Popups and Modals

```cpp
if (ImGui::Button("Delete"))
    ImGui::OpenPopup("Confirm Delete");

if (ImGui::BeginPopupModal("Confirm Delete", nullptr,
        ImGuiWindowFlags_AlwaysAutoResize)) {
    ImGui::Text("Are you sure you want to delete this item?");
    ImGui::Separator();
    if (ImGui::Button("Yes", ImVec2(120, 0))) {
        deleteItem();
        ImGui::CloseCurrentPopup();
    }
    ImGui::SameLine();
    if (ImGui::Button("Cancel", ImVec2(120, 0)))
        ImGui::CloseCurrentPopup();
    ImGui::EndPopup();
}
```

### Tabs

```cpp
if (ImGui::BeginTabBar("MyTabs")) {
    if (ImGui::BeginTabItem("General")) {
        ImGui::Text("General settings here");
        ImGui::EndTabItem();
    }
    if (ImGui::BeginTabItem("Advanced")) {
        ImGui::Text("Advanced settings here");
        ImGui::EndTabItem();
    }
    ImGui::EndTabBar();
}
```

### Plots

```cpp
static float values[60] = {};
static int offset = 0;
values[offset] = sinf(offset * 0.1f);
offset = (offset + 1) % 60;

ImGui::PlotLines("Sin wave", values, 60, offset, nullptr, -1.0f, 1.0f, ImVec2(0, 40));
ImGui::PlotHistogram("Histogram", values, 60, 0, nullptr, -1.0f, 1.0f, ImVec2(0, 40));
```

### "Custom Widgets"

In Dear ImGui, there is no widget base class to inherit from. A "custom widget" is just a
function that calls ImGui drawing and interaction primitives:

```cpp
bool ToggleSwitch(const char* label, bool* value) {
    ImGui::Text("%s", label);
    ImGui::SameLine();
    if (ImGui::Button(*value ? "[ON ]" : "[OFF]")) {
        *value = !*value;
        return true;  // value changed
    }
    return false;
}
```

### Complete Application Example

```cpp
#include "imtui/imtui.h"
#include "imtui/imtui-impl-ncurses.h"

int main() {
    IMGUI_CHECKVERSION();
    ImGui::CreateContext();

    auto screen = ImTui_ImplNcurses_Init(true);
    ImTui_ImplText_Init();

    // Application state -- owned entirely by the application
    bool running = true;
    char searchBuf[256] = "";
    int selected = -1;
    float volume = 0.5f;
    bool darkMode = true;

    while (running) {
        ImTui_ImplNcurses_NewFrame();
        ImTui_ImplText_NewFrame();
        ImGui::NewFrame();

        ImGui::Begin("My App");
        ImGui::InputText("Search", searchBuf, sizeof(searchBuf));
        ImGui::SliderFloat("Volume", &volume, 0.0f, 1.0f);
        ImGui::Checkbox("Dark mode", &darkMode);

        if (ImGui::Button("Quit"))
            running = false;
        ImGui::End();

        ImGui::Render();
        ImTui_ImplText_RenderDrawData(ImGui::GetDrawData(), screen);
        ImTui_ImplNcurses_DrawScreen();
    }

    ImTui_ImplText_Shutdown();
    ImTui_ImplNcurses_Shutdown();
    return 0;
}
```

---

## Styling

ImTui inherits Dear ImGui's style system, which is based on a global `ImGuiStyle` struct
containing colors, sizes, and spacing values.

### ImGuiStyle

The style struct contains ~55 color values (indexed by `ImGuiCol_` enum) and ~25 size/
spacing values. Key fields:

```cpp
ImGuiStyle& style = ImGui::GetStyle();

// Spacing and sizing
style.WindowPadding    = ImVec2(2, 1);    // padding inside windows
style.FramePadding     = ImVec2(1, 0);    // padding inside framed widgets
style.ItemSpacing      = ImVec2(1, 1);    // spacing between widgets
style.IndentSpacing    = 4.0f;            // indentation for tree nodes
style.ScrollbarSize    = 1.0f;            // scrollbar width

// Colors (set individually or via theme)
style.Colors[ImGuiCol_WindowBg]     = ImVec4(0.0f, 0.0f, 0.0f, 1.0f);
style.Colors[ImGuiCol_Text]         = ImVec4(1.0f, 1.0f, 1.0f, 1.0f);
style.Colors[ImGuiCol_Button]       = ImVec4(0.2f, 0.4f, 0.7f, 1.0f);
style.Colors[ImGuiCol_ButtonHovered]= ImVec4(0.3f, 0.5f, 0.8f, 1.0f);
style.Colors[ImGuiCol_ButtonActive] = ImVec4(0.1f, 0.3f, 0.6f, 1.0f);
```

### Scoped Style Changes (Push/Pop)

Temporary style overrides use a push/pop stack:

```cpp
// Change button color for one button
ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(0.8f, 0.1f, 0.1f, 1.0f));
ImGui::PushStyleColor(ImGuiCol_ButtonHovered, ImVec4(0.9f, 0.2f, 0.2f, 1.0f));
if (ImGui::Button("Delete"))
    deleteItem();
ImGui::PopStyleColor(2);  // pop both colors

// Change spacing temporarily
ImGui::PushStyleVar(ImGuiStyleVar_ItemSpacing, ImVec2(0, 0));
// ... tightly packed widgets ...
ImGui::PopStyleVar();
```

### Built-in Themes

```cpp
ImGui::StyleColorsDark();      // dark theme (default)
ImGui::StyleColorsLight();     // light theme
ImGui::StyleColorsClassic();   // classic ImGui gray theme
```

### Terminal Color Mapping

ImGui's colors are specified as `ImVec4` (RGBA float). ImTui's text backend converts these
to the ANSI 256-color palette via `rgbToAnsi256()`:

1. **Grayscale detection:** If R, G, B values are close (within a threshold), map to the
   24-step grayscale ramp (indices 232-255).
2. **RGB color cube:** Otherwise, quantize each channel to a 6-level scale and map to the
   6x6x6 color cube (indices 16-231).

This means ImGui's smooth color gradients and precise RGB values are approximated. Subtle
color differences in GPU-rendered ImGui may collapse to the same terminal color. ImTui's
`ImTui_ImplText_Init()` configures ImGui's style with terminal-appropriate defaults:
disabled anti-aliasing, minimal padding, and compact spacing.

---

## Event Handling

Event handling in ImTui is **fully integrated into the immediate-mode widget calls**. There
is no separate event system, no event bus, no callback registration, and no event
propagation/bubbling model.

### Widget Return Values

Interactive widgets return a boolean indicating whether they were activated or their value
changed:

```cpp
// Button: returns true on the frame it was clicked
if (ImGui::Button("Submit")) {
    submitForm();
}

// Checkbox: returns true when toggled (value is modified via pointer)
bool changed = ImGui::Checkbox("Enable logging", &loggingEnabled);

// Slider: returns true while the value is being dragged
if (ImGui::SliderFloat("Zoom", &zoom, 0.1f, 10.0f)) {
    applyZoom(zoom);
}

// Input text: returns true when the buffer is modified
if (ImGui::InputText("Search", buf, sizeof(buf))) {
    updateSearchResults(buf);
}

// Combo: returns true when selection changes
if (ImGui::Combo("Theme", &themeIdx, themes, numThemes)) {
    applyTheme(themeIdx);
}
```

### Item Query Functions

After any widget call, you can query its interaction state:

```cpp
ImGui::Button("Hover me");
if (ImGui::IsItemHovered()) {
    ImGui::SetTooltip("This is a tooltip");
}

ImGui::InputText("Name", buf, sizeof(buf));
if (ImGui::IsItemActive()) {
    // Input field is currently focused and accepting input
}
if (ImGui::IsItemDeactivatedAfterEdit()) {
    // User just finished editing (pressed Enter or clicked away)
    validateInput(buf);
}
```

### Keyboard Input

```cpp
ImGuiIO& io = ImGui::GetIO();

// Direct key state queries
if (ImGui::IsKeyPressed(ImGuiKey_Escape))
    closePopup();

if (ImGui::IsKeyPressed(ImGuiKey_Enter))
    submitForm();

// Modifier keys
if (io.KeyCtrl && ImGui::IsKeyPressed(ImGuiKey_S))
    saveFile();
```

### Mouse Input

```cpp
ImGuiIO& io = ImGui::GetIO();

// Mouse position (in terminal cell coordinates for ImTui)
float mouseX = io.MousePos.x;
float mouseY = io.MousePos.y;

// Mouse button states
bool leftDown = io.MouseDown[0];
bool rightDown = io.MouseDown[1];

// Double-click detection
if (ImGui::IsMouseDoubleClicked(0))
    openItem();
```

### No Event Propagation

There is no bubbling, no capturing, no event delegation. When `ImGui::Button("OK")` is
called, ImGui checks the mouse position against the button's bounding rectangle right then
and there. If the mouse is over the button and clicked, the function returns `true`. If the
button is behind another window, ImGui knows because it tracks window Z-order internally.
That is the entire event model.

---

## State Management

Application state management in ImTui is trivially simple because it follows Dear ImGui's
fundamental principle: **the application owns all state**.

### Application Owns Permanent State

Every piece of persistent data -- checkbox values, text buffers, slider positions, list
selections -- lives in application variables. ImGui functions take pointers or references to
these variables and modify them directly:

```cpp
// Application state
struct AppState {
    char username[128] = "";
    char password[128] = "";
    bool rememberMe = false;
    int themeChoice = 0;
    float fontSize = 14.0f;
    std::vector<std::string> items;
    int selectedItem = -1;
};

AppState state;

// In render loop -- ImGui reads/writes state directly
ImGui::InputText("Username", state.username, sizeof(state.username));
ImGui::InputText("Password", state.password, sizeof(state.password),
    ImGuiInputTextFlags_Password);
ImGui::Checkbox("Remember me", &state.rememberMe);
ImGui::SliderFloat("Font size", &state.fontSize, 8.0f, 24.0f);
```

There is no binding system, no observable properties, no signals/slots, no `setState()`
calls. The ImGui function reads the current value from the pointer, renders the widget
showing that value, and if the user interacts with the widget, writes the new value back
through the same pointer. This happens every frame.

### ImGui Holds Only Transient State

The `ImGuiContext` (created by `ImGui::CreateContext()`) holds only transient interaction
metadata:

- **Hot widget ID** -- which widget the mouse is currently over
- **Active widget ID** -- which widget is currently being interacted with
- **Input state** -- current mouse position, button states, keyboard state, text input
  buffer
- **Window state** -- positions, sizes, collapsed/expanded state, scroll offsets, Z-order
- **ID stack** -- current stack for generating unique widget identifiers

None of this is "application state" in the traditional sense. It is all interaction
bookkeeping that ImGui manages automatically.

### No State Synchronization Problem

Because the application state and the UI state are the same thing (the application variable
IS the widget's value), there is no synchronization problem. There is no possibility of the
UI showing a stale value, no need for dirty flags, no data binding bugs. The slider shows
whatever `state.fontSize` currently is, because it reads it directly every frame.

---

## Extensibility and Ecosystem

### Dear ImGui Ecosystem

Because ImTui is a backend for Dear ImGui, it inherits access to Dear ImGui's massive
ecosystem. Dear ImGui has over 1000 community extensions, including:

- **ImPlot** -- advanced plotting (line, scatter, bar, heatmap, etc.)
- **ImGuiFileDialog** -- file browser dialog
- **ImGuiColorTextEdit** -- syntax-highlighted text editor
- **ImNodes** -- node editor for visual programming interfaces
- **ImGuizmo** -- 3D gizmos for manipulation

However, extensions that rely heavily on pixel-precise rendering, anti-aliased lines, or
GPU textures will have degraded visual quality or may not function correctly in the terminal
context.

### ImTui-Specific

ImTui itself is minimal by design. Its specific additions beyond the backends are limited to
the `TScreen` data structure and the color conversion utilities. The value proposition is
that Dear ImGui itself provides everything needed.

### hnterm: A Complete Application

The hnterm example (Hacker News terminal client) demonstrates a production-quality
application built with ImTui:

- Queries the official Hacker News API via libcurl
- Displays stories, comments, and user profiles in navigable windows
- Supports split-view for browsing multiple stories simultaneously
- Fetches only currently visible content for efficiency
- Compiles to both native (ncurses) and web (Emscripten) targets
- Development has since moved to its own repository at
  <https://github.com/ggerganov/hnterm>

---

## Strengths

- **Zero widget boilerplate.** No classes to define, no constructors, no destructors, no
  inheritance hierarchies. A widget is a function call. A custom widget is a function you
  write.
- **UI code is extremely concise.** A complete interactive form with input fields, sliders,
  checkboxes, and buttons can be written in 10-20 lines of code.
- **Full Dear ImGui ecosystem.** Access to the entire ImGui widget library and 1000+
  community extensions, battle-tested across thousands of applications.
- **No callback hell.** Event handling is inline with rendering. There is no registration,
  no subscription, no handler maps. The code reads top to bottom.
- **Easy to prototype.** Building a terminal UI is as fast as writing a sequence of ImGui
  calls. Iteration is instant -- change a call, recompile, see the result.
- **State management is trivial.** The application owns all state as plain variables. No
  binding system, no state containers, no synchronization logic.
- **Live demos via WebAssembly.** The Emscripten backend allows ImTui applications to run
  in a web browser, making it easy to share and demonstrate applications.
- **Minimal dependencies.** Only ncurses for the terminal backend. No framework, no runtime,
  no build system complexity.
- **Active/idle frame rate optimization.** The ncurses backend supports different redraw
  rates for active and idle states, reducing CPU usage when there is no user input.

---

## Weaknesses and Limitations

- **Pixel-to-character mapping loses precision.** ImGui was designed for pixel-addressed
  displays. Mapping to a character grid means widgets are coarser, alignment is approximate,
  and the visual polish of GPU-rendered ImGui is lost.
- **Limited terminal color support.** ImGui's full RGBA color space is quantized to 256
  ANSI colors. Subtle color variations collapse; gradients become bands.
- **ncurses dependency.** The primary backend requires libncurses, which adds a system
  dependency and does not support all terminal features (e.g., true color, Kitty keyboard
  protocol, sixel graphics).
- **Cursor-based layout is limited for complex terminal UIs.** There is no constraint
  solver, no flexbox, no proportional sizing. Complex layouts require manual size
  calculations and careful use of child regions.
- **No styled text support.** ImGui's `Text()` renders plain monochrome text. There is no
  concept of inline styled spans (bold word within a sentence, colored substrings). The
  `TextColored()` function applies a single color to an entire text block.
- **No proper box-drawing characters.** ImGui renders borders using its own vector graphics
  (lines, rectangles). ImTui approximates these with ASCII characters rather than using
  Unicode box-drawing characters (e.g., `+--+` instead of `+---+`), which
  looks less polished than native terminal UIs.
- **ImGui's horizontal bias does not match terminal's vertical bias.** ImGui was designed
  for wide tool windows on a GPU display. Terminal UIs tend to be vertically oriented with
  narrow columns. ImGui's default spacing, padding, and widget sizing assumes more
  horizontal room than a typical terminal provides.
- **No accessibility.** Being a graphical rendering approach adapted for terminal, there is
  no semantic widget information exposed to screen readers or other assistive technology.
- **Stale Dear ImGui version.** ImTui bundles ImGui v1.81, which is several versions behind
  the latest Dear ImGui releases. Newer ImGui features (docking, multi-viewport, improved
  tables) are not available.

---

## Lessons for D / Sparkles

This section maps ImTui/Dear ImGui patterns to D idioms, exploring how the pure
immediate-mode paradigm could inform Sparkles' design.

### Pure Immediate-Mode as a Rapid Prototyping Layer

D could support an ImGui-like API layer for rapid terminal UI prototyping. The core idea:
UI is a function of your data, called every frame, with zero retained state.

```d
// Hypothetical Sparkles immediate-mode API
void renderUI(ref AppState state, ref TerminalBuffer buf) @nogc {
    if (button(buf, "Submit"))
        state.submit();

    sliderInt(buf, "Volume", &state.volume, 0, 100);
    checkbox(buf, "Mute", &state.muted);

    if (inputText(buf, "Search", state.searchBuf[]))
        state.updateResults();
}
```

This would complement (not replace) a more structured widget system. The immediate-mode
layer is ideal for quick tools, debug UIs, and configuration panels where visual polish
matters less than development speed.

### Widget-as-Function-Call

In the ImGui model, there are no traits, no interfaces, no objects. A widget is just a
function that writes to a buffer and returns interaction state. In D:

```d
/// A button that returns true when clicked.
/// Zero allocations, zero retained state.
bool button(ref TerminalBuffer buf, string label) @safe pure nothrow @nogc {
    auto rect = layoutNext(buf, label.length + 2, 1);
    bool hovered = isMouseOver(rect);
    bool clicked = hovered && mouseClicked();

    auto style = hovered ? Style.highlighted : Style.normal;
    buf.putString(rect.x, rect.y, label, style);

    return clicked;
}
```

No widget type to implement. No render method to override. Just a `@nogc` function
returning `bool` for activation. This is the most minimal possible widget API.

### Hot/Active Model with Compile-Time Widget IDs

ImGui identifies widgets by hashing their string labels. D could use compile-time string
hashing for zero-cost widget IDs:

```d
/// Widget ID generated at compile time from source location.
WidgetId widgetId(string label = "", string file = __FILE__, size_t line = __LINE__)() {
    enum id = hashOf(label ~ file ~ line.stringof);
    return WidgetId(id);
}

bool button(string label = "", string file = __FILE__, size_t line = __LINE__)(
    ref TerminalBuffer buf
) @safe pure nothrow @nogc {
    enum id = hashOf(label ~ file ~ line.stringof);
    auto rect = layoutNext(buf, label.length + 2, 1);

    bool hovered = isMouseOver(rect);
    if (hovered) setHot(id);
    if (hovered && mouseClicked()) setActive(id);
    bool activated = isActive(id) && mouseReleased();

    // ...render...
    return activated;
}
```

Using `__FILE__` and `__LINE__` as template parameters gives each call site a unique ID at
compile time with zero runtime overhead -- no string hashing per frame.

### Direct State Mutation via `ref` Parameters

ImGui's `InputText("Name", &myString)` pattern maps directly to D:

```d
bool inputText(ref TerminalBuffer buf, string label, char[] buffer) @nogc {
    // Render input field, handle keyboard input
    // Directly modify buffer contents
    return changed;
}

// Usage: state is mutated in place
inputText(buf, "Name", state.name[]);
sliderFloat(buf, "Volume", &state.volume, 0.0f, 1.0f);
checkbox(buf, "Mute", &state.muted);
```

Passing `ref` or pointer parameters is natural in D and avoids any need for a binding or
synchronization system. The function directly reads and writes the application's state.

### Push/Pop Style Stacks with `scope(exit)`

ImGui's `PushStyleColor` / `PopStyleColor` maps elegantly to D's `scope` guards:

```d
/// RAII-style color push that auto-pops.
auto pushColor(ref StyleStack stack, StyleColor idx, Color color) @nogc {
    stack.push(idx, color);
    struct Guard {
        StyleStack* s;
        ~this() @nogc { s.pop(); }
    }
    return Guard(&stack);
}

// Usage with scope(exit) -- cannot forget to pop
{
    auto _ = pushColor(styleStack, StyleColor.button, Color.red);
    // Everything in this scope renders with red buttons
    if (button(buf, "Delete"))
        deleteItem();
}  // auto-pops here
```

Alternatively, using D's `scope(exit)` directly:

```d
styleStack.pushColor(StyleColor.button, Color.red);
scope(exit) styleStack.popColor();
```

Both approaches prevent the "forgot to pop" bugs that plague C++ ImGui code.

### No Retained State Means @nogc Friendly

The entire immediate-mode render pass can be `@nogc` because there is no widget tree to
allocate. Each frame:

1. Read application state (plain variables, `@nogc`)
2. Call widget functions that write to a fixed-size terminal buffer (`@nogc`)
3. Diff the buffer against the previous frame (`@nogc`)
4. Write changed cells to the terminal (`@nogc` or `@trusted` for syscalls)

There is no `new`, no GC array append, no class instantiation anywhere in the hot path.
This makes immediate-mode a natural fit for Sparkles' `@nogc` philosophy and `SmallBuffer`
infrastructure.

### ImGui ID System via D's `__LINE__` and `__FILE__`

ImGui requires unique widget IDs to track interaction state across frames. In C++, this is
done by hashing string labels at runtime. In D, the same can be achieved at compile time
with zero runtime cost:

```d
/// Each call site gets a unique ID at compile time.
bool button(string file = __FILE__, size_t line = __LINE__)(
    ref TerminalBuffer buf, string label
) @safe pure nothrow @nogc {
    // ID is computed at compile time -- zero runtime cost
    enum id = hashCombine(fnv1aHash(file), line);
    // ... use id for hot/active tracking ...
}
```

For dynamic widget lists (e.g., buttons generated in a loop), the application can push
additional ID components:

```d
foreach (i, item; items) {
    idStack.push(i);
    scope(exit) idStack.pop();
    if (button(buf, item.name))
        selectItem(i);
}
```

---

## References

- **ImTui Repository:** <https://github.com/ggerganov/imtui>
- **Dear ImGui:** <https://github.com/ocornut/imgui>
- **Dear ImGui Documentation:** <https://github.com/ocornut/imgui/wiki>
- **Dear ImGui Demo:** <https://github.com/ocornut/imgui/blob/master/imgui_demo.cpp>
  (comprehensive widget reference)
- **hnterm (Hacker News terminal client):** <https://github.com/ggerganov/hnterm>
- **hnterm Live Web Demo:** <https://hnterm.ggerganov.com>
- **Dear ImGui ID System:** <https://github.com/ocornut/imgui/wiki/FAQ#q-why-is-my-widget-not-reacting-when-i-click-on-it>
- **Dear ImGui Style Reference:** <https://github.com/ocornut/imgui/issues/707>
  (community style gallery)
- **ImGui Immediate-Mode GUI Introduction:**
  Casey Muratori's original talk: <https://caseymuratori.com/blog_0001>
